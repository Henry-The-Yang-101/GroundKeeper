import Foundation

/// Shared with the Python contract tests and schema-reference generator.
enum DatabaseMigrations {
    static func names() throws -> [String] {
        guard let url = Bundle.module.url(forResource: "migrations", withExtension: "json") else {
            throw LedgerError.unavailable("Missing migration manifest.")
        }
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        guard !names.isEmpty, Set(names).count == names.count,
              names.enumerated().allSatisfy({ index, name in
                  name.hasPrefix(String(format: "%03d-", index + 1)) &&
                  name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }) else {
            throw LedgerError.unavailable("Invalid migration manifest.")
        }
        return names
    }
}
