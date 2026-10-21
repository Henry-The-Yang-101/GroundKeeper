import SwiftUI
import GroundKeeperCore

struct ReportEntryRow: View {
    let entry: SpendingEntry
    let currency: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.description).fontWeight(.medium).lineLimit(2).help(entry.description)
                Text(entry.day + (entry.pending ? " · Pending" : "") + (entry.needsReview ? " · Needs review" : ""))
                    .font(.caption).foregroundStyle(AppStyle.muted)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(drilldown.title).font(VaultTypography.sheet)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(ReportFormat.range(filter.range, timezone: filter.timezone)).foregroundStyle(AppStyle.muted)
            if drilldown.filter.baseline != nil {
                Picker("Period", selection: $previous) { Text("Selected").tag(false); Text("Previous").tag(true) }
                    .pickerStyle(.segmented).tint(AppStyle.controlAccent).onChange(of: previous) { page = 0 }
            }
            Text("\(filter.currency) · \(filter.includePending ? "Includes pending" : "Posted only") · \(filter.purchasesOnly ? "Purchase amounts before refunds." : "Refunds reduce spending.") Category and tag filters show only the matching portions of split purchases.")
                .font(.caption).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
            Divider()
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error { Text(error).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if rows.isEmpty { UnavailableFeature(title: "No matching entries", symbol: "tray", description: "There are no recorded purchases or refunds in this view.").frame(maxHeight: .infinity) }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(rows) { entry in ReportEntryRow(entry: entry, currency: filter.currency); Divider() }
                    }
                }
            }
            HStack {
                Text("Page \(page + 1)").font(.caption).foregroundStyle(AppStyle.muted)
                Spacer()
                Button("Previous") { page -= 1 }.disabled(page == 0 || loading)
                Button("Next") { page += 1 }.disabled(!hasMore || loading)
            }
        }
        .padding(24).frame(minWidth: 540, idealWidth: 680, minHeight: 450, idealHeight: 620)
        .task(id: "\(page)|\(previous)|\(workspace.reportingRevision)|\(workspace.ready)") {
            rows = []; error = nil; loading = true
            do {
                let fetched = try await workspace.spendingEntries(filter, offset: page * 100)
                try Task.checkCancellation()
                hasMore = fetched.count > 100; rows = Array(fetched.prefix(100)); loading = false
            } catch is CancellationError { return }
            catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription; loading = false }
        }
        .onChange(of: workspace.ready) { if !workspace.ready { rows = []; dismiss() } }
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
            ViewThatFits(in: .horizontal) {
                HStack { evidenceButton; Spacer(); hideButtons }
                VStack(alignment: .leading, spacing: 8) { evidenceButton; hideButtons }
            }.buttonStyle(.borderless)
        }
    }
    private var title: String {
        if finding.kind == "purchase_pattern" { return "How purchase totals changed" }
        let name = finding.category.map(ReportFormat.category) ?? "Recorded spending"
        return name + (finding.current > finding.previous ? " increased" : " decreased")
    }
    private var detail: String {
        if finding.kind == "purchase_pattern" {
            let currentAverage = (Decimal(finding.current) / Decimal(finding.currentCount) / 100).formatted(.currency(code: filter.currency))
            let previousAverage = (Decimal(finding.previous) / Decimal(finding.previousCount) / 100).formatted(.currency(code: filter.currency))
            return "\(finding.currentCount) purchases averaging \(currentAverage), compared with \(finding.previousCount) averaging \(previousAverage). This compares purchase amounts before refunds."
        }
        return "\(ReportFormat.money(finding.current, filter.currency)) versus \(ReportFormat.money(finding.previous, filter.currency)): \(ReportFormat.change(finding.current, finding.previous, currency: filter.currency).lowercased()). Based on recorded transactions in the selected and previous periods."
    }
    private var evidenceButton: some View {
        Button("See supporting transactions") {
            var result = filter
            if let category = finding.category { result.category = category }
            result.purchasesOnly = finding.kind == "purchase_pattern"
            open(result, title)
        }
    }
    private var hideButtons: some View {
        HStack(spacing: 16) { Button("Snooze 7 days") { hide(true) }; Button("Dismiss") { hide(false) } }
    }
}
