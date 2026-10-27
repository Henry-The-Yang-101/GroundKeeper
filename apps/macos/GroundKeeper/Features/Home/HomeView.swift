import SwiftUI

struct HomeView: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(TransactionWorkspace.self) private var transactionState
    var body: some View {
        PageContent {
            PageHeading(title: "Your vault")
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 18) {
                    Metric(label: "Saved transactions", value: "\(transactionState.totalTransactions)")
                    Metric(label: "Transactions to review", value: "\(transactionState.transactionReviewCount)")
                    Metric(label: "Captures to review", value: "\(workspace.reviews.count)")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(alignment: .leading, spacing: 10) { actions }
                }
                if transactionState.accounts.isEmpty {
                    Text("Start by adding an account in Settings, then connect your capture folder in Sync.").foregroundStyle(AppStyle.muted)
                }
            }
            if !transactionState.accounts.isEmpty { HomeSpendingOverview() }
            Surface {
                SectionHeading(title: "Recent transactions")
                if transactionState.recentTransactions.isEmpty {
                    UnavailableFeature(title: "No transactions yet", symbol: "tray", description: "Import a bank CSV, connect your capture folder, or add a transaction with ⌘N.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(transactionState.recentTransactions.prefix(5)) { transaction in
                            Button { transactionState.editor = transaction } label: {
                                TransactionRow(transaction: transaction).contentShape(Rectangle())
                            }.buttonStyle(VaultRowButtonStyle())
                            if transaction.id != transactionState.recentTransactions.prefix(5).last?.id {
                                Divider().overlay(AppStyle.separator).padding(.horizontal, 12)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("View transactions") { workspace.showTransactions() }.buttonStyle(.brass)
        Button("Review transactions (\(transactionState.transactionReviewCount))") { workspace.showTransactions(needingReview: true) }
            .disabled(transactionState.transactionReviewCount == 0)
        Button("Review captures (\(workspace.reviews.count))") { workspace.selectedTab = .sync }
            .disabled(workspace.reviews.isEmpty)
        Button("Import CSV…") { transactionState.showingImportPreview = true }.disabled(transactionState.accounts.isEmpty)
    }
}
