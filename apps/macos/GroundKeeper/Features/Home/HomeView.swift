import SwiftUI

struct HomeView: View {
    @Environment(PreviewWorkspace.self) private var workspace

    private var recentTransactions: [Transaction] {
        Array(workspace.transactions.sorted { $0.date > $1.date }.prefix(5))
    }

    var body: some View {
        PageContent {
            PageHeading(title: "Overview", subtitle: "Your spending at a glance · October 1–10, 2026")
            Surface {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Net spending").foregroundStyle(.secondary)
                        Text(742.50, format: .currency(code: "CAD"))
                            .font(.system(size: 42, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("CAD · Illustrative report").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Full report", systemImage: "arrow.up.right") {
                        workspace.insightsSection = .spending
                        workspace.selectedTab = .fullInsights
                    }.buttonStyle(.borderless)
                }
                SpendingChart(compact: true)
                Divider()
                HStack(spacing: 32) {
                    Metric(label: "Purchases", value: "36")
                    Metric(label: "Gross spending", value: "$772.40")
                    Metric(label: "Refunds", value: "$29.90")
                    Spacer(minLength: 0)
                }
            }
            if workspace.reviewCount > 0 {
                Button { workspace.showTransactions(needingReview: true) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "tray").font(.title2).foregroundStyle(AppStyle.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(workspace.reviewCount) \(workspace.reviewCount == 1 ? "transaction" : "transactions") to review").fontWeight(.medium)
                            Text("A few details need your input.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(AppStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).help("Open transactions that need review")
            }
            Surface {
                HStack {
                    SectionHeading(title: "Recent transactions")
                    Button("View all") { workspace.showTransactions() }.buttonStyle(.borderless)
                }
                if workspace.transactions.isEmpty {
                    UnavailableFeature(title: "No transactions yet", symbol: "tray", description: "Add a sample transaction with the + button or press ⌘N.")
                } else {
                    ForEach(recentTransactions) { transaction in
                        Button { workspace.editor = transaction } label: {
                            TransactionRow(transaction: transaction)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if transaction.id != recentTransactions.last?.id {
                            Divider()
                        }
                    }
                }
            }
            Text("Report figures are fixed examples, independent of your sample transaction edits.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
