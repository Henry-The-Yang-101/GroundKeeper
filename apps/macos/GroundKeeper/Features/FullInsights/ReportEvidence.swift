import SwiftUI
import GroundKeeperCore

struct ReportEntryRow: View {
    @Environment(AppWorkspace.self) private var workspace
    let entry: SpendingEntry
    let currency: String
    private var accountName: String {
        workspace.accounts.first { $0.id == entry.accountID }?.displayName(in: workspace.accounts) ?? entry.accountName
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.description).fontWeight(.medium).lineLimit(2).help(entry.description)
                Text(entry.day + (entry.needsReview ? " · Needs review" : ""))
                    .font(.caption).foregroundStyle(AppStyle.muted)
                Text(accountName).font(.caption).foregroundStyle(AppStyle.muted)
            }
            Spacer(minLength: 0)
            Text(ReportFormat.money(entry.net, currency)).monospacedDigit().fixedSize()
        }.padding(.vertical, 7).accessibilityElement(children: .combine)
    }
}

struct ReportTransactionsSheet: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let drilldown: ReportDrilldown
    @State private var rows: [SpendingEntry] = []
    @State private var presentation: ReportEntryPresentation?
    @State private var openingEntryID: String?
    @State private var entryError: String?
    @State private var page = 0
    @State private var previous = false
    @State private var loading = false
    @State private var error: String?
    @State private var hasMore = false
    private var filter: SpendingFilter {
        var result = drilldown.filter
        if previous, let baseline = result.baseline { result.range = baseline }
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: drilldown.title)
            VStack(alignment: .leading, spacing: 16) {
                Text(ReportFormat.range(filter.range, timezone: filter.timezone)).foregroundStyle(AppStyle.muted)
                if drilldown.filter.baseline != nil {
                    Picker("Period", selection: $previous) { Text("Selected").tag(false); Text("Previous").tag(true) }
                        .pickerStyle(.segmented).tint(AppStyle.controlAccent).onChange(of: previous) { page = 0 }
                }
                Text("\(filter.currency) · \(filter.purchasesOnly ? "Purchase amounts before refunds." : "Refunds reduce spending.") Category and tag filters show only the matching portions of split purchases.")
                    .font(.caption).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
                if let entryError { Text(entryError).font(.callout).foregroundStyle(.red) }
                Divider()
                if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error { Text(error).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if rows.isEmpty { UnavailableFeature(title: "No matching entries", symbol: "tray", description: "There are no recorded purchases or refunds in this view.").frame(maxHeight: .infinity) }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(rows) { entry in
                                HStack {
                                    ReportEntryRow(entry: entry, currency: filter.currency)
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) { open(entry, receipts: false) }
                                    Button("Edit") { open(entry, receipts: false) }
                                        .buttonStyle(.borderless).accessibilityLabel("Edit " + entry.description)
                                        .disabled(openingEntryID != nil)
                                    Button { open(entry, receipts: true) } label: { Image(systemName: "doc.text") }
                                        .buttonStyle(.borderless).help("View notes and receipts")
                                        .accessibilityLabel("Notes and receipts for " + entry.description)
                                        .disabled(openingEntryID != nil)
                                    Button { presentation = .merchant(entry) } label: { Image(systemName: "building.2") }
                                        .buttonStyle(.borderless).help("Correct merchant for this entry")
                                        .accessibilityLabel("Correct merchant for " + entry.description)
                                }
                                Divider()
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 24)
            SheetFooter {
                Text("Page \(page + 1)").font(.caption).foregroundStyle(AppStyle.muted)
                Spacer()
                Button("Previous") { page -= 1 }.disabled(page == 0 || loading)
                Button("Next") { page += 1 }.disabled(!hasMore || loading)
                SheetDoneButton()
            }
        }
        .frame(minWidth: 540, idealWidth: 680, minHeight: 450, idealHeight: 620)
        .task(id: "\(page)|\(previous)|\(workspace.reportingRevision)|\(workspace.ready)") {
            rows = []; error = nil; loading = true
            do {
                let fetched = try await workspace.spendingEntries(filter, offset: page * 100)
                try Task.checkCancellation()
                hasMore = fetched.count > 100; rows = Array(fetched.prefix(100)); loading = false
            } catch is CancellationError { return }
            catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription; loading = false }
        }
        .sheet(item: $presentation) { destination in
            Group {
                switch destination {
                case .merchant(let entry): TransactionMerchantSheet(entry: entry)
                case .editor(let transaction): ReportEvidenceEditor(transaction: transaction)
                case .receipts(let transaction): ReportEvidenceReceipts(transaction: transaction)
                }
            }.environment(workspace).vaultSheet()
        }
        .onChange(of: workspace.ready) { if !workspace.ready { rows = []; presentation = nil; dismiss() } }
    }

    private func open(_ entry: SpendingEntry, receipts: Bool) {
        guard openingEntryID == nil else { return }
        openingEntryID = entry.id; entryError = nil
        Task {
            defer { openingEntryID = nil }
            do {
                guard let transaction = try await workspace.transaction(id: entry.id) else {
                    entryError = "This transaction is no longer available. Refresh the report to update its entries."
                    return
                }
                try Task.checkCancellation()
                presentation = receipts ? .receipts(transaction) : .editor(transaction)
            } catch is CancellationError { return }
            catch { entryError = error.localizedDescription }
        }
    }
}

private enum ReportEntryPresentation: Identifiable {
    case merchant(SpendingEntry)
    case editor(Transaction)
    case receipts(Transaction)

    var id: String {
        switch self {
        case .merchant(let entry): "merchant-" + entry.id
        case .editor(let transaction): "editor-" + transaction.id.uuidString
        case .receipts(let transaction): "receipts-" + transaction.id.uuidString
        }
    }
}

private struct ReportEvidenceEditor: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let transaction: Transaction
    @State private var saveError: String?

    var body: some View {
        TransactionEditor(transaction: transaction) { draft in
            Task {
                do { try await workspace.saveTransaction(draft); dismiss() }
                catch { saveError = error.localizedDescription }
            }
        }
        .alert("Transaction could not be saved", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }
}

private struct ReportEvidenceReceipts: View {
    let transaction: Transaction

    var body: some View {
        ReceiptEvidenceView(transactionID: transaction.id.uuidString, title: transaction.merchant)
    }
}

struct ReportFindingRow: View {
    let finding: SpendingFinding
    let filter: SpendingFilter
    let open: (SpendingFilter, String) -> Void
    let hide: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
            if let pattern = finding.pattern {
                DisclosureGroup("How this was found") { Text(pattern.method).font(.caption).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true) }
            }
            ViewThatFits(in: .horizontal) {
                HStack { evidenceButton; Spacer(); hideButtons }
                VStack(alignment: .leading, spacing: 8) { evidenceButton; hideButtons }
            }.buttonStyle(.borderless)
        }
    }
    private var title: String {
        if let pattern = finding.pattern { return pattern.title }
        if finding.kind == "purchase_pattern" { return "How purchase totals changed" }
        let name = finding.category.map(ReportFormat.category) ?? "Recorded spending"
        return name + (finding.current > finding.previous ? " increased" : " decreased")
    }
    private var detail: String {
        if let pattern = finding.pattern { return pattern.detail }
        if finding.kind == "purchase_pattern" {
            let currentAverage = (Decimal(finding.current) / Decimal(finding.currentCount) / 100).formatted(.currency(code: filter.currency))
            let previousAverage = (Decimal(finding.previous) / Decimal(finding.previousCount) / 100).formatted(.currency(code: filter.currency))
            return "\(finding.currentCount) purchases averaging \(currentAverage), compared with \(finding.previousCount) averaging \(previousAverage). This compares purchase amounts before refunds."
        }
        return "\(ReportFormat.money(finding.current, filter.currency)) versus \(ReportFormat.money(finding.previous, filter.currency)): \(ReportFormat.change(finding.current, finding.previous, currency: filter.currency).lowercased()). Based on recorded transactions in the selected and previous periods."
    }
    private var evidenceButton: some View {
        Button("See supporting transactions") {
            var result = finding.pattern?.evidenceFilter ?? filter
            if finding.pattern == nil {
                if let category = finding.category { result.category = category }
                result.purchasesOnly = finding.kind == "purchase_pattern"
            }
            open(result, title)
        }
    }
    private var hideButtons: some View {
        HStack(spacing: 16) { Button("Snooze 7 days") { hide(true) }; Button("Dismiss") { hide(false) } }
    }
}
