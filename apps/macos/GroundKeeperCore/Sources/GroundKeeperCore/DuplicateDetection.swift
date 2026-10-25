import Foundation

extension LedgerStore {
    /// Capture times identify the two automation deliveries of one purchase.
    /// CSV import/receipt arrival times are never purchase timestamps.
    static func duplicateCandidates(db: Database, observation: Observation, kind: String) throws -> [Row] {
        let complementary: String
        switch kind {
        case "apple_wallet": complementary = "bank_notification"
        case "bank_notification": complementary = "apple_wallet"
        default: return []
        }
        let candidates = try db.query("""
            SELECT t.id,t.description,t.lifecycle FROM transactions t
            WHERE t.state='active' AND t.account_id=? AND t.currency=? AND t.amount_minor=?
              AND EXISTS(SELECT 1 FROM transaction_event_links l
                JOIN raw_events e ON e.id=l.event_id JOIN sources s ON s.id=e.source_id
                WHERE l.transaction_id=t.id AND l.unlinked_at_ms IS NULL AND e.is_test=0
                  AND s.kind=? AND e.captured_at_ms BETWEEN ? AND ?)
              AND NOT EXISTS(SELECT 1 FROM transaction_event_links l
                JOIN raw_events e ON e.id=l.event_id JOIN sources s ON s.id=e.source_id
                WHERE l.transaction_id=t.id AND l.unlinked_at_ms IS NULL AND s.kind=?)
            """, [.optional(observation.accountID), .optional(observation.currency), .optional(observation.amount),
                  .text(complementary), .integer(observation.captured - 300_000),
                  .integer(observation.captured + 300_000), .text(kind)])
        return candidates.filter { normalize($0.text("description")) == normalize(observation.description) }
    }

    /// Recheck unresolved legacy flags on opening a vault. Previously linked or
    /// explicitly dismissed evidence is preserved. This also handles review ties
    /// whose candidates have since been linked/deleted.
    static func repairDuplicateReviews(db: Database) throws {
        let reviews = try db.query("""
            SELECT r.id AS review_id,o.*,e.captured_at_ms,e.captured_offset_minutes,e.source_id,s.kind,
              EXISTS(SELECT 1 FROM transaction_event_links l WHERE l.event_id=e.id AND l.unlinked_at_ms IS NULL) AS linked
            FROM review_items r JOIN raw_events e ON e.id=r.event_id JOIN sources s ON s.id=e.source_id
            JOIN event_observations o ON o.id=(SELECT id FROM event_observations WHERE event_id=e.id
              ORDER BY parsed_at_ms DESC,rowid DESC LIMIT 1)
            WHERE r.status='open' AND r.reason_code='possible_duplicate' AND e.is_test=0
            ORDER BY r.created_at_ms,r.id
            """)
        for row in reviews {
            let observation = Observation(description: row.text("description"), amount: row["amount_minor"]?.int,
                currency: row["currency"]?.string, day: row.text("occurred_on"), captured: row.number("captured_at_ms"),
                offset: Int(row.number("captured_offset_minutes")), accountID: row["account_id"]?.string,
                label: row.text("instrument_text"), lifecycle: row.text("lifecycle"),
                dateOnly: row.text("time_precision") == "date", externalID: row["external_record_id"]?.string)
            guard row.text("status") == "parsed", observation.amount != nil,
                  observation.currency != nil, observation.accountID != nil else { continue }
            let candidates = try duplicateCandidates(db: db, observation: observation, kind: row.text("kind"))
            if row.number("linked") == 0, !candidates.isEmpty {
                try db.query("UPDATE review_items SET details_json=? WHERE id=?",
                    [.text(try json(candidates.map { $0.text("id") })), .text(row.text("review_id"))])
                continue
            }
            if row.number("linked") == 0 {
                let transactionID = try createTransaction(db: db, observation: observation), decisionID = identifier()
                try db.query("INSERT INTO reconciliation_decisions(id,event_id,left_transaction_id,action,actor,algorithm_version,evidence_json,created_at_ms) VALUES (?,?,?,'link','system','automation-window-v2','{}',?)",
                    [.text(decisionID), .text(row.text("event_id")), .text(transactionID), .integer(nowMS())])
                try db.query("INSERT INTO transaction_event_links(id,transaction_id,event_id,observation_id,role,decision_id,linked_at_ms) VALUES (?,?,?,?,?,?,?)",
                    [.text(identifier()), .text(transactionID), .text(row.text("event_id")), .text(row.text("id")),
                     .text(row.text("kind") == "csv" ? "posted" : "capture"), .text(decisionID), .integer(nowMS())])
                if let external = observation.externalID {
                    try db.query("INSERT OR IGNORE INTO external_transaction_refs(id,source_id,external_account_key,namespace,external_record_id,transaction_id,first_event_id) VALUES (?,?,?,'csv-posted',?,?,?)",
                        [.text(identifier()), .text(row.text("source_id")), .text(observation.accountID!), .text(external),
                         .text(transactionID), .text(row.text("event_id"))])
                }
            }
            try db.query("UPDATE review_items SET status='resolved',resolved_at_ms=?,resolution='automation_window_recheck' WHERE id=?",
                [.integer(nowMS()), .text(row.text("review_id"))])
        }
    }
}
