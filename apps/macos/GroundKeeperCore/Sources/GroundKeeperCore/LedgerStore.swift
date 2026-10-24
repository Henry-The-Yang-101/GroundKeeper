import Foundation

/// Serializes all writers. No transaction spans an await or an inference call.
public actor LedgerStore {
    let db: Database
    public init(url: URL, passphrase: String? = nil) throws {
        let db = try Database(url: url, passphrase: passphrase)
        // This is a single-process, single-writer vault. Recover work interrupted by quit/crash.
        try db.transaction {
            try db.query("UPDATE classification_runs SET status='unavailable',error_code='interrupted',finished_at_ms=? WHERE status='running'", [.integer(nowMS())])
            try db.query("UPDATE classification_jobs SET status=CASE WHEN attempts>=3 THEN 'failed' ELSE 'pending' END,error_code='interrupted',next_attempt_at_ms=0 WHERE status='running'")
            try db.query("UPDATE processing_runs SET status='interrupted',finished_at_ms=? WHERE status='running'", [.integer(nowMS())])
            try db.query("INSERT OR IGNORE INTO sources(id,kind,name,created_at_ms) VALUES ('manual','manual','Manual entry',?)", [.integer(nowMS())])
        }
        try db.transaction {
            for row in try db.query("SELECT id,description FROM transactions WHERE merchant_resolved=0") {
                try Self.resolveMerchant(db: db, transactionID: row.text("id"), description: row.text("description"))
            }
        }
        self.db = db
    }
    public func integrityCheck() throws -> Bool {
        try db.query("PRAGMA integrity_check").first?.text("integrity_check") == "ok" && db.query("PRAGMA foreign_key_check").isEmpty
    }
    public func close() { db.close() }
    public func verifyPassphrase(_ passphrase: String) throws { try db.verifyPassphrase(passphrase) }
    public func changeEncryption(to passphrase: String?) throws { try db.changeEncryption(to: passphrase) }
    public func addAccount(name: String, currency: String, kind: String = "credit_card") throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 100, ExactMoney.currencies.contains(currency),
              ["credit_card", "checking", "cash", "savings", "other"].contains(kind) else { throw LedgerError.invalid("Enter an account name, currency and valid account type.") }
        try db.query("INSERT INTO accounts(id,name,kind,currency,created_at_ms) VALUES (?,?,?,?,?)", [.text(identifier()), .text(name), .text(kind), .text(currency), .integer(nowMS())])
    }
    func account(_ id: String) throws -> Account? {
        try db.query("SELECT id,name,currency FROM accounts WHERE id=?", [.text(id)]).first.map { Account(id: $0.text("id"), name: $0.text("name"), currency: $0.text("currency")) }
    }
    public func snapshot(limit: Int = 500, offset: Int = 0) throws -> LedgerSnapshot {
        let accounts = try db.query("SELECT id,name,currency FROM accounts ORDER BY name,id").map { Account(id: $0.text("id"), name: $0.text("name"), currency: $0.text("currency")) }
        let rows = try db.query("""
            SELECT t.*,p.id AS part_id,a.type_code,a.category_id,a.needs_review,a.origin,ac.name AS account_name,
            EXISTS(SELECT 1 FROM review_items r WHERE r.status='open' AND (r.transaction_id=t.id OR r.part_id=p.id OR r.event_id IN
              (SELECT event_id FROM transaction_event_links WHERE transaction_id=t.id AND unlinked_at_ms IS NULL))) AS open_review,
            (SELECT group_concat(DISTINCT s.kind) FROM transaction_event_links l JOIN raw_events e ON e.id=l.event_id
              JOIN sources s ON s.id=e.source_id WHERE l.transaction_id=t.id AND l.unlinked_at_ms IS NULL) AS sources
            FROM transactions t JOIN transaction_parts p ON p.transaction_id=t.id
            JOIN category_assignments a ON a.id=p.current_assignment_id LEFT JOIN accounts ac ON ac.id=t.account_id
            WHERE t.state='active' ORDER BY t.occurred_on DESC,t.id LIMIT ? OFFSET ?
            """, [.integer(Int64(max(1, min(limit, 5000)))), .integer(Int64(max(0, offset)))])
        let transactions = rows.map { row in LedgerTransaction(id: row.text("id"), partID: row.text("part_id"), revision: Int(row.number("revision")),
            description: row.text("description"), amountMinor: row.number("amount_minor"), currency: row.text("currency"), occurredOn: row.text("occurred_on"),
            accountID: row["account_id"]?.string, accountName: row["account_name"]?.string ?? "Unassigned", type: row.text("type_code"), category: row["category_id"]?.string,
            needsReview: row.number("needs_review") == 1 || row.number("open_review") == 1, notes: row.text("notes"), sources: row["sources"]?.string ?? "manual", origin: row.text("origin")) }
        let reviews = try db.query("""
            SELECT r.*,e.source_id,e.external_account_key,o.description FROM review_items r
            JOIN raw_events e ON e.id=r.event_id LEFT JOIN event_observations o ON o.id=(SELECT id FROM event_observations WHERE event_id=e.id ORDER BY parsed_at_ms DESC,rowid DESC LIMIT 1)
            WHERE r.status='open' ORDER BY r.created_at_ms LIMIT 200
            """).map { row in
                ReviewRecord(id: row.text("id"), eventID: row.text("event_id"), reason: row.text("reason_code"), sourceID: row.text("source_id"),
                    label: String(row.text("external_account_key").dropFirst("label:".count)), description: row.text("description"),
                    candidates: (try? JSONDecoder().decode([String].self, from: Data(row.text("details_json").utf8))) ?? [])
            }
        let queue = try db.query("SELECT * FROM queue_items ORDER BY first_seen_at_ms DESC LIMIT 100").map { QueueRecord(id: $0.text("id"), path: $0.text("relative_path"), state: $0.text("state"), error: $0.text("error_code"), attempts: Int($0.number("attempt_count"))) }
        return LedgerSnapshot(transactions: transactions, accounts: accounts, reviews: reviews, queue: queue, cardMappings: try cardAccountMappings(),
            totalTransactions: Int(try db.query("SELECT count(*) AS n FROM transactions WHERE state='active'").first!.number("n")),
            pendingJobs: Int(try db.query("SELECT count(*) AS n FROM classification_jobs WHERE status IN ('pending','running')").first!.number("n")),
            failedJobs: Int(try db.query("SELECT count(*) AS n FROM classification_jobs WHERE status='failed'").first!.number("n")))
    }
    /// Includes transactions awaiting their first model selection, without creating jobs.
    public func unqueuedClassificationCount() throws -> Int {
        Int(try db.query("""
            SELECT count(*) AS n FROM transaction_parts p JOIN transactions t ON t.id=p.transaction_id
            JOIN category_assignments a ON a.id=p.current_assignment_id
            WHERE t.state='active' AND (a.origin='system' OR (a.origin IN ('model','council') AND EXISTS(SELECT 1 FROM receipt_captures r WHERE r.transaction_id=t.id))) AND a.confirmed_at_ms IS NULL
            AND NOT EXISTS(SELECT 1 FROM classification_jobs j WHERE j.part_id=p.id
              AND j.input_revision=t.revision AND j.status<>'obsolete'
              AND (coalesce(j.model_id,j.council_config_id)=json_extract((SELECT value_json FROM app_settings WHERE key='classifier_model'),'$')
                OR NOT EXISTS(SELECT 1 FROM app_settings WHERE key='classifier_model')))
            """).first!.number("n"))
    }
    public func captureDeliveryStates() throws -> [String: CaptureDeliveryState] {
        Dictionary(uniqueKeysWithValues: try db.query("SELECT id,state,next_attempt_at_ms FROM queue_items").map {
            ($0.text("id"), CaptureDeliveryState(terminal: ["imported", "quarantined"].contains($0.text("state")), nextAttemptMS: $0.number("next_attempt_at_ms")))
        })
    }
    /// A deliberate scheduler stop should not consume an inference retry.
    public func releaseClassification(_ task: ClassificationTask) throws {
        try db.transaction {
            try db.query("UPDATE classification_runs SET status='unavailable',error_code='paused',finished_at_ms=? WHERE status='running' AND id IN (SELECT member_run_id FROM council_member_inputs WHERE council_run_id=?)", [.integer(nowMS()), .text(task.runID)])
            try db.query("UPDATE classification_runs SET status='unavailable',error_code='paused',finished_at_ms=? WHERE id=? AND status='running'", [.integer(nowMS()), .text(task.runID)])
            try db.query("UPDATE classification_jobs SET status='pending',attempts=max(0,attempts-1),next_attempt_at_ms=0,error_code=NULL WHERE id=? AND run_id=? AND status='running'", [.text(task.id), .text(task.runID)])
        }
    }
    public func save(_ edit: TransactionEdit) throws {
        guard !edit.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, edit.description.count <= 2048,
              edit.amountMinor != 0, edit.amountMinor != Int64.min, edit.notes.count <= 10000,
              ExactMoney.currencies.contains(edit.currency) else { throw LedgerError.invalid("Invalid transaction fields.") }
        _ = try CivilDate.parse(edit.occurredOn)
        guard let accountID = edit.accountID, let selected = try account(accountID), selected.currency == edit.currency else { throw LedgerError.invalid("Select an account with the transaction's currency.") }
        try db.transaction {
            let old = try db.query("SELECT * FROM transactions WHERE id=?", [.text(edit.id)]).first
            if let old {
                guard old.number("revision") == edit.revision, old.text("state") == "active" else { throw LedgerError.conflict }
                guard try db.query("SELECT id FROM transaction_parts WHERE transaction_id=?", [.text(edit.id)]).count == 1 else { throw LedgerError.invalid("Split editing is not available yet.") }
                try db.query("UPDATE transactions SET state='draft' WHERE id=?", [.text(edit.id)])
                try db.query("UPDATE transactions SET description=?,amount_minor=?,currency=?,account_id=?,occurred_on=?,occurred_at_ms=NULL,time_precision='date',utc_offset_minutes=NULL,notes=?,revision=revision+1,updated_at_ms=? WHERE id=?",
                    [.text(edit.description), .integer(edit.amountMinor), .text(edit.currency), .text(accountID), .text(edit.occurredOn), .text(edit.notes), .integer(nowMS()), .text(edit.id)])
                try db.query("UPDATE transaction_parts SET amount_minor=? WHERE transaction_id=?", [.integer(edit.amountMinor), .text(edit.id)])
            } else {
                guard edit.revision == 0 else { throw LedgerError.conflict }
                try db.query("INSERT INTO transactions(id,account_id,description,amount_minor,currency,occurred_on,time_precision,lifecycle,notes,created_at_ms,updated_at_ms) VALUES (?,?,?,?,?,?,'date','posted',?,?,?)",
                    [.text(edit.id), .text(accountID), .text(edit.description), .integer(edit.amountMinor), .text(edit.currency), .text(edit.occurredOn), .text(edit.notes), .integer(nowMS()), .integer(nowMS())])
                try db.query("INSERT INTO transaction_parts(id,transaction_id,position,amount_minor) VALUES (?,?,0,?)", [.text(identifier()), .text(edit.id), .integer(edit.amountMinor)])
            }
            try Self.resolveMerchant(db: db, transactionID: edit.id, description: edit.description)
            let part = try db.query("SELECT * FROM transaction_parts WHERE transaction_id=?", [.text(edit.id)]).first!
            try assign(partID: part.text("id"), type: edit.type, category: edit.category, review: edit.needsReview, origin: "user", runID: nil)
            try db.query("UPDATE transactions SET state='active' WHERE id=?", [.text(edit.id)])
            try db.query("UPDATE classification_jobs SET status='obsolete',updated_at_ms=? WHERE part_id=? AND status IN ('pending','running')", [.integer(nowMS()), .text(part.text("id"))])
            try db.query("INSERT INTO change_log(id,operation_id,entity_type,entity_id,actor,reason,changed_at_ms,before_json,after_json) VALUES (?,?,'transaction',?,'user','edit',?,?,?)",
                [.text(identifier()), .text(identifier()), .text(edit.id), .integer(nowMS()), .optional(try old.map { try json($0.mapValues { $0.string ?? $0.int.map(String.init) ?? "" }) }), .text(try json(["description": edit.description, "amount_minor": String(edit.amountMinor), "type": edit.type, "category": edit.category ?? ""]))])
        }
    }
    public func delete(id: String, revision: Int) throws {
        try db.transaction {
            guard let old = try db.query("SELECT revision,state FROM transactions WHERE id=?", [.text(id)]).first,
                  old.number("revision") == revision, old.text("state") == "active" else { throw LedgerError.conflict }
            try db.query("UPDATE transactions SET state='deleted',deleted_at_ms=?,updated_at_ms=?,revision=revision+1 WHERE id=?", [.integer(nowMS()), .integer(nowMS()), .text(id)])
            try db.query("UPDATE classification_jobs SET status='obsolete' WHERE part_id IN (SELECT id FROM transaction_parts WHERE transaction_id=?) AND status IN ('pending','running')", [.text(id)])
            try db.query("INSERT INTO change_log(id,operation_id,entity_type,entity_id,actor,reason,changed_at_ms) VALUES (?,?,'transaction',?,'user','delete',?)", [.text(identifier()), .text(identifier()), .text(id), .integer(nowMS())])
        }
    }
    func assign(partID: String, type: String, category: String?, review: Bool, origin: String, runID: String?) throws {
        let old = try db.query("SELECT current_assignment_id FROM transaction_parts WHERE id=?", [.text(partID)]).first?["current_assignment_id"]?.string
        let id = identifier()
        try db.query("INSERT INTO category_assignments(id,part_id,type_code,category_id,origin,run_id,supersedes_id,needs_review,selected_at_ms,confirmed_at_ms,confirmed_by) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            [.text(id), .text(partID), .text(type), .optional(category), .text(origin), .optional(runID), .optional(old), .integer(review ? 1 : 0), .integer(nowMS()), origin == "user" ? .integer(nowMS()) : .null, origin == "user" ? .text("local-user") : .null])
        try db.query("UPDATE transaction_parts SET current_assignment_id=? WHERE id=?", [.text(id), .text(partID)])
    }
    func review(eventID: String, reason: String, candidates: [String] = []) throws {
        guard try db.query("SELECT id FROM review_items WHERE event_id=? AND status='open' AND reason_code=?", [.text(eventID), .text(reason)]).isEmpty else { return }
        try db.query("INSERT INTO review_items(id,event_id,reason_code,status,details_json,created_at_ms) VALUES (?,?,?,'open',?,?)", [.text(identifier()), .text(eventID), .text(reason), .text(try json(candidates)), .integer(nowMS())])
    }
    func resolveReviews(_ eventID: String) throws {
        try db.query("UPDATE review_items SET status='resolved',resolved_at_ms=?,resolution='processed' WHERE event_id=? AND status='open'", [.integer(nowMS()), .text(eventID)])
    }
}
