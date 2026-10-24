import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GroundKeeperCore

struct ImportPreviewView: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var document: CSVDocument?
    @State private var mapping = CSVMapping()
    @State private var rows: [CSVPreviewRow] = []
    @State private var skipped = Set<Int>()
    @State private var reviewing = false
    @State private var busy = false
    @State private var error: String?
    @State private var result: String?
    @State private var delimiter = ","
    private var summary: CSVImportSelectionSummary { CSVImportSelectionSummary(rows: rows, skipped: skipped) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Import bank CSV")
            VStack(alignment: .leading, spacing: 16) {
                if let result {
                    Label(result, systemImage: "checkmark.circle")
                    Text("Possible matches are in Sync → Review captures. Categories remain suggestions until you confirm them.").foregroundStyle(AppStyle.muted)
                } else if let document {
                    Text("\(document.filename) · \(document.rows.count) rows").foregroundStyle(AppStyle.muted)
                    if !reviewing {
                        Form {
                            column("Date", selection: $mapping.dateColumn, document: document)
                            column("Description", selection: $mapping.descriptionColumn, document: document)
                            column("Amount / debit", selection: $mapping.amountColumn, document: document)
                            optionalColumn("Credit (optional)", selection: $mapping.creditColumn, document: document)
                            optionalColumn("Bank record ID (optional)", selection: $mapping.externalIDColumn, document: document)
                            Picker("Account", selection: $mapping.accountID) {
                                Text("Choose account").tag("")
                                ForEach(workspace.accounts) { Text("\($0.name) · \($0.currency)").tag($0.id) }
                            }
                            Picker("Date format", selection: $mapping.dateFormat) {
                                ForEach(["yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy"], id: \.self) { Text($0) }
                            }
                            Toggle("Positive amounts mean spending", isOn: $mapping.positiveMeansDebit).disabled(mapping.creditColumn != nil)
                            Toggle("Comma decimal separator (1.234,56)", isOn: $mapping.decimalComma)
                            Text("Signed amounts: negative is money out, positive is money in. A debit/credit pair must contain exactly one positive value. Select a bank ID only if it uniquely identifies a posted record.").font(.caption)
                        }.formStyle(.grouped).scrollContentBackground(.hidden)
                    } else {
                        GroupBox("Import summary") {
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent("Destination account", value: workspace.accounts.first { $0.id == mapping.accountID }?.name ?? "Unavailable account")
                                LabeledContent("Currency", value: mapping.currency)
                                Text("\(summary.selectedCount) selected · \(summary.validCount) valid · \(summary.invalidCount) invalid selected · \(summary.skippedCount) skipped")
                                    .font(.caption)
                                if let first = summary.firstDay, let last = summary.lastDay {
                                    LabeledContent("Selected dates", value: first == last ? first : "\(first) – \(last)")
                                }
                                HStack(spacing: 24) {
                                    VStack(alignment: .leading) { Text("Money out").font(.caption); Text(summary.moneyOut.formatted(.currency(code: mapping.currency))) }
                                    VStack(alignment: .leading) { Text("Money in").font(.caption); Text(summary.moneyIn.formatted(.currency(code: mapping.currency))) }
                                    VStack(alignment: .leading) { Text("Net change").font(.caption); Text(summary.net.formatted(.currency(code: mapping.currency))) }
                                }
                                if summary.invalidCount > 0 {
                                    Text("Totals include valid selected rows only. Skip invalid rows before importing.")
                                        .font(.caption).foregroundStyle(.red)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("Skip all invalid rows") { skipped.formUnion(rows.filter { $0.error != nil }.map(\.id)) }
                            .disabled(!rows.contains { $0.error != nil && !skipped.contains($0.id) })
                        List(rows.prefix(200)) { row in
                            HStack {
                                Toggle("Row \(row.id)", isOn: Binding(get: { !skipped.contains(row.id) }, set: { if $0 { skipped.remove(row.id) } else { skipped.insert(row.id) } })).frame(width: 85)
                                VStack(alignment: .leading) {
                                    Text(row.description.isEmpty ? "Missing description" : row.description)
                                    Text(row.error ?? "\(row.day) · \((Decimal(row.amountMinor ?? 0) / 100).formatted(.currency(code: mapping.currency))) \(mapping.currency)")
                                        .font(.caption).foregroundStyle(row.error == nil ? AppStyle.muted : Color.red)
                                }
                            }.listRowBackground(AppStyle.surface)
                        }.listStyle(.plain).scrollContentBackground(.hidden)
                            .background(AppStyle.surface).clipShape(.rect(cornerRadius: 10))
                        if rows.count > 200 { Text("Showing the first 200 rows. Validation covers the entire file.").font(.caption) }
                    }
                } else {
                    Text("Choose a UTF-8 CSV with a header row. Add your real accounts in Settings first.").foregroundStyle(AppStyle.muted)
                    Picker("Delimiter", selection: $delimiter) { Text("Comma").tag(","); Text("Semicolon").tag(";"); Text("Tab").tag("\t") }
                    Button("Choose CSV…", action: choose).disabled(busy)
                    if busy { ProgressView("Reading CSV…").controlSize(.small) }
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 24)
            SheetFooter {
                if result == nil {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                }
                Spacer()
                if result != nil { SheetDoneButton(disabled: busy) }
                if document != nil && result == nil {
                    if reviewing { Button("Back") { reviewing = false }.disabled(busy) }
                    Button(reviewing ? "Import selected rows" : "Validate rows") {
                        guard let document else { return }
                        if !reviewing {
                            mapping.currency = workspace.accounts.first { $0.id == mapping.accountID }?.currency ?? "CAD"
                            busy = true
                            let selectedMapping = mapping
                            Task {
                                rows = await Task.detached { document.preview(selectedMapping) }.value
                                skipped = []; reviewing = true; busy = false; error = nil
                            }
                        } else {
                            busy = true; error = nil
                            Task {
                                defer { busy = false }
                                do {
                                    let count = try await workspace.importCSV(document, mapping: mapping, skipped: skipped)
                                    result = count == 0 ? "This file was already imported for this account." : "Imported \(count) source records."
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }.buttonStyle(.brass)
                    .disabled(busy || mapping.accountID.isEmpty || (reviewing && (summary.validCount == 0 || summary.invalidCount > 0)))
                }
            }
        }.frame(width: 690, height: document != nil && result == nil ? 650 : nil).interactiveDismissDisabled(busy)
    }
    private func column(_ title: String, selection: Binding<Int>, document: CSVDocument) -> some View {
        Picker(title, selection: selection) { ForEach(document.headers.indices, id: \.self) { Text("\($0 + 1): \(document.headers[$0])").tag($0) } }
    }
    private func optionalColumn(_ title: String, selection: Binding<Int?>, document: CSVDocument) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(nil as Int?)
            ForEach(document.headers.indices, id: \.self) { Text("\($0 + 1): \(document.headers[$0])").tag(Optional($0)) }
        }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; let separator = Character(delimiter)
        Task {
            defer { busy = false }
            do {
                document = try await Task.detached {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                    let data = try handle.read(upToCount: 20_000_001) ?? Data()
                    return try CSVDocument(data: data, filename: url.lastPathComponent, delimiter: separator)
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }
}
