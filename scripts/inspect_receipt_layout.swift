// Diagnostic only: preserve native Vision table cells instead of flattening them.
// Run with xcrun swift scripts/inspect_receipt_layout.swift IMAGE PRIVATE_OUTPUT.json.
import Foundation
import Vision

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: inspect_receipt_layout.swift IMAGE PRIVATE_OUTPUT.json")
}
if #available(macOS 26, *) {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard data.count <= 8_388_608 else { fatalError("Image exceeds the production size limit") }
    let documents = try await RecognizeDocumentsRequest().perform(on: data)
    let tables: [[String: Any]] = documents.flatMap { observation in
        observation.document.tables.map { table in
            ["rows": table.rows.map { row in
                row.map { cell in
                    ["text": cell.content.text.transcript,
                     "row_start": cell.rowRange.lowerBound, "row_end": cell.rowRange.upperBound,
                     "column_start": cell.columnRange.lowerBound, "column_end": cell.columnRange.upperBound] as [String: Any]
                }
            }]
        }
    }
    let result: [String: Any] = ["producer": "apple_vision_documents", "tables": tables,
        "text": documents.map { $0.document.text.transcript }.joined(separator: "\n")]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("Inspected \(documents.count) document(s), \(tables.count) table(s). Raw output is private.")
} else {
    fatalError("Document layout inspection requires macOS 26 or later")
}
