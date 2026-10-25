import SwiftUI
import GroundKeeperCore

struct TransactionsView: View {
    @Environment(AppWorkspace.self) private var workspace
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var category: SpendingCategory?
    @State private var accountID: String?
    @State private var selectedID: Transaction.ID?
    @State private var sortOrder = [KeyPathComparator(\Transaction.date, order: .reverse)]
    @State private var deletionCandidate: Transaction?
    @State private var receiptTransaction: Transaction?

    private var filteredTransactions: [Transaction] { workspace.transactions }

    private var selectedTransaction: Transaction? {
        filteredTransactions.first { $0.id == selectedID }
    }

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeading(title: "Transactions", subtitle: "Every entry, kept in order.")
                HStack(spacing: 12) {
                    TextField("Search transactions", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
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
                    Picker("Account", selection: $accountID) {
                        Text("All accounts").tag(nil as String?)
                        ForEach(workspace.accounts) { account in
                            Text("\(account.displayName(in: workspace.accounts)) · \(account.currency)").tag(Optional(account.id))
                        }
                    }.frame(maxWidth: 240)
                    Spacer(minLength: 0)
                    if hasFilters {
                        Button("Clear filters", action: clearFilters).buttonStyle(.borderless)
                    }
                }.labelsHidden()
            }
            .frame(maxWidth: PageLayout.contentWidth, alignment: .leading)
            .padding(PageLayout.inset).frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            // Bound the native table to the space left by the header and footer.
            // Its intrinsic height must not expand the split view beyond the window.
            GeometryReader { geometry in
                Table(filteredTransactions, selection: $selectedID, sortOrder: $sortOrder) {
                    TableColumn("Date", value: \Transaction.date) { transaction in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transaction.date, format: .dateTime.month(.abbreviated).day())
                            Text(transaction.date, format: .dateTime.year()).font(.caption)
                        }
                        .foregroundStyle(AppStyle.muted)
                        .accessibilityElement(children: .combine)
                    }.width(min: 65, ideal: 80, max: 95)
                    TableColumn("Transaction", value: \Transaction.merchant) { transaction in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transaction.merchant).fontWeight(.medium).lineLimit(1).help(transaction.merchant)
                            Text(workspace.accountLabel(id: transaction.accountID, fallback: transaction.account)).font(.caption).foregroundStyle(AppStyle.muted)
                        }.padding(.vertical, 15)
                    }.width(min: 140, ideal: 190)
                    TableColumn("Category / type") { transaction in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transaction.kind.usesCategory ? transaction.category.rawValue : transaction.kind.rawValue)
                                .lineLimit(1).help(transaction.category.rawValue)
                            if transaction.needsReview {
                                Label("Needs review", systemImage: "circle.dashed")
                                    .font(.caption).foregroundStyle(AppStyle.muted)
                            } else if transaction.kind == .refund {
                                Text("Refund").font(.caption).foregroundStyle(AppStyle.muted)
                            }
                        }
                    }.width(min: 120, ideal: 190)
                    TableColumn("Source") { transaction in
                        Text(transaction.source)
                            .font(.callout).foregroundStyle(AppStyle.muted)
                            .lineLimit(3).help(transaction.source)
                    }.width(min: 130, ideal: 175, max: 240)
                    TableColumn("Amount", value: \Transaction.amount) { transaction in
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(transaction.formattedAmount).monospacedDigit()
                            Text(transaction.currency).font(.caption2).foregroundStyle(AppStyle.muted)
                        }.frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(min: 100, ideal: 110, max: 150).alignment(.trailing)
                }
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
                .background(AppStyle.surface)
                .contextMenu(forSelectionType: Transaction.ID.self) { ids in
                    if let id = ids.first, let transaction = workspace.transactions.first(where: { $0.id == id }) {
                        Button("Edit transaction…") { workspace.editor = transaction }
                        Button("Notes & receipts…") { receiptTransaction = transaction }
                        Button("Delete transaction…", role: .destructive) { deletionCandidate = transaction }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { workspace.editor = workspace.transactions.first { $0.id == id } }
                }
                .overlay {
                    if filteredTransactions.isEmpty {
                        ContentUnavailableView {
                            Label {
                                Text(hasFilters ? "No matching transactions" : "No transactions yet").font(VaultTypography.section)
                            } icon: {
                                Image(systemName: hasFilters ? "magnifyingglass" : "tray").foregroundStyle(AppStyle.accent)
                            }
                        } description: {
                            Text(hasFilters ? "Try a different search or clear your filters." : "Import or add a transaction.")
                        } actions: {
                            if hasFilters {
                                Button("Clear filters", action: clearFilters)
                            } else {
                                Button("Add transaction") { workspace.editor = Transaction() }
                            }
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { pagination; Spacer(minLength: 0); selectionActions }
                VStack(alignment: .leading, spacing: 12) {
                    pagination
                    HStack { Spacer(); selectionActions }
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppStyle.pageBackground)
        .task { updateQuery() }
        .onChange(of: search) { updateQuery() }
        .onChange(of: category) { updateQuery() }
        .onChange(of: accountID) { updateQuery() }
        .onChange(of: workspace.reviewOnly) { updateQuery() }
        .onChange(of: sortOrder) { updateQuery() }
        .onChange(of: workspace.transactions.map(\.id)) {
            if !workspace.transactions.contains(where: { $0.id == selectedID }) { selectedID = nil }
        }
        .task(id: workspace.focusTransactionSearch) {
            guard workspace.focusTransactionSearch else { return }
            // Let the split-view navigation install its focus scope first.
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            focusSearchIfRequested()
        }
        .confirmationDialog("Delete this transaction?", isPresented: Binding(
            get: { deletionCandidate != nil },
            set: { if !$0 { deletionCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Delete transaction", role: .destructive) {
                guard let id = deletionCandidate?.id else { return }
                if let transaction = workspace.transactions.first(where: { $0.id == id }) { workspace.delete(transaction) }
                selectedID = nil
                deletionCandidate = nil
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: {
            Text("This hides the transaction while retaining its source evidence and history. Re-importing the same capture will not recreate it.")
        }
        .sheet(item: $receiptTransaction) { transaction in
            ReceiptEvidenceView(transactionID: transaction.id.uuidString, title: transaction.merchant).vaultSheet()
        }
    }

    private var pagination: some View {
        HStack(spacing: 10) {
            Text(workspace.matchingTransactions == 0 ? "0 transactions" : "\(workspace.page * 500 + 1)–\(workspace.page * 500 + filteredTransactions.count) of \(workspace.matchingTransactions) \(workspace.matchingTransactions == 1 ? "transaction" : "transactions")")
                .font(.caption).foregroundStyle(AppStyle.muted)
            Button { workspace.changePage(workspace.page - 1) } label: {
                Image(systemName: "chevron.left")
            }.disabled(workspace.page == 0).accessibilityLabel("Previous page")
            Text("Page \(workspace.page + 1)").font(.caption).monospacedDigit()
            Button { workspace.changePage(workspace.page + 1) } label: {
                Image(systemName: "chevron.right")
            }.disabled((workspace.page + 1) * 500 >= workspace.matchingTransactions).accessibilityLabel("Next page")
        }.fixedSize()
    }

    private var selectionActions: some View {
        HStack(spacing: 10) {
            Button("Delete…", role: .destructive) { deletionCandidate = selectedTransaction }
            Button("Notes & receipts…") { receiptTransaction = selectedTransaction }
            Button("Edit…") { workspace.editor = selectedTransaction }.keyboardShortcut("e", modifiers: .command)
        }.disabled(selectedTransaction == nil).fixedSize()
    }

    private func focusSearchIfRequested() {
        if workspace.focusTransactionSearch {
            searchFocused = true
            workspace.focusTransactionSearch = false
        }
    }

    private func updateQuery() {
        var query = LedgerTransactionQuery()
        query.search = search
        query.categoryNames = Dictionary(uniqueKeysWithValues: SpendingCategory.allCases.map { ($0.code, $0.rawValue) })
        query.typeNames = Dictionary(uniqueKeysWithValues: TransactionKind.allCases.map { ($0.code, $0.rawValue) })
        query.category = category?.code
        query.accountID = accountID
        query.reviewOnly = workspace.reviewOnly
        query.sort = sortOrder.compactMap { comparator in
            let column: LedgerTransactionSort.Column
            switch comparator.keyPath {
            case \Transaction.date: column = .date
            case \Transaction.merchant: column = .merchant
            case \Transaction.amount: column = .amount
            default: return nil
            }
            return LedgerTransactionSort(column, descending: comparator.order == .reverse)
        }
        workspace.queryTransactions(query)
        selectedID = nil
    }

    private var hasFilters: Bool { !search.isEmpty || category != nil || accountID != nil || workspace.reviewOnly }
    private func clearFilters() {
        search = ""
        category = nil
        accountID = nil
        workspace.reviewOnly = false
    }
}
