import SwiftUI
import GroundKeeperCore

struct CardMappingsSection: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(CaptureWorkspace.self) private var captureState
    @Environment(TransactionWorkspace.self) private var transactionState

    var body: some View {
        Section {
            if captureState.cardMappings.isEmpty {
                Text("No remembered cards.").foregroundStyle(AppStyle.muted)
            }
            ForEach(captureState.cardMappings) { mapping in
                VStack(alignment: .leading, spacing: 8) {
                    Text(mapping.label.isEmpty ? "Missing card description" : mapping.label)
                        .fontWeight(.medium).textSelection(.enabled)
                    Text(mapping.sourceName).font(.caption).foregroundStyle(AppStyle.muted)
                    Picker("Account", selection: Binding(
                        get: { mapping.accountID },
                        set: { captureState.updateCardMapping(mapping, accountID: $0) }
                    )) {
                        ForEach(transactionState.accounts) { account in
                            Text("\(account.displayName(in: transactionState.accounts)) · \(account.currency)").tag(account.id)
                        }
                    }
                    Button("Remove mapping", role: .destructive) { captureState.removeCardMapping(mapping) }
                }
            }
        } header: {
            Text("Card mappings").font(VaultTypography.section)
        } footer: {
            Text("Remember a card when choosing an account in Sync. Wallet and bank descriptions are mapped separately. Changes apply to future imports, including delayed captures; saved transactions and other reviews keep their existing choices.")
        }
        .disabled(!session.ready || session.saving)
    }
}
