import SwiftUI
import AppKit

struct SetupView: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(CaptureWorkspace.self) private var captureState
    @Environment(ClassifierWorkspace.self) private var classifier
    @Environment(TransactionWorkspace.self) private var transactionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppPreferences.Key.setupStep) private var savedStep = 0
    var reviewMode = false
    @AppStorage(AppPreferences.Key.vaultProtectionChosen) private var protectionChosen = false
    @AppStorage(AppPreferences.Key.phoneSetupConfirmed) private var phoneReady = false
    @State private var installer = ModelInstaller()
    @State private var accountName = ""
    @State private var currency = "CAD"
    @State private var accountKind = "credit_card"
    @State private var reviewStep = 0
    @State private var changingProtection = false
    private let titles = ["Welcome", "Privacy", "Intelligence", "iCloud Drive", "iPhone", "Account", "Ready"]
    private var step: Int { min(max(reviewMode ? reviewStep : savedStep, 0), titles.count - 1) }
    private var canContinue: Bool { workspace.ready && !workspace.saving && !installer.busy && (reviewMode || step != 1 || protectionChosen) }
    private var duplicateAccountName: Bool { transactionState.accountNameExists(name: accountName, currency: currency) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("GroundKeeper", systemImage: "square.grid.3x3.square").font(VaultTypography.wordmark)
                Spacer()
                Text("\(titles[step]) · \(step + 1) of \(titles.count)").foregroundStyle(AppStyle.muted)
                if reviewMode {
                    Button("Return to app") { workspace.showingSetup = false }
                        .disabled(workspace.saving || installer.busy)
                        .keyboardShortcut(.cancelAction)
                }
            }.padding(.horizontal, 36).padding(.vertical, 24)
            Divider()
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        page
                    }.frame(maxWidth: 660, alignment: .leading).padding(.horizontal, 48).padding(.vertical, 36)
                        .frame(maxWidth: .infinity)
                }.id(step).transition(.opacity)
            }.animation(reduceMotion ? nil : VaultMotion.feedback, value: step)
            Divider()
            HStack {
                Button("Back") { move(to: step - 1) }.disabled(step == 0 || workspace.saving || installer.busy)
                Spacer()
                if step > 1 && step < 6 { Text("You can revisit this in Settings.").font(.callout).foregroundStyle(AppStyle.muted) }
                Button(step == 6 ? "Open GroundKeeper" : "Continue") {
                    if step == 6 {
                        if reviewMode { workspace.showingSetup = false } else { workspace.finishSetup() }
                    } else { move(to: step + 1) }
                }.buttonStyle(.brass).controlSize(.large).keyboardShortcut(.defaultAction).disabled(!canContinue)
            }.padding(.horizontal, 36).padding(.vertical, 22)
        }
        .background(AppStyle.pageBackground)
        .frame(minWidth: 820, minHeight: 680)
        .alert("Setup needs attention", isPresented: Binding(get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } })) {
            Button("OK") { workspace.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? "") }
    }
    @ViewBuilder private var page: some View {
        switch step {
        case 0:
            header("square.grid.3x3.square", "A clearer picture.\nA place of your own.", "Welcome to GroundKeeper. Bring your transactions together, make sense of each purchase, and keep your financial history on your Mac.")
            feature("iphone.and.arrow.forward", "Capture as you pay", "iPhone Shortcuts save transaction events to your personal iCloud Drive.")
            feature("sparkles", "Get a useful first pass", "Qwen, Laya, or Apple Intelligence suggest categories. You review the result.")
            feature("externaldrive", "Keep the full record", "Import CSVs, reconcile repeated captures, and edit transactions in a local vault.")
            Text("Setup takes a few minutes. Model downloads and iPhone setup can be completed later. Spending reports run locally; budgeting and planning are coming later.").font(.callout).foregroundStyle(AppStyle.muted)
            if !workspace.ready { Text(workspace.status).foregroundStyle(AppStyle.muted); Button("Retry opening vault") { Task { await workspace.start() } } }
        case 1:
            header("lock.shield.fill", "Your records.\nYour choice of protection.", reviewMode
                   ? "Review how your vault is protected on this Mac. You can continue without changing or reapplying protection."
                   : "Choose how GroundKeeper stores the transaction database on this Mac. Your existing records are preserved when you change protection.")
            if reviewMode {
                LabeledContent("Current protection", value: workspace.ready
                               ? (workspace.encrypted ? "Encrypted vault" : "Unencrypted vault") : workspace.status)
                if changingProtection {
                    VaultProtectionView(onApplied: { changingProtection = false })
                    Button("Cancel protection change") { changingProtection = false }.disabled(workspace.saving)
                } else {
                    Button("Change vault protection…") { changingProtection = true }.disabled(!workspace.ready || workspace.saving)
                }
            } else {
                VaultProtectionView(onboarding: true)
                if protectionChosen { Label(workspace.encrypted ? "Encrypted vault selected" : "Unencrypted vault selected", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        case 2:
            header("sparkles", "Intelligence,\nwhere you want it.", "Install local models, use Ollama, choose Apple Intelligence Cloud, or categorize by hand. You are in control of where your transaction text goes.")
            ModelSetupView(installer: installer)
        case 3:
            header("icloud.fill", "From your iPhone.\nTo your Mac.", "Choose an iCloud Drive inbox for the transaction files your iPhone captures. Both devices must use the same Apple Account and have iCloud Drive enabled.")
            feature("folder.badge.plus", "A home for your captures", "The standard location is iCloud Drive/Shortcuts/Groundkeeper/inbox. GroundKeeper can create it after you grant folder access.")
            HStack {
                Button("Create standard iCloud inbox…", action: captureState.createDefaultCaptureFolder).buttonStyle(.brass)
                Button("Choose another folder…", action: captureState.selectFolder)
            }
            if captureState.hasCaptureFolder { Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green); Text(captureState.captureFolderPath).font(.callout).textSelection(.enabled) }
            feature("externaldrive.badge.icloud", "Capture files sync. Your vault stays local.", "Original capture files remain readable in your personal iCloud Drive after import. The Mac database, model files, and vault key stay outside iCloud Drive.")
            Text("Use exactly this folder in your iPhone capture Shortcut. If you skip this step, manual entries and CSV imports still work.").foregroundStyle(AppStyle.muted)
        case 4:
            header("iphone", "Make the connection\non your iPhone.", "Install the capture Shortcuts, then create your personal automation on the phone. Shared Shortcuts cannot select your cards or install personal automations for you.")
            PhoneSetupView()
            Toggle("I configured my iPhone automation and checked a sample capture", isOn: $phoneReady)
            Text("You can continue without a phone. Capture remains pending until you configure and test the automation.").font(.callout).foregroundStyle(AppStyle.muted)
        case 5:
            header("creditcard.fill", "Start with one account.", "Give your first account a name and currency. You can add more later and match captured card labels to the right account.")
            if !transactionState.accounts.isEmpty {
                ForEach(transactionState.accounts) { account in Label("\(account.displayName(in: transactionState.accounts)) · \(account.currency)", systemImage: "checkmark.circle").foregroundStyle(AppStyle.muted) }
            }
            TextField("Account name, for example Everyday card", text: $accountName).textFieldStyle(.roundedBorder)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    Text("Currency")
                    Picker("Currency", selection: $currency) { ForEach(["CAD", "USD", "EUR", "GBP"], id: \.self) { Text($0).tag($0) } }.labelsHidden()
                }
                GridRow {
                    Text("Account type")
                    Picker("Account type", selection: $accountKind) {
                        Text("Credit card").tag("credit_card"); Text("Chequing").tag("checking"); Text("Savings").tag("savings"); Text("Cash").tag("cash"); Text("Other").tag("other")
                    }.labelsHidden()
                }
            }
            if duplicateAccountName {
                Text("An account with this name already uses \(currency). Choose a different name. You can rename existing accounts in Settings.")
                    .font(.caption).foregroundStyle(.red)
            }
            Button("Add account") { transactionState.addAccount(name: accountName, currency: currency, kind: accountKind); accountName = "" }
                .disabled(workspace.saving || accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || duplicateAccountName)
            Text("No bank login is needed. CSV imports and captured transactions are matched to accounts you create.").foregroundStyle(AppStyle.muted)
        default:
            header("checkmark.seal.fill", "Make yourself at home.", "Your workspace is ready. Here is how GroundKeeper is configured.")
            feature("lock.shield", "Local vault", workspace.encrypted ? "Encrypted with SQLCipher. Unlock with your passphrase" + (VaultKeychain.isEnabled ? " or this Mac’s protected Keychain." : ".") : "Standard, unencrypted SQLite on this Mac.")
            feature("sparkles", "Categorization", classifier.classifierStatus)
            feature("icloud", "Capture inbox", captureState.hasCaptureFolder ? captureState.captureFolderPath : "Not connected. Start with a CSV or a manual transaction.")
            feature("iphone", "iPhone automation", phoneReady ? "Marked configured by you. Review the first real capture in Sync." : "Still to set up. Return to this guide from Settings.")
            Text("Start with a fictional transaction. Review suggestions, confirm account mappings, and check Sync for anything that needs attention.").foregroundStyle(AppStyle.muted)
        }
    }
    private func move(to nextStep: Int) {
        if reviewMode { reviewStep = nextStep } else { savedStep = nextStep }
    }
    private func header(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: symbol).font(.system(size: 64, weight: .medium)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(title).font(VaultTypography.welcome).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 16)).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 8)
    }
    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(VaultTypography.section); Text(detail).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct PhoneSetupView: View {
    private let captureNames = ["GroundKeeper Capture Transaction", "GK Receipt OCR", "GroundKeeper Add Receipt", "GroundKeeper Attach Receipt Later", "GroundKeeper Wallet Automation"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("1. Install the capture Shortcuts").font(VaultTypography.section)
            Text("Enable Shortcuts iCloud sync on Mac and iPhone. Open these on your Mac to sync them, or share them to your phone with AirDrop.").foregroundStyle(AppStyle.muted)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                ForEach(captureNames, id: \.self) { name in
                    if let url = SetupResources.shortcut(name) {
                        GridRow {
                            Button(name) { NSWorkspace.shared.open(url) }.frame(maxWidth: .infinity, alignment: .leading)
                            ShareLink(item: url) { Label("Send to iPhone", systemImage: "square.and.arrow.up") }
                                .fixedSize().accessibilityLabel("Send \(name) to iPhone")
                        }
                    } else {
                        Label("\(name): export not available in this build", systemImage: "exclamationmark.circle")
                            .foregroundStyle(AppStyle.muted).gridCellColumns(2)
                    }
                }
            }
            Text("2. Set the destination").font(VaultTypography.section)
            Text("On iPhone, edit GroundKeeper Capture Transaction. Set its final JSON Save File action to the same iCloud inbox selected here, turn off Ask Where to Save, and grant folder access. For a custom folder, update the Shortcut’s destination too.").foregroundStyle(AppStyle.muted)
            Text("Receipts and notes are optional. All chosen steps finish before the transaction is saved; cancelling stops the capture. For image retention, create an assets folder inside that inbox and set the image Save File actions in Capture Transaction and Add Receipt to it. Leave overwrite off. The default receipt choice keeps text only; retained images are copied into your local vault with its existing encryption mode.").foregroundStyle(AppStyle.muted)
            Text("3. Create a Wallet automation").font(VaultTypography.section)
            Text("Open Shortcuts → Automation → + → Transaction. Choose your cards and Run Immediately. Add Run Shortcut → GroundKeeper Wallet Automation and pass the transaction input. Check the merchant, amount, and card variables on your phone; available fields vary by iOS and card.").foregroundStyle(AppStyle.muted)
            Text("4. Add Apple Intelligence, if selected").font(VaultTypography.section)
            if let url = SetupResources.shortcut("GK Categorize Cloud") {
                HStack { Button("Install Apple Intelligence Shortcut") { NSWorkspace.shared.open(url) }; ShareLink(item: url) { Text("Send to iPhone") } }
            }
            Text("The classifier runs on your Mac when GroundKeeper processes the queue. Inspect Use Model: Cloud, web search off, Text output, Follow Up off. Enable it explicitly under Intelligence or Settings. Receipt text sharing with this provider is a separate setting and is off by default.").foregroundStyle(AppStyle.muted)
            if let url = SetupResources.shortcut("GroundKeeper CIBC Automation") {
                DisclosureGroup("Optional: CIBC notification adapter (experimental)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Only use this if your iPhone offers a suitable notification trigger and exposes the expected fields. Enable it deliberately after testing; it is not required for Wallet capture.").foregroundStyle(AppStyle.muted)
                        ShareLink(item: url) { Label("Send CIBC adapter to iPhone", systemImage: "square.and.arrow.up") }
                    }.padding(.top, 8)
                }
            }
            Text("5. Check a sample capture").font(VaultTypography.section)
            Text("Run a fictional sample, confirm a JSON file appears in the inbox, then check Sync on your Mac. A real Wallet purchase and locked-phone delivery need a separate test. CIBC notification capture is experimental; leave it off until its input and trigger are verified on your phone.").foregroundStyle(AppStyle.muted)
            Link("Apple’s Shortcuts guide", destination: URL(string: "https://support.apple.com/guide/shortcuts/welcome/ios")!)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
