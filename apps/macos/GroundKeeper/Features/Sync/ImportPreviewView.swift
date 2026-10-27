import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GroundKeeperCore

struct ImportPreviewView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(TransactionWorkspace.self) private var transactionState
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
    @State private var history: CSVImportHistory?
    @State private var updateExisting = false
    @State private var reviewPage = 0
    private var mappingChanged: Bool { history.map { $0.mapping != mapping } ?? false }
    private var importedRows: Set<Int> { history?.importedRows ?? [] }
    private var selectedRows: [CSVPreviewRow] { mappingChanged ? rows : rows.filter { !importedRows.contains($0.id) } }
    private var summary: CSVImportSelectionSummary { CSVImportSelectionSummary(rows: selectedRows, skipped: skipped) }
    private var visibleRows: [CSVPreviewRow] { Array(rows.dropFirst(reviewPage * 100).prefix(100)) }

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
                                ForEach(transactionState.accounts) { Text("\($0.displayName(in: transactionState.accounts)) · \($0.currency)").tag($0.id) }
                            }
                            Picker("Date format", selection: $mapping.dateFormat) {
                                ForEach(["yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy"], id: \.self) { Text($0) }
                            }
                            Toggle("Positive amounts mean spending", isOn: $mapping.positiveMeansDebit).disabled(mapping.creditColumn != nil)
                            Toggle("Comma decimal separator (1.234,56)", isOn: $mapping.decimalComma)
                            if history != nil {
                                Text("The previous mapping for this file and account was restored. You can change it to review corrections.")
                                    .font(.caption).foregroundStyle(AppStyle.muted)
                            }
                            Text("Signed amounts: negative is money out, positive is money in. A debit/credit pair must contain exactly one positive value. Select a bank ID only if it uniquely identifies a posted record.").font(.caption)
                        }.formStyle(.grouped).scrollContentBackground(.hidden)
                    } else {
                        GroupBox("Import summary") {
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent("Destination account", value: transactionState.accountLabel(id: mapping.accountID, fallback: "Unavailable account"))
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
                        if let history {
                            Text("\(history.importedRows.count) rows were imported earlier. Skipped rows can be imported now without duplicating saved records.")
                                .font(.caption).foregroundStyle(AppStyle.muted)
                            if mappingChanged {
                                Toggle("Review mapping corrections for previously imported rows", isOn: $updateExisting)
                                Text("Saved entries keep their current details until you approve each correction in Sync.")
                                    .font(.caption).foregroundStyle(AppStyle.muted)
                            }
                        }
                        Button("Skip all invalid new rows") {
                            skipped.formUnion(rows.filter { $0.error != nil && !importedRows.contains($0.id) }.map(\.id))
                        }.disabled(!rows.contains { $0.error != nil && !importedRows.contains($0.id) && !skipped.contains($0.id) })
                        List(visibleRows) { row in
                            HStack {
                                Toggle("Row \(row.id)", isOn: Binding(get: { importedRows.contains(row.id) || !skipped.contains(row.id) }, set: { if $0 { skipped.remove(row.id) } else { skipped.insert(row.id) } }))
                                    .frame(width: 85).disabled(importedRows.contains(row.id))
                                VStack(alignment: .leading) {
                                    Text(row.description.isEmpty ? "Missing description" : row.description)
                                    if importedRows.contains(row.id) {
                                        Text(mappingChanged ? "Mapping correction" : "Already imported").font(.caption).foregroundStyle(AppStyle.muted)
                                    }
                                    Text(row.error ?? "\(row.day) · \((Decimal(row.amountMinor ?? 0) / 100).formatted(.currency(code: mapping.currency))) \(mapping.currency)")
                                        .font(.caption).foregroundStyle(row.error == nil ? AppStyle.muted : Color.red)
                                }
                            }.listRowBackground(AppStyle.surface)
                        }.listStyle(.plain).scrollContentBackground(.hidden)
                            .background(AppStyle.surface).clipShape(.rect(cornerRadius: 10))
                        HStack {
                            Button("Previous rows") { reviewPage -= 1 }.disabled(reviewPage == 0)
                            Text("Rows \(reviewPage * 100 + 1)–\(min(rows.count, (reviewPage + 1) * 100)) of \(rows.count)").font(.caption)
                            Button("Next rows") { reviewPage += 1 }.disabled((reviewPage + 1) * 100 >= rows.count)
                        }
                    }
                } else {
                    Text("Choose a UTF-8 CSV with a header row. Add your real accounts in Settings first.").foregroundStyle(AppStyle.muted)
                    Picker("Delimiter", selection: $delimiter) { Text("Comma").tag(","); Text("Semicolon").tag(";"); Text("Tab").tag("\t") }
                    Button("Choose CSV…", action: choose).disabled(busy)
                    if busy { ProgressView("Reading CSV…").controlSize(.small) }
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }.disabled(busy).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 24)
            SheetFooter {
                if result == nil {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                }
                Spacer()
                if result != nil { SheetDoneButton(disabled: busy) }
                if document != nil && result == nil {
                    if reviewing { Button("Back") { reviewing = false }.disabled(busy) }
                    Button(reviewing ? (mappingChanged ? "Review mapping corrections" : "Import selected rows") : "Validate rows") {
                        guard let document else { return }
                        if !reviewing {
                            mapping.currency = transactionState.accounts.first { $0.id == mapping.accountID }?.currency ?? "CAD"
                            busy = true
                            let selectedMapping = mapping
                            Task {
                                defer { busy = false }
                                do {
                                    rows = await Task.detached { document.preview(selectedMapping) }.value
                                    history = try await session.store?.csvImportHistory(hash: document.hash, accountID: selectedMapping.accountID)
                                    skipped = []; updateExisting = false; reviewPage = 0; reviewing = true; error = nil
                                } catch { self.error = error.localizedDescription }
                            }
                        } else {
                            busy = true; error = nil
                            Task {
                                defer { busy = false }
                                do {
                                    let count = try await transactionState.importCSV(document, mapping: mapping, skipped: skipped, updateExisting: updateExisting)
                                    result = count == 0 ? "No new rows to import. Previously imported rows were kept." : "Processed \(count) source records."
                                    if mappingChanged { result = "Processed \(count) records. Review mapping corrections in Sync before they change saved entries." }
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }.buttonStyle(.brass)
                    .disabled(busy || mapping.accountID.isEmpty || (reviewing && (summary.validCount == 0 || summary.invalidCount > 0 || (mappingChanged && !updateExisting))))
                }
            }
        }.frame(width: 690, height: document != nil && result == nil ? 650 : nil).interactiveDismissDisabled(busy)
        .task(id: (document?.hash ?? "") + "|" + mapping.accountID) {
            guard let document, !mapping.accountID.isEmpty, !reviewing else { return }
            let accountID = mapping.accountID
            do {
                let saved = try await session.store?.csvImportHistory(hash: document.hash, accountID: accountID)
                try Task.checkCancellation()
                guard mapping.accountID == accountID, !busy, !reviewing else { return }
                history = saved
                if let saved { mapping = saved.mapping }
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
        }
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
