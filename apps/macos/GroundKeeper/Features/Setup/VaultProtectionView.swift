import SwiftUI

struct VaultProtectionView: View {
    @Environment(AppWorkspace.self) private var workspace
    var onboarding = false
    var onApplied: () -> Void = {}
    @State private var encrypt = true
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
            }.pickerStyle(.segmented)
            Text(encrypt ? "Protect your local database with a passphrase. Unlock it when you open GroundKeeper, then process and review your transactions as usual." : "Store your transactions in a standard SQLite database on this Mac. Anyone who can read that file can read its contents.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if encrypt {
                SecureField(workspace.encrypted ? "New passphrase (at least 12 characters)" : "Passphrase (at least 12 characters)", text: $passphrase)
                SecureField("Confirm passphrase", text: $confirmation)
                Toggle("Also unlock with Touch ID or my Mac password", isOn: $remember)
                Text("Your passphrase is the recovery key. Keep it somewhere safe: GroundKeeper cannot reset it. Convenience unlock stores it in this Mac’s protected Keychain and asks you to authenticate.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("This protects the local vault. Original capture files in iCloud Drive, exported files, and earlier backups keep their existing protection. Encrypted vaults process only while the app is open and unlocked.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(workspace.saving ? "Saving…" : encrypt ? (workspace.encrypted ? "Change passphrase" : "Encrypt my vault") : "Use unencrypted SQLite") {
                    error = nil
                    Task {
                        do {
                            try await workspace.setEncryption(passphrase: encrypt ? passphrase : nil, remember: encrypt && remember)
                            passphrase = ""; confirmation = ""; applied = true
                            AppPreferences.defaults.set(true, forKey: "vaultProtectionChosen")
                            onApplied()
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(!workspace.ready || workspace.saving || workspace.processing || (encrypt && (passphrase.count < 12 || passphrase != confirmation || passphrase.utf8.count > 1024 || passphrase.contains("\0"))))
                if applied { Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { encrypt = onboarding ? true : workspace.encrypted; remember = VaultKeychain.isEnabled }
        .onDisappear { passphrase = ""; confirmation = "" }
    }
}

struct VaultUnlockView: View {
    @Environment(AppWorkspace.self) private var workspace
    @State private var passphrase = ""
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill").font(.system(size: 72)).foregroundStyle(.tint)
            Text("Your vault is locked.").font(.system(size: 36, weight: .bold))
            Text("Unlock to see your transactions and resume processing.").foregroundStyle(.secondary)
            SecureField("Vault passphrase", text: $passphrase).textFieldStyle(.roundedBorder).frame(width: 340)
                .onSubmit { unlock() }
            HStack {
                Button(workspace.unlocking ? "Unlocking…" : "Unlock", action: unlock).buttonStyle(.borderedProminent)
                    .disabled(passphrase.isEmpty || workspace.unlocking)
                if VaultKeychain.isEnabled {
                    Button("Touch ID or Mac password") { Task { await workspace.unlock(usingKeychain: true) } }
                        .disabled(workspace.unlocking)
                }
            }
            if let error = workspace.errorMessage { Text(error).foregroundStyle(.red).frame(maxWidth: 440) }
            Text("Your vault stays on this Mac. Use the passphrase you chose during setup.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(50).frame(maxWidth: .infinity, maxHeight: .infinity).frame(minWidth: 760, minHeight: 600)
            .onDisappear { passphrase = "" }
    }
    private func unlock() { let key = passphrase; passphrase = ""; Task { await workspace.unlock(passphrase: key) } }
}
