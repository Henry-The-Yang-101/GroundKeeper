import SwiftUI
import GroundKeeperCore
import ServiceManagement

struct SettingsView: View {
    @Environment(AppWorkspace.self) private var workspace
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @State private var accountName = ""
    @State private var currency = "CAD"
    @State private var showingProtection = false
    @State private var showingModels = false
    @State private var showingPhoneGuide = false
    @State private var installer = ModelInstaller()
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
                    ForEach(QueueProcessingMode.allCases.filter { $0 != .background || (QueueBackgroundService.isSupported && !workspace.encrypted) }) { Text($0.title).tag($0) }
                }.disabled(workspace.changingProcessingMode || workspace.saving)
                Text(workspace.processingDescription).font(.caption).foregroundStyle(.secondary)
                if !QueueBackgroundService.isSupported {
                    Text(QueueBackgroundService.unsupportedMessage).font(.caption).foregroundStyle(.secondary)
                }
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
                LabeledContent("Storage", value: workspace.ready ? (workspace.encrypted ? "SQLCipher · encrypted · local Mac" : "SQLite · unencrypted · local Mac") : "Unavailable")
                Text(workspace.vaultPath).font(.caption).textSelection(.enabled)
                Text("The database is stored locally in Application Support, outside iCloud Drive. Original capture files keep their existing iCloud protection.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Change vault protection…") { showingProtection = true }.disabled(!workspace.ready || workspace.processing || workspace.saving)
                    if workspace.encrypted { Button("Lock vault") { Task { await workspace.lockVault() } }.disabled(workspace.saving || workspace.changingProcessingMode) }
                }
                if workspace.encrypted { Text("Encrypted vaults process while the app is open and unlocked, or manually.").font(.caption).foregroundStyle(.secondary) }
                if !workspace.ready { Button("Retry opening vault") { Task { await workspace.start() } } }
            } header: { Text("Local vault") }
            Section {
                LabeledContent("Model", value: workspace.classifierStatus)
                Button("Install models or choose a provider…") { showingModels = true }.disabled(!workspace.ready || workspace.processing || workspace.saving)
                Button("Choose local model package…", action: workspace.selectModel).disabled(!workspace.ready || workspace.processing || workspace.saving)
                TextField("Apple Intelligence Shortcut", text: Binding(get: { workspace.shortcutName }, set: { workspace.shortcutName = $0 }))
                    .disabled(workspace.processing || workspace.saving)
                Text("Using this provider sends description, direction and currency to the selected Shortcut. Its Use Model action controls whether Apple Intelligence runs on device or in the cloud. Check that action in Shortcuts before enabling.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Include receipt text with Apple Intelligence", isOn: Binding(get: { workspace.shareReceiptContextWithApple }, set: workspace.setReceiptSharing))
                    .disabled(!workspace.ready || workspace.processing || workspace.saving)
                Text("Off by default. When enabled, selected receipt excerpts also go to your Apple Intelligence Shortcut and may be processed in the cloud. Qwen and Laya use receipt context locally. Original images stay out of classifier requests.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Use Apple Intelligence Shortcut", action: workspace.useShortcut)
                    .disabled(!workspace.ready || workspace.processing || workspace.saving)
                LabeledContent("Queue", value: "\(workspace.pendingJobs) pending · \(workspace.failedJobs) failed")
                Text("Choose a Qwen or Laya package for local inference, or explicitly enable the Shortcut above. Every result requires review. Confirmed choices are preserved. Providers never fall back to one another.")
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
            Section("Setup and iPhone") {
                Button("Review setup assistant…") { AppPreferences.defaults.set(0, forKey: "setupStep"); workspace.showingSetup = true }
                    .disabled(workspace.processing || workspace.saving)
                Button("iPhone Shortcuts and automation guide…") { showingPhoneGuide = true }
                Button("Create standard iCloud inbox…", action: workspace.createDefaultCaptureFolder)
                Button("Choose capture folder…", action: workspace.selectFolder)
                Text(workspace.captureFolderPath).font(.caption).textSelection(.enabled)
            }
            Section("GroundKeeper") {
                Text("Local capture, import, reconciliation and classification")
                Text("Analytics and planning will be added later.").foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(maxWidth: 850).frame(maxWidth: .infinity).background(AppStyle.pageBackground)
            .sheet(isPresented: $showingProtection) {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Vault protection").font(.largeTitle.bold())
                    VaultProtectionView()
                    HStack { Spacer(); Button("Done") { showingProtection = false }.disabled(workspace.saving) }
                }.padding(32).frame(width: 580).interactiveDismissDisabled(workspace.saving)
            }
            .sheet(isPresented: $showingModels) {
                VStack {
                    ScrollView { ModelSetupView(installer: installer).padding(30) }
                    HStack { Spacer(); Button("Done") { showingModels = false }.disabled(installer.busy || workspace.saving) }.padding()
                }.frame(width: 720, height: 730).interactiveDismissDisabled(installer.busy || workspace.saving)
            }
            .sheet(isPresented: $showingPhoneGuide) {
                VStack { ScrollView { PhoneSetupView().padding(30) }; Button("Done") { showingPhoneGuide = false }.padding() }.frame(width: 700, height: 700)
            }
    }
}
