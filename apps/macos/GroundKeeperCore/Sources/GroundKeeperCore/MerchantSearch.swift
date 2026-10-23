import Foundation

public struct MerchantContext: Codable, Sendable, Equatable {
    public let version: String
    public let source: String
    public let results: [Result]
    public struct Result: Codable, Sendable, Equatable {
        public let title: String, body: String, url: String
        public init(title: String, body: String, url: String) { self.title = title; self.body = body; self.url = url }
    }
    public init(results: [Result]) { version = "merchant-search-v1"; source = "duckduckgo"; self.results = results }
    public func validate() throws {
        guard version == "merchant-search-v1", source == "duckduckgo", (1...2).contains(results.count) else { throw LedgerError.invalid("Invalid merchant evidence.") }
        for result in results {
            for (text, limit) in [(result.title, 120), (result.body, 360), (result.url, 320)] {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= limit,
                      !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw LedgerError.invalid("Invalid merchant evidence text.") }
            }
            guard let url = URLComponents(string: result.url), ["https", "http"].contains(url.scheme), url.host != nil,
                  url.user == nil, url.password == nil else { throw LedgerError.invalid("Invalid merchant source URL.") }
        }
        guard try JSONEncoder().encode(self).count <= 1500 else { throw LedgerError.invalid("Merchant evidence is too large.") }
    }
}

public struct MerchantSearchSettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var locality = ""
    public init(enabled: Bool = false, locality: String = "") { self.enabled = enabled; self.locality = locality }
}

public struct MerchantSearchQuery: Codable, Sendable, Equatable {
    public let merchant: String, locality: String
    public var cacheKey: String { contentHash(Data("merchant-search-v1|\(merchant.lowercased())|\(locality.lowercased())".utf8)) }
    public static func make(merchant: String?, description: String, locality: String) -> Self? {
        let raw = merchant?.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = (raw?.isEmpty == false ? raw! : description).precomposedStringWithCanonicalMapping
        // Do not search personal transfer/payee descriptions or payment/account details.
        guard text.range(of: "(?i)@|https?://|\\b(e[ -]?transfer|payroll|salary|account|iban|routing|interac|transfer to|transfer from)\\b", options: .regularExpression) == nil else { return nil }
        text = text.replacingOccurrences(of: "(?i)^(?:pos |purchase |withdrawal from |debit purchase |visa debit |card purchase |sq ?\\*|tst ?\\*)+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)\\b(ref(?:erence)?|auth(?:orization)?|card|acct|terminal)\\b.*$", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[$€£]\\s*\\d+(?:[.,]\\d+)?|\\b\\d+(?:[.,]\\d+)?\\b|[*#]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "[^\\p{L}\\p{N}'’& .-]", with: " ", options: .regularExpression)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let area = locality.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.count >= 3, text.utf8.count <= 120, area.utf8.count <= 80,
              area.range(of: "[^\\p{L} ,.'’-]", options: .regularExpression) == nil else { return nil }
        return Self(merchant: text, locality: area)
    }
}

public struct MerchantSearchEvidence: Codable, Sendable {
    public let query: MerchantSearchQuery?
    public let outcome: String
    public let context: MerchantContext?
    public let fetchedAtMS: Int64
    public let cached: Bool
    public init(query: MerchantSearchQuery?, outcome: String, context: MerchantContext? = nil, fetchedAtMS: Int64 = Int64(Date().timeIntervalSince1970 * 1000), cached: Bool = false) {
        self.query = query; self.outcome = outcome; self.context = context; self.fetchedAtMS = fetchedAtMS; self.cached = cached
    }
}

extension LedgerStore {
    public func merchantSearchSettings() throws -> MerchantSearchSettings {
        guard let row = try db.query("SELECT value_json FROM app_settings WHERE key='merchant_search'").first else { return .init() }
        return try JSONDecoder().decode(MerchantSearchSettings.self, from: Data(row.text("value_json").utf8))
    }
    public func setMerchantSearchSettings(_ settings: MerchantSearchSettings) throws {
        guard settings.locality.utf8.count <= 80, settings.locality.range(of: "[^\\p{L} ,.'’-]", options: .regularExpression) == nil else { throw LedgerError.invalid("Use a city and region, without an address or coordinates.") }
        try db.query("INSERT INTO app_settings(key,value_json,updated_at_ms) VALUES ('merchant_search',?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at_ms=excluded.updated_at_ms", [.text(try json(settings)), .integer(nowMS())])
    }
    public func merchantSearchQuery(for task: ClassificationTask, locality: String) throws -> MerchantSearchQuery? {
        let row = try db.query("SELECT m.name FROM transaction_parts p JOIN transactions t ON t.id=p.transaction_id LEFT JOIN merchants m ON m.id=t.merchant_id WHERE p.id=?", [.text(task.partID)]).first
        var merchant = row?["name"]?.string
        if merchant == nil {
            let rows = try db.query("""
                SELECT json_extract(r.payload_json,'$.merchant') AS merchant FROM transaction_parts p
                JOIN transaction_event_links l ON l.transaction_id=p.transaction_id AND l.unlinked_at_ms IS NULL
                JOIN raw_event_payloads r ON r.event_id=l.event_id
                WHERE p.id=? AND json_type(r.payload_json,'$.merchant')='text'
                """, [.text(task.partID)])
            let names = Set(rows.map { $0.text("merchant") }.filter { !$0.isEmpty })
            if names.count == 1 { merchant = names.first }
        }
        return MerchantSearchQuery.make(merchant: merchant, description: task.description, locality: locality)
    }
    public func cachedMerchantSearch(_ query: MerchantSearchQuery) throws -> MerchantSearchEvidence? {
        guard try merchantSearchSettings().enabled,
              let row = try db.query("SELECT * FROM merchant_search_cache WHERE cache_key=? AND expires_at_ms>?", [.text(query.cacheKey), .integer(nowMS())]).first else { return nil }
        let context = try row["context_json"]?.string.map { try JSONDecoder().decode(MerchantContext.self, from: Data($0.utf8)) }
        try context?.validate()
        return .init(query: query, outcome: row.text("outcome"), context: context, fetchedAtMS: row.number("fetched_at_ms"), cached: true)
    }
    public func cacheMerchantSearch(_ evidence: MerchantSearchEvidence) throws {
        guard let query = evidence.query, ["matched", "no_match"].contains(evidence.outcome), try merchantSearchSettings().enabled else { return }
        try evidence.context?.validate()
        let ttl: Int64 = evidence.context == nil ? 86_400_000 : 2_592_000_000
        try db.query("DELETE FROM merchant_search_cache WHERE expires_at_ms<=?", [.integer(nowMS())])
        try db.query("INSERT OR REPLACE INTO merchant_search_cache VALUES (?,?,?,?,?,?)", [.text(query.cacheKey), .text(try json(query)), .text(evidence.outcome), .optional(try evidence.context.map(json)), .integer(evidence.fetchedAtMS), .integer(evidence.fetchedAtMS + ttl)])
        try db.query("DELETE FROM merchant_search_cache WHERE cache_key IN (SELECT cache_key FROM merchant_search_cache ORDER BY fetched_at_ms DESC LIMIT -1 OFFSET 1000)")
    }
    public func clearMerchantSearchCache() throws { try db.query("DELETE FROM merchant_search_cache") }
    public func merchantSearchNotBeforeMS() throws -> Int64 {
        guard let row = try db.query("SELECT value_json FROM app_settings WHERE key='merchant_search_not_before'").first else { return 0 }
        return Int64(row.text("value_json")) ?? 0
    }
    public func setMerchantSearchNotBeforeMS(_ value: Int64) throws {
        try db.query("INSERT INTO app_settings(key,value_json,updated_at_ms) VALUES ('merchant_search_not_before',?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at_ms=excluded.updated_at_ms", [.text(String(value)), .integer(nowMS())])
    }
    /// Bind the actual wire input before inference; cache refreshes never change run evidence.
    public func bindMerchantSearch(_ evidence: MerchantSearchEvidence, to task: ClassificationTask) throws -> MerchantContext? {
        try db.transaction {
            let settings = try merchantSearchSettings()
            let context = settings.enabled ? evidence.context : nil
            try context?.validate()
            guard let row = try db.query("SELECT input_json FROM classification_runs WHERE id=? AND status='running'", [.text(task.runID)]).first else { throw LedgerError.invalid("Classification is no longer running.") }
            var audit = try JSONSerialization.jsonObject(with: Data(row.text("input_json").utf8)) as! [String: Any]
            if let context { audit["merchant_context"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) }
            var wire = audit
            wire.removeValue(forKey: "wallet_category_source_event_id")
            if let hint = task.walletCategoryRaw { wire["wallet_category_raw"] = hint }
            let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
            let wireData = try JSONSerialization.data(withJSONObject: wire, options: options)
            let auditData = try JSONSerialization.data(withJSONObject: audit, options: options)
            let recorded = settings.enabled ? evidence : MerchantSearchEvidence(query: nil, outcome: "disabled")
            try db.query("UPDATE classification_runs SET input_json=?,input_sha256=?,merchant_search_json=? WHERE id=? AND status='running'", [.text(String(decoding: auditData, as: UTF8.self)), .text(contentHash(wireData)), .text(try json(recorded)), .text(task.runID)])
            return context
        }
    }
}
