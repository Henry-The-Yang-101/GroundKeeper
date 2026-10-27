import SwiftUI

struct VaultProtectionView: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onboarding = false
    var onApplied: () -> Void = {}
    @State private var encrypt = true
    @State private var currentPassphrase = ""
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var remember = false
    @State private var error: String?
    @State private var applied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Vault protection", selection: $encrypt) {
                Text("Encrypted with SQLCipher").tag(true)
                Text("Unencrypted SQLite").tag(false)
            }.pickerStyle(.segmented).tint(AppStyle.controlAccent)
            Text(encrypt ? "Protect your local database with a passphrase. Unlock it when you open GroundKeeper, then process and review your transactions as usual." : "Store your transactions in a standard SQLite database on this Mac. Anyone who can read that file can read its contents.")
                .foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
            if workspace.encrypted { SecureField("Current vault passphrase", text: $currentPassphrase) }
            if encrypt {
                SecureField(workspace.encrypted ? "New passphrase (at least 12 characters)" : "Passphrase (at least 12 characters)", text: $passphrase)
                SecureField("Confirm passphrase", text: $confirmation)
                Toggle("Also unlock with Touch ID or my Mac password", isOn: $remember).disabled(!VaultKeychain.isSupported)
                if !VaultKeychain.isSupported { Text("Convenience unlock requires a build provisioned for Keychain access. Passphrase encryption works in this build.").font(.caption).foregroundStyle(AppStyle.muted) }
                Text("Your passphrase is the recovery key. Keep it somewhere safe: GroundKeeper cannot reset it. Convenience unlock stores it in this Mac’s protected Keychain and asks you to authenticate.")
                    .font(.callout).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            Text("This choice applies to the local vault. Original capture files in iCloud Drive, exported files, and earlier backups keep their existing protection. Encrypted vaults process only while the app is open and unlocked.")
                .font(.callout).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(workspace.saving ? "Saving…" : encrypt ? (workspace.encrypted ? "Change passphrase" : "Encrypt my vault") : "Use unencrypted SQLite") {
                    error = nil
                    Task {
                        do {
                            try await workspace.setEncryption(passphrase: encrypt ? passphrase : nil, remember: encrypt && remember, currentPassphrase: currentPassphrase)
                            passphrase = ""; confirmation = ""; currentPassphrase = ""; applied = true
                            AppPreferences.defaults.set(true, forKey: AppPreferences.Key.vaultProtectionChosen)
                            onApplied()
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.brass)
                    .disabled(!workspace.ready || workspace.saving || workspace.processing || (workspace.encrypted && currentPassphrase.isEmpty) || (encrypt && (passphrase.count < 12 || passphrase != confirmation || passphrase.utf8.count > 1024 || passphrase.contains("\0"))))
                if applied {
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(AppStyle.accent)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : VaultMotion.feedback, value: applied)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { encrypt = onboarding ? true : workspace.encrypted; remember = VaultKeychain.isEnabled }
        .onDisappear { passphrase = ""; confirmation = ""; currentPassphrase = "" }
    }
}

struct VaultUnlockView: View {
    @Environment(AppWorkspace.self) private var workspace
    @State private var passphrase = ""
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill").font(.system(size: 72)).foregroundStyle(.tint)
            Text("Your vault is locked.").font(VaultTypography.welcome)
            Text("Unlock to see your transactions and resume processing.").foregroundStyle(AppStyle.muted)
            SecureField("Vault passphrase", text: $passphrase).textFieldStyle(.roundedBorder).frame(width: 340)
                .onSubmit { unlock() }
            HStack {
                Button(workspace.unlocking ? "Unlocking…" : "Unlock", action: unlock).buttonStyle(.brass)
                    .disabled(passphrase.isEmpty || workspace.unlocking)
                if VaultKeychain.isEnabled {
                    Button("Touch ID or Mac password") { Task { await workspace.unlock(usingKeychain: true) } }
                        .disabled(workspace.unlocking)
                }
            }
            if let error = workspace.errorMessage { Text(error).foregroundStyle(.red).frame(maxWidth: 440) }
            Text("Your vault stays on this Mac. Use the passphrase you chose during setup.")
                .font(.callout).foregroundStyle(AppStyle.muted)
        }.padding(50).frame(maxWidth: .infinity, maxHeight: .infinity).frame(minWidth: 760, minHeight: 600)
            .background(AppStyle.pageBackground)
            .onDisappear { passphrase = "" }
    }
    private func unlock() { let key = passphrase; passphrase = ""; Task { await workspace.unlock(passphrase: key) } }
}
