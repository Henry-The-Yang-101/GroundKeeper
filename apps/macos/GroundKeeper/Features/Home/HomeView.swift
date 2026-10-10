import SwiftUI

struct HomeView: View {
    @Environment(PreviewWorkspace.self) private var workspace

    var body: some View {
        PageContent {
            PageHeading(title: "A little clarity.", subtitle: "Your spending at a glance · October 1–10, 2026")
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
                            Text("\(workspace.reviewCount) transactions to review").fontWeight(.medium)
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
                    ForEach(Array(workspace.transactions.sorted { $0.date > $1.date }.prefix(5))) { transaction in
                        Button { workspace.editor = transaction } label: {
                            TransactionRow(transaction: transaction)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if transaction.id != workspace.transactions.sorted(by: { $0.date > $1.date }).prefix(5).last?.id {
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

struct Metric: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: transaction.category)
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchant).fontWeight(.medium)
                Text(transaction.kind.usesCategory ? transaction.category.rawValue : transaction.kind.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if transaction.needsReview { ReviewBadge() }
            VStack(alignment: .trailing, spacing: 4) {
                Text(transaction.formattedAmount).monospacedDigit()
                Text(transaction.date, format: .dateTime.month(.abbreviated).day())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
