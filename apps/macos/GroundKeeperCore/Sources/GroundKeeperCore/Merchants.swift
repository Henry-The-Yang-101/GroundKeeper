import Foundation

/// Versioned, deliberately conservative: preserve punctuation, digits, accents and processor prefixes.
public enum MerchantIdentity {
    public static let version = "descriptor-v1"
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    public static func key(_ text: String) -> String? {
        let value = normalized(text)
        guard value.count >= 2, value.contains(where: { $0.isLetter }),
              !["unknown", "unknown merchant", "purchase", "payment", "transaction", "pos", "card purchase"].contains(value) else { return nil }
        return version + ":" + contentHash(Data(value.utf8))
    }
}

public struct Merchant: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public struct MerchantName: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let merchantID: String
    public let originalMerchantID: String
    public let confirmed: Bool
    public let transactionCount: Int
}
public struct TransactionMerchant: Sendable {
    public let transactionID: String
    public let description: String
    public let merchantID: String?
    public let overridden: Bool
    public let revision: Int64
}

extension LedgerStore {
    static func resolveMerchant(db: Database, transactionID: String, description: String) throws {
        guard let row = try db.query("SELECT merchant_override FROM transactions WHERE id=?", [.text(transactionID)]).first,
              row.number("merchant_override") == 0 else { return }
        guard let key = MerchantIdentity.key(description) else {
            try db.query("UPDATE transactions SET merchant_id=NULL,merchant_key=NULL,merchant_resolved=1 WHERE id=?", [.text(transactionID)])
            return
        }
        let original = "merchant:" + key
        if try db.query("SELECT key FROM merchant_names WHERE key=?", [.text(key)]).isEmpty {
            try db.query("INSERT OR IGNORE INTO merchants(id,name,created_at_ms) VALUES (?,?,?)",
                         [.text(original), .text(description.trimmingCharacters(in: .whitespacesAndNewlines)), .integer(nowMS())])
            try db.query("INSERT INTO merchant_names(key,label,merchant_id,original_merchant_id,updated_at_ms) VALUES (?,?,?,?,?)",
                         [.text(key), .text(description), .text(original), .text(original), .integer(nowMS())])
        }
        try db.query("UPDATE transactions SET merchant_id=(SELECT merchant_id FROM merchant_names WHERE key=?),merchant_key=?,merchant_resolved=1 WHERE id=?",
                     [.text(key), .text(key), .text(transactionID)])
    }

    public func merchants() throws -> [Merchant] {
        try db.query("SELECT id,name FROM merchants WHERE archived_at_ms IS NULL ORDER BY name COLLATE NOCASE,id")
            .map { Merchant(id: $0.text("id"), name: $0.text("name")) }
    }
    public func merchantNames() throws -> [MerchantName] {
        try db.query("""
            SELECT n.*,count(t.id) AS n FROM merchant_names n LEFT JOIN transactions t
              ON t.merchant_key=n.key AND t.merchant_override=0 AND t.state='active'
            GROUP BY n.key ORDER BY n.label COLLATE NOCASE,n.key
            """).map { MerchantName(key: $0.text("key"), label: $0.text("label"), merchantID: $0.text("merchant_id"),
                                    originalMerchantID: $0.text("original_merchant_id"), confirmed: $0.number("confirmed") == 1, transactionCount: Int($0.number("n"))) }
    }
    public func createMerchant(name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, !name.contains("\0") else { throw LedgerError.invalid("Enter a merchant name of at most 200 characters.") }
        let id = identifier()
        try db.query("INSERT INTO merchants(id,name,created_at_ms) VALUES (?,?,?)", [.text(id), .text(name), .integer(nowMS())])
        return id
    }

    /// Explicit alias rule. Applies to existing automatic matches and future imports, never per-purchase overrides.
    public func groupMerchantName(key: String, merchantID: String, expectedMerchantID: String) throws {
        try db.transaction {
            guard let old = try db.query("SELECT * FROM merchant_names WHERE key=?", [.text(key)]).first,
                  old.text("merchant_id") == expectedMerchantID else { throw LedgerError.conflict }
            guard try db.query("SELECT id FROM merchants WHERE id=? AND archived_at_ms IS NULL", [.text(merchantID)]).count == 1 else { throw LedgerError.invalid("Choose an existing merchant.") }
            try db.query("UPDATE merchant_names SET merchant_id=?,confirmed=1,updated_at_ms=? WHERE key=?", [.text(merchantID), .integer(nowMS()), .text(key)])
            try db.query("UPDATE transactions SET merchant_id=?,revision=revision+1,updated_at_ms=? WHERE merchant_key=? AND merchant_override=0", [.text(merchantID), .integer(nowMS()), .text(key)])
            try merchantAudit(entity: "merchant_name", id: key, before: old.text("merchant_id"), after: merchantID)
        }
    }
    public func restoreMerchantName(key: String, expectedMerchantID: String) throws {
        try db.transaction {
            guard let old = try db.query("SELECT original_merchant_id FROM merchant_names WHERE key=? AND merchant_id=?", [.text(key), .text(expectedMerchantID)]).first else { throw LedgerError.conflict }
            let original = old.text("original_merchant_id")
            try db.query("UPDATE merchant_names SET merchant_id=?,confirmed=0,updated_at_ms=? WHERE key=?", [.text(original), .integer(nowMS()), .text(key)])
            try db.query("UPDATE transactions SET merchant_id=?,revision=revision+1,updated_at_ms=? WHERE merchant_key=? AND merchant_override=0", [.text(original), .integer(nowMS()), .text(key)])
            try merchantAudit(entity: "merchant_name", id: key, before: expectedMerchantID, after: original)
        }
    }
    public func transactionMerchant(id: String) throws -> TransactionMerchant {
        guard let r = try db.query("SELECT * FROM transactions WHERE id=? AND state='active'", [.text(id)]).first else { throw LedgerError.conflict }
        return TransactionMerchant(transactionID: id, description: r.text("description"), merchantID: r["merchant_id"]?.string, overridden: r.number("merchant_override") == 1, revision: r.number("revision"))
    }
    public func setTransactionMerchant(id: String, merchantID: String?, automatic: Bool = false, expectedRevision: Int64? = nil) throws {
        try db.transaction {
            let old = try transactionMerchant(id: id)
            if let expectedRevision, old.revision != expectedRevision { throw LedgerError.conflict }
            if let merchantID, !automatic {
                guard try db.query("SELECT id FROM merchants WHERE id=? AND archived_at_ms IS NULL", [.text(merchantID)]).count == 1 else { throw LedgerError.invalid("Choose an existing merchant.") }
            }
            try db.query("UPDATE transactions SET merchant_id=?,merchant_override=?,merchant_resolved=1,revision=revision+1,updated_at_ms=? WHERE id=?",
                         [.optional(merchantID), .integer(automatic ? 0 : 1), .integer(nowMS()), .text(id)])
            if automatic { try Self.resolveMerchant(db: db, transactionID: id, description: old.description) }
            try merchantAudit(entity: "transaction_merchant", id: id, before: old.merchantID ?? "unassigned", after: automatic ? "automatic" : merchantID ?? "unassigned")
        }
    }
    private func merchantAudit(entity: String, id: String, before: String, after: String) throws {
        try db.query("INSERT INTO change_log(id,operation_id,entity_type,entity_id,actor,reason,changed_at_ms,before_json,after_json) VALUES (?,?,?,?,'user','merchant_identity',?,?,?)",
                     [.text(identifier()), .text(identifier()), .text(entity), .text(id), .integer(nowMS()), .text(try json(["merchant": before])), .text(try json(["merchant": after]))])
    }
}
