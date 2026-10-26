import Foundation

extension LedgerStore {
    /// Statement dates may be posting dates. These are suggestions for explicit
    /// review, never an amount/date rule that automatically merges purchases.
    func statementCandidates(_ observation: Observation, kind: String) throws -> [Row] {
        try Self.statementCandidates(db: db, observation: observation, kind: kind)
    }
    static func statementCandidates(db: Database, observation: Observation, kind: String) throws -> [Row] {
        guard ["csv", "apple_wallet", "bank_notification"].contains(kind) else { return [] }
        let evidence = kind == "csv"
            ? "s.kind IN ('apple_wallet','bank_notification')"
            : "s.kind='csv'"
        let excluded = kind == "csv" ? "csv" : kind
        return try db.query("""
            SELECT t.id,t.description,t.lifecycle FROM transactions t
            WHERE t.state='active' AND t.account_id=? AND t.currency=? AND t.amount_minor=?
              AND abs(julianday(t.occurred_on)-julianday(?))<=7
              AND EXISTS(SELECT 1 FROM transaction_event_links l JOIN raw_events e ON e.id=l.event_id
                JOIN sources s ON s.id=e.source_id WHERE l.transaction_id=t.id AND l.unlinked_at_ms IS NULL AND \(evidence))
              AND NOT EXISTS(SELECT 1 FROM transaction_event_links l JOIN raw_events e ON e.id=l.event_id
                JOIN sources s ON s.id=e.source_id WHERE l.transaction_id=t.id AND l.unlinked_at_ms IS NULL AND s.kind=?)
            ORDER BY abs(julianday(t.occurred_on)-julianday(?)),t.description,t.id
            """, [.optional(observation.accountID), .optional(observation.currency), .optional(observation.amount),
                   .text(observation.day), .text(excluded), .text(observation.day)])
    }

    /// Also makes older, already-imported duplicates discoverable from Details.
    public func savedStatementMatches(transactionID: String) throws -> [CaptureReconciliationCandidate] {
        guard let t = try transaction(id: transactionID) else { return [] }
        let kinds = Set(t.sources.split(separator: ",").map(String.init))
        guard kinds.contains("csv") != (!kinds.isDisjoint(with: ["apple_wallet", "bank_notification"])) else { return [] }
        let observation = Observation(description: t.description, amount: t.amountMinor, currency: t.currency,
            day: t.occurredOn, captured: 0, offset: 0, accountID: t.accountID, label: "", lifecycle: "posted")
        let rows = try statementCandidates(observation, kind: kinds.contains("csv") ? "csv" : kinds.contains("bank_notification") ? "bank_notification" : "apple_wallet")
        return try captureReconciliationCandidates(transactionIDs: rows.map { $0.text("id") }.filter { $0 != transactionID })
    }

    /// Keep the selected entry's description, purchase date and categorization.
    /// Move evidence atomically; the merged entry and its assignment history remain.
    public func mergeStatementMatch(transactionID: String, otherID: String, revision: Int, otherRevision: Int) throws {
        try db.transaction {
            guard let target = try transaction(id: transactionID), let other = try transaction(id: otherID),
                  target.revision == revision, other.revision == otherRevision,
                  try savedStatementMatches(transactionID: transactionID).contains(where: { $0.id == otherID }) else { throw LedgerError.conflict }
            let parts = try db.query("SELECT transaction_id,id FROM transaction_parts WHERE transaction_id IN (?,?)", [.text(transactionID), .text(otherID)])
            guard parts.count == 2 else { throw LedgerError.invalid("Split entries must be reconciled separately.") }
            let targetPart = parts.first { $0.text("transaction_id") == transactionID }!.text("id")
            let otherPart = parts.first { $0.text("transaction_id") == otherID }!.text("id")
            let decision = identifier(), stamp = nowMS()
            try db.query("INSERT INTO reconciliation_decisions(id,left_transaction_id,right_transaction_id,action,actor,algorithm_version,evidence_json,created_at_ms) VALUES (?,?,?,'merge','user','statement-review-v1','{}',?)",
                [.text(decision), .text(transactionID), .text(otherID), .integer(stamp)])
            for link in try db.query("SELECT * FROM transaction_event_links WHERE transaction_id=? AND unlinked_at_ms IS NULL", [.text(otherID)]) {
                try db.query("UPDATE transaction_event_links SET unlinked_at_ms=? WHERE id=?", [.integer(stamp), .text(link.text("id"))])
                try db.query("INSERT INTO transaction_event_links(id,transaction_id,event_id,observation_id,role,decision_id,linked_at_ms) VALUES (?,?,?,?,?,?,?)",
                    [.text(identifier()), .text(transactionID), .text(link.text("event_id")), .text(link.text("observation_id")), .text(link.text("role")), .text(decision), .integer(stamp)])
            }
            try db.query("UPDATE receipt_captures SET transaction_id=? WHERE transaction_id=?", [.text(transactionID), .text(otherID)])
            try db.query("UPDATE capture_note_imports SET transaction_id=? WHERE transaction_id=?", [.text(transactionID), .text(otherID)])
            try db.query("UPDATE transactions SET selected_geotag_id=NULL WHERE id=?", [.text(otherID)])
            try db.query("UPDATE geotags SET transaction_id=? WHERE transaction_id=?", [.text(transactionID), .text(otherID)])
            try db.query("UPDATE external_transaction_refs SET transaction_id=? WHERE transaction_id=?", [.text(transactionID), .text(otherID)])
            try db.query("INSERT OR IGNORE INTO transaction_tags SELECT ?,tag_id FROM transaction_tags WHERE transaction_id=?", [.text(transactionID), .text(otherID)])
            try db.query("INSERT OR IGNORE INTO part_tags SELECT ?,tag_id FROM part_tags WHERE part_id=?", [.text(targetPart), .text(otherPart)])
            try db.query("UPDATE review_items SET transaction_id=? WHERE transaction_id=?", [.text(transactionID), .text(otherID)])
            try db.query("UPDATE review_items SET part_id=? WHERE part_id=?", [.text(targetPart), .text(otherPart)])
            let notes = other.notes.isEmpty || other.notes == target.notes ? target.notes : target.notes.isEmpty ? other.notes : target.notes + "\n\n" + other.notes
            let posted = try db.query("SELECT posted_on FROM transactions WHERE id IN (?,?) AND lifecycle='posted' ORDER BY posted_on DESC LIMIT 1", [.text(transactionID), .text(otherID)]).first
            try db.query("UPDATE transactions SET notes=?,lifecycle=CASE WHEN ? THEN 'posted' ELSE lifecycle END,posted_on=coalesce(?,posted_on) WHERE id=?",
                [.text(notes), .integer(posted == nil ? 0 : 1), .optional(posted?["posted_on"]?.string), .text(transactionID)])
            try db.query("UPDATE transactions SET state='merged',merged_into_id=?,revision=revision+1,updated_at_ms=? WHERE id=?", [.text(transactionID), .integer(stamp), .text(otherID)])
            try db.query("UPDATE classification_jobs SET status='obsolete' WHERE part_id=? AND status IN ('pending','running')", [.text(otherPart)])
            try receiptEvidenceChanged(transactionID: transactionID)
            try db.query("INSERT INTO change_log(id,operation_id,entity_type,entity_id,actor,reason,changed_at_ms,before_json,after_json) VALUES (?,?,'transaction',?,'user','merge_statement',?,?,?)",
                [.text(identifier()), .text(decision), .text(transactionID), .integer(stamp), .text(try json(["other_id": otherID, "notes": target.notes])), .text(try json(["merged_id": otherID, "notes": notes]))])
        }
    }
}
