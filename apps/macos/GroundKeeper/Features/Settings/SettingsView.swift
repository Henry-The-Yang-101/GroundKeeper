import SwiftUI
import GroundKeeperCore
import ServiceManagement

struct SettingsView: View {
    @Environment(AppWorkspace.self) private var workspace
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @State private var accountName = ""
    @State private var currency = "CAD"
    @State private var kind = "credit_card"
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            Section("Queue processing") {
                Picker("Process queue", selection: Binding(get: { workspace.processingMode }, set: workspace.changeProcessingMode)) {
                    ForEach(QueueProcessingMode.allCases) { Text($0.title).tag($0) }
                }.disabled(workspace.changingProcessingMode || workspace.saving)
                Text(workspace.processingDescription).font(.caption).foregroundStyle(.secondary)
                if workspace.processingMode == .background {
                    Text(workspace.backgroundStatus).font(.caption)
                    HStack {
                        Button("Enable background service") { workspace.changeProcessingMode(.background) }
                            .disabled(workspace.changingProcessingMode)
                        Button("Open Login Items settings…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                QueueControls()
            }
            Section {
                LabeledContent("Storage", value: workspace.ready ? "SQLite · local Mac" : "Unavailable")
                Text(workspace.vaultPath).font(.caption).textSelection(.enabled)
                Text("The database is stored locally in Application Support, outside iCloud Drive. Encryption and backup features are deferred.")
                    .font(.caption).foregroundStyle(.secondary)
                if !workspace.ready { Button("Retry opening vault") { Task { await workspace.start() } } }
            } header: { Text("Local vault") }
            Section {
                LabeledContent("Model", value: workspace.classifierStatus)
                Button("Choose local model package…", action: workspace.selectModel).disabled(!workspace.ready || workspace.processing || workspace.saving)
                LabeledContent("Queue", value: "\(workspace.pendingJobs) pending · \(workspace.failedJobs) failed")
                Text("Unconfirmed new transactions are sent to the local Python worker. Every result requires review. Confirmed choices are preserved. Cloud providers and Council are not enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Categorization") }
            Section {
                ForEach(workspace.accounts) { account in LabeledContent(account.name, value: account.currency) }
                TextField("New account name", text: $accountName)
                Picker("Currency", selection: $currency) { ForEach(["CAD", "USD", "EUR", "GBP"], id: \.self) { Text($0) } }
                Picker("Kind", selection: $kind) {
                    Text("Credit card").tag("credit_card"); Text("Chequing").tag("checking")
                    Text("Savings").tag("savings"); Text("Cash").tag("cash"); Text("Other").tag("other")
                }
                Button("Add account") { workspace.addAccount(name: accountName, currency: currency, kind: kind); accountName = "" }
                    .disabled(!workspace.ready || workspace.saving || accountName.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Confirm Wallet and bank card labels in Sync. Names and last-four digits alone do not establish account identity.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Accounts") }
            Section("GroundKeeper") {
                Text("Local capture, import, reconciliation and classification")
                Text("Analytics and planning will be added later.").foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(maxWidth: 850).frame(maxWidth: .infinity).background(AppStyle.pageBackground)
    }
}
