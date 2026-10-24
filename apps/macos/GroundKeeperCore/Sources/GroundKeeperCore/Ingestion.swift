import Foundation

extension LedgerStore {
    public func captureIsTerminal(path: String, hash: String) throws -> Bool {
        let id = contentHash(Data("\(path)|\(hash)".utf8))
        let state = try db.query("SELECT state FROM queue_items WHERE id=?", [.text(id)]).first?.text("state")
        return state == "imported" || state == "quarantined"
    }
    /// A delivery is durable only after its raw event, observation and disposition commit together.
    public func ingestCapture(data: Data, deliveryPath: String, forceRetry: Bool = false) throws {
        let hash = contentHash(data)
        let queueID = contentHash(Data("\(deliveryPath)|\(hash)".utf8))
        if let old = try db.query("SELECT * FROM queue_items WHERE id=?", [.text(queueID)]).first, !forceRetry {
            if ["imported", "quarantined"].contains(old.text("state")) || old.number("next_attempt_at_ms") > nowMS() { return }
        }
        try db.query("INSERT OR IGNORE INTO queue_items(id,relative_path,content_sha256,state,first_seen_at_ms) VALUES (?,?,?,'discovered',?)", [.text(queueID), .text(deliveryPath), .text(hash), .integer(nowMS())])
        try db.query("UPDATE queue_items SET attempt_count=attempt_count+1,last_attempt_at_ms=? WHERE id=?", [.integer(nowMS()), .text(queueID)])
        do {
            if let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any], header["source"] as? String == "receipt_attachment" {
                try ingestReceipt(data: data, queueID: queueID, hash: hash)
                return
            }
            let envelope = try CaptureParser.decode(data)
            let (captured, offset) = try CaptureParser.timestamp(envelope.capturedAt)
            try db.transaction {
                try db.query("INSERT OR IGNORE INTO sources(id,kind,name,configuration_json,created_at_ms) VALUES (?,?,?,?,?)", [.text(envelope.sourceID), .text(envelope.sourceKind), .text(envelope.app ?? envelope.source), .text("{}"), .integer(nowMS())])
                if let existing = try db.query("SELECT id,payload_sha256 FROM raw_events WHERE source_id=? AND source_event_id=?", [.text(envelope.sourceID), .text(envelope.eventID)]).first {
                    if existing.text("payload_sha256") != hash {
                        try review(eventID: existing.text("id"), reason: "event_identity_collision")
                        try db.query("UPDATE queue_items SET state='quarantined',error_code='event_identity_collision',event_id=? WHERE id=?", [.text(existing.text("id")), .text(queueID)])
                        return
                    }
                    try receipt(eventID: existing.text("id"), delivery: queueID, hash: hash)
                    try db.query("UPDATE queue_items SET state='imported',event_id=?,error_code=NULL WHERE id=?", [.text(existing.text("id")), .text(queueID)])
                    return
                }
                let eventID = identifier()
                try db.query("INSERT INTO raw_events(id,source_id,source_event_id,schema_version,event_kind,captured_at_ms,captured_offset_minutes,received_at_ms,payload_sha256,is_test,external_account_key) VALUES (?,?,?,?,'transaction',?,?,?,?,?,?)",
                    [.text(eventID), .text(envelope.sourceID), .text(envelope.eventID), .integer(Int64(envelope.schemaVersion)), .integer(captured), .integer(Int64(offset)), .integer(nowMS()), .text(hash), .integer(envelope.isTest == true ? 1 : 0), .text("label:" + envelope.label)])
                try db.query("INSERT INTO raw_event_payloads(event_id,payload_json) VALUES (?,?)", [.text(eventID), .text(String(decoding: data, as: UTF8.self))])
                try storeCaptureDetails(envelope, eventID: eventID, data: data, hash: hash)
                try receipt(eventID: eventID, delivery: queueID, hash: hash)
                if envelope.isTest != true { try parseAndReconcile(envelope, eventID: eventID) }
                try db.query("UPDATE queue_items SET state='imported',event_id=?,error_code=NULL,next_attempt_at_ms=NULL WHERE id=?", [.text(eventID), .text(queueID)])
            }
        } catch {
            let attempts = try db.query("SELECT attempt_count FROM queue_items WHERE id=?", [.text(queueID)]).first!.number("attempt_count")
            try db.query("UPDATE queue_items SET state=?,error_code='invalid_capture',next_attempt_at_ms=? WHERE id=?",
                [.text(attempts >= 3 ? "quarantined" : "waiting"), .integer(nowMS() + min(300_000, 5000 * attempts * attempts)), .text(queueID)])
            if case LedgerError.storage = error { throw error }
        }
    }
    func receipt(eventID: String, delivery: String, hash: String) throws {
        try db.query("INSERT OR IGNORE INTO event_receipts(id,event_id,delivery_key,received_at_ms,payload_sha256) VALUES (?,?,?,?,?)", [.text(identifier()), .text(eventID), .text(delivery), .integer(nowMS()), .text(hash)])
    }
    func parseAndReconcile(_ envelope: CaptureEnvelope, eventID: String) throws {
        let mapped = envelope.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try db.query(
            "SELECT account_id FROM source_account_mappings WHERE source_id=? AND external_account_key=? AND valid_until_ms IS NULL",
            [.text(envelope.sourceID), .text("label:" + envelope.label)]).first?["account_id"]?.string
        let selected = try mapped.flatMap { try account($0) }
        let observation = try CaptureParser.parse(envelope, account: selected)
        try process(observation, eventID: eventID, sourceID: envelope.sourceID, kind: envelope.sourceKind)
    }
    public func confirmMapping(sourceID: String, label: String, accountID: String) throws {
        guard try account(accountID) != nil else { throw LedgerError.invalid("Choose an existing account.") }
        try db.transaction {
            try rememberCard(sourceID: sourceID, label: label, accountID: accountID)
            let events = try db.query("""
                SELECT e.id,p.payload_json FROM raw_events e JOIN raw_event_payloads p ON p.event_id=e.id
                WHERE e.source_id=? AND e.external_account_key=? AND e.is_test=0
                AND NOT EXISTS(SELECT 1 FROM transaction_event_links WHERE event_id=e.id AND unlinked_at_ms IS NULL)
                AND EXISTS(SELECT 1 FROM review_items WHERE event_id=e.id AND status='open' AND reason_code IN ('account_mapping_required','currency_required'))
                AND NOT EXISTS(SELECT 1 FROM review_items WHERE event_id=e.id AND reason_code='event_identity_collision')
                """, [.text(sourceID), .text("label:" + label)])
            for event in events {
                let envelope = try CaptureParser.decode(Data(event.text("payload_json").utf8))
                try resolveReviews(event.text("id")); try parseAndReconcile(envelope, eventID: event.text("id"))
            }
        }
    }
    func process(_ observation: Observation, eventID: String, sourceID: String, kind: String) throws {
        let observationID = identifier()
        try db.query("INSERT INTO event_observations(id,event_id,parser_version,parsed_at_ms,status,amount_minor,currency,occurred_on,time_precision,posted_on,description,merchant_text,account_id,instrument_text,lifecycle,external_record_id,error_code) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [.text(observationID), .text(eventID), .text("swift-v1:" + observationID), .integer(nowMS()), .text(observation.error == nil ? "parsed" : "partial"), .optional(observation.amount), .optional(observation.currency), .text(observation.day), .text(observation.dateOnly ? "date" : "unknown"), observation.dateOnly ? .text(observation.day) : .null, .text(observation.description), .text(observation.description), .optional(observation.accountID), .text(observation.label), .text(observation.lifecycle), .optional(observation.externalID), .optional(observation.error)])
        if let error = observation.error { try review(eventID: eventID, reason: error); return }
        guard observation.amount != nil, observation.currency != nil, observation.accountID != nil else { try review(eventID: eventID, reason: "incomplete_observation"); return }
        if let external = observation.externalID, let existing = try db.query("SELECT r.transaction_id,t.amount_minor,t.currency,t.state FROM external_transaction_refs r JOIN transactions t ON t.id=r.transaction_id WHERE r.source_id=? AND r.external_account_key=? AND r.namespace='csv-posted' AND r.external_record_id=?",
            [.text(sourceID), .text(observation.accountID!), .text(external)]).first {
            guard existing.number("amount_minor") == observation.amount, existing.text("currency") == observation.currency, existing.text("state") == "active" else { try review(eventID: eventID, reason: "external_id_conflict"); return }
            try link(eventID: eventID, observationID: observationID, transactionID: existing.text("transaction_id"), kind: kind, actor: "system")
            return
        }
        let candidates = try db.query("""
            SELECT t.id,t.description,t.lifecycle,
              (SELECT min(e.captured_at_ms) FROM transaction_event_links l JOIN raw_events e ON e.id=l.event_id WHERE l.transaction_id=t.id AND l.unlinked_at_ms IS NULL) AS capture_time,
              EXISTS(SELECT 1 FROM transaction_event_links l JOIN raw_events e ON e.id=l.event_id JOIN sources s ON s.id=e.source_id
                WHERE l.transaction_id=t.id AND l.unlinked_at_ms IS NULL AND s.kind=?) AS same_kind,
              EXISTS(SELECT 1 FROM transaction_event_links l JOIN raw_events e ON e.id=l.event_id JOIN sources s ON s.id=e.source_id
                WHERE l.transaction_id=t.id AND l.unlinked_at_ms IS NULL AND s.kind IN ('apple_wallet','bank_notification')) AS has_capture
            FROM transactions t WHERE t.state='active' AND t.account_id=? AND t.currency=? AND t.amount_minor=?
              AND t.occurred_on BETWEEN date(?,'-3 days') AND date(?,'+3 days')
            """, [.text(kind), .text(observation.accountID!), .text(observation.currency!), .integer(observation.amount!), .text(observation.day), .text(observation.day)])
        let matches = candidates.filter { normalize($0.text("description")) == normalize(observation.description) }
        let possible = matches.filter { kind == "csv" || $0.number("same_kind") == 0 }
        let captures = matches.filter { $0.number("same_kind") == 0 && $0.number("has_capture") == 1 && abs($0.number("capture_time") - observation.captured) <= 300_000 && $0.text("lifecycle") == "pending" }
        if kind != "csv", captures.count == 1, possible.count == 1 {
            try link(eventID: eventID, observationID: observationID, transactionID: captures[0].text("id"), kind: kind, actor: "system")
        } else if !possible.isEmpty {
            try review(eventID: eventID, reason: "possible_duplicate", candidates: possible.map { $0.text("id") })
        } else {
            // Distinct same-source captures are distinct purchases. No merchant/amount hash dedup.
            let transactionID = try createTransaction(observation)
            try link(eventID: eventID, observationID: observationID, transactionID: transactionID, kind: kind, actor: "system")
            try externalReference(observation, eventID: eventID, transactionID: transactionID, sourceID: sourceID)
        }
    }
    func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    func createTransaction(_ observation: Observation) throws -> String {
        let id = identifier(), partID = identifier()
        try db.query("INSERT INTO transactions(id,account_id,description,amount_minor,currency,occurred_on,time_precision,posted_on,lifecycle,created_at_ms,updated_at_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            [.text(id), .optional(observation.accountID), .text(observation.description), .integer(observation.amount!), .text(observation.currency!), .text(observation.day), .text(observation.dateOnly ? "date" : "unknown"), observation.dateOnly ? .text(observation.day) : .null, .text(observation.lifecycle), .integer(nowMS()), .integer(nowMS())])
        try db.query("INSERT INTO transaction_parts(id,transaction_id,position,amount_minor) VALUES (?,?,0,?)", [.text(partID), .text(id), .integer(observation.amount!)])
        try assign(partID: partID, type: "unknown", category: "uncategorized", review: true, origin: "system", runID: nil)
        try db.query("UPDATE transactions SET state='active' WHERE id=?", [.text(id)])
        try Self.resolveMerchant(db: db, transactionID: id, description: observation.description)
        return id
    }
    func link(eventID: String, observationID: String, transactionID: String, kind: String, actor: String) throws {
        let decisionID = identifier()
        try db.query("INSERT INTO reconciliation_decisions(id,event_id,left_transaction_id,action,actor,algorithm_version,evidence_json,created_at_ms) VALUES (?,?,?,'link',?,'swift-v1','{}',?)", [.text(decisionID), .text(eventID), .text(transactionID), .text(actor), .integer(nowMS())])
        try db.query("INSERT INTO transaction_event_links(id,transaction_id,event_id,observation_id,role,decision_id,linked_at_ms) VALUES (?,?,?,?,?,?,?)", [.text(identifier()), .text(transactionID), .text(eventID), .text(observationID), .text(kind == "csv" ? "posted" : "capture"), .text(decisionID), .integer(nowMS())])
        if kind == "csv" {
            let observation = try db.query("SELECT posted_on FROM event_observations WHERE id=?", [.text(observationID)]).first!
            try db.query("UPDATE transactions SET lifecycle='posted',posted_on=?,revision=revision+1,updated_at_ms=? WHERE id=?", [.optional(observation["posted_on"]?.string), .integer(nowMS()), .text(transactionID)])
        }
        try resolveReceiptLinks()
    }
    func externalReference(_ observation: Observation, eventID: String, transactionID: String, sourceID: String) throws {
        if let external = observation.externalID {
            try db.query("INSERT OR IGNORE INTO external_transaction_refs(id,source_id,external_account_key,namespace,external_record_id,transaction_id,first_event_id) VALUES (?,?,?,'csv-posted',?,?,?)", [.text(identifier()), .text(sourceID), .text(observation.accountID!), .text(external), .text(transactionID), .text(eventID)])
        }
    }
    public func resolveMatch(eventID: String, transactionID: String?) throws {
        try db.transaction {
            guard let row = try db.query("SELECT o.*,s.kind,e.source_id FROM event_observations o JOIN raw_events e ON e.id=o.event_id JOIN sources s ON s.id=e.source_id WHERE o.event_id=? AND e.is_test=0 ORDER BY o.parsed_at_ms DESC,o.rowid DESC LIMIT 1", [.text(eventID)]).first,
                  row.text("status") == "parsed", try db.query("SELECT id FROM transaction_event_links WHERE event_id=? AND unlinked_at_ms IS NULL", [.text(eventID)]).isEmpty else { throw LedgerError.invalid("This event cannot be reconciled yet.") }
            let observation = Observation(description: row.text("description"), amount: row["amount_minor"]?.int, currency: row["currency"]?.string, day: row.text("occurred_on"), captured: 0, offset: 0, accountID: row["account_id"]?.string, label: row.text("instrument_text"), lifecycle: row.text("lifecycle"), dateOnly: row.text("time_precision") == "date", externalID: row["external_record_id"]?.string)
            guard observation.amount != nil, observation.currency != nil, observation.accountID != nil else { throw LedgerError.invalid("Complete the account and amount first.") }
            let target: String
            if let transactionID {
                guard let existing = try db.query("SELECT * FROM transactions WHERE id=? AND state='active'", [.text(transactionID)]).first,
                      existing.number("amount_minor") == observation.amount, existing.text("currency") == observation.currency, existing["account_id"]?.string == observation.accountID else { throw LedgerError.invalid("Only matching account, currency and amount can be linked.") }
                target = transactionID
            } else { target = try createTransaction(observation) }
            try link(eventID: eventID, observationID: row.text("id"), transactionID: target, kind: row.text("kind"), actor: "user")
            try externalReference(observation, eventID: eventID, transactionID: target, sourceID: row.text("source_id"))
            try resolveReviews(eventID)
        }
    }
    public func dismissReview(_ id: String) throws {
        try db.query("UPDATE review_items SET status='dismissed',resolved_at_ms=?,resolution='user_dismissed' WHERE id=?", [.integer(nowMS()), .text(id)])
    }
    public func correctCapture(eventID: String, description: String, amountMinor: Int64, accountID: String, day: String, remember: Bool = false) throws {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, description.count <= 2048,
              amountMinor != 0, amountMinor != Int64.min, let account = try account(accountID) else { throw LedgerError.invalid("Enter a description, nonzero amount and account.") }
        _ = try CivilDate.parse(day)
        try db.transaction {
            let envelope = try unmappedCapture(eventID: eventID)
            guard let event = try db.query("SELECT e.*,s.kind FROM raw_events e JOIN sources s ON s.id=e.source_id WHERE e.id=? AND e.is_test=0", [.text(eventID)]).first,
                  try db.query("SELECT id FROM transaction_event_links WHERE event_id=? AND unlinked_at_ms IS NULL", [.text(eventID)]).isEmpty else { throw LedgerError.invalid("This capture already has a transaction or is test evidence.") }
            if remember { try rememberCard(sourceID: envelope.sourceID, label: envelope.label, accountID: accountID) }
            let observation = Observation(description: description, amount: amountMinor, currency: account.currency, day: day, captured: event.number("captured_at_ms"), offset: Int(event.number("captured_offset_minutes")), accountID: accountID, label: envelope.label, lifecycle: "pending", dateOnly: true)
            try resolveReviews(eventID)
            try process(observation, eventID: eventID, sourceID: event.text("source_id"), kind: event.text("kind"))
            try db.query("INSERT INTO change_log(id,operation_id,entity_type,entity_id,actor,reason,changed_at_ms,after_json) VALUES (?,?,'raw_event',?,'user','correct_observation',?,?)", [.text(identifier()), .text(identifier()), .text(eventID), .integer(nowMS()), .text(try json(observation))])
        }
    }
    public func retryQueue() throws {
        try db.query("UPDATE queue_items SET state='waiting',attempt_count=0,next_attempt_at_ms=0 WHERE state IN ('waiting','quarantined') AND error_code IS NOT 'event_identity_collision'")
        try db.query("UPDATE receipt_captures SET image_state='pending',image_error=NULL WHERE image_state='invalid'")
    }
    @discardableResult public func importCSV(_ document: CSVDocument, mapping: CSVMapping, skipped: Set<Int> = []) throws -> Int {
        guard let selected = try account(mapping.accountID), selected.currency == mapping.currency else { throw LedgerError.invalid("Select an account with the import currency.") }
        let sourceID = "csv:" + mapping.accountID
        return try db.transaction {
            try db.query("INSERT OR IGNORE INTO sources(id,kind,name,created_at_ms) VALUES (?,'csv','CSV import',?)", [.text(sourceID), .integer(nowMS())])
            if !(try db.query("SELECT id FROM import_batches WHERE source_id=? AND account_scope_id=? AND file_sha256=? AND status='committed'", [.text(sourceID), .text(mapping.accountID), .text(document.hash)])).isEmpty { return 0 }
            let batch = identifier()
            try db.query("INSERT INTO import_batches(id,source_id,account_scope_id,file_sha256,original_filename,mapping_snapshot_json,status,created_at_ms) VALUES (?,?,?,?,?,?,'preview',?)", [.text(batch), .text(sourceID), .text(mapping.accountID), .text(document.hash), .text(document.filename), .text(try json(mapping)), .integer(nowMS())])
            var count = 0
            for (index, cells) in document.rows.enumerated() {
                let rowNumber = index + 2, rowID = identifier()
                if skipped.contains(rowNumber) {
                    try db.query("INSERT INTO import_rows(id,batch_id,row_number,status,row_json) VALUES (?,?,?,'skipped',?)", [.text(rowID), .text(batch), .integer(Int64(rowNumber)), .text(try json(cells))]); continue
                }
                let observation = try CSVParser.observation(cells, mapping: mapping, width: document.headers.count)
                let eventID = identifier(), payload = try json(cells), hash = contentHash(Data(payload.utf8))
                try db.query("INSERT INTO raw_events(id,source_id,source_event_id,schema_version,event_kind,captured_at_ms,captured_offset_minutes,received_at_ms,payload_sha256,external_account_key) VALUES (?,?,?,1,'transaction',?,0,?,?,?)", [.text(eventID), .text(sourceID), .text(document.hash + ":" + String(rowNumber)), .integer(nowMS()), .integer(nowMS()), .text(hash), .text(mapping.accountID)])
                try db.query("INSERT INTO raw_event_payloads(event_id,payload_json) VALUES (?,?)", [.text(eventID), .text(payload)])
                try db.query("INSERT INTO import_rows(id,batch_id,row_number,event_id,status,row_json) VALUES (?,?,?,?,'accepted',?)", [.text(rowID), .text(batch), .integer(Int64(rowNumber)), .text(eventID), .text(payload)])
                try process(observation, eventID: eventID, sourceID: sourceID, kind: "csv")
                count += 1
            }
            try db.query("UPDATE import_batches SET status='committed',committed_at_ms=? WHERE id=?", [.integer(nowMS()), .text(batch)])
            return count
        }
    }
}
