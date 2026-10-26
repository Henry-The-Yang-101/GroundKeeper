import Foundation

/// Latest parsed facts and the immutable source used to review a capture.
public struct CaptureReviewContext: Sendable {
    public let description: String
    public let amountMinor: Int64?
    public let currency: String?
    public let day: String
    public let accountID: String?
    public let accountName: String?
    public let payload: String
    public let sourceKind: String
}

public struct CaptureReconciliationCandidate: Identifiable, Sendable {
    public let id: String
    public let description: String
    public let amountMinor: Int64
    public let currency: String
    public let day: String
    public let accountID: String?
    public let accountName: String
    public let revision: Int
}

extension LedgerStore {
    /// Refresh eligibility as other reviews are resolved; a saved entry can still
    /// exist after it has already consumed its matching statement/capture.
    public func reviewCandidates(reviewID: String) throws -> [CaptureReconciliationCandidate] {
        guard let row = try db.query("""
            SELECT r.reason_code,r.details_json,o.*,e.source_id,e.captured_at_ms,e.captured_offset_minutes,s.kind
            FROM review_items r JOIN raw_events e ON e.id=r.event_id JOIN sources s ON s.id=e.source_id
            JOIN event_observations o ON o.id=(SELECT id FROM event_observations WHERE event_id=e.id ORDER BY parsed_at_ms DESC,rowid DESC LIMIT 1)
            WHERE r.id=? AND r.status='open'
            """, [.text(reviewID)]).first else { return [] }
        var ids = (try? JSONDecoder().decode([String].self, from: Data(row.text("details_json").utf8))) ?? []
        if ["possible_duplicate", "statement_match"].contains(row.text("reason_code")) {
            let observation = Observation(description: row.text("description"), amount: row["amount_minor"]?.int,
                currency: row["currency"]?.string, day: row.text("occurred_on"), captured: row.number("captured_at_ms"),
                offset: Int(row.number("captured_offset_minutes")), accountID: row["account_id"]?.string,
                label: row.text("instrument_text"), lifecycle: row.text("lifecycle"))
            let matches = try Self.duplicateCandidates(db: db, observation: observation, kind: row.text("kind"))
                + statementCandidates(observation, kind: row.text("kind"))
            ids = Array(Set(matches.map { $0.text("id") })).sorted()
        } else if ["external_id_conflict", "csv_mapping_changed"].contains(row.text("reason_code")) {
            let linked = try db.query("SELECT transaction_id FROM transaction_event_links WHERE event_id=? AND unlinked_at_ms IS NULL", [.text(row.text("event_id"))]).first
            let referenced = try db.query("SELECT transaction_id FROM external_transaction_refs WHERE source_id=? AND external_account_key=? AND namespace='csv-posted' AND external_record_id=?",
                [.text(row.text("source_id")), .text(row.text("account_id")), .text(row.text("external_record_id"))]).first
            ids = [linked?["transaction_id"]?.string ?? referenced?["transaction_id"]?.string].compactMap { $0 }
        }
        return try captureReconciliationCandidates(transactionIDs: ids)
    }

    public func captureReviewContext(eventID: String) throws -> CaptureReviewContext {
        guard let row = try db.query("""
            SELECT o.description,o.amount_minor,o.currency,o.occurred_on,o.account_id,a.name AS account_name,p.payload_json,s.kind AS source_kind
            FROM raw_events e JOIN sources s ON s.id=e.source_id JOIN raw_event_payloads p ON p.event_id=e.id
            JOIN event_observations o ON o.id=(SELECT id FROM event_observations WHERE event_id=e.id ORDER BY parsed_at_ms DESC,rowid DESC LIMIT 1)
            LEFT JOIN accounts a ON a.id=o.account_id WHERE e.id=? AND e.is_test=0
            """, [.text(eventID)]).first else {
            throw LedgerError.invalid("The original capture details are unavailable. Refresh Sync and try again.")
        }
        return CaptureReviewContext(description: row.text("description"), amountMinor: row["amount_minor"]?.int,
            currency: row["currency"]?.string, day: row.text("occurred_on"), accountID: row["account_id"]?.string,
            accountName: row["account_name"]?.string, payload: row.text("payload_json"), sourceKind: row.text("source_kind"))
    }

    /// Fetches candidates by identity, independently of the Transactions page.
    public func captureReconciliationCandidates(transactionIDs: [String]) throws -> [CaptureReconciliationCandidate] {
        try transactionIDs.compactMap { id in
            try db.query("""
                SELECT t.id,t.description,t.amount_minor,t.currency,t.occurred_on,t.account_id,a.name AS account_name,t.revision
                FROM transactions t LEFT JOIN accounts a ON a.id=t.account_id WHERE t.id=? AND t.state='active'
                """, [.text(id)]).first.map {
                    CaptureReconciliationCandidate(id: $0.text("id"), description: $0.text("description"),
                        amountMinor: $0.number("amount_minor"), currency: $0.text("currency"), day: $0.text("occurred_on"),
                        accountID: $0["account_id"]?.string, accountName: $0["account_name"]?.string ?? "Unassigned", revision: Int($0.number("revision")))
                }
        }
    }
}
