import Foundation
import GroundKeeperCore

/// Project frozen evaluation rows through the app's actual query sanitizer.
/// No vault is opened and no network request is made.
struct Row: Decodable {
    let id: String
    let input: Input
    struct Input: Decodable { let description: String }
}
struct Projection: Encodable {
    let id: String
    let query: MerchantSearchQuery?
}
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: MerchantQueryPilot <sample.jsonl>\n".utf8))
    exit(2)
}
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
for line in source.split(separator: "\n") {
    let row = try JSONDecoder().decode(Row.self, from: Data(line.utf8))
    let query = MerchantSearchQuery.make(merchant: nil, description: row.input.description, locality: "")
    let encoded = try encoder.encode(Projection(id: row.id, query: query))
    FileHandle.standardOutput.write(encoded + Data("\n".utf8))
}
