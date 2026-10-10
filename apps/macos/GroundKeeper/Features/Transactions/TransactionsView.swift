import SwiftUI

struct TransactionsView: View {
    @Environment(PreviewWorkspace.self) private var workspace
    @State private var search = ""
    @State private var category: SpendingCategory?
    @State private var account = "All accounts"
    @State private var selectedID: Transaction.ID?
    @State private var sortOrder = [KeyPathComparator(\Transaction.date, order: .reverse)]
    @State private var deletionCandidate: Transaction?

    private var filteredTransactions: [Transaction] {
        workspace.transactions.filter { transaction in
            (!workspace.reviewOnly || transaction.needsReview)
                && (category == nil || (transaction.kind.usesCategory && transaction.category == category))
                && (account == "All accounts" || transaction.account == account)
                && (search.isEmpty || "\(transaction.merchant) \(transaction.notes) \(transaction.category.rawValue) \(transaction.kind.rawValue)".localizedStandardContains(search))
        }.sorted(using: sortOrder)
    }

    private var selectedTransaction: Transaction? {
        filteredTransactions.first { $0.id == selectedID }
    }

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    TextField("Search transactions", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search transactions")
                    Toggle("Needs review", isOn: $workspace.reviewOnly)
                        .toggleStyle(.button)
                        .help("Show only transactions that need your input")
                }
                HStack {
                    Picker("Category", selection: $category) {
                        Text("All categories").tag(nil as SpendingCategory?)
                        ForEach(SpendingCategory.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }.frame(maxWidth: 290)
                    Picker("Account", selection: $account) {
                        ForEach(["All accounts", "Everyday card", "Chequing", "Cash"], id: \.self) { Text($0) }
                    }.frame(maxWidth: 240)
                    Spacer(minLength: 0)
                    if hasFilters {
                        Button("Clear filters", action: clearFilters).buttonStyle(.borderless)
                    }
                }.labelsHidden()
            }.padding(20)
            Divider()
            Table(filteredTransactions, selection: $selectedID, sortOrder: $sortOrder) {
                TableColumn("Date", value: \Transaction.date) { transaction in
                    Text(transaction.date, format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(.secondary)
                }.width(min: 65, ideal: 80, max: 95)
                TableColumn("Transaction", value: \Transaction.merchant) { transaction in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transaction.merchant).fontWeight(.medium)
                        Text(transaction.account).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }.width(min: 140, ideal: 190)
                TableColumn("Category / type") { transaction in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transaction.kind.usesCategory ? transaction.category.rawValue : transaction.kind.rawValue)
                            .lineLimit(1).help(transaction.category.rawValue)
                        if transaction.needsReview {
                            Label("Needs review", systemImage: "circle.dashed")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if transaction.kind == .refund {
                            Text("Refund").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.width(min: 120, ideal: 190)
                TableColumn("Amount", value: \Transaction.amount) { transaction in
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(transaction.formattedAmount).monospacedDigit()
                        Text(transaction.currency).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .trailing)
                }.width(min: 100, ideal: 110, max: 150)
            }
            .contextMenu(forSelectionType: Transaction.ID.self) { ids in
                if let id = ids.first, let transaction = workspace.transactions.first(where: { $0.id == id }) {
                    Button("Edit transaction…") { workspace.editor = transaction }
                    Button("Delete sample transaction…", role: .destructive) { deletionCandidate = transaction }
                }
            } primaryAction: { ids in
                if let id = ids.first { workspace.editor = workspace.transactions.first { $0.id == id } }
            }
            .overlay {
                if filteredTransactions.isEmpty {
                    ContentUnavailableView {
                        Label(hasFilters ? "No matching transactions" : "No transactions yet", systemImage: hasFilters ? "magnifyingglass" : "tray")
                    } description: {
                        Text(hasFilters ? "Try a different search or clear your filters." : "Add a sample transaction to try the interface.")
                    } actions: {
                        if hasFilters {
                            Button("Clear filters", action: clearFilters)
                        } else {
                            Button("Add transaction") { workspace.editor = Transaction() }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(filteredTransactions.count) transactions").foregroundStyle(.secondary)
                Spacer()
                Button("Delete…", role: .destructive) { deletionCandidate = selectedTransaction }
                    .disabled(selectedTransaction == nil)
                Button("Edit…") { workspace.editor = selectedTransaction }
                    .disabled(selectedTransaction == nil)
                    .keyboardShortcut("e", modifiers: .command)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .confirmationDialog("Delete this sample transaction?", isPresented: Binding(
            get: { deletionCandidate != nil },
            set: { if !$0 { deletionCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Delete transaction", role: .destructive) {
                guard let id = deletionCandidate?.id else { return }
                workspace.transactions.removeAll { $0.id == id }
                selectedID = nil
                deletionCandidate = nil
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: {
            Text("You can restore the original examples in Settings.")
        }
    }

    private var hasFilters: Bool { !search.isEmpty || category != nil || account != "All accounts" || workspace.reviewOnly }
    private func clearFilters() {
        search = ""
        category = nil
        account = "All accounts"
        workspace.reviewOnly = false
    }
}
