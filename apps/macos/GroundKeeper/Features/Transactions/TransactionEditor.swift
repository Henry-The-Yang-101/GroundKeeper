import SwiftUI

struct TransactionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Transaction
    @State private var amountText: String
    @State private var showingDiscardConfirmation = false
    @FocusState private var merchantFocused: Bool
    private let original: Transaction
    let onSave: (Transaction) -> Void

    init(transaction: Transaction, onSave: @escaping (Transaction) -> Void) {
        original = transaction
        _draft = State(initialValue: transaction)
        _amountText = State(initialValue: transaction.amount == 0 ? "" : transaction.amount.formatted(.number.grouping(.never)))
        self.onSave = onSave
    }

    private var amount: Decimal? {
        try? Decimal(amountText, format: .number.locale(.current), lenient: false)
    }
    private var valid: Bool {
        !draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (amount ?? 0) > 0
            && !(draft.kind.usesCategory && draft.category == .other && draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var isChanged: Bool {
        draft != original || (amount ?? 0) != original.amount
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(original.merchant.isEmpty ? "Add transaction" : "Edit transaction")
                        .font(.title2.weight(.semibold))
                    Text("Sample workspace · Saved for this session only")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            Form {
                Section("Transaction") {
                    TextField("Merchant or description", text: $draft.merchant)
                        .focused($merchantFocused)
                    HStack {
                        TextField("Amount", text: $amountText)
                            .accessibilityHint("Enter a positive amount. Transaction type determines its purpose.")
                        Picker("Currency", selection: $draft.currency) {
                            ForEach(["CAD", "USD", "EUR", "GBP"], id: \.self) { Text($0) }
                        }.labelsHidden().frame(width: 85)
                    }
                    if !amountText.isEmpty && (amount ?? 0) <= 0 {
                        Text("Enter an amount greater than zero.").font(.caption).foregroundStyle(.red)
                    }
                    DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                    Picker("Account", selection: $draft.account) {
                        Text("Everyday card").tag("Everyday card")
                        Text("Chequing").tag("Chequing")
                        Text("Cash").tag("Cash")
                    }
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
                    Text("Details")
                } footer: {
                    Text(draft.kind.usesCategory && draft.category == .other
                         ? "Add a note describing this expense."
                         : "Changes apply to this transaction only. Uncategorized purchases stay in review.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save sample transaction") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }.padding(20)
        }
        .frame(width: 530, height: 650)
        .interactiveDismissDisabled(isChanged)
        .onAppear { merchantFocused = true }
        .onChange(of: draft.category) { _, category in
            if category == .uncategorized { draft.needsReview = true }
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
        dismiss()
    }
}
