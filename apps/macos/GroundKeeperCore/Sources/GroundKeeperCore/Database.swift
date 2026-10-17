import Foundation
import CryptoKit
import SQLite3
import Darwin

public enum LedgerError: Error, LocalizedError, Sendable {
    case invalid(String), storage(Int32), conflict, unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason), .unavailable(let reason): reason
        case .storage(let code): "Database operation failed (\(code)). Your source data has been retained."
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
    case text(String), integer(Int64), null
    var string: String? { if case .text(let value) = self { return value }; return nil }
    var int: Int64? { if case .integer(let value) = self { return value }; return nil }
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
    init(url: URL) throws {
        ownerLock = Darwin.open(url.path + ".ownerlock", O_CREAT | O_RDWR, 0o600)
        guard ownerLock >= 0, flock(ownerLock, LOCK_EX | LOCK_NB) == 0 else {
            if ownerLock >= 0 { Darwin.close(ownerLock) }; ownerLock = -1
            throw LedgerError.unavailable("This database is already open in another GroundKeeper process.")
        }
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else { close(); throw LedgerError.storage(rc) }
        do {
            _ = try query("SELECT count(*) FROM sqlite_master")
            sqlite3_busy_timeout(handle, 3000)
            try executeScript("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA temp_store=MEMORY;")
            guard try query("PRAGMA foreign_keys").first?.number("foreign_keys") == 1 else { throw LedgerError.unavailable("Foreign keys could not be enabled.") }
            try migrate()
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() {
        if let handle { sqlite3_close(handle); self.handle = nil }
        if ownerLock >= 0 { flock(ownerLock, LOCK_UN); Darwin.close(ownerLock); ownerLock = -1 }
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
    private func migrate() throws {
        let exists = try query("SELECT name FROM sqlite_master WHERE name='schema_migrations'").count == 1
        if !exists, !(try query("SELECT name FROM sqlite_master WHERE type='table'")).isEmpty {
            throw LedgerError.unavailable("This is not a GroundKeeper vault. It was not changed.")
        }
        if exists, try query("SELECT max(version) AS version FROM schema_migrations").first?.number("version") ?? 0 > 2 {
            throw LedgerError.unavailable("This vault requires a newer GroundKeeper version.")
        }
        for (version, name) in [(1, "001-schema"), (2, "002-processing")] {
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
