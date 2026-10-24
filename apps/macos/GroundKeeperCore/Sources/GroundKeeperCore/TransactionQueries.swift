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
    public var matchingCategoryCodes: [String] = []
    public var matchingTypeCodes: [String] = []
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

extension LedgerStore {
    static let ledgerTransactionSQL = """
        SELECT t.*,p.id AS part_id,a.type_code,a.category_id,a.needs_review,a.origin,ac.name AS account_name,
        EXISTS(SELECT 1 FROM review_items r WHERE r.status='open' AND (r.transaction_id=t.id OR r.part_id=p.id OR r.event_id IN
          (SELECT event_id FROM transaction_event_links WHERE transaction_id=t.id AND unlinked_at_ms IS NULL))) AS open_review,
        (SELECT group_concat(DISTINCT s.kind) FROM transaction_event_links l JOIN raw_events e ON e.id=l.event_id
          JOIN sources s ON s.id=e.source_id WHERE l.transaction_id=t.id AND l.unlinked_at_ms IS NULL) AS sources
        FROM transactions t JOIN transaction_parts p ON p.transaction_id=t.id
        JOIN category_assignments a ON a.id=p.current_assignment_id LEFT JOIN accounts ac ON ac.id=t.account_id
        """

    static func ledgerTransaction(_ row: Row) -> LedgerTransaction {
        LedgerTransaction(id: row.text("id"), partID: row.text("part_id"), revision: Int(row.number("revision")),
            description: row.text("description"), amountMinor: row.number("amount_minor"), currency: row.text("currency"), occurredOn: row.text("occurred_on"),
            accountID: row["account_id"]?.string, accountName: row["account_name"]?.string ?? "Unassigned", type: row.text("type_code"), category: row["category_id"]?.string,
            needsReview: row.number("needs_review") == 1 || row.number("open_review") == 1, notes: row.text("notes"), sources: row["sources"]?.string ?? "manual", origin: row.text("origin"))
    }

    public func transactionPage(_ query: LedgerTransactionQuery, limit: Int = 500, offset: Int = 0) throws -> LedgerTransactionPage {
        let size = max(1, min(limit, 5000))
        var predicates = ["state='active'"], bindings: [SQLValue] = []
        if query.reviewOnly { predicates.append("(needs_review=1 OR open_review=1)") }
        if let category = query.category {
            predicates.append("type_code IN ('expense','refund','unknown') AND coalesce(category_id,'uncategorized')=?")
            bindings.append(.text(category))
        }
        if let account = query.accountID { predicates.append("account_id=?"); bindings.append(.text(account)) }
        if !query.search.isEmpty {
            var search = ["gk_ledger_contains(description || ' ' || notes, ?)"]
            bindings.append(.text(query.search))
            if !query.matchingCategoryCodes.isEmpty {
                search.append("coalesce(category_id,'uncategorized') IN (\(Array(repeating: "?", count: query.matchingCategoryCodes.count).joined(separator: ",")))")
                bindings += query.matchingCategoryCodes.map(SQLValue.text)
            }
            if !query.matchingTypeCodes.isEmpty {
                search.append("type_code IN (\(Array(repeating: "?", count: query.matchingTypeCodes.count).joined(separator: ",")))")
                bindings += query.matchingTypeCodes.map(SQLValue.text)
            }
            predicates.append("(" + search.joined(separator: " OR ") + ")")
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

    public func transactionReviewCount() throws -> Int {
        Int(try db.query("WITH ledger AS (\(Self.ledgerTransactionSQL)) SELECT count(DISTINCT id) AS n FROM ledger WHERE state='active' AND (needs_review=1 OR open_review=1)").first!.number("n"))
    }
}
