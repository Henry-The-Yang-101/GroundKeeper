import SwiftUI
import AppKit

struct SetupView: View {
    @Environment(AppWorkspace.self) private var workspace
    @AppStorage("setupStep") private var savedStep = 0
    @AppStorage("vaultProtectionChosen") private var protectionChosen = false
    @AppStorage("phoneSetupConfirmed") private var phoneReady = false
    @State private var installer = ModelInstaller()
    @State private var accountName = ""
    @State private var currency = "CAD"
    @State private var accountKind = "credit_card"
    private let titles = ["Welcome", "Privacy", "Intelligence", "iCloud Drive", "iPhone", "Account", "Ready"]
    private var step: Int { min(max(savedStep, 0), titles.count - 1) }
    private var canContinue: Bool { workspace.ready && !workspace.saving && !installer.busy && (step != 1 || protectionChosen) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("GroundKeeper", systemImage: "leaf.fill").font(.headline)
                Spacer()
                Text("\(titles[step]) · \(step + 1) of \(titles.count)").foregroundStyle(.secondary)
            }.padding(.horizontal, 36).padding(.vertical, 24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    page
                }.frame(maxWidth: 660, alignment: .leading).padding(.horizontal, 48).padding(.vertical, 36)
                    .frame(maxWidth: .infinity)
            }.id(step)
            Divider()
            HStack {
                Button("Back") { savedStep = step - 1 }.disabled(step == 0 || workspace.saving || installer.busy)
                Spacer()
                if step > 1 && step < 6 { Text("You can revisit this in Settings.").font(.callout).foregroundStyle(.secondary) }
                Button(step == 6 ? "Open GroundKeeper" : "Continue") {
                    if step == 6 { workspace.finishSetup() } else { savedStep = step + 1 }
                }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(!canContinue)
            }.padding(.horizontal, 36).padding(.vertical, 22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 820, minHeight: 680)
        .alert("Setup needs attention", isPresented: Binding(get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } })) {
            Button("OK") { workspace.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? "") }
    }
    @ViewBuilder private var page: some View {
        switch step {
        case 0:
            header("leaf.fill", "A clearer picture.\nA place of your own.", "Welcome to GroundKeeper. Bring your transactions together, make sense of each purchase, and keep your financial history on your Mac.")
            feature("iphone.and.arrow.forward", "Capture as you pay", "iPhone Shortcuts save transaction events to your personal iCloud Drive.")
            feature("sparkles", "Get a useful first pass", "Qwen, Laya, or Apple Intelligence suggest categories. You review the result.")
            feature("externaldrive", "Keep the full record", "Import CSVs, reconcile repeated captures, and edit transactions in a local vault.")
            Text("Setup takes a few minutes. Model downloads and iPhone setup can be completed later. Analytics and planning are still in development.").font(.callout).foregroundStyle(.secondary)
            if !workspace.ready { Text(workspace.status).foregroundStyle(.secondary); Button("Retry opening vault") { Task { await workspace.start() } } }
        case 1:
            header("lock.shield.fill", "Your records.\nYour choice of protection.", "Choose how GroundKeeper stores the transaction database on this Mac. Your existing records are preserved when you change protection.")
            VaultProtectionView(onboarding: true)
            if protectionChosen { Label(workspace.encrypted ? "Encrypted vault selected" : "Unencrypted vault selected", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        case 2:
            header("sparkles", "Intelligence,\nwhere you want it.", "Install local models, choose Apple Intelligence Cloud, or categorize by hand. You are in control of where your transaction text goes.")
            ModelSetupView(installer: installer)
        case 3:
            header("icloud.fill", "From your iPhone.\nTo your Mac.", "Choose an iCloud Drive inbox for the transaction files your iPhone captures. Both devices must use the same Apple Account and have iCloud Drive enabled.")
            feature("folder.badge.plus", "A home for your captures", "The standard location is iCloud Drive/Shortcuts/Groundkeeper/inbox. GroundKeeper can create it after you grant folder access.")
            HStack {
                Button("Create standard iCloud inbox…", action: workspace.createDefaultCaptureFolder).buttonStyle(.borderedProminent)
                Button("Choose another folder…", action: workspace.selectFolder)
            }
            if workspace.hasCaptureFolder { Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green); Text(workspace.captureFolderPath).font(.callout).textSelection(.enabled) }
            feature("externaldrive.badge.icloud", "Capture files sync. Your vault stays local.", "Original capture files remain readable in your personal iCloud Drive after import. The Mac database, model files, and vault key stay outside iCloud Drive.")
            Text("Use exactly this folder in your iPhone capture Shortcut. If you skip this step, manual entries and CSV imports still work.").foregroundStyle(.secondary)
        case 4:
            header("iphone", "Make the connection\non your iPhone.", "Install the capture Shortcuts, then create your personal automation on the phone. Shared Shortcuts cannot select your cards or install personal automations for you.")
            PhoneSetupView()
            Toggle("I configured my iPhone automation and checked a sample capture", isOn: $phoneReady)
            Text("You can continue without a phone. Capture remains pending until you configure and test the automation.").font(.callout).foregroundStyle(.secondary)
        case 5:
            header("creditcard.fill", "Start with one account.", "Give your first account a name and currency. You can add more later and match captured card labels to the right account.")
            if !workspace.accounts.isEmpty {
                ForEach(workspace.accounts) { account in Label("\(account.name) · \(account.currency)", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            TextField("Account name, for example Everyday card", text: $accountName).textFieldStyle(.roundedBorder)
            Picker("Currency", selection: $currency) { ForEach(["CAD", "USD", "EUR", "GBP"], id: \.self) { Text($0).tag($0) } }
            Picker("Account type", selection: $accountKind) {
                Text("Credit card").tag("credit_card"); Text("Chequing").tag("checking"); Text("Savings").tag("savings"); Text("Cash").tag("cash"); Text("Other").tag("other")
            }
            Button("Add account") { workspace.addAccount(name: accountName, currency: currency, kind: accountKind); accountName = "" }
                .disabled(workspace.saving || accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("No bank login is needed. CSV imports and captured transactions are matched to accounts you create.").foregroundStyle(.secondary)
        default:
            header("checkmark.seal.fill", "Make yourself at home.", "Your workspace is ready. Here is how GroundKeeper is configured.")
            feature("lock.shield", "Local vault", workspace.encrypted ? "Encrypted with SQLCipher. Unlock with your passphrase" + (VaultKeychain.isEnabled ? " or this Mac’s protected Keychain." : ".") : "Standard, unencrypted SQLite on this Mac.")
            feature("sparkles", "Categorization", workspace.classifierStatus)
            feature("icloud", "Capture inbox", workspace.hasCaptureFolder ? workspace.captureFolderPath : "Not connected. Start with a CSV or a manual transaction.")
            feature("iphone", "iPhone automation", phoneReady ? "Marked configured by you. Review the first real capture in Sync." : "Still to set up. Return to this guide from Settings.")
            Text("Start with a fictional transaction. Review suggestions, confirm account mappings, and check Sync for anything that needs attention.").foregroundStyle(.secondary)
        }
    }
    private func header(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: symbol).font(.system(size: 64, weight: .medium)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(title).font(.system(size: 40, weight: .bold, design: .rounded)).tracking(-1).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 16)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 8)
    }
    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct PhoneSetupView: View {
    private let captureNames = ["GroundKeeper Capture Transaction", "GroundKeeper Wallet Automation"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("1. Install the capture Shortcuts").font(.headline)
            Text("Enable Shortcuts iCloud sync on Mac and iPhone. Open these on your Mac to sync them, or share them to your phone with AirDrop.").foregroundStyle(.secondary)
            ForEach(captureNames, id: \.self) { name in
                if let url = SetupResources.shortcut(name) {
                    HStack { Button(name) { NSWorkspace.shared.open(url) }; ShareLink(item: url) { Label("Send to iPhone", systemImage: "square.and.arrow.up") } }
                } else { Label("\(name): export not available in this build", systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
            }
            Text("2. Set the destination").font(.headline)
            Text("On iPhone, edit GroundKeeper Capture Transaction. Set its Save File action to the same iCloud inbox selected here, turn off Ask Where to Save, and grant folder access. For a custom folder, update the Shortcut’s destination too.").foregroundStyle(.secondary)
            Text("3. Create a Wallet automation").font(.headline)
            Text("Open Shortcuts → Automation → + → Transaction. Choose your cards and Run Immediately. Add Run Shortcut → GroundKeeper Wallet Automation and pass the transaction input. Check the merchant, amount, and card variables on your phone; available fields vary by iOS and card.").foregroundStyle(.secondary)
            Text("4. Add Apple Intelligence, if selected").font(.headline)
            if let url = SetupResources.shortcut("GK Categorize Cloud") {
                HStack { Button("Install Apple Intelligence Shortcut") { NSWorkspace.shared.open(url) }; ShareLink(item: url) { Text("Send to iPhone") } }
            }
            Text("The classifier runs on your Mac when GroundKeeper processes the queue. Shortcuts sync can also make it available on your phone. Inspect Use Model: Cloud, Broad World Knowledge on, Text output, Follow Up off. Enable it explicitly under Intelligence or Settings.").foregroundStyle(.secondary)
            if let url = SetupResources.shortcut("GroundKeeper CIBC Automation") {
                DisclosureGroup("Optional: CIBC notification adapter (experimental)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Only use this if your iPhone offers a suitable notification trigger and exposes the expected fields. Enable it deliberately after testing; it is not required for Wallet capture.").foregroundStyle(.secondary)
                        ShareLink(item: url) { Label("Send CIBC adapter to iPhone", systemImage: "square.and.arrow.up") }
                    }.padding(.top, 8)
                }
            }
            Text("5. Check a sample capture").font(.headline)
            Text("Run a fictional sample, confirm a JSON file appears in the inbox, then check Sync on your Mac. A real Wallet purchase and locked-phone delivery need a separate test. CIBC notification capture is experimental; leave it off until its input and trigger are verified on your phone.").foregroundStyle(.secondary)
            Link("Apple’s Shortcuts guide", destination: URL(string: "https://support.apple.com/guide/shortcuts/welcome/ios")!)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
