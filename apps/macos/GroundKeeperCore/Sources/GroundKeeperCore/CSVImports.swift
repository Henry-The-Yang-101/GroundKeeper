import Foundation

public struct CSVImportHistory: Sendable {
    public let mapping: CSVMapping
    public let importedRows: Set<Int>
}

extension LedgerStore {
    public func csvImportHistory(hash: String, accountID: String) throws -> CSVImportHistory? {
        guard let batch = try db.query("SELECT * FROM import_batches WHERE source_id=? AND account_scope_id=? AND file_sha256=? AND status='committed'",
            [.text("csv:" + accountID), .text(accountID), .text(hash)]).first else { return nil }
        let mapping = try JSONDecoder().decode(CSVMapping.self, from: Data(batch.text("mapping_snapshot_json").utf8))
        let rows = try db.query("SELECT row_number FROM import_rows WHERE batch_id=? AND event_id IS NOT NULL", [.text(batch.text("id"))])
        return CSVImportHistory(mapping: mapping, importedRows: Set(rows.map { Int($0.number("row_number")) }))
    }

    @discardableResult public func importCSV(_ document: CSVDocument, mapping: CSVMapping, skipped: Set<Int> = [], updateExisting: Bool = false) throws -> Int {
        guard let selected = try account(mapping.accountID), selected.currency == mapping.currency else { throw LedgerError.invalid("Select an account with the import currency.") }
        let sourceID = "csv:" + mapping.accountID
        return try db.transaction {
            try db.query("INSERT OR IGNORE INTO sources(id,kind,name,created_at_ms) VALUES (?,'csv','CSV import',?)", [.text(sourceID), .integer(nowMS())])
            let old = try db.query("SELECT * FROM import_batches WHERE source_id=? AND account_scope_id=? AND file_sha256=?", [.text(sourceID), .text(mapping.accountID), .text(document.hash)]).first
            let batch = old?.text("id") ?? identifier()
            let oldMapping = try old.map { try JSONDecoder().decode(CSVMapping.self, from: Data($0.text("mapping_snapshot_json").utf8)) }
            let mappingChanged = oldMapping.map { $0 != mapping } ?? false
            if mappingChanged && !updateExisting { throw LedgerError.invalid("This file used a different mapping. Choose Review mapping corrections to update its imported rows.") }
            if old == nil {
                try db.query("INSERT INTO import_batches(id,source_id,account_scope_id,file_sha256,original_filename,mapping_snapshot_json,status,created_at_ms) VALUES (?,?,?,?,?,?,'preview',?)",
                    [.text(batch), .text(sourceID), .text(mapping.accountID), .text(document.hash), .text(document.filename), .text(try json(mapping)), .integer(nowMS())])
            }
            var count = 0
            for (index, cells) in document.rows.enumerated() {
                let number = index + 2
                let prior = try db.query("SELECT * FROM import_rows WHERE batch_id=? AND row_number=?", [.text(batch), .integer(Int64(number))]).first
                if let eventID = prior?["event_id"]?.string {
                    guard mappingChanged else { continue }
                    // Corrected mappings are proposals. Never rewrite a saved
                    // transaction merely because the same file was opened again.
                    let observation = try CSVParser.observation(cells, mapping: mapping, width: document.headers.count)
                    if let target = try db.query("SELECT transaction_id FROM transaction_event_links WHERE event_id=? AND unlinked_at_ms IS NULL", [.text(eventID)]).first {
                        _ = try recordObservation(observation, eventID: eventID)
                        try resolveReviews(eventID)
                        try review(eventID: eventID, reason: "csv_mapping_changed", candidates: [target.text("transaction_id")])
                    } else {
                        try resolveReviews(eventID)
                        try process(observation, eventID: eventID, sourceID: sourceID, kind: "csv")
                    }
                    count += 1
                    continue
                }
                if skipped.contains(number) {
                    try db.query("INSERT OR IGNORE INTO import_rows(id,batch_id,row_number,status,row_json) VALUES (?,?,?,'skipped',?)",
                        [.text(identifier()), .text(batch), .integer(Int64(number)), .text(try json(cells))])
                    continue
                }
                let observation = try CSVParser.observation(cells, mapping: mapping, width: document.headers.count)
                let eventID = identifier(), payload = try json(cells)
                try db.query("INSERT INTO raw_events(id,source_id,source_event_id,schema_version,event_kind,captured_at_ms,captured_offset_minutes,received_at_ms,payload_sha256,external_account_key) VALUES (?,?,?,1,'transaction',?,0,?,?,?)",
                    [.text(eventID), .text(sourceID), .text(document.hash + ":" + String(number)), .integer(nowMS()), .integer(nowMS()), .text(contentHash(Data(payload.utf8))), .text(mapping.accountID)])
                try db.query("INSERT INTO raw_event_payloads(event_id,payload_json) VALUES (?,?)", [.text(eventID), .text(payload)])
                try db.query("INSERT INTO import_rows(id,batch_id,row_number,event_id,status,row_json) VALUES (?,?,?,?,'accepted',?) ON CONFLICT(batch_id,row_number) DO UPDATE SET event_id=excluded.event_id,status='accepted'",
                    [.text(identifier()), .text(batch), .integer(Int64(number)), .text(eventID), .text(payload)])
                try process(observation, eventID: eventID, sourceID: sourceID, kind: "csv")
                count += 1
            }
            try db.query("UPDATE import_batches SET status='committed',committed_at_ms=?,mapping_snapshot_json=? WHERE id=?", [.integer(nowMS()), .text(try json(mapping)), .text(batch)])
            if mappingChanged {
                try db.query("INSERT INTO change_log(id,operation_id,entity_type,entity_id,actor,reason,changed_at_ms,before_json,after_json) VALUES (?,?,'import_batch',?,'user','correct_csv_mapping',?,?,?)",
                    [.text(identifier()), .text(identifier()), .text(batch), .integer(nowMS()), .text(old!.text("mapping_snapshot_json")), .text(try json(mapping))])
            }
            return count
        }
    }

    /// CSV conflicts compare statement facts with an existing entry. They never
    /// pass array-shaped CSV evidence through the phone capture decoder.
    public func resolveCSVReview(eventID: String, useStatement: Bool, expectedRevision: Int? = nil) throws {
        try db.transaction {
            guard let row = try db.query("""
                SELECT o.*,e.source_id FROM event_observations o JOIN raw_events e ON e.id=o.event_id
                JOIN sources s ON s.id=e.source_id WHERE o.event_id=? AND s.kind='csv' AND e.is_test=0
                AND EXISTS(SELECT 1 FROM review_items WHERE event_id=e.id AND status='open' AND reason_code IN ('external_id_conflict','csv_mapping_changed'))
                ORDER BY o.parsed_at_ms DESC,o.rowid DESC LIMIT 1
                """, [.text(eventID)]).first else { throw LedgerError.conflict }
            let link = try db.query("SELECT * FROM transaction_event_links WHERE event_id=? AND unlinked_at_ms IS NULL", [.text(eventID)]).first
            let reference = try db.query("SELECT transaction_id FROM external_transaction_refs WHERE source_id=? AND external_account_key=? AND namespace='csv-posted' AND external_record_id=?",
                [.text(row.text("source_id")), .text(row.text("account_id")), .text(row.text("external_record_id"))]).first
            guard let targetID = link?["transaction_id"]?.string ?? reference?["transaction_id"]?.string,
                  let target = try transaction(id: targetID) else { throw LedgerError.invalid("The saved entry is no longer available. Dismiss this review or correct the file’s bank record ID mapping.") }
            if let expectedRevision, target.revision != expectedRevision { throw LedgerError.conflict }
            guard target.accountID == row["account_id"]?.string, target.currency == row.text("currency") else {
                throw LedgerError.invalid("This entry now uses a different account or currency. Correct its account in Transactions before resolving the statement review.")
            }
            if useStatement {
                guard reference == nil || reference?.text("transaction_id") == targetID else { throw LedgerError.invalid("This bank record ID belongs to another entry. Correct its column mapping before applying these details.") }
                let parts = try db.query("SELECT id FROM transaction_parts WHERE transaction_id=?", [.text(targetID)])
                guard parts.count == 1, let amount = row["amount_minor"]?.int, amount != 0 else { throw LedgerError.invalid("Split entries cannot have their statement amount replaced here.") }
                try db.query("UPDATE transactions SET state='draft' WHERE id=?", [.text(targetID)])
                try db.query("UPDATE transactions SET description=?,amount_minor=?,occurred_on=?,time_precision=CASE WHEN occurred_on=? THEN time_precision ELSE 'date' END,occurred_at_ms=CASE WHEN occurred_on=? THEN occurred_at_ms ELSE NULL END,utc_offset_minutes=CASE WHEN occurred_on=? THEN utc_offset_minutes ELSE NULL END,posted_on=?,lifecycle='posted' WHERE id=?",
                    [.text(row.text("description")), .integer(amount), .text(row.text("occurred_on")), .text(row.text("occurred_on")), .text(row.text("occurred_on")), .text(row.text("occurred_on")), .optional(row["posted_on"]?.string), .text(targetID)])
                try db.query("UPDATE transaction_parts SET amount_minor=? WHERE transaction_id=?", [.integer(amount), .text(targetID)])
                if (target.amountMinor < 0) != (amount < 0) {
                    try assign(partID: parts[0].text("id"), type: "unknown", category: nil, review: true, origin: "user", runID: nil)
                    try releaseUncategorizedAssignment(partID: parts[0].text("id"))
                }
                try db.query("UPDATE transactions SET state='active' WHERE id=?", [.text(targetID)])
                try Self.resolveMerchant(db: db, transactionID: targetID, description: row.text("description"))
                try db.query("DELETE FROM external_transaction_refs WHERE first_event_id=? AND external_record_id<>?", [.text(eventID), .text(row.text("external_record_id"))])
                if let external = row["external_record_id"]?.string {
                    let observation = Observation(description: row.text("description"), amount: amount, currency: row["currency"]?.string, day: row.text("occurred_on"), captured: 0, offset: 0, accountID: row["account_id"]?.string, label: "", lifecycle: "posted", dateOnly: true, externalID: external)
                    try externalReference(observation, eventID: eventID, transactionID: targetID, sourceID: row.text("source_id"))
                }
                if let link { try db.query("UPDATE transaction_event_links SET unlinked_at_ms=? WHERE id=?", [.integer(nowMS()), .text(link.text("id"))]) }
            }
            if link == nil || useStatement { try self.link(eventID: eventID, observationID: row.text("id"), transactionID: targetID, kind: "csv", actor: "user") }
            try receiptEvidenceChanged(transactionID: targetID)
            try resolveReviews(eventID)
            try db.query("INSERT INTO change_log(id,operation_id,entity_type,entity_id,actor,reason,changed_at_ms,before_json,after_json) VALUES (?,?,'transaction',?,'user','resolve_csv_review',?,?,?)",
                [.text(identifier()), .text(identifier()), .text(targetID), .integer(nowMS()), .text(try json(["description": target.description, "amount_minor": String(target.amountMinor), "occurred_on": target.occurredOn])), .text(try json(["event_id": eventID, "choice": useStatement ? "statement" : "saved"]))])
        }
    }
}
