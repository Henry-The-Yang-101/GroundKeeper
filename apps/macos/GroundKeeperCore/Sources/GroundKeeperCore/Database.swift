import Foundation
import CryptoKit
import SQLCipher
import Darwin

public enum LedgerError: Error, LocalizedError, Sendable {
    case invalid(String), storage(Int32), conflict, unavailable(String), ownedByAnotherProcess
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason), .unavailable(let reason): reason
        case .storage(let code): "Database operation failed (\(code)). Your source data has been retained."
        case .ownedByAnotherProcess: "This database is already open in another GroundKeeper process."
        case .conflict: "This record changed. Refresh it before saving."
        }
    }
}
public func contentHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func nowMS() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
func identifier() -> String { UUID().uuidString }
func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
enum SQLValue: Sendable {
    case text(String), integer(Int64), blob(Data), null
    var string: String? { if case .text(let value) = self { return value }; return nil }
    var int: Int64? { if case .integer(let value) = self { return value }; return nil }
    var data: Data? { if case .blob(let value) = self { return value }; return nil }
    static func optional(_ value: String?) -> Self { value.map(Self.text) ?? .null }
    static func optional(_ value: Int64?) -> Self { value.map(Self.integer) ?? .null }
}
typealias Row = [String: SQLValue]
extension Dictionary where Key == String, Value == SQLValue {
    func text(_ key: String) -> String { self[key]?.string ?? "" }
    func number(_ key: String) -> Int64 { self[key]?.int ?? 0 }
}

/// Confined to LedgerStore. No SQL or binding values escape in errors/logs.
final class Database {
    private var handle: OpaquePointer?
    private var ownerLock: Int32 = -1
    private let url: URL
    init(url: URL, passphrase: String? = nil) throws {
        self.url = url
        ownerLock = Darwin.open(url.path + ".ownerlock", O_CREAT | O_RDWR, 0o600)
        guard ownerLock >= 0, flock(ownerLock, LOCK_EX | LOCK_NB) == 0 else {
            if ownerLock >= 0 { Darwin.close(ownerLock) }; ownerLock = -1
            throw LedgerError.ownedByAnotherProcess
        }
        do { try openConnection(passphrase: passphrase) } catch { close(); throw error }
    }
    private func openConnection(passphrase: String?) throws {
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else { close(); throw LedgerError.storage(rc) }
        do {
            guard !(try query("PRAGMA cipher_version")).isEmpty else { throw LedgerError.unavailable("SQLCipher is unavailable. The vault was not opened.") }
            if let passphrase {
                guard !passphrase.isEmpty else { throw LedgerError.invalid("Enter the vault passphrase.") }
                guard !passphrase.contains("\0"), passphrase.utf8.count <= 1024 else { throw LedgerError.invalid("Invalid passphrase length or characters.") }
                // PRAGMA does not accept bindings; quote the literal and never log SQL.
                try executeScript("PRAGMA key='\(passphrase.replacingOccurrences(of: "'", with: "''"))'")
            }
            _ = try query("SELECT count(*) FROM sqlite_master")
            sqlite3_busy_timeout(handle, 3000)
            try executeScript("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA temp_store=MEMORY;")
            guard try query("PRAGMA foreign_keys").first?.number("foreign_keys") == 1 else { throw LedgerError.unavailable("Foreign keys could not be enabled.") }
            try migrate()
            try registerReportingFunctions()
        } catch { if let handle { sqlite3_close(handle); self.handle = nil }; throw error }
    }
    deinit { close() }
    func close() {
        if let handle { sqlite3_close(handle); self.handle = nil }
        if ownerLock >= 0 { flock(ownerLock, LOCK_UN); Darwin.close(ownerLock); ownerLock = -1 }
    }
    func verifyPassphrase(_ passphrase: String) throws {
        guard !passphrase.isEmpty, !passphrase.contains("\0"), passphrase.utf8.count <= 1024 else { throw LedgerError.invalid("Enter your current vault passphrase.") }
        var verification: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &verification, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let verification { sqlite3_close(verification) } }
        guard result == SQLITE_OK else { throw LedgerError.storage(result) }
        let key = "PRAGMA key='\(passphrase.replacingOccurrences(of: "'", with: "''"))'"
        guard sqlite3_exec(verification, key, nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(verification, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else {
            throw LedgerError.invalid("The current vault passphrase is incorrect.")
        }
    }
    /// Export to a sibling file, validate it, then atomically replace the vault under its owner lock.
    /// The header is the source of truth, so a crash cannot leave a separate mode flag out of sync.
    func changeEncryption(to passphrase: String?) throws {
        if let passphrase, (passphrase.count < 12 || passphrase.utf8.count > 1024 || passphrase.contains("\0")) { throw LedgerError.invalid("Use a passphrase of at least 12 characters.") }
        let staging = url.deletingLastPathComponent().appendingPathComponent(".vault-conversion-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm", ".ownerlock"] { try? FileManager.default.removeItem(atPath: staging.path + suffix) } }
        try query("ATTACH DATABASE ? AS converted KEY ?", [.text(staging.path), .text(passphrase ?? "")])
        do {
            try query("SELECT sqlcipher_export('converted')")
            guard try query("PRAGMA converted.integrity_check").first?.text("integrity_check") == "ok" else { throw LedgerError.unavailable("The converted vault did not pass validation.") }
            try query("DETACH DATABASE converted")
        } catch { _ = try? query("DETACH DATABASE converted"); throw error }
        let verification = try Database(url: staging, passphrase: passphrase)
        guard try verification.query("PRAGMA integrity_check").first?.text("integrity_check") == "ok",
              try verification.query("PRAGMA foreign_key_check").isEmpty else {
            verification.close(); throw LedgerError.unavailable("The converted vault did not pass validation.")
        }
        try verification.executeScript("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")
        verification.close()
        // Remove WAL dependencies before replacing the main file. No other process can open this vault.
        try executeScript("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        // fsync the completed copy before the atomic replacement.
        let file = try FileHandle(forWritingTo: staging); try file.synchronize(); try file.close()
        guard Darwin.rename(staging.path, url.path) == 0 else { throw LedgerError.unavailable("Could not replace the vault. The original was retained.") }
        if let handle { sqlite3_close(handle); self.handle = nil }
        try openConnection(passphrase: passphrase)
    }
    func executeScript(_ sql: String) throws {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw LedgerError.storage(rc) }
    }
    @discardableResult func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [Row] {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw LedgerError.storage(rc) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == bindings.count else { throw LedgerError.invalid("Internal database binding mismatch.") }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw LedgerError.storage(result) }
        }
        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw LedgerError.storage(step) }
            var row: Row = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_NULL: row[name] = .null
                case SQLITE_BLOB:
                    let size = Int(sqlite3_column_bytes(statement, column))
                    row[name] = .blob(sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: size) } ?? Data())
                default: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                }
            }
            rows.append(row)
        }
        return rows
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try executeScript("BEGIN IMMEDIATE")
        do { let result = try body(); try executeScript("COMMIT"); return result }
        catch { try? executeScript("ROLLBACK"); throw error }
    }
    private func registerReportingFunctions() throws {
        let searchResult = sqlite3_create_function_v2(handle, "gk_ledger_contains", 2, SQLITE_UTF8, nil, { context, count, values in
            guard count == 2, let values, let value = values[0], let needle = values[1],
                  let valueText = sqlite3_value_text(value), let needleText = sqlite3_value_text(needle) else {
                sqlite3_result_int(context, 0); return
            }
            sqlite3_result_int(context, String(cString: valueText).localizedStandardContains(String(cString: needleText)) ? 1 : 0)
        }, nil, nil, nil)
        guard searchResult == SQLITE_OK else { throw LedgerError.storage(searchResult) }

        let result = sqlite3_create_function_v2(handle, "gk_report_day", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, count, values in
            guard count == 2, let values, let timestamp = values[0], let zone = values[1],
                  let text = sqlite3_value_text(zone),
                  let calendar = try? ReportCalendar(timezone: String(cString: text)) else {
                sqlite3_result_error(context, "Invalid reporting timezone", -1); return
            }
            let value = calendar.day(Date(timeIntervalSince1970: Double(sqlite3_value_int64(timestamp)) / 1000))
            value.withCString { sqlite3_result_text(context, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }, nil, nil, nil)
        guard result == SQLITE_OK else { throw LedgerError.storage(result) }
    }
    private func migrate() throws {
        let migrations = try DatabaseMigrations.names()
        let exists = try query("SELECT name FROM sqlite_master WHERE name='schema_migrations'").count == 1
        if !exists, !(try query("SELECT name FROM sqlite_master WHERE type='table'")).isEmpty {
            throw LedgerError.unavailable("This is not a GroundKeeper vault. It was not changed.")
        }
        if exists, try query("SELECT max(version) AS version FROM schema_migrations").first?.number("version") ?? 0 > Int64(migrations.count) {
            throw LedgerError.unavailable("This vault requires a newer GroundKeeper version.")
        }
        for (index, name) in migrations.enumerated() {
            let version = index + 1
            guard let url = Bundle.module.url(forResource: name, withExtension: "sql") else { throw LedgerError.unavailable("Missing bundled migration.") }
            let data = try Data(contentsOf: url), checksum = contentHash(data)
            if exists, let applied = try query("SELECT checksum FROM schema_migrations WHERE version=?", [.integer(Int64(version))]).first {
                guard applied.text("checksum") == checksum else { throw LedgerError.unavailable("Migration checksum mismatch.") }
                continue
            }
            // The original fixture owns a transaction; the runner owns the real migration.
            let sql = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\nBEGIN;", with: "").replacingOccurrences(of: "\nCOMMIT;", with: "")
            try transaction {
                try executeScript(sql)
                try query("INSERT INTO schema_migrations VALUES (?,?,?,?)", [.integer(Int64(version)), .text(name), .text(checksum), .integer(nowMS())])
            }
        }
    }
}
