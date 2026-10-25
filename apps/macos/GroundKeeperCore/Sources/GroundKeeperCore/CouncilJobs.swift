import Foundation

public struct CouncilMemberTask: Sendable {
    public let runID: String
    public let input: CouncilInput
}

public struct CouncilReport: Sendable {
    public let runID: String
    public let result: CouncilResult
    public let search: MerchantSearchEvidence?
    public let receiptSharedWithApple: Bool
    public let isCurrentRevision: Bool
}

extension LedgerStore {
    public func registerCouncil(_ configuration: CouncilConfiguration) throws {
        let checked = try CouncilConfiguration(members: configuration.members)
        guard checked.id == configuration.id else { throw LedgerError.invalid("Invalid Council identity.") }
        try db.transaction {
            for member in configuration.members {
                guard try db.query("SELECT provider FROM model_versions WHERE id=?", [.text(member.id)]).first?.text("provider") == member.backend else {
                    throw LedgerError.invalid("Verify all Council members before selecting Council.")
                }
            }
            try db.query("INSERT OR IGNORE INTO council_configs(id,policy_version_id,algorithm_version,configuration_json,created_at_ms) VALUES (?,'groundkeeper-18-v1',?,?,?)",
                         [.text(configuration.id), .text(CouncilConfiguration.algorithm), .text(try json(configuration)), .integer(nowMS())])
            for member in configuration.members {
                try db.query("INSERT OR IGNORE INTO council_config_members(config_id,model_version_id,weight) VALUES (?,?,1)", [.text(configuration.id), .text(member.id)])
            }
            try db.query("UPDATE classification_jobs SET status='obsolete' WHERE coalesce(model_id,council_config_id)<>? AND status='pending'", [.text(configuration.id)])
            try db.query("INSERT INTO app_settings(key,value_json,updated_at_ms) VALUES ('classifier_model',?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at_ms=excluded.updated_at_ms",
                         [.text(try json(configuration.id)), .integer(nowMS())])
        }
    }
    public func selectedCouncil() throws -> CouncilConfiguration? {
        guard let row = try db.query("SELECT configuration_json FROM council_configs WHERE id=json_extract((SELECT value_json FROM app_settings WHERE key='classifier_model'),'$')").first else { return nil }
        let saved = try JSONDecoder().decode(CouncilConfiguration.self, from: Data(row.text("configuration_json").utf8))
        let checked = try CouncilConfiguration(members: saved.members)
        guard checked.id == saved.id else { throw LedgerError.invalid("Invalid saved Council configuration.") }
        return checked
    }
    public func claimCouncil(configID: String) throws -> ClassificationTask? {
        try db.transaction {
            guard let row = try db.query("""
                SELECT j.*,t.id AS transaction_id,t.description,t.amount_minor,t.currency FROM classification_jobs j
                JOIN transaction_parts p ON p.id=j.part_id JOIN transactions t ON t.id=p.transaction_id
                JOIN category_assignments a ON a.id=p.current_assignment_id
                WHERE j.status='pending' AND j.council_config_id=? AND j.next_attempt_at_ms<=? AND j.attempts<3
                AND t.state='active' AND t.revision=j.input_revision AND a.confirmed_at_ms IS NULL
                ORDER BY j.created_at_ms,j.id LIMIT 1
                """, [.text(configID), .integer(nowMS())]).first else { return nil }
            let context = try receiptContext(transactionID: row.text("transaction_id"))
            let notes = try classifierNotes(transactionID: row.text("transaction_id"))
            let hint = try walletCategoryHint(transactionID: row.text("transaction_id"))
            let input = CouncilInput(description: row.text("description"), direction: row.number("amount_minor") < 0 ? "debit" : "credit",
                                     currency: row.text("currency"), receiptContext: context, walletCategoryRaw: hint?.value, transactionNotes: notes)
            var audit = try JSONSerialization.jsonObject(with: Data(try json(input).utf8)) as! [String: Any]
            audit.removeValue(forKey: "wallet_category_raw")
            if let hint { audit["wallet_category_source_event_id"] = hint.eventID }
            var auditText = String(decoding: try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys]), as: UTF8.self)
            var hash = contentHash(Data(try json(input).utf8))
            var search: String?
            // The queue keeps its last run pointer on retry/release. Preserve the original snapshot.
            if let previous = try db.query("SELECT input_json,input_sha256,merchant_search_json FROM classification_runs WHERE id=? AND kind='council'", [.text(row.text("run_id"))]).first {
                auditText = previous.text("input_json"); hash = previous.text("input_sha256"); search = previous["merchant_search_json"]?.string
            }
            let runID = identifier()
            try db.query("INSERT INTO classification_runs(id,part_id,input_revision,kind,council_config_id,policy_version_id,input_json,input_sha256,started_at_ms,status,context_version,merchant_search_json) VALUES (?,?,?,'council',?,'groundkeeper-18-v1',?,?,?,'running',?,?)",
                         [.text(runID), .text(row.text("part_id")), .integer(row.number("input_revision")), .text(configID), .text(auditText), .text(hash), .integer(nowMS()), .optional(context?.version), .optional(search)])
            try db.query("UPDATE classification_jobs SET status='running',attempts=attempts+1,run_id=?,updated_at_ms=?,receipt_context_sha256=? WHERE id=?",
                         [.text(runID), .integer(nowMS()), .optional(context?.evidenceSHA256), .text(row.text("id"))])
            return ClassificationTask(id: row.text("id"), runID: runID, partID: row.text("part_id"), revision: Int(row.number("input_revision")),
                                      description: input.description, direction: input.direction, currency: input.currency, receiptContext: context, walletCategoryRaw: hint?.value, transactionNotes: notes)
        }
    }
    public func savedCouncilSearch(for task: ClassificationTask) throws -> MerchantSearchEvidence? {
        guard let data = try db.query("SELECT merchant_search_json FROM classification_runs WHERE id=? AND kind='council'", [.text(task.runID)]).first?["merchant_search_json"]?.string else { return nil }
        return try JSONDecoder().decode(MerchantSearchEvidence.self, from: Data(data.utf8))
    }
    public func councilTaskIsCurrent(_ task: ClassificationTask) throws -> Bool {
        try !db.query("""
            SELECT 1 FROM classification_jobs j JOIN transaction_parts p ON p.id=j.part_id
            JOIN transactions t ON t.id=p.transaction_id JOIN category_assignments a ON a.id=p.current_assignment_id
            JOIN classification_runs r ON r.id=j.run_id
            WHERE j.id=? AND j.run_id=? AND j.status='running' AND r.status='running'
            AND t.revision=? AND t.state='active' AND a.confirmed_at_ms IS NULL
            """, [.text(task.id), .text(task.runID), .integer(Int64(task.revision))]).isEmpty
    }
    public func startCouncilMember(_ member: CouncilMember, task: ClassificationTask) throws -> CouncilMemberTask {
        try db.transaction {
            guard try councilTaskIsCurrent(task), let parent = try db.query("""
                SELECT r.* FROM classification_runs r JOIN council_config_members m ON m.config_id=r.council_config_id
                JOIN model_versions v ON v.id=m.model_version_id
                WHERE r.id=? AND m.model_version_id=? AND m.weight=1 AND v.provider=?
                """, [.text(task.runID), .text(member.id), .text(member.backend)]).first else { throw LedgerError.conflict }
            var audit = try JSONSerialization.jsonObject(with: Data(parent.text("input_json").utf8)) as! [String: Any]
            if member.backend == "apple_shortcut", try !receiptCloudConsent() { audit.removeValue(forKey: "receipt_context") }
            if try !merchantSearchSettings().enabled { audit.removeValue(forKey: "merchant_context") }
            let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
            let auditData = try JSONSerialization.data(withJSONObject: audit, options: options)
            let hintReference = audit.removeValue(forKey: "wallet_category_source_event_id") as? String
            if let hintReference, let value = try db.query("SELECT json_extract(payload_json,'$.wallet_category_raw') AS value FROM raw_event_payloads WHERE event_id=?", [.text(hintReference)]).first?["value"]?.string {
                audit["wallet_category_raw"] = value
            }
            let wire = try JSONSerialization.data(withJSONObject: audit, options: options)
            let input = try JSONDecoder().decode(CouncilInput.self, from: wire)
            let runID = identifier(), hash = contentHash(wire), auditText = String(decoding: auditData, as: UTF8.self)
            try db.query("INSERT INTO classification_runs(id,part_id,input_revision,kind,model_version_id,policy_version_id,input_json,input_sha256,started_at_ms,status,context_version,merchant_search_json) VALUES (?,?,?,'model',?,'groundkeeper-18-v1',?,?,?,'running',?,?)",
                         [.text(runID), .text(task.partID), .integer(Int64(task.revision)), .text(member.id), .text(auditText), .text(hash), .integer(nowMS()), .optional(input.receiptContext?.version), .optional(parent["merchant_search_json"]?.string)])
            try db.query("INSERT INTO council_member_inputs VALUES (?,?,?,?,?,?)", [.text(task.runID), .text(member.id), .text(runID), .text(auditText), .text(hash), .integer(input.receiptContext == nil ? 0 : 1)])
            return CouncilMemberTask(runID: runID, input: input)
        }
    }
    public func recordCouncilVote(_ vote: CouncilVote, memberRunID: String, task: ClassificationTask) throws {
        try db.transaction {
            guard let child = try db.query("SELECT status FROM classification_runs WHERE id=?", [.text(memberRunID)]).first, child.text("status") == "running" else { throw LedgerError.conflict }
            if vote.disposition == "valid" {
                guard let decision = vote.decision else { throw LedgerError.invalid("Missing Council member decision.") }
                try decision.validateSuggestion()
                try db.query("UPDATE classification_runs SET status='succeeded',finished_at_ms=?,type_code=?,category_id=?,needs_review=1,output_json=? WHERE id=?",
                             [.integer(nowMS()), .text(decision.type), .optional(decision.category), .text(try json(decision)), .text(memberRunID)])
            } else {
                guard ["failed", "timeout", "unavailable", "invalid", "skipped"].contains(vote.disposition), vote.decision == nil else { throw LedgerError.invalid("Invalid Council failure.") }
                let status = vote.disposition == "skipped" ? "unavailable" : vote.disposition
                try db.query("UPDATE classification_runs SET status=?,finished_at_ms=?,error_code=? WHERE id=?",
                             [.text(status), .integer(nowMS()), .optional(vote.errorCode), .text(memberRunID)])
            }
            try db.query("INSERT INTO council_votes VALUES (?,?,?,1,?)", [.text(task.runID), .text(vote.member.id), .text(memberRunID), .text(vote.disposition)])
        }
    }
    public func completeCouncil(_ task: ClassificationTask, configuration: CouncilConfiguration) throws -> CouncilResult {
        try db.transaction {
            guard try db.query("SELECT council_config_id FROM classification_runs WHERE id=?", [.text(task.runID)]).first?.text("council_config_id") == configuration.id else { throw LedgerError.conflict }
            let rows = try db.query("SELECT v.*,r.output_json,r.error_code FROM council_votes v JOIN classification_runs r ON r.id=v.member_run_id WHERE v.council_run_id=?", [.text(task.runID)])
            let votes = try configuration.members.map { member -> CouncilVote in
                guard let row = rows.first(where: { $0.text("model_version_id") == member.id }) else { throw LedgerError.invalid("Council is incomplete.") }
                let decision = try row["output_json"]?.string.map { try JSONDecoder().decode(ClassificationDecision.self, from: Data($0.utf8)) }
                return CouncilVote(member: member, disposition: row.text("disposition"), decision: decision, errorCode: row["error_code"]?.string)
            }
            let result = try CouncilResult.resolve(votes)
            let eligible = try councilTaskIsCurrent(task)
            guard try db.query("SELECT status FROM classification_runs WHERE id=?", [.text(task.runID)]).first?.text("status") == "running" else { throw LedgerError.conflict }
            try db.query("UPDATE classification_runs SET status=?,finished_at_ms=?,type_code=?,category_id=?,needs_review=1,degraded=?,error_code=?,output_json=? WHERE id=?",
                         [.text(result.decision == nil ? "failed" : "succeeded"), .integer(nowMS()), .optional(result.decision?.type), .optional(result.decision?.category), .integer(result.degraded ? 1 : 0),
                          .optional(result.decision == nil ? "no_consensus" : nil), .text(try json(result)), .text(task.runID)])
            if eligible, let decision = result.decision {
                try assign(partID: task.partID, type: decision.type, category: decision.category, review: true, origin: "council", runID: task.runID)
            }
            try db.query("UPDATE classification_jobs SET status=?,updated_at_ms=?,error_code=? WHERE id=? AND run_id=?",
                         [.text(!eligible ? "obsolete" : result.decision == nil ? "failed" : "succeeded"), .integer(nowMS()), .optional(result.decision == nil ? "no_consensus" : nil), .text(task.id), .text(task.runID)])
            return result
        }
    }
    public func councilReport(transactionID: String) throws -> CouncilReport? {
        guard let row = try db.query("""
            SELECT r.*,t.revision AS current_revision FROM classification_runs r JOIN transaction_parts p ON p.id=r.part_id
            JOIN transactions t ON t.id=p.transaction_id
            WHERE p.transaction_id=? AND r.kind='council' AND r.output_json IS NOT NULL
            ORDER BY r.started_at_ms DESC,r.rowid DESC LIMIT 1
            """, [.text(transactionID)]).first else { return nil }
        let result = try JSONDecoder().decode(CouncilResult.self, from: Data(row.text("output_json").utf8))
        let search = try row["merchant_search_json"]?.string.map { try JSONDecoder().decode(MerchantSearchEvidence.self, from: Data($0.utf8)) }
        let shared = try !db.query("SELECT 1 FROM council_member_inputs i JOIN model_versions m ON m.id=i.model_version_id WHERE i.council_run_id=? AND m.provider='apple_shortcut' AND i.receipt_shared=1", [.text(row.text("id"))]).isEmpty
        return CouncilReport(runID: row.text("id"), result: result, search: search, receiptSharedWithApple: shared,
                             isCurrentRevision: row.number("input_revision") == row.number("current_revision"))
    }
}
