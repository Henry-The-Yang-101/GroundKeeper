import SwiftUI

struct RememberCardChoice: View {
    let label: String
    @Binding var remember: Bool

    var body: some View {
        if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Toggle("Remember this card for future transactions", isOn: $remember)
                .toggleStyle(.checkbox)
            Text(remember
                 ? "Future captures with this exact card description from this source will use the selected account. Manage mappings in Settings."
                 : "Leave unchecked to use the account for this transaction only.")
                .font(.caption).foregroundStyle(AppStyle.muted)
        }
    }
}
