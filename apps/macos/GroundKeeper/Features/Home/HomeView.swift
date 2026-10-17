import SwiftUI

struct HomeView: View {
    @Environment(AppWorkspace.self) private var workspace
    var body: some View {
        PageContent {
            PageHeading(title: "Your transactions", subtitle: workspace.status)
            Surface {
                SectionHeading(title: "Local workspace", detail: "\(workspace.totalTransactions) saved transactions")
                HStack {
                    Button("View transactions") { workspace.showTransactions() }
                    Button("Review captures (\(workspace.reviews.count))") { workspace.selectedTab = .sync }
                    Button("Import CSV…") { workspace.showingImportPreview = true }.disabled(workspace.accounts.isEmpty)
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
                    ForEach(workspace.transactions.prefix(5)) { transaction in
                        Button { workspace.editor = transaction } label: { TransactionRow(transaction: transaction).contentShape(Rectangle()) }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }
}
