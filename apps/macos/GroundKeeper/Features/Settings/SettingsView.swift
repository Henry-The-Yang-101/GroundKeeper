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
    @State private var renamingAccount: Account?
    private var duplicateAccountName: Bool { workspace.accountNameExists(name: accountName, currency: currency) }
    var body: some View {
        Form {
            VaultFormSection("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).tint(AppStyle.controlAccent)
            }
            VaultFormSection("Queue processing") {
                Picker("Process queue", selection: Binding(get: { workspace.processingMode }, set: workspace.changeProcessingMode)) {
                    ForEach(QueueProcessingMode.allCases.filter { $0 != .background || (QueueBackgroundService.isSupported && !workspace.encrypted) }) { Text($0.title).tag($0) }
                }.disabled(workspace.changingProcessingMode || workspace.saving)
                Text(workspace.processingDescription).font(.caption).foregroundStyle(AppStyle.muted)
                if !QueueBackgroundService.isSupported {
                    Text(QueueBackgroundService.unsupportedMessage).font(.caption).foregroundStyle(AppStyle.muted)
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
                    .font(.caption).foregroundStyle(AppStyle.muted)
                HStack {
                    Button("Change vault protection…") { showingProtection = true }.disabled(!workspace.ready || workspace.processing || workspace.saving)
                    if workspace.encrypted { Button("Lock vault") { Task { await workspace.lockVault() } }.disabled(workspace.saving || workspace.changingProcessingMode) }
                }
                if workspace.encrypted { Text("Encrypted vaults process while the app is open and unlocked, or manually.").font(.caption).foregroundStyle(AppStyle.muted) }
                if !workspace.ready { Button("Retry opening vault") { Task { await workspace.start() } } }
            } header: { Text("Local vault").font(VaultTypography.section) }
            Section {
                LabeledContent("Model", value: workspace.classifierStatus)
                Button("Install models or choose a provider…") { showingModels = true }.disabled(!workspace.ready || workspace.processing || workspace.saving)
                Button("Choose local model package…", action: workspace.selectModel).disabled(!workspace.ready || workspace.processing || workspace.saving)
                TextField("Apple Intelligence Shortcut", text: Binding(get: { workspace.shortcutName }, set: { workspace.shortcutName = $0 }))
                    .disabled(workspace.processing || workspace.saving)
                Text("Using this provider sends description, direction and currency to the selected Shortcut. Its Use Model action controls whether Apple Intelligence runs on device or in the cloud. Check that action in Shortcuts before enabling.")
                    .font(.caption).foregroundStyle(AppStyle.muted)
                Toggle("Include receipt text with Apple Intelligence", isOn: Binding(get: { workspace.shareReceiptContextWithApple }, set: workspace.setReceiptSharing))
                    .disabled(!workspace.ready || workspace.processing || workspace.saving)
                Text("Off by default. When enabled, selected receipt excerpts also go to your Apple Intelligence Shortcut and may be processed in the cloud. Qwen and Laya use receipt context locally. Original images stay out of classifier requests.")
                    .font(.caption).foregroundStyle(AppStyle.muted)
                Button("Use Apple Intelligence Shortcut", action: workspace.useShortcut)
                    .disabled(!workspace.ready || workspace.processing || workspace.saving)
                LabeledContent("Queue", value: "\(workspace.pendingJobs) pending · \(workspace.failedJobs) failed")
                MerchantSearchSettingsView(workspace: workspace)
                Text("Choose Qwen or Laya, Apple Intelligence, or Model council in provider setup. Council consults all three with equal votes. Every result requires review. Confirmed choices are preserved. Providers never fall back to one another.")
                    .font(.caption).foregroundStyle(AppStyle.muted)
            } header: { Text("Categorization").font(VaultTypography.section) }
            Section {
                ForEach(workspace.accounts) { account in
                    HStack {
                        LabeledContent(account.displayName(in: workspace.accounts), value: account.currency)
                        Button("Rename…") { renamingAccount = account }
                            .disabled(!workspace.ready || workspace.saving)
                            .accessibilityLabel("Rename \(account.displayName(in: workspace.accounts))")
                    }
                }
                TextField("New account name", text: $accountName)
                Picker("Currency", selection: $currency) { ForEach(["CAD", "USD", "EUR", "GBP"], id: \.self) { Text($0) } }
                Picker("Kind", selection: $kind) {
                    Text("Credit card").tag("credit_card"); Text("Chequing").tag("checking")
                    Text("Savings").tag("savings"); Text("Cash").tag("cash"); Text("Other").tag("other")
                }
                if duplicateAccountName {
                    Text("An account with this name already uses \(currency). Choose a different name, or rename the existing account above.")
                        .font(.caption).foregroundStyle(.red)
                }
                Button("Add account") { workspace.addAccount(name: accountName, currency: currency, kind: kind); accountName = "" }
                    .disabled(!workspace.ready || workspace.saving || accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || duplicateAccountName)
                Text("Choose an account for Wallet and bank captures in Sync, with the option to remember each card description.").font(.caption).foregroundStyle(AppStyle.muted)
            } header: { Text("Accounts").font(VaultTypography.section) }
            CardMappingsSection()
            VaultFormSection("Setup and iPhone") {
                Button("Review setup assistant…") { workspace.reviewingSetup = true; workspace.showingSetup = true }
                    .disabled(workspace.processing || workspace.saving)
                Button("iPhone Shortcuts and automation guide…") { showingPhoneGuide = true }
                Button("Create standard iCloud inbox…", action: workspace.createDefaultCaptureFolder)
                Button("Choose capture folder…", action: workspace.selectFolder)
                Text(workspace.captureFolderPath).font(.caption).textSelection(.enabled)
            }
            VaultFormSection("GroundKeeper") {
                Text("Local capture, import, reconciliation and classification")
                Text("Spending reports and calculated insights run locally. Budgeting and planning are coming later.").foregroundStyle(AppStyle.muted)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            // The grouped form supplies 20 points; match the page's 28-point edge.
            .padding(.horizontal, PageLayout.inset - 20)
            .safeAreaInset(edge: .top, spacing: 0) {
                PageHeading(title: "Settings", subtitle: "Make this space your own.")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(PageLayout.inset)
                    .background(AppStyle.pageBackground)
            }
            .frame(maxWidth: PageLayout.contentWidth + 2 * PageLayout.inset).frame(maxWidth: .infinity).background(AppStyle.pageBackground)
            .sheet(item: $renamingAccount) { account in AccountRenameSheet(account: account).vaultSheet() }
            .sheet(isPresented: $showingProtection) {
                VStack(spacing: 0) {
                    SheetHeading(title: "Vault protection")
                    ContentSizedScrollView(maximumHeight: 520) {
                        VaultProtectionView().padding(.horizontal, 24).padding(.bottom, 24)
                    }
                    SheetFooter { Spacer(); SheetDoneButton(disabled: workspace.saving) }
                }.frame(width: 580).vaultSheet().interactiveDismissDisabled(workspace.saving)
            }
            .sheet(isPresented: $showingModels) {
                VStack(spacing: 0) {
                    SheetHeading(title: "Categorization")
                    ScrollView { ModelSetupView(installer: installer).padding(.horizontal, 24).padding(.bottom, 24) }
                    SheetFooter { Spacer(); SheetDoneButton(disabled: installer.busy || workspace.saving) }
                }.frame(width: 720, height: 730).vaultSheet().interactiveDismissDisabled(installer.busy || workspace.saving)
            }
            .sheet(isPresented: $showingPhoneGuide) {
                VStack(spacing: 0) {
                    SheetHeading(title: "iPhone capture")
                    ScrollView { PhoneSetupView().padding(.horizontal, 24).padding(.bottom, 24) }
                    SheetFooter { Spacer(); SheetDoneButton() }
                }.frame(width: 700, height: 700).vaultSheet()
            }
    }
}
