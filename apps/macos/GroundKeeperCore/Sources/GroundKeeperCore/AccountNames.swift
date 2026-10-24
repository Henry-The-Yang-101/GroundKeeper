import Foundation

extension Account {
    public static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public func displayName(in accounts: [Account]) -> String {
        let duplicate = accounts.contains { $0.id != id && $0.currency == currency && Self.normalizedName($0.name) == Self.normalizedName(name) }
        return duplicate ? "\(name) · \(id.suffix(8))" : name
    }
}

extension LedgerStore {
    func validateAccountName(_ name: String, currency: String, excludingID: String? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else { throw LedgerError.invalid("Use an account name of 1 to 100 characters.") }
        let existing = try db.query("SELECT id,name FROM accounts WHERE currency=?", [.text(currency)])
        guard !existing.contains(where: { $0.text("id") != excludingID && Account.normalizedName($0.text("name")) == Account.normalizedName(trimmed) }) else {
            throw LedgerError.invalid("An account with this name already uses \(currency). Choose a distinguishing name.")
        }
        return trimmed
    }
    public func renameAccount(id: String, name: String) throws {
        try db.transaction {
            guard let old = try account(id) else { throw LedgerError.invalid("This account is no longer available.") }
            let trimmed = try validateAccountName(name, currency: old.currency, excludingID: id)
            try db.query("UPDATE accounts SET name=? WHERE id=?", [.text(trimmed), .text(id)])
            try db.query("INSERT INTO change_log(id,operation_id,entity_type,entity_id,actor,reason,changed_at_ms,before_json,after_json) VALUES (?,?,'account',?,'user','rename',?,?,?)",
                [.text(identifier()), .text(identifier()), .text(id), .integer(nowMS()), .text(try json(["name": old.name])), .text(try json(["name": trimmed]))])
        }
    }
}
