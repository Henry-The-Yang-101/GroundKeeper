import Foundation

extension LedgerStore {
    public func cardAccountMappings() throws -> [CardAccountMapping] {
        try db.query("""
            SELECT m.*,s.name FROM source_account_mappings m JOIN sources s ON s.id=m.source_id
            WHERE m.valid_until_ms IS NULL ORDER BY s.name,m.external_account_key,m.id
            """).map {
                CardAccountMapping(id: $0.text("id"), sourceID: $0.text("source_id"), sourceName: $0.text("name"),
                                   label: String($0.text("external_account_key").dropFirst("label:".count)), accountID: $0.text("account_id"))
            }
    }

    /// Assign this capture only. Remembering is explicit and never replays other reviews.
    public func assignCaptureAccount(eventID: String, accountID: String, remember: Bool = false) throws {
        guard let selected = try account(accountID) else { throw LedgerError.invalid("Choose an existing account.") }
        try db.transaction {
            let envelope = try unmappedCapture(eventID: eventID)
            let observation = try CaptureParser.parse(envelope, account: selected)
            if remember {
                guard observation.error == nil else { throw LedgerError.invalid("Correct the capture details before remembering its card mapping.") }
                try rememberCard(sourceID: envelope.sourceID, label: envelope.label, accountID: accountID)
            }
            try resolveReviews(eventID)
            try process(observation, eventID: eventID, sourceID: envelope.sourceID, kind: envelope.sourceKind)
        }
    }

    public func updateCardMapping(id: String, accountID: String) throws {
        guard try account(accountID) != nil else { throw LedgerError.invalid("Choose an existing account.") }
        try db.transaction {
            guard let mapping = try db.query("SELECT * FROM source_account_mappings WHERE id=? AND valid_until_ms IS NULL", [.text(id)]).first else {
                throw LedgerError.invalid("This mapping has changed. Refresh Settings and try again.")
            }
            try rememberCard(sourceID: mapping.text("source_id"), label: String(mapping.text("external_account_key").dropFirst("label:".count)), accountID: accountID)
        }
    }

    public func removeCardMapping(id: String) throws {
        // Retain mapping history without changing transactions that already used it.
        try db.query("UPDATE source_account_mappings SET valid_until_ms=max(?,valid_from_ms+1) WHERE id=? AND valid_until_ms IS NULL", [.integer(nowMS()), .text(id)])
    }

    /// Must run inside the caller's transaction. Active rules govern future imports,
    /// including delayed iCloud deliveries, rather than inferring purchase-time identity.
    func rememberCard(sourceID: String, label: String, accountID: String) throws {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LedgerError.invalid("This capture has no card description to remember.")
        }
        let key = "label:" + label
        let history = try db.query("SELECT * FROM source_account_mappings WHERE source_id=? AND external_account_key=? ORDER BY valid_from_ms DESC LIMIT 1", [.text(sourceID), .text(key)]).first
        if let history, history["valid_until_ms"]?.int == nil, history.text("account_id") == accountID { return }
        // Strictly increasing boundaries also handle two edits in the same millisecond.
        let start = max(nowMS(), (history?.number("valid_from_ms") ?? -1) + 1, history?["valid_until_ms"]?.int ?? 0)
        try db.query("UPDATE source_account_mappings SET valid_until_ms=? WHERE source_id=? AND external_account_key=? AND valid_until_ms IS NULL", [.integer(start), .text(sourceID), .text(key)])
        try db.query("INSERT INTO source_account_mappings(id,source_id,external_account_key,account_id,valid_from_ms,confirmed_at_ms) VALUES (?,?,?,?,?,?)",
                     [.text(identifier()), .text(sourceID), .text(key), .text(accountID), .integer(start), .integer(nowMS())])
    }

    func unmappedCapture(eventID: String) throws -> CaptureEnvelope {
        guard let row = try db.query("""
            SELECT p.payload_json FROM raw_events e JOIN raw_event_payloads p ON p.event_id=e.id
            WHERE e.id=? AND e.is_test=0
            AND NOT EXISTS(SELECT 1 FROM transaction_event_links WHERE event_id=e.id AND unlinked_at_ms IS NULL)
            AND NOT EXISTS(SELECT 1 FROM review_items WHERE event_id=e.id AND reason_code='event_identity_collision')
            """, [.text(eventID)]).first else {
                throw LedgerError.invalid("This capture already has a transaction, is test evidence, or has an identity conflict.")
            }
        return try CaptureParser.decode(Data(row.text("payload_json").utf8))
    }
}
