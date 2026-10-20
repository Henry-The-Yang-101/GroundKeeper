import SwiftUI

struct HomeView: View {
    @Environment(AppWorkspace.self) private var workspace
    var body: some View {
        PageContent {
            PageHeading(title: "Your vault", subtitle: workspace.status)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 32) {
                    Metric(label: "Saved transactions", value: "\(workspace.totalTransactions)")
                    Metric(label: "To review", value: "\(workspace.reviewCount)")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(alignment: .leading, spacing: 10) { actions }
                }
                if workspace.accounts.isEmpty {
                    Text("Start by adding an account in Settings, then connect your capture folder in Sync.").foregroundStyle(.secondary)
                }
            }
            Surface {
                SectionHeading(title: "Recent transactions")
                if workspace.transactions.isEmpty {
                    UnavailableFeature(title: "No transactions yet", symbol: "tray", description: "Import a bank CSV, connect your capture folder, or add a transaction with ⌘N.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(workspace.transactions.prefix(5)) { transaction in
                            Button { workspace.editor = transaction } label: {
                                TransactionRow(transaction: transaction).contentShape(Rectangle())
                            }.buttonStyle(VaultRowButtonStyle())
                            if transaction.id != workspace.transactions.prefix(5).last?.id {
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
        Button("Review captures (\(workspace.reviews.count))") { workspace.selectedTab = .sync }
        Button("Import CSV…") { workspace.showingImportPreview = true }.disabled(workspace.accounts.isEmpty)
    }
}
