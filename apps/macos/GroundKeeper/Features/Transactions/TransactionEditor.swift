import SwiftUI
import GroundKeeperCore

struct TransactionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppWorkspace.self) private var workspace
    @Environment(ClassifierWorkspace.self) private var classifier
    @Environment(TransactionWorkspace.self) private var transactionState
    // A sheet owns an edit session. Parent refreshes must not overwrite unsaved input.
    @State private var draft: Transaction
    @State private var amountText: String
    @State private var showingDiscardConfirmation = false
    @State private var suggestion: DraftCategorySuggestion?
    @State private var suggestionError: String?
    @State private var suggestionTask: Task<Void, Never>?
    @State private var suggesting = false
    @State private var receiptsLoading = false
    @FocusState private var merchantFocused: Bool
    private let original: Transaction
    private let originalAmountText: String
    let onSave: (Transaction) -> Void

    init(transaction: Transaction, onSave: @escaping (Transaction) -> Void) {
        original = transaction
        _draft = State(initialValue: transaction)
        let initialAmount = transaction.amount == 0 ? "" : TransactionInput.amountText(transaction.amount)
        originalAmountText = initialAmount
        _amountText = State(initialValue: initialAmount)
        self.onSave = onSave
    }

    private var amount: Decimal? { TransactionInput.positiveAmount(amountText) }
    private var selectedAccount: Account? {
        transactionState.accounts.first { $0.id == draft.accountID }
    }
    private var currencyMismatch: Bool {
        selectedAccount.map { $0.currency != draft.currency } ?? false
    }
    private var valid: Bool {
        !draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validAmount && validDirection && draft.accountID != nil && transactionState.accounts.contains { $0.id == draft.accountID && $0.currency == draft.currency }
    }
    private var validAmount: Bool { amount != nil }
    private var validDirection: Bool { draft.kind.requiredDebit.map { $0 == draft.isDebit } ?? true }
    private var isChanged: Bool {
        draft != original || amountText != originalAmountText
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: original.merchant.isEmpty ? "Add transaction" : "Edit transaction",
                         subtitle: "Save this entry to your local database.")
            Divider()
            Form {
                Section {
                    TextField("Merchant or description", text: $draft.merchant)
                        .focused($merchantFocused)
                    HStack {
                        Button(action: suggestCategory) {
                            Label(suggesting ? "Suggesting…" : "Suggest category", systemImage: "sparkles")
                        }
                        .disabled(draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || suggesting || workspace.processing)
                        if suggesting { ProgressView().controlSize(.small) }
                    }
                    Text("Suggestions use your description, notes, and available receipt text. Apple receipt sharing follows Settings.")
                        .font(.caption).foregroundStyle(AppStyle.muted)
                    if let suggestionError {
                        Text(suggestionError).font(.caption).foregroundStyle(.red)
                    }
                    if let suggestion {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Suggested: \(suggestion.kind.rawValue) · \(suggestion.category.rawValue)", systemImage: "sparkles")
                            Text(suggestion.provider).font(.caption).foregroundStyle(.secondary)
                            if !suggestion.contextSummary.isEmpty {
                                Text(suggestion.contextSummary).font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Use suggestion") {
                                draft.kind = suggestion.kind
                                draft.category = suggestion.category
                                draft.confirmCategory = true
                                draft.categoryAttribution = .init(origin: "user")
                                draft.needsReview = suggestion.kind == .unknown
                                self.suggestion = nil
                            }
                        }
                    }
                    HStack {
                        TransactionAmountField(text: $amountText, currency: draft.currency)
                        Picker("Currency", selection: $draft.currency) {
                            ForEach(["CAD", "USD", "EUR", "GBP"], id: \.self) { Text($0) }
                        }.labelsHidden().frame(width: 85)
                    }
                    if !amountText.isEmpty && !validAmount {
                        Text("Use a positive amount, up to two decimal places, and no thousands separators.").font(.caption).foregroundStyle(.red)
                    }
                    TransactionDatePicker(date: $draft.date)
                    Picker("Account", selection: $draft.accountID) {
                        Text("Choose account").tag(nil as String?)
                        ForEach(transactionState.accounts) { Text("\($0.displayName(in: transactionState.accounts)) · \($0.currency)").tag(Optional($0.id)) }
                    }
                    if currencyMismatch, let account = selectedAccount {
                        Text("This account uses \(account.currency), but the entered amount is \(draft.currency). Changing its currency keeps the number unchanged; it does not convert the amount.")
                            .font(.caption).foregroundStyle(.red)
                        Button("Use \(account.currency) for this amount") { draft.currency = account.currency }
                    }
                    TransactionDirectionPicker(isDebit: $draft.isDebit)
                    LabeledContent("Source", value: draft.source)
                    Picker("Type", selection: $draft.kind) {
                        ForEach(TransactionKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if let explanation = draft.kind.directionExplanation {
                        Text(explanation)
                            .font(.caption)
                            .foregroundStyle(validDirection ? Color.secondary : Color.red)
                    }
                    if !validDirection, let requiredDebit = draft.kind.requiredDebit {
                        Button(requiredDebit ? "Use Money out" : "Use Money in") {
                            draft.isDebit = requiredDebit
                        }
                    }
                    if draft.kind.usesCategory {
                        Picker("Category", selection: $draft.category) {
                            ForEach(SpendingCategory.allCases) { Text($0.rawValue).tag($0) }
                        }
                        CategoryLabel(transaction: draft)
                        if draft.category != .none && draft.categoryAttribution.isAI && !draft.confirmCategory {
                            Button("Use this category") {
                                draft.confirmCategory = true
                                draft.categoryAttribution = .init(origin: "user")
                                if draft.kind != .unknown { draft.needsReview = false }
                            }
                        }
                    }
                    Toggle("Category needs review", isOn: $draft.needsReview)
                        .disabled(draft.kind.usesCategory && draft.category == .none)
                    if !draft.reviewIssues.isEmpty {
                        ForEach(draft.reviewIssues) { issue in
                            Label(issue.title, systemImage: "exclamationmark.bubble")
                                .font(.caption).foregroundStyle(AppStyle.muted)
                        }
                        Text("Source issues are resolved separately from the category.").font(.caption).foregroundStyle(AppStyle.muted)
                        Button("Resolve source issues in Sync") { workspace.selectedTab = .sync; dismiss() }
                            .disabled(isChanged).help("Save or cancel your changes before opening Sync.")
                    }
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...5)
                } header: {
                    Text("Transaction").font(VaultTypography.section)
                } footer: {
                    Text(draft.kind.usesCategory && draft.category == .other
                         ? "Other includes spending whose purpose is uncertain. You can add details in Notes."
                         : classifier.classifierProvider == "manual"
                            ? "Changes apply to this transaction only. Uncategorized purchases stay in review until you choose a category or enable a classifier."
                            : "Changes apply to this transaction only. Uncategorized purchases receive suggestions when the queue processes.")
                }
                TransactionReceiptEditor(transaction: $draft, loading: $receiptsLoading)
                CouncilEvidenceView(transactionID: original.id.uuidString)
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            .disabled(workspace.saving)
            SheetFooter {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).disabled(workspace.saving)
                Spacer()
                if workspace.saving { ProgressView("Saving…").controlSize(.small) }
                Button("Save transaction") { save() }
                    .buttonStyle(.brass)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || workspace.saving || suggesting || receiptsLoading)
            }
        }
        .frame(width: 580, height: 700)
        .interactiveDismissDisabled(isChanged || workspace.saving)
        .onAppear { merchantFocused = true }
        .onDisappear { suggestionTask?.cancel() }
        .onChange(of: suggestionInput) { _, _ in
            suggestionTask?.cancel()
            suggestion = nil; suggestionError = nil
        }
        .onChange(of: draft.accountID) { _, id in
            if let account = transactionState.accounts.first(where: { $0.id == id }) {
                draft.selectAccount(account, amountEntered: !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onChange(of: draft.category) { _, category in
            if category == .none { draft.needsReview = true }
            draft.categoryAttribution = category == original.category && draft.kind == original.kind && !draft.confirmCategory
                ? original.categoryAttribution : .init(origin: "user")
        }
        .onChange(of: draft.kind) { _, kind in
            if let requiredDebit = kind.requiredDebit { draft.isDebit = requiredDebit }
            if kind.usesCategory && draft.category == .none { draft.needsReview = true }
            draft.categoryAttribution = kind == original.kind && draft.category == original.category && !draft.confirmCategory
                ? original.categoryAttribution : .init(origin: "user")
        }
        .confirmationDialog("Discard your changes?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) { }
        }
    }

    private var suggestionInput: [String] {
        [draft.merchant, draft.currency, draft.isDebit ? "debit" : "credit", draft.notes,
         draft.newReceiptImages.map { $0.id.uuidString }.joined(separator: ","), draft.removedReceiptIDs.sorted().joined(separator: ",")]
    }

    private func suggestCategory() {
        let input = suggestionInput
        let snapshot = draft
        suggestion = nil; suggestionError = nil; suggesting = true
        suggestionTask = Task {
            defer { suggesting = false }
            do {
                let result = try await classifier.suggestCategory(for: snapshot)
                try Task.checkCancellation()
                guard suggestionInput == input else { return }
                suggestion = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled { suggestionError = error.localizedDescription } }
        }
    }

    private func cancel() {
        if isChanged { showingDiscardConfirmation = true } else { dismiss() }
    }

    private func save() {
        guard valid, let amount else { return }
        draft.amount = amount
        draft.merchant = draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.kind.usesCategory { draft.category = .none }
        if draft.kind.usesCategory && draft.category == .none { draft.needsReview = true }
        onSave(draft)
    }
}
