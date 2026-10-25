import Foundation

extension LedgerStore {
    public func registerModel(id: String, name: String, backend: String, policy: String, configuration: String, select: Bool = true) throws {
        guard policy == "groundkeeper-19-v2", ["qwen_mlx", "laya_mps", "apple_shortcut", "ollama"].contains(backend), id.count == 64,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LedgerError.invalid("Unsupported classifier identity.") }
        try db.transaction {
            if let existing = try db.query("SELECT provider,model_name FROM model_versions WHERE id=?", [.text(id)]).first {
                guard existing.text("provider") == backend, existing.text("model_name") == name else {
                    throw LedgerError.invalid("A saved model identity cannot be relabeled.")
                }
            }
            let definition = try json(["policy": [policy], "categories": ["groceries","dining","local_transport","vehicle","housing","utilities","shopping","medical","personal_care","fitness","entertainment","software","education","travel","insurance","financial","taxes","gifts","other"]])
            try db.query("INSERT OR IGNORE INTO policy_versions(id,name,content_sha256,definition_json,created_at_ms) VALUES (?,?,?,?,?)", [.text(policy), .text(policy), .text(contentHash(Data(definition.utf8))), .text(definition), .integer(nowMS())])
            try db.query("INSERT OR IGNORE INTO model_versions(id,provider,model_name,execution,package_sha256,configuration_json,created_at_ms) VALUES (?,?,?,?,?,?,?)", [.text(id), .text(backend), .text(name), .text(backend == "apple_shortcut" ? "cloud" : "local"), .text(id), .text(configuration), .integer(nowMS())])
            guard select else { return }
            try db.query("UPDATE classification_jobs SET status='obsolete' WHERE coalesce(model_id,council_config_id)<>? AND status='pending'", [.text(id)])
            try db.query("INSERT INTO app_settings(key,value_json,updated_at_ms) VALUES ('classifier_model',?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at_ms=excluded.updated_at_ms", [.text(try json(id)), .integer(nowMS())])
        }
    }
    /// Enqueue using saved metadata and check retry eligibility before loading weights.
    public func prepareSelectedClassifications() throws -> Bool {
        guard let value = try db.query("SELECT value_json FROM app_settings WHERE key='classifier_model'").first?.text("value_json"),
              let id = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) else {
            // Older/new vaults may need provider registration first.
            return true
        }
        try enqueueClassifications(modelID: id)
        return try !db.query("""
            SELECT j.id FROM classification_jobs j
            JOIN transaction_parts p ON p.id=j.part_id JOIN transactions t ON t.id=p.transaction_id
            JOIN category_assignments a ON a.id=p.current_assignment_id
            WHERE j.status='pending' AND j.model_id=? AND j.next_attempt_at_ms<=? AND j.attempts<3
              AND t.state='active' AND t.revision=j.input_revision AND a.confirmed_at_ms IS NULL LIMIT 1
            """, [.text(id), .integer(nowMS())]).isEmpty
    }

    public func enqueueClassifications(modelID: String) throws {
        try enqueueJobs(targetID: modelID, council: false)
    }
    public func enqueueCouncil(configID: String) throws {
        guard try !db.query("SELECT id FROM council_configs WHERE id=?", [.text(configID)]).isEmpty else { throw LedgerError.invalid("Council is not configured.") }
        try enqueueJobs(targetID: configID, council: true)
    }
    private func enqueueJobs(targetID: String, council: Bool) throws {
        let targetColumn = council ? "council_config_id" : "model_id"
        try db.transaction {
            try db.query("""
                UPDATE classification_jobs SET status='obsolete' WHERE status='pending' AND EXISTS(
                SELECT 1 FROM transaction_parts p JOIN transactions t ON t.id=p.transaction_id
                JOIN category_assignments a ON a.id=p.current_assignment_id WHERE p.id=classification_jobs.part_id
                AND (t.revision<>classification_jobs.input_revision OR t.state<>'active' OR a.confirmed_at_ms IS NOT NULL))
                """)
            // Returning to a provider should revive its superseded, still-eligible
            // jobs; the uniqueness key otherwise prevents enqueueing them again.
            try db.query("""
                UPDATE classification_jobs SET status='pending',attempts=0,next_attempt_at_ms=0,run_id=NULL,error_code=NULL
                WHERE \(targetColumn)=? AND status='obsolete' AND EXISTS (
                    SELECT 1 FROM transaction_parts p JOIN transactions t ON t.id=p.transaction_id
                    JOIN category_assignments a ON a.id=p.current_assignment_id
                    WHERE p.id=classification_jobs.part_id AND t.revision=classification_jobs.input_revision
                    AND t.state='active' AND (a.origin='system' OR a.origin IN ('model','council')) AND a.confirmed_at_ms IS NULL)
                """, [.text(targetID)])
            try db.query("""
                INSERT OR IGNORE INTO classification_jobs(id,part_id,input_revision,\(targetColumn),status,next_attempt_at_ms,created_at_ms,updated_at_ms)
                SELECT lower(hex(randomblob(16))),p.id,t.revision,?,'pending',0,?,?
                FROM transaction_parts p JOIN transactions t ON t.id=p.transaction_id JOIN category_assignments a ON a.id=p.current_assignment_id
                WHERE t.state='active' AND (a.origin='system' OR a.origin IN ('model','council')) AND a.confirmed_at_ms IS NULL
                """, [.text(targetID), .integer(nowMS()), .integer(nowMS())])
        }
    }
    public func claimClassification(modelID: String) throws -> ClassificationTask? {
        try db.transaction {
            guard let row = try db.query("""
                SELECT j.*,t.id AS transaction_id,t.description,t.amount_minor,t.currency,m.provider FROM classification_jobs j
                JOIN model_versions m ON m.id=j.model_id
                JOIN transaction_parts p ON p.id=j.part_id JOIN transactions t ON t.id=p.transaction_id
                JOIN category_assignments a ON a.id=p.current_assignment_id
                WHERE j.status='pending' AND j.model_id=? AND j.next_attempt_at_ms<=? AND j.attempts<3
                AND t.state='active' AND t.revision=j.input_revision AND a.confirmed_at_ms IS NULL
                ORDER BY j.created_at_ms,j.id LIMIT 1
                """, [.text(modelID), .integer(nowMS())]).first else { return nil }
            let mayUseReceipt = try row.text("provider") != "apple_shortcut" || receiptCloudConsent()
            let context = mayUseReceipt ? try receiptContext(transactionID: row.text("transaction_id")) : nil
            let notes = try classifierNotes(transactionID: row.text("transaction_id"))
            let walletHint = try walletCategoryHint(transactionID: row.text("transaction_id"))
            let runID = identifier()
            struct Input: Encodable {
                let description: String, direction: String, currency: String
                let transaction_notes: String?
                let receipt_context: ReceiptContext?
                let wallet_category_raw: String?
                let wallet_category_source_event_id: String?
            }
            let input = try json(Input(description: row.text("description"), direction: row.number("amount_minor") < 0 ? "debit" : "credit", currency: row.text("currency"), transaction_notes: notes, receipt_context: context, wallet_category_raw: walletHint?.value, wallet_category_source_event_id: nil))
            // The category value lives only in its immutable source payload.
            // Audit the source reference and hash the actual inference input.
            let audit = try json(Input(description: row.text("description"), direction: row.number("amount_minor") < 0 ? "debit" : "credit", currency: row.text("currency"), transaction_notes: notes, receipt_context: context, wallet_category_raw: nil, wallet_category_source_event_id: walletHint?.eventID))
            try db.query("INSERT INTO classification_runs(id,part_id,input_revision,kind,model_version_id,policy_version_id,input_json,input_sha256,started_at_ms,status,context_version) VALUES (?,?,?,'model',?,'groundkeeper-19-v2',?,?,?,'running',?)",
                [.text(runID), .text(row.text("part_id")), .integer(row.number("input_revision")), .text(modelID), .text(audit), .text(contentHash(Data(input.utf8))), .integer(nowMS()), .optional(context?.version)])
            try db.query("UPDATE classification_jobs SET status='running',attempts=attempts+1,run_id=?,updated_at_ms=?,receipt_context_sha256=? WHERE id=?", [.text(runID), .integer(nowMS()), .optional(context?.evidenceSHA256), .text(row.text("id"))])
            return ClassificationTask(id: row.text("id"), runID: runID, partID: row.text("part_id"), revision: Int(row.number("input_revision")), description: row.text("description"), direction: row.number("amount_minor") < 0 ? "debit" : "credit", currency: row.text("currency"), receiptContext: context, walletCategoryRaw: walletHint?.value, transactionNotes: notes)
        }
    }
    /// Missing, malformed or conflicting hints must not prevent classification.
    func walletCategoryHint(transactionID: String) throws -> (eventID: String, value: String)? {
        let events = try db.query("""
            SELECT e.id,p.payload_json FROM transaction_event_links l
            JOIN raw_events e ON e.id=l.event_id JOIN sources s ON s.id=e.source_id
            JOIN raw_event_payloads p ON p.event_id=e.id
            WHERE l.transaction_id=? AND l.unlinked_at_ms IS NULL AND e.is_test=0 AND s.kind='apple_wallet'
            ORDER BY e.captured_at_ms,e.id
            """, [.text(transactionID)])
        var selected: (eventID: String, value: String)?
        for event in events {
            guard let payload = try? JSONSerialization.jsonObject(with: Data(event.text("payload_json").utf8)) as? [String: Any],
                  let hint = payload["wallet_category_raw"] as? String,
                  !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  hint.utf8.count <= 128,
                  !hint.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { continue }
            if let selected, selected.value != hint { return nil }
            if selected == nil { selected = (event.text("id"), hint) }
        }
        return selected
    }
    public func completeClassification(_ task: ClassificationTask, decision: ClassificationDecision) throws {
        try db.transaction {
            guard let job = try db.query("SELECT * FROM classification_jobs WHERE id=? AND run_id=?", [.text(task.id), .text(task.runID)]).first else { return }
            guard try db.query("SELECT status FROM classification_runs WHERE id=?", [.text(task.runID)]).first?.text("status") == "running" else { return }
            try decision.validateSuggestion()
            try db.query("UPDATE classification_runs SET status='succeeded',finished_at_ms=?,type_code=?,category_id=?,needs_review=1,output_json=? WHERE id=? AND status='running'",
                [.integer(nowMS()), .text(decision.type), .optional(decision.category), .text(try json(decision)), .text(task.runID)])
            let current = try db.query("SELECT t.revision,t.state,a.confirmed_at_ms FROM transaction_parts p JOIN transactions t ON t.id=p.transaction_id JOIN category_assignments a ON a.id=p.current_assignment_id WHERE p.id=?", [.text(task.partID)]).first
            let eligible = job.text("status") == "running" && current?.number("revision") == Int64(task.revision) && current?.text("state") == "active" && current?["confirmed_at_ms"]?.int == nil
            if eligible { try assign(partID: task.partID, type: decision.type, category: decision.category, review: true, origin: "model", runID: task.runID) }
            try db.query("UPDATE classification_jobs SET status=?,updated_at_ms=?,error_code=NULL WHERE id=?", [.text(eligible ? "succeeded" : "obsolete"), .integer(nowMS()), .text(task.id)])
        }
    }
    public func failClassification(_ task: ClassificationTask, code: String, retryable: Bool) throws {
        try db.transaction {
            try db.query("UPDATE classification_runs SET status='failed',error_code=?,finished_at_ms=? WHERE id=? AND status='running'", [.text(code), .integer(nowMS()), .text(task.runID)])
            guard let job = try db.query("SELECT attempts,status FROM classification_jobs WHERE id=? AND run_id=?", [.text(task.id), .text(task.runID)]).first, job.text("status") == "running" else { return }
            let attempts = job.number("attempts")
            try db.query("UPDATE classification_jobs SET status=?,error_code=?,next_attempt_at_ms=?,updated_at_ms=? WHERE id=?", [.text(retryable && attempts < 3 ? "pending" : "failed"), .text(code), .integer(nowMS() + 10_000 * attempts * attempts), .integer(nowMS()), .text(task.id)])
        }
    }
    public func retryClassificationFailures() throws {
        try db.query("UPDATE classification_jobs SET status='pending',attempts=0,next_attempt_at_ms=0,error_code=NULL WHERE status='failed'")
    }
}
