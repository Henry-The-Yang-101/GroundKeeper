import AppKit
import GroundKeeperCore

/// Exercises the app-level lock lifecycle only against a disposable preview vault/preferences.
@MainActor enum SetupSmoke {
    static func run() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) { exit(124) }
        guard AppPreferences.isSetupPreview else { print("setup_smoke_requires_disposable_preview"); exit(1) }
        do {
            let workspace = AppWorkspace()
            await workspace.vault.start()
            guard workspace.session.ready else { throw LedgerError.invalid("Preview vault did not open.") }
            let first = "fictional setup smoke passphrase"
            let second = "fictional rotated smoke passphrase"
            try await workspace.vault.setEncryption(passphrase: first, remember: false)
            guard workspace.vault.encrypted else { throw LedgerError.invalid("Vault was not encrypted.") }
            await workspace.vault.lockVault()
            guard !workspace.session.ready, workspace.transactionState.transactions.isEmpty else { throw LedgerError.invalid("Lock did not close the workspace.") }
            await workspace.vault.unlock(passphrase: "deliberately incorrect")
            guard !workspace.session.ready else { throw LedgerError.invalid("Incorrect passphrase was accepted.") }
            await workspace.vault.unlock(passphrase: first)
            guard workspace.session.ready else { throw LedgerError.invalid("Correct passphrase failed.") }
            try await workspace.vault.setEncryption(passphrase: second, remember: false, currentPassphrase: first)
            await workspace.vault.lockVault()
            await workspace.vault.unlock(passphrase: second)
            guard workspace.session.ready else { throw LedgerError.invalid("Rotated passphrase failed.") }
            try await workspace.vault.setEncryption(passphrase: nil, remember: false, currentPassphrase: second)
            guard !workspace.vault.encrypted else { throw LedgerError.invalid("Plain SQLite conversion failed.") }
            if VaultKeychain.isSupported {
                try VaultKeychain.save("disposable convenience-unlock fixture")
                guard VaultKeychain.isEnabled else { throw LedgerError.invalid("Keychain preference not saved.") }
                try VaultKeychain.remove()
                print("protected_keychain_creation_passed; interactive authentication still requires user verification")
            } else { print("protected_keychain_unavailable_in_this_signing_configuration; passphrase_lifecycle_passed") }
            let catalog = try ModelCatalog.bundled()
            guard catalog.models.count == 2 else { throw LedgerError.invalid("Model catalog missing.") }
            for name in ["GroundKeeper Capture Transaction", "GroundKeeper Wallet Automation", "GK Categorize Cloud"] {
                guard SetupResources.shortcut(name) != nil else { throw LedgerError.invalid("Bundled Shortcut missing.") }
            }
            await workspace.vault.stop()
            print("setup_smoke_passed")
            exit(0)
        } catch { print("setup_smoke_failed: \(error.localizedDescription)"); exit(1) }
    }
}
