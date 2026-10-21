import SwiftUI
import GroundKeeperCore

struct CardMappingsSection: View {
    @Environment(AppWorkspace.self) private var workspace

    var body: some View {
        Section {
            if workspace.cardMappings.isEmpty {
                Text("No remembered cards.").foregroundStyle(AppStyle.muted)
            }
            ForEach(workspace.cardMappings) { mapping in
                VStack(alignment: .leading, spacing: 8) {
                    Text(mapping.label.isEmpty ? "Missing card description" : mapping.label)
                        .fontWeight(.medium).textSelection(.enabled)
                    Text(mapping.sourceName).font(.caption).foregroundStyle(AppStyle.muted)
                    Picker("Account", selection: Binding(
                        get: { mapping.accountID },
                        set: { workspace.updateCardMapping(mapping, accountID: $0) }
                    )) {
                        ForEach(workspace.accounts) { account in
                            Text("\(account.name) · \(account.currency)").tag(account.id)
                        }
                    }
                    Button("Remove mapping", role: .destructive) { workspace.removeCardMapping(mapping) }
                }
            }
        } header: {
            Text("Card mappings").font(VaultTypography.section)
        } footer: {
            Text("Remember a card when choosing an account in Sync. Wallet and bank descriptions are mapped separately. Changes apply to future imports, including delayed captures; saved transactions and other reviews keep their existing choices.")
        }
        .disabled(!workspace.ready || workspace.saving)
    }
}
