import SwiftUI

/// A fixture-only walkthrough. It never opens or imports a file.
struct ImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var dateColumn = "Date"
    @State private var descriptionColumn = "Description"
    @State private var amountColumn = "Amount"
    @State private var account = "Everyday card"
    @State private var currency = "CAD"
    private let columns = ["Date", "Description", "Amount"]

    private var distinctColumns: Bool { Set([dateColumn, descriptionColumn, amountColumn]).count == 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(step == 0 ? "Match your columns" : "Review before importing")
                    .font(.title2.weight(.semibold))
                Text("Sample CSV · \(step == 0 ? "1 of 2" : "2 of 2") · No file will be read or imported")
                    .foregroundStyle(.secondary)
            }
            if step == 0 {
                Form {
                    Section("Column mapping") {
                        columnPicker("Date", selection: $dateColumn)
                        columnPicker("Description", selection: $descriptionColumn)
                        columnPicker("Amount", selection: $amountColumn)
                    }
                    Section("Defaults") {
                        Picker("Account", selection: $account) {
                            Text("Everyday card").tag("Everyday card")
                            Text("Chequing").tag("Chequing")
                        }
                        Picker("Currency", selection: $currency) {
                            Text("CAD").tag("CAD")
                            Text("USD").tag("USD")
                        }
                        LabeledContent("Date format", value: "YYYY-MM-DD")
                        LabeledContent("Amounts", value: "Positive values are spending")
                    }
                }.formStyle(.grouped)
                if !distinctColumns {
                    Label("Choose a different source column for each field.", systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red)
                }
            } else {
                Surface {
                    SectionHeading(title: "Example validation states")
                    previewRow("Vincenzo’s", detail: "64.28 \(currency) · Ready", symbol: "checkmark.circle")
                    Divider()
                    previewRow("Balzac’s Coffee", detail: "6.75 \(currency) · Possible duplicate", symbol: "doc.on.doc")
                    Divider()
                    previewRow("Grand River Transit", detail: "Missing amount · Needs correction", symbol: "exclamationmark.circle")
                }
                Text("Destination: \(account) · \(currency)").font(.callout).foregroundStyle(.secondary)
                Text("These are illustrative validation states. A connected importer will validate your rows, flag possible duplicates, and let you correct or skip them before importing.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if step == 1 { Button("Back") { step = 0 } }
                Button(step == 0 ? "Preview review screen" : "Done") {
                    if step == 0 { step = 1 } else { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(step == 0 && !distinctColumns)
            }
        }
        .padding(24)
        .frame(width: 560, height: 590)
    }

    private func columnPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(columns, id: \.self) { Text($0) }
        }
    }

    private func previewRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
