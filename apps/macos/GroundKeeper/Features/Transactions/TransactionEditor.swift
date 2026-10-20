import SwiftUI

struct TransactionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppWorkspace.self) private var workspace
    // A sheet owns an edit session. Parent refreshes must not overwrite unsaved input.
    @State private var draft: Transaction
    @State private var amountText: String
    @State private var showingDiscardConfirmation = false
    @FocusState private var merchantFocused: Bool
    private let original: Transaction
    private let originalAmountText: String
    let onSave: (Transaction) -> Void

    init(transaction: Transaction, onSave: @escaping (Transaction) -> Void) {
        original = transaction
        _draft = State(initialValue: transaction)
        let initialAmount = transaction.amount == 0 ? "" : transaction.amount.formatted(.number.grouping(.never))
        originalAmountText = initialAmount
        _amountText = State(initialValue: initialAmount)
        self.onSave = onSave
    }

    private var amount: Decimal? {
        let input = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = input.components(separatedBy: Locale.current.decimalSeparator ?? ".")
        // Foundation's parser accepts numeric prefixes, even with lenient: false.
        // Validate the entire field first; grouping separators are not input syntax.
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ $0.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) }),
              parts.count == 1 || parts[1].count <= 2 else { return nil }
        return try? Decimal(input, format: .number.locale(.current), lenient: false)
    }
    private var valid: Bool {
        !draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validAmount && draft.accountID != nil && workspace.accounts.contains { $0.id == draft.accountID && $0.currency == draft.currency }
            && !(draft.kind.usesCategory && draft.category == .other && draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var validAmount: Bool {
        guard let amount else { return false }
        return amount > 0 && amount.exponent >= -2
    }
    private var isChanged: Bool {
        draft != original || amountText != originalAmountText
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(original.merchant.isEmpty ? "Add transaction" : "Edit transaction")
                        .font(VaultTypography.sheet)
                    Text("Saved to your local database")
                        .font(.callout).foregroundStyle(AppStyle.muted)
                }
                Spacer()
            }.padding(24)
            Divider()
            Form {
                VaultFormSection("Transaction") {
                    TextField("Merchant or description", text: $draft.merchant)
                        .focused($merchantFocused)
                    HStack {
                        TextField("Amount", text: $amountText)
                            .accessibilityHint("Enter a positive amount without thousands separators. Transaction type determines its purpose.")
                        Picker("Currency", selection: $draft.currency) {
                            ForEach(["CAD", "USD", "EUR", "GBP"], id: \.self) { Text($0) }
                        }.labelsHidden().frame(width: 85)
                    }
                    if !amountText.isEmpty && !validAmount {
                        Text("Use a positive amount, up to two decimal places, and no thousands separators.").font(.caption).foregroundStyle(.red)
                    }
                    DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                    Picker("Account", selection: $draft.accountID) {
                        Text("Choose account").tag(nil as String?)
                        ForEach(workspace.accounts) { Text("\($0.name) · \($0.currency)").tag(Optional($0.id)) }
                    }
                    Picker("Direction", selection: $draft.isDebit) { Text("Money out").tag(true); Text("Money in").tag(false) }
                    LabeledContent("Source", value: draft.source)
                    Picker("Type", selection: $draft.kind) {
                        ForEach(TransactionKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section {
                    if draft.kind.usesCategory {
                        Picker("Category", selection: $draft.category) {
                            ForEach(SpendingCategory.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    Toggle("Needs review", isOn: $draft.needsReview)
                        .disabled(draft.kind.usesCategory && draft.category == .uncategorized)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...5)
                } header: {
                    Text("Details").font(VaultTypography.section)
                } footer: {
                    Text(draft.kind.usesCategory && draft.category == .other
                         ? "Add a note describing this expense."
                         : "Changes apply to this transaction only. Uncategorized purchases stay in review.")
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save transaction") { save() }
                    .buttonStyle(.brass)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || workspace.saving)
            }.padding(20)
        }
        .frame(width: 530, height: 600)
        .interactiveDismissDisabled(isChanged)
        .onAppear { merchantFocused = true }
        .onChange(of: draft.accountID) { _, id in
            if let account = workspace.accounts.first(where: { $0.id == id }) { draft.currency = account.currency; draft.account = account.name }
        }
        .onChange(of: draft.category) { _, category in
            if category == .uncategorized { draft.needsReview = true }
        }
        .onChange(of: draft.kind) { _, kind in
            if kind.usesCategory && draft.category == .uncategorized { draft.needsReview = true }
        }
        .confirmationDialog("Discard your changes?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) { }
        }
    }

    private func cancel() {
        if isChanged { showingDiscardConfirmation = true } else { dismiss() }
    }

    private func save() {
        guard valid, let amount else { return }
        draft.amount = amount
        draft.merchant = draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.kind.usesCategory { draft.category = .uncategorized }
        if draft.kind.usesCategory && draft.category == .uncategorized { draft.needsReview = true }
        onSave(draft)
    }
}
