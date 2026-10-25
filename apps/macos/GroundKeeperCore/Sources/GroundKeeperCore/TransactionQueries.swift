import Foundation

public struct LedgerTransactionSort: Equatable, Sendable {
    public enum Column: String, Sendable { case date, merchant, amount }
    public var column: Column
    public var descending: Bool
    public init(_ column: Column, descending: Bool = false) { self.column = column; self.descending = descending }
}

/// Filters and sorting apply to the entire ledger before the result page is selected.
public struct LedgerTransactionQuery: Equatable, Sendable {
    public var search = ""
    public var categoryNames: [String: String] = [:]
    public var typeNames: [String: String] = [:]
    public var category: String?
    public var accountID: String?
    public var reviewOnly = false
    public var sort = [LedgerTransactionSort(.date, descending: true)]
    public init() {}
}

public struct LedgerTransactionPage: Sendable {
    public let transactions: [LedgerTransaction]
    public let totalMatches: Int
    public let offset: Int
}

public struct LedgerWorkspaceSnapshot: Sendable {
    public let ledger: LedgerSnapshot
    public let page: LedgerTransactionPage
    public let reviewCount: Int
    public let unqueuedJobs: Int
    public let reportingRevision: Int64
}

extension LedgerStore {
    static let ledgerTransactionSQL = """
        SELECT t.*,p.id AS part_id,a.type_code,a.category_id,a.needs_review,a.origin,ac.name AS account_name,
        m.model_name AS category_model_name,m.provider AS category_model_provider,
        g.latitude AS location_latitude,g.longitude AS location_longitude,
        g.horizontal_accuracy_m AS location_accuracy,g.label AS location_label,
        EXISTS(SELECT 1 FROM receipt_captures r JOIN receipt_images i ON i.receipt_id=r.id
          WHERE r.transaction_id=t.id AND r.removed_at_ms IS NULL AND r.image_state='stored') AS has_receipt_image,
        EXISTS(SELECT 1 FROM review_items r WHERE r.status='open' AND (r.transaction_id=t.id OR r.part_id=p.id OR r.event_id IN
          (SELECT event_id FROM transaction_event_links WHERE transaction_id=t.id AND unlinked_at_ms IS NULL))) AS open_review,
        (SELECT group_concat(DISTINCT s.kind) FROM transaction_event_links l JOIN raw_events e ON e.id=l.event_id
          JOIN sources s ON s.id=e.source_id WHERE l.transaction_id=t.id AND l.unlinked_at_ms IS NULL) AS sources
        FROM transactions t JOIN transaction_parts p ON p.transaction_id=t.id
        JOIN category_assignments a ON a.id=p.current_assignment_id LEFT JOIN accounts ac ON ac.id=t.account_id
        LEFT JOIN classification_runs cr ON cr.id=a.run_id
        LEFT JOIN model_versions m ON m.id=cr.model_version_id
        LEFT JOIN geotags g ON g.id=coalesce(t.selected_geotag_id,
          (SELECT id FROM geotags WHERE transaction_id=t.id ORDER BY measured_at_ms DESC,id LIMIT 1),
          (SELECT geo.id FROM geotags geo JOIN transaction_event_links link ON link.event_id=geo.event_id
            WHERE link.transaction_id=t.id AND link.unlinked_at_ms IS NULL ORDER BY geo.measured_at_ms DESC,geo.id LIMIT 1))
        """

    static func ledgerTransaction(_ row: Row) -> LedgerTransaction {
        LedgerTransaction(id: row.text("id"), partID: row.text("part_id"), revision: Int(row.number("revision")),
            description: row.text("description"), amountMinor: row.number("amount_minor"), currency: row.text("currency"), occurredOn: row.text("occurred_on"),
            accountID: row["account_id"]?.string, accountName: row["account_name"]?.string ?? "Unassigned", type: row.text("type_code"), category: row["category_id"]?.string,
            needsReview: row.number("needs_review") == 1 || row.number("open_review") == 1, notes: row.text("notes"), sources: row["sources"]?.string ?? "manual", origin: row.text("origin"),
            categoryModelName: row["category_model_name"]?.string, categoryModelProvider: row["category_model_provider"]?.string,
            location: location(row), hasReceiptImage: row.number("has_receipt_image") == 1)
    }

    private static func location(_ row: Row) -> TransactionLocation? {
        guard let latitude = row["location_latitude"]?.string.flatMap(Double.init),
              let longitude = row["location_longitude"]?.string.flatMap(Double.init),
              latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return TransactionLocation(latitude: latitude, longitude: longitude,
            accuracyMeters: row["location_accuracy"]?.string.flatMap(Double.init), label: row["location_label"]?.string)
    }

    public func transactionPage(_ query: LedgerTransactionQuery, limit: Int = 500, offset: Int = 0) throws -> LedgerTransactionPage {
        let size = max(1, min(limit, 5000))
        var predicates = ["state='active'"], bindings: [SQLValue] = []
        if query.reviewOnly { predicates.append("(needs_review=1 OR open_review=1)") }
        if let category = query.category {
            if category == "none" { predicates.append("category_id IS NULL") }
            else { predicates.append("category_id=?"); bindings.append(.text(category)) }
        }
        if let account = query.accountID { predicates.append("account_id=?"); bindings.append(.text(account)) }
        if !query.search.isEmpty {
            // Keep the same combined display-text search as the transaction table.
            func displayName(_ column: String, names: [String: String]) -> String {
                guard !names.isEmpty else { return column }
                let clauses = names.sorted { $0.key < $1.key }.map { key, value in
                    bindings += [.text(key), .text(value)]
                    return "WHEN ? THEN ?"
                }.joined(separator: " ")
                return "CASE \(column) \(clauses) ELSE \(column) END"
            }
            let category = displayName("coalesce(category_id,'none')", names: query.categoryNames)
            let type = displayName("type_code", names: query.typeNames)
            predicates.append("gk_ledger_contains(description || ' ' || notes || ' ' || (\(category)) || ' ' || (\(type)), ?)")
            bindings.append(.text(query.search))
        }
        let source = "WITH ledger AS (\(Self.ledgerTransactionSQL)) ", condition = predicates.joined(separator: " AND ")
        let total = Int(try db.query(source + "SELECT count(*) AS n FROM ledger WHERE " + condition, bindings).first!.number("n"))
        let start = min(max(0, offset) / size * size, max(0, (total - 1) / size) * size)
        let sorts = query.sort.map { sort in
            let column = switch sort.column { case .date: "occurred_on"; case .merchant: "description COLLATE NOCASE"; case .amount: "abs(amount_minor)" }
            return column + (sort.descending ? " DESC" : " ASC")
        } + ["id ASC"]
        let rows = try db.query(source + "SELECT * FROM ledger WHERE " + condition + " ORDER BY " + sorts.joined(separator: ",") + " LIMIT ? OFFSET ?",
            bindings + [.integer(Int64(size)), .integer(Int64(start))])
        return LedgerTransactionPage(transactions: rows.map(Self.ledgerTransaction), totalMatches: total, offset: start)
    }

    /// One actor turn keeps dashboard totals, recent entries, and the query page consistent.
    public func workspaceSnapshot(_ query: LedgerTransactionQuery, limit: Int = 500, offset: Int = 0) throws -> LedgerWorkspaceSnapshot {
        LedgerWorkspaceSnapshot(ledger: try snapshot(limit: 5), page: try transactionPage(query, limit: limit, offset: offset),
            reviewCount: try transactionReviewCount(), unqueuedJobs: try unqueuedClassificationCount(), reportingRevision: try spendingRevision())
    }

    public func transaction(id: String) throws -> LedgerTransaction? {
        try db.query(Self.ledgerTransactionSQL + " WHERE t.state='active' AND t.id=?", [.text(id)]).first.map(Self.ledgerTransaction)
    }

    public func transactionReviewCount() throws -> Int {
        Int(try db.query("WITH ledger AS (\(Self.ledgerTransactionSQL)) SELECT count(DISTINCT id) AS n FROM ledger WHERE state='active' AND (needs_review=1 OR open_review=1)").first!.number("n"))
    }
}
