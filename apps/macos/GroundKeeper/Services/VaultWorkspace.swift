import Foundation
import GroundKeeperCore
import Observation

/// Opens, unlocks, encrypts, and closes the session's sole LedgerStore.
@MainActor @Observable final class VaultWorkspace: WorkspaceComponent {
    let session: WorkspaceSession
    let captureState: CaptureWorkspace
    @ObservationIgnored private let isBackgroundAgent: Bool
    @ObservationIgnored var didOpen: @MainActor (LedgerStore) async throws -> Void = { _ in }
    @ObservationIgnored var willClose: @MainActor () async -> Void = {}
    @ObservationIgnored var didLock: @MainActor () -> Void = {}
    private var status: String {
        get { session.status }
        set { session.status = newValue }
    }
    var showingSetup = !InterfacePreview.isEnabled && (!AppPreferences.defaults.bool(forKey: AppPreferences.Key.setupCompleted) || CommandLine.arguments.contains("--setup-preview"))
    var reviewingSetup = false
    var encrypted = VaultAccess.isEncrypted
    var unlocking = false
    var vaultPath = ""
    @ObservationIgnored var started = false

    init(session: WorkspaceSession, captureState: CaptureWorkspace, isBackgroundAgent: Bool) {
        self.session = session; self.captureState = captureState; self.isBackgroundAgent = isBackgroundAgent
    }

    func start(passphrase: String? = nil) async {
        guard !started else { return }
        encrypted = VaultAccess.isEncrypted
        guard !encrypted || passphrase != nil else { status = "Unlock your local vault"; return }
        started = true
        do {
            if !QueueBackgroundService.isSupported && QueuePreferences.mode == .background {
                try QueuePreferences.save(.whileOpen)
            }
            var opened: (LedgerStore, URL)?
            // A background pass cancels and releases its writer as soon as the UI lease appears.
            for attempt in 0..<20 {
                try Task.checkCancellation()
                do { opened = try await Task.detached(priority: .userInitiated) { try VaultAccess.open(passphrase: passphrase) }.value; break }
                catch LedgerError.ownedByAnotherProcess where !isBackgroundAgent && attempt < 19 {
                    status = "Waiting for background processing to hand over…"
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
            guard let opened else { return }
            store = opened.0; vaultPath = opened.1.path; status = "Local database ready"
            try await didOpen(opened.0)
        } catch is CancellationError { await store?.close(); store = nil; started = false } catch { await store?.close(); store = nil; status = "Vault unavailable"; errorMessage = error.localizedDescription; started = false }
    }

    func unlock(passphrase: String? = nil, usingKeychain: Bool = false) async {
        guard !unlocking else { return }; unlocking = true; errorMessage = nil; defer { unlocking = false }
        do {
            let key = try await Task.detached(priority: .userInitiated) {
                if usingKeychain { return try VaultKeychain.load() }
                guard let passphrase, !passphrase.isEmpty else { throw LedgerError.invalid("Enter your vault passphrase.") }
                return passphrase
            }.value
            await start(passphrase: key)
            if !ready { errorMessage = "Could not unlock the vault. Check your passphrase and try again. No data was changed." }
        } catch { errorMessage = error.localizedDescription }
    }

    func setEncryption(passphrase: String?, remember: Bool, currentPassphrase: String = "") async throws {
        guard !saving, !captureState.processing, !captureState.changingProcessingMode, let store else { throw LedgerError.unavailable("Wait for the current operation to finish and unlock the vault first.") }
        saving = true; defer { finishSaving() }
        if encrypted { try await store.verifyPassphrase(currentPassphrase) }
        // Prevent a background launch from opening a newly encrypted vault without interaction.
        if passphrase != nil && captureState.processingMode == .background {
            try QueuePreferences.save(.whileOpen); captureState.processingMode = .whileOpen
            try await QueueBackgroundService.disable()
        }
        if VaultKeychain.isEnabled { try VaultKeychain.remove() }
        do { try await store.changeEncryption(to: passphrase) }
        catch { encrypted = VaultAccess.isEncrypted; throw error }
        encrypted = VaultAccess.isEncrypted
        if remember, let passphrase {
            do { try VaultKeychain.save(passphrase) }
            catch { errorMessage = "Vault encryption was saved, but convenience unlock could not be enabled. Keep your new passphrase. " + error.localizedDescription }
        }
        status = encrypted ? "Encrypted local vault ready" : "Local database ready"
    }

    func lockVault() async {
        guard encrypted, !saving, !captureState.changingProcessingMode else { return }
        await stop()
        didLock()
        status = "Unlock your local vault"
    }

    func finishSetup() {
        guard ready else { return }
        AppPreferences.defaults.set(true, forKey: AppPreferences.Key.setupCompleted)
        AppPreferences.defaults.removeObject(forKey: AppPreferences.Key.setupStep)
        showingSetup = false
        Task { await processIfAutomatic() }
    }

    func stop() async {
        guard !captureState.stopping else { return }
        await captureState.beginShutdown()
        defer { captureState.finishShutdown() }
        await willClose()
        await store?.close(); store = nil; started = false
    }
}
