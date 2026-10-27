import SwiftUI
import GroundKeeperCore

struct AccountRenameSheet: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(TransactionWorkspace.self) private var transactionState
    @Environment(\.dismiss) private var dismiss
    let account: Account
    // Each sheet owns one rename draft; workspace refreshes must not replace it.
    @State private var name: String
    @State private var saving = false
    @State private var error: String?

    init(account: Account) {
        self.account = account
        _name = State(initialValue: account.name)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicateName: Bool {
        transactionState.accountNameExists(name: name, currency: account.currency, excludingID: account.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Rename account", subtitle: "Use a name that helps you recognize this account.")
            Form {
                TextField("Account name", text: $name)
                LabeledContent("Currency", value: account.currency)
                Text("Transactions and remembered card mappings stay linked to this account.")
                    .font(.caption).foregroundStyle(AppStyle.muted)
                if duplicateName {
                    Text("Another account with this name already uses \(account.currency). Choose a different name.")
                        .font(.caption).foregroundStyle(.red)
                }
                if trimmedName.count > 100 {
                    Text("Use an account name of 100 characters or fewer.").font(.caption).foregroundStyle(.red)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.formStyle(.grouped).scrollContentBackground(.hidden).disabled(saving)
            SheetFooter {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save name") {
                    saving = true
                    error = nil
                    Task {
                        do {
                            try await transactionState.renameAccount(id: account.id, name: trimmedName)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }
                .buttonStyle(.brass).keyboardShortcut(.defaultAction)
                .disabled(saving || workspace.saving || trimmedName.isEmpty || trimmedName.count > 100 || trimmedName == account.name || duplicateName)
            }
        }
        .frame(width: 500, height: 320)
        .interactiveDismissDisabled(saving)
    }
}
