import SwiftUI

struct FullInsightsView: View {
    @Environment(PreviewWorkspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $workspace.insightsSection) {
                    ForEach(InsightsSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
                Spacer()
            }.padding(.horizontal, 28).padding(.vertical, 16)
            Divider()
            switch workspace.insightsSection {
            case .spending: SpendingReportView()
            case .transactions: TransactionsView()
            case .planning: PlanningView()
            }
        }.background(AppStyle.pageBackground)
    }
}

private struct SpendingReportView: View {
    var body: some View {
        PageContent {
            PageHeading(title: "Spending", subtitle: "October 1–10, 2026 · CAD · Illustrative report")
            HStack(spacing: 16) {
                Surface { Metric(label: "Net spending", value: "$742.50") }
                Surface { Metric(label: "Daily average", value: "$74.25") }
                Surface { Metric(label: "Purchases", value: "36") }
            }
            Surface { SpendingChart() }
            Surface {
                SectionHeading(title: "By category", detail: "Net spending · CAD")
                ForEach(SampleData.categories) { item in
                    HStack(spacing: 12) {
                        CategoryIcon(category: item.category)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(item.category.rawValue).font(.callout)
                                Spacer()
                                Text(item.amount, format: .currency(code: "CAD")).monospacedDigit()
                            }
                            ProgressView(value: item.amount, total: 300)
                                .tint(item.category == .uncategorized ? .secondary : AppStyle.accent)
                                .accessibilityLabel(item.category.rawValue)
                                .accessibilityValue(item.amount.formatted(.currency(code: "CAD")))
                        }
                    }
                }
            }
            Text("Fixed examples for exploring the interface. Reports do not recalculate when you edit sample transactions. Transfers and card payments will be kept separate from spending.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
