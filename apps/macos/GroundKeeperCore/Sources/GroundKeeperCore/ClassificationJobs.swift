import Foundation

extension LedgerStore {
    public func registerModel(id: String, name: String, backend: String, policy: String, configuration: String) throws {
        guard policy == "groundkeeper-18-v1", ["qwen_mlx", "laya_mps", "apple_shortcut"].contains(backend), id.count == 64 else { throw LedgerError.invalid("Unsupported classifier identity.") }
        try db.transaction {
            let definition = try json(["policy": [policy], "categories": ["groceries","dining","local_transport","vehicle","housing","utilities","shopping","medical","personal_care","fitness","entertainment","software","education","travel","insurance","financial","taxes","gifts","other","uncategorized"]])
            try db.query("INSERT OR IGNORE INTO policy_versions(id,name,content_sha256,definition_json,created_at_ms) VALUES (?,?,?,?,?)", [.text(policy), .text(policy), .text(contentHash(Data(definition.utf8))), .text(definition), .integer(nowMS())])
            try db.query("INSERT OR IGNORE INTO model_versions(id,provider,model_name,execution,package_sha256,configuration_json,created_at_ms) VALUES (?,?,?,?,?,?,?)", [.text(id), .text(backend), .text(name), .text(backend == "apple_shortcut" ? "cloud" : "local"), .text(id), .text(configuration), .integer(nowMS())])
            try db.query("UPDATE classification_jobs SET status='obsolete' WHERE model_id<>? AND status='pending'", [.text(id)])
            try db.query("INSERT INTO app_settings(key,value_json,updated_at_ms) VALUES ('classifier_model',?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at_ms=excluded.updated_at_ms", [.text(try json(id)), .integer(nowMS())])
        }
    }
    public func enqueueClassifications(modelID: String) throws {
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
                WHERE model_id=? AND status='obsolete' AND EXISTS (
                    SELECT 1 FROM transaction_parts p JOIN transactions t ON t.id=p.transaction_id
                    JOIN category_assignments a ON a.id=p.current_assignment_id
                    WHERE p.id=classification_jobs.part_id AND t.revision=classification_jobs.input_revision
                    AND t.state='active' AND (a.origin='system' OR (a.origin='model' AND EXISTS(SELECT 1 FROM receipt_captures r WHERE r.transaction_id=t.id))) AND a.confirmed_at_ms IS NULL)
                """, [.text(modelID)])
            try db.query("""
                INSERT OR IGNORE INTO classification_jobs(id,part_id,input_revision,model_id,status,next_attempt_at_ms,created_at_ms,updated_at_ms)
                SELECT lower(hex(randomblob(16))),p.id,t.revision,?,'pending',0,?,?
                FROM transaction_parts p JOIN transactions t ON t.id=p.transaction_id JOIN category_assignments a ON a.id=p.current_assignment_id
                WHERE t.state='active' AND (a.origin='system' OR (a.origin='model' AND EXISTS(SELECT 1 FROM receipt_captures r WHERE r.transaction_id=t.id))) AND a.confirmed_at_ms IS NULL
                """, [.text(modelID), .integer(nowMS()), .integer(nowMS())])
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
            let runID = identifier()
            struct Input: Encodable { let description: String, direction: String, currency: String; let receipt_context: ReceiptContext? }
            let input = try json(Input(description: row.text("description"), direction: row.number("amount_minor") < 0 ? "debit" : "credit", currency: row.text("currency"), receipt_context: context))
            try db.query("INSERT INTO classification_runs(id,part_id,input_revision,kind,model_version_id,policy_version_id,input_json,input_sha256,started_at_ms,status,context_version) VALUES (?,?,?,'model',?,'groundkeeper-18-v1',?,?,?,'running',?)",
                [.text(runID), .text(row.text("part_id")), .integer(row.number("input_revision")), .text(modelID), .text(input), .text(contentHash(Data(input.utf8))), .integer(nowMS()), .optional(context?.version)])
            try db.query("UPDATE classification_jobs SET status='running',attempts=attempts+1,run_id=?,updated_at_ms=?,receipt_context_sha256=? WHERE id=?", [.text(runID), .integer(nowMS()), .optional(context?.evidenceSHA256), .text(row.text("id"))])
            return ClassificationTask(id: row.text("id"), runID: runID, partID: row.text("part_id"), revision: Int(row.number("input_revision")), description: row.text("description"), direction: row.number("amount_minor") < 0 ? "debit" : "credit", currency: row.text("currency"), receiptContext: context)
        }
    }
    public func completeClassification(_ task: ClassificationTask, decision: ClassificationDecision) throws {
        try db.transaction {
            guard let job = try db.query("SELECT * FROM classification_jobs WHERE id=? AND run_id=?", [.text(task.id), .text(task.runID)]).first else { return }
            guard try db.query("SELECT status FROM classification_runs WHERE id=?", [.text(task.runID)]).first?.text("status") == "running" else { return }
            guard decision.review else { throw LedgerError.invalid("Classifier suggestions must require review.") }
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
