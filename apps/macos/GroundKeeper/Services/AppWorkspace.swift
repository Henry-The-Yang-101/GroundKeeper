import AppKit
import Observation
import SwiftUI
import GroundKeeperCore

@MainActor @Observable final class AppWorkspace {
    var showingSetup = !AppPreferences.defaults.bool(forKey: "setupCompleted") || CommandLine.arguments.contains("--setup-preview")
    var encrypted = VaultAccess.isEncrypted
    var unlocking = false
    var selectedTab: AppTab? = .home
    var insightsSection: InsightsSection = .transactions
    var transactions: [Transaction] = []
    var accounts: [Account] = []
    var reviews: [ReviewRecord] = []
    var queue: [QueueRecord] = []
    var totalTransactions = 0
    var processingMode = QueuePreferences.mode
    var backgroundStatus = QueueBackgroundService.status
    var changingProcessingMode = false
    var pendingCaptures = 0
    var waitingCaptures = 0
    var unqueuedJobs = 0
    var countError: String?
    var countUpdatedAt: Date?
    var queueCount: Int { pendingCaptures + pendingJobs + unqueuedJobs }
    var processButtonTitle: String { if countError != nil { return "Process queue (count unavailable)" }; return processing ? "Processing… (\(queueCount))" : "Process queue (\(queueCount))" }
    var processingDescription: String {
        switch processingMode {
        case .background: "Checks every 15 seconds, including after you quit GroundKeeper. Your Mac must be awake and you must be signed in."
        case .whileOpen: "Checks every 15 seconds while GroundKeeper is running. Quitting the app stops processing."
        case .manual: "Counts update automatically. Capture processing and classification run only when you click Process queue."
        }
    }
    var pendingJobs = 0
    var failedJobs = 0
    var page = 0
    var reviewOnly = false
    var focusTransactionSearch = false
    var editor: Transaction?
    var showingImportPreview = false
    var errorMessage: String?
    var status = "Opening local vault…"
    var vaultPath = ""
    var folderName = "Not connected"
    var classifierProvider = AppPreferences.defaults.string(forKey: "classifierProvider") ?? (AppPreferences.defaults.data(forKey: "classifierModelBookmark") == nil ? "manual" : "local")
    var classifierStatus = "Manual categorization until you choose a provider"
    var processing = false
    var saving = false
    var model: ClassifierModel?
    var lastSync: Date?
    // Views observe readiness through this reference, including setup resumed on a later page.
    private var store: LedgerStore?
    @ObservationIgnored private let client = ClassifierClient()
    @ObservationIgnored private let folder = CaptureFolder()
    @ObservationIgnored private var folderBookmark: Data?
    @ObservationIgnored private var modelURL: URL?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private let isBackgroundAgent: Bool
    init(isBackgroundAgent: Bool = false) {
        self.isBackgroundAgent = isBackgroundAgent
        if !QueueBackgroundService.isSupported && processingMode == .background { processingMode = .whileOpen }
    }
    @ObservationIgnored private var classifying = false
    @ObservationIgnored private var started = false
    var reviewCount: Int { transactions.filter(\.needsReview).count + reviews.count }
    var ready: Bool { store != nil }

    func configureQueueSmoke(store: LedgerStore, bookmark: Data, mode: QueueProcessingMode) {
        self.store = store; folderBookmark = bookmark; processingMode = mode; showingSetup = false
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
            folderBookmark = AppPreferences.defaults.data(forKey: "captureFolderBookmark")
            if folderBookmark != nil { folderName = "Saved capture folder" }
            if classifierProvider == "manual" { classifierStatus = "Manual categorization" }
            else if classifierProvider == "shortcut" {
                // A changed execution route needs an explicit new choice; never silently activate cloud.
                classifierProvider = "manual"
                AppPreferences.defaults.set("manual", forKey: "classifierProvider")
                AppPreferences.defaults.removeObject(forKey: "classifierShortcutName")
                classifierStatus = "Apple Shortcut provider retired. Choose native Private Cloud Compute in Settings."
            } else if classifierProvider == "apple_pcc" { classifierStatus = "Apple Private Cloud Compute · native Swift" }
            else if AppPreferences.defaults.data(forKey: "classifierModelBookmark") != nil { classifierStatus = "Saved model · loads when processing needs it" }
            try await refresh()
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    await self.updateQueueCount()
                    if !self.showingSetup && self.processingMode.automaticallyProcesses { await self.sync(automatic: true) }
                    do { try await Task.sleep(for: .seconds(15)) } catch { break }
                }
            }
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
        guard !saving, !processing, !changingProcessingMode, let store else { throw LedgerError.unavailable("Wait for the current operation to finish and unlock the vault first.") }
        saving = true; defer { saving = false }
        if encrypted { try await store.verifyPassphrase(currentPassphrase) }
        // Prevent a background launch from opening a newly encrypted vault without interaction.
        if passphrase != nil && processingMode == .background {
            try QueuePreferences.save(.whileOpen); processingMode = .whileOpen
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
        guard encrypted, !saving, !changingProcessingMode else { return }
        await stop()
        transactions = []; accounts = []; reviews = []; queue = []; editor = nil; showingImportPreview = false
        totalTransactions = 0; model = nil; status = "Unlock your local vault"
    }
    func finishSetup() {
        guard ready else { return }
        AppPreferences.defaults.set(true, forKey: "setupCompleted")
        AppPreferences.defaults.removeObject(forKey: "setupStep")
        showingSetup = false
        Task { await processIfAutomatic() }
    }
    func refresh() async throws {
        guard let store else { return }
        let snapshot = try await store.snapshot(limit: 500, offset: page * 500)
        transactions = snapshot.transactions.map(Transaction.init)
        accounts = snapshot.accounts; reviews = snapshot.reviews; queue = snapshot.queue
        unqueuedJobs = try await store.unqueuedClassificationCount()
        totalTransactions = snapshot.totalTransactions; pendingJobs = snapshot.pendingJobs; failedJobs = snapshot.failedJobs
    }
    func showTransactions(needingReview: Bool = false) {
        reviewOnly = needingReview; insightsSection = .transactions; selectedTab = .fullInsights
    }
    func save(_ transaction: Transaction) {
        perform {
            guard let store = self.store else { return }
            try await store.save(transaction.edit)
            self.editor = nil
            try await self.refresh()
        }
    }
    func delete(_ transaction: Transaction) {
        perform { try await self.store?.delete(id: transaction.id.uuidString, revision: transaction.revision); try await self.refresh() }
    }
    func addAccount(name: String, currency: String, kind: String) {
        perform { try await self.store?.addAccount(name: name, currency: currency, kind: kind); try await self.refresh() }
    }
    func map(_ review: ReviewRecord, accountID: String) {
        perform {
            try await self.store?.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: accountID)
            try await self.refresh(); await self.processIfAutomatic()
        }
    }
    func resolve(_ review: ReviewRecord, transactionID: String?) {
        perform { try await self.store?.resolveMatch(eventID: review.eventID, transactionID: transactionID); try await self.refresh(); await self.processIfAutomatic() }
    }
    func dismiss(_ review: ReviewRecord) {
        perform { try await self.store?.dismissReview(review.id); try await self.refresh() }
    }
    func correct(_ review: ReviewRecord, description: String, amount: String, accountID: String, day: String) async throws {
        guard let account = accounts.first(where: { $0.id == accountID }) else { throw LedgerError.invalid("Choose an account.") }
        let minor = try ExactMoney.parse(amount, currency: account.currency)
        try await store?.correctCapture(eventID: review.eventID, description: description, amountMinor: minor, accountID: accountID, day: day)
        try await refresh()
    }
    var hasCaptureFolder: Bool { AppPreferences.defaults.data(forKey: "captureFolderBookmark") != nil }
    var captureFolderPath: String { AppPreferences.defaults.string(forKey: "captureFolderPath") ?? folderName }
    func selectFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose the folder where your iPhone Shortcut saves transaction JSON files. You can create a new folder here."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try connectCaptureFolder(url, exact: true) } catch { errorMessage = error.localizedDescription }
    }
    func createDefaultCaptureFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Create Inbox"
        panel.message = "Select iCloud Drive. GroundKeeper will create Shortcuts/Groundkeeper/inbox inside it."
        let home = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
        panel.directoryURL = URL(fileURLWithPath: home).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard panel.runModal() == .OK, let root = panel.url else { return }
        let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
        do {
            guard root.lastPathComponent == "com~apple~CloudDocs" else { throw LedgerError.invalid("Select iCloud Drive itself, or use Choose another folder for a custom destination.") }
            let inbox = root.appendingPathComponent("Shortcuts/Groundkeeper/inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try connectCaptureFolder(inbox, exact: true)
        } catch { errorMessage = error.localizedDescription }
    }
    private func connectCaptureFolder(_ url: URL, exact: Bool) throws {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        folderBookmark = bookmark
        AppPreferences.defaults.set(bookmark, forKey: "captureFolderBookmark")
        AppPreferences.defaults.set(exact, forKey: "captureFolderIsExact")
        AppPreferences.defaults.set(url.path, forKey: "captureFolderPath")
        folderName = url.lastPathComponent
        Task { await folder.reset(); await updateQueueCount(); await processIfAutomatic() }
    }
    func updateQueueCount() async {
        guard let store else { return }
        do {
            if let folderBookmark {
                let scan = try await folder.scan(bookmark: folderBookmark, store: store, readFiles: false, exactFolder: AppPreferences.defaults.bool(forKey: "captureFolderIsExact"))
                pendingCaptures = scan.pending; waitingCaptures = scan.waiting
            } else { pendingCaptures = 0; waitingCaptures = 0 }
            try await refresh(); countError = nil; countUpdatedAt = Date()
            backgroundStatus = QueueBackgroundService.status
        } catch is CancellationError {} catch { countError = error.localizedDescription }
    }
    func processIfAutomatic() async {
        if !showingSetup && processingMode.automaticallyProcesses { await sync(automatic: true) }
        else { await updateQueueCount() }
    }
    func sync(automatic: Bool = false) async {
        guard !processing, !saving, store != nil, !changingProcessingMode, !Task.isCancelled,
              !automatic || processingMode.automaticallyProcesses else { return }
        processing = true
        let task = Task { await self.processQueuePass() }
        processingTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        processingTask = nil; processing = false
    }
    private func processQueuePass() async {
        guard let store else { return }
        do {
            if let folderBookmark {
                // Drain the files present at the start; retries respect their persisted deadlines.
                var remaining = Int.max
                repeat {
                    try Task.checkCancellation()
                    let scan = try await folder.scan(bookmark: folderBookmark, store: store, readFiles: true, exactFolder: AppPreferences.defaults.bool(forKey: "captureFolderIsExact"))
                    if remaining == Int.max { remaining = scan.pending }
                    for entry in scan.files.prefix(remaining) {
                        try Task.checkCancellation()
                        try await store.ingestCapture(data: entry.data, deliveryPath: entry.path)
                        remaining -= 1
                    }
                    lastSync = Date(); status = scan.waiting == 0 ? "Capture folder checked" : "Waiting for \(scan.waiting) iCloud files"
                    if scan.files.count < 200 { break }
                } while remaining > 0
            }
            try Task.checkCancellation()
            try await refresh()
            if pendingJobs + unqueuedJobs > 0 {
                if model == nil { try await restoreModel() }
                try Task.checkCancellation()
                await classifyPending()
            }
            await updateQueueCount()
        } catch is CancellationError {} catch { status = "Queue needs attention"; errorMessage = error.localizedDescription }
    }
    private func restoreModel() async throws {
        if classifierProvider == "manual" { return }
        if classifierProvider == "apple_pcc" {
            do { try await loadAppleCloud() }
            catch let error as AppleCloudError { classifierStatus = error.message }
            return
        }
        guard let bookmark = AppPreferences.defaults.data(forKey: "classifierModelBookmark") else { return }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        guard !stale else { throw LedgerError.unavailable("Select the model package again.") }
        try await loadModel(url)
    }
    func changeProcessingMode(_ mode: QueueProcessingMode) {
        guard !(encrypted && mode == .background) else { errorMessage = "Encrypted vaults process while GroundKeeper is open and unlocked, or manually."; return }
        guard !changingProcessingMode, !saving else { return }
        guard mode != .background || QueueBackgroundService.isSupported else {
            errorMessage = QueueBackgroundService.unsupportedMessage; return
        }
        let previousMode = processingMode
        changingProcessingMode = true
        Task {
            defer { changingProcessingMode = false }
            processingTask?.cancel(); await processingTask?.value
            do {
                // Persist before registering; launchd may start the helper immediately.
                try QueuePreferences.save(mode); processingMode = mode
                if mode == .background { try await QueueBackgroundService.enable() }
                else { try await QueueBackgroundService.disable() }
            } catch {
                let failure = error.localizedDescription
                if mode == .background {
                    let fallback: QueueProcessingMode = previousMode == .background ? .whileOpen : previousMode
                    try? QueuePreferences.save(fallback); processingMode = fallback
                    try? await QueueBackgroundService.disable()
                }
                errorMessage = failure
            }
            backgroundStatus = QueueBackgroundService.status
        }
    }
    func stop() async {
        loop?.cancel(); processingTask?.cancel()
        await loop?.value; await processingTask?.value
        await client.shutdown()
        await store?.close(); store = nil; started = false
    }
    func retryFailures() {
        perform { try await self.store?.retryQueue(); try await self.store?.retryClassificationFailures(); await self.folder.reset(); await self.updateQueueCount(); await self.processIfAutomatic() }
    }
    func selectModel() {
        guard !classifying, !processing, !saving else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a verified GroundKeeper model package. Pending transactions will be classified locally."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            try await self.loadModel(url)
            self.classifierProvider = "local"
            AppPreferences.defaults.set("local", forKey: "classifierProvider")
            AppPreferences.defaults.set(bookmark, forKey: "classifierModelBookmark")
            await self.processIfAutomatic()
        }
    }
    func useAppleCloud() {
        guard !processing, !saving else { return }
        perform {
            try await self.loadAppleCloud()
            self.classifierProvider = "apple_pcc"
            AppPreferences.defaults.set("apple_pcc", forKey: "classifierProvider")
            await self.processIfAutomatic()
        }
    }
    private func loadAppleCloud() async throws {
        let loaded = try AppleCloudClassifier.prepare()
        await client.shutdown()
        model = nil; modelURL = nil
        try await store?.registerModel(id: loaded.manifestSHA256, name: loaded.modelID, backend: loaded.backend,
            policy: loaded.policyVersion, configuration: String(decoding: JSONEncoder().encode(loaded), as: UTF8.self))
        model = loaded; classifierStatus = "Apple Private Cloud Compute · native Swift"
    }
    func useInstalledModel(_ url: URL) {
        guard !processing, !saving else { return }
        perform {
            try await self.loadModel(url)
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            AppPreferences.defaults.set(bookmark, forKey: "classifierModelBookmark")
            AppPreferences.defaults.set("local", forKey: "classifierProvider")
            self.classifierProvider = "local"
            await self.processIfAutomatic()
        }
    }
    func useManualCategorization() {
        guard !processing, !saving else { return }
        classifierProvider = "manual"; model = nil; modelURL = nil
        AppPreferences.defaults.set("manual", forKey: "classifierProvider")
        AppPreferences.defaults.removeObject(forKey: "classifierModelBookmark")
        classifierStatus = "Manual categorization"
        Task { await client.shutdown() }
    }
    private func loadModel(_ url: URL) async throws {
        classifierStatus = "Verifying and loading model…"
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        model = nil; modelURL = nil
        let loaded = try await client.prepareModel(at: url)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try await store?.registerModel(id: loaded.manifestSHA256, name: loaded.modelID, backend: loaded.backend, policy: loaded.policyVersion,
            configuration: String(decoding: encoder.encode(loaded), as: UTF8.self))
        modelURL = url; model = loaded; classifierStatus = "\(loaded.modelID) · \(loaded.device)"
    }
    private func classifyPending() async {
        guard !classifying, let store, let selectedModel = model else { return }
        if selectedModel.backend == AppleCloudClassifier.backend {
            do { try AppleCloudClassifier.checkRequestAvailability() }
            catch { classifierStatus = error.localizedDescription; return }
        }
        classifying = true; defer { classifying = false }
        do {
            try await store.enqueueClassifications(modelID: selectedModel.manifestSHA256)
            // Process the existing backlog; do not chase newly arriving work forever.
            let limit = (try await store.snapshot(limit: 1)).pendingJobs
            for _ in 0..<limit {
                try Task.checkCancellation()
                guard let job = try await store.claimClassification(modelID: selectedModel.manifestSHA256) else { break }
                do {
                    let input = ClassifierInput(description: job.description, direction: job.direction, currency: job.currency)
                    let decision: ClassificationDecision
                    if selectedModel.backend == AppleCloudClassifier.backend {
                        decision = try await AppleCloudClassifier.classify(input)
                    } else {
                        let result = try await client.classify(input, model: selectedModel, partID: job.partID, revision: job.revision, jobID: job.id)
                        guard let output = result.decision else { throw ClassifierBridgeError.invalidResponse }
                        decision = ClassificationDecision(type: output.type, category: output.category, review: output.review)
                    }
                    try Task.checkCancellation()
                    try await store.completeClassification(job, decision: decision)
                } catch is CancellationError {
                    try await store.releaseClassification(job)
                    throw CancellationError()
                } catch {
                    var code = "worker_unavailable", retryable = true
                    if case ClassifierBridgeError.worker(let workerCode, _) = error {
                        code = workerCode
                        retryable = ["busy", "deadline_exceeded", "model_not_ready", "runtime_failed", "inference_failed"].contains(code)
                    }
                    if let cloud = error as? AppleCloudError { code = cloud.code; retryable = cloud.retryable }
                    try await store.failClassification(job, code: code, retryable: retryable)
                    classifierStatus = error.localizedDescription
                    errorMessage = error.localizedDescription
                    if retryable, let url = modelURL {
                        // Reconnect and prepare without replaying an uncommitted job immediately.
                        do { try await loadModel(url) } catch { model = nil; classifierStatus = "Model unavailable — select it again to resume" }
                    }
                    break
                }
            }
            try await refresh()
        } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }
    func importCSV(_ document: CSVDocument, mapping: CSVMapping, skipped: Set<Int>) async throws -> Int {
        guard let store else { throw LedgerError.unavailable("Open the vault first.") }
        let count = try await store.importCSV(document, mapping: mapping, skipped: skipped)
        page = 0; try await refresh(); Task { await processIfAutomatic() }; return count
    }
    func changePage(_ value: Int) { page = max(0, value); perform { try await self.refresh() } }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !saving else { return }; saving = true
        Task { defer { saving = false }; do { try await operation() } catch { errorMessage = error.localizedDescription } }
    }
}
