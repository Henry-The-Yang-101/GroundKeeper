import AppKit
import Foundation
import GroundKeeperCore
import Observation

/// Owns capture inventory, review actions, scheduling, and cancellation/handoff.
@MainActor @Observable final class CaptureWorkspace: WorkspaceComponent {
    let session: WorkspaceSession
    let transactions: TransactionWorkspace
    let classifier: ClassifierWorkspace
    @ObservationIgnored var isSetup: @MainActor () -> Bool = { true }
    @ObservationIgnored var isEncrypted: @MainActor () -> Bool = { false }
    private var showingSetup: Bool { isSetup() }
    private var encrypted: Bool { isEncrypted() }
    private var status: String {
        get { session.status }
        set { session.status = newValue }
    }
    var cardMappings: [CardAccountMapping] = []
    var reviews: [ReviewRecord] = []
    var queue: [QueueRecord] = []
    var processingMode = QueuePreferences.mode
    var backgroundStatus = QueueBackgroundService.status
    var changingProcessingMode = false
    var pendingCaptures = 0
    var waitingCaptures = 0
    var unqueuedJobs = 0
    var countError: String?
    var countUpdatedAt: Date?
    var pendingFileWork = 0
    var cleanupMessage: String?
    var pendingJobs = 0
    var failedJobs = 0
    var captureFeedback: WorkspaceFeedback?
    var folderName = "Not connected"
    var processing = false
    var processingScope: QueueProcessingScope?
    var lastSync: Date?
    @ObservationIgnored private let folder = CaptureFolder()
    @ObservationIgnored var folderBookmark: Data?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var automaticProcessingRequested = false
    @ObservationIgnored private var automaticResumeTask: Task<Void, Never>?
    @ObservationIgnored var stopping = false
    var captureFolderNeedsReconnect: Bool { hasCaptureFolder && !AppPreferences.defaults.bool(forKey: AppPreferences.Key.captureFolderWritable) }
    var queueCount: Int { pendingCaptures + pendingFileWork + (classifier.classifierProvider == "manual" ? 0 : pendingJobs + unqueuedJobs) }
    var suggestionCount: Int { pendingJobs + unqueuedJobs }
    var importButtonTitle: String {
        if processingScope?.importsCaptures == true { return "Importing captures…" }
        return countError == nil ? "Import captures (\(pendingCaptures))" : "Import captures"
    }
    var suggestionButtonTitle: String {
        processingScope?.suggestsCategories == true ? "Suggesting categories…" : "Suggest categories (\(suggestionCount))"
    }
    var processingDescription: String {
        switch processingMode {
        case .background: "Checks every 15 seconds, including after you quit GroundKeeper. Your Mac must be awake and you must be signed in."
        case .whileOpen: "Checks every 15 seconds while GroundKeeper is running. Quitting the app stops processing."
        case .manual: "Counts update automatically. Use Import captures for new files and Suggest categories for saved transactions. Resolving a capture review saves it immediately when its details are complete."
        }
    }
    var hasCaptureFolder: Bool { AppPreferences.defaults.data(forKey: AppPreferences.Key.captureFolderBookmark) != nil }
    var captureFolderPath: String { AppPreferences.defaults.string(forKey: AppPreferences.Key.captureFolderPath) ?? folderName }

    init(session: WorkspaceSession, transactions: TransactionWorkspace, classifier: ClassifierWorkspace) {
        self.session = session; self.transactions = transactions; self.classifier = classifier
        if !QueueBackgroundService.isSupported && processingMode == .background { processingMode = .whileOpen }
    }

    func startMonitoring() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.processIfAutomatic()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
    }

    func beginShutdown() async {
        stopping = true
        automaticProcessingRequested = false
        loop?.cancel(); automaticResumeTask?.cancel(); processingTask?.cancel()
        await loop?.value; await automaticResumeTask?.value; await processingTask?.value
        loop = nil; automaticResumeTask = nil; processingTask = nil
    }
    func finishShutdown() { stopping = false }

    func applySnapshot(_ result: LedgerWorkspaceSnapshot) {
        reviews = result.ledger.reviews; queue = result.ledger.queue
        cardMappings = result.ledger.cardMappings
        unqueuedJobs = result.unqueuedJobs
        pendingJobs = result.ledger.pendingJobs; failedJobs = result.ledger.failedJobs
    }

    func clearLockedState() {
        cardMappings = []; reviews = []; queue = []; captureFeedback = nil
        pendingCaptures = 0; waitingCaptures = 0; unqueuedJobs = 0
        pendingJobs = 0; failedJobs = 0; pendingFileWork = 0
        countError = nil; countUpdatedAt = nil; cleanupMessage = nil; lastSync = nil
    }

    func restoreFolder() {
        folderBookmark = AppPreferences.defaults.data(forKey: AppPreferences.Key.captureFolderBookmark)
        if folderBookmark != nil { folderName = "Saved capture folder" }
    }

    func assignAccount(_ review: ReviewRecord, accountID: String, remember: Bool) {
        perform {
            guard let store = self.store else { throw LedgerError.unavailable("Unlock your vault first.") }
            let result = try await store.assignCaptureAccount(eventID: review.eventID, accountID: accountID, remember: remember)
            try await self.presentCaptureResult(result, remembered: remember)
            await self.processIfAutomatic()
        }
    }

    func updateCardMapping(_ mapping: CardAccountMapping, accountID: String) {
        perform {
            try await self.store?.updateCardMapping(id: mapping.id, accountID: accountID)
            try await self.refresh()
            self.feedback = WorkspaceFeedback(message: "Card mapping updated for future imports")
        }
    }

    func removeCardMapping(_ mapping: CardAccountMapping) {
        perform {
            try await self.store?.removeCardMapping(id: mapping.id)
            try await self.refresh()
            self.feedback = WorkspaceFeedback(message: "Card mapping removed")
        }
    }

    func resolve(_ review: ReviewRecord, transactionID: String?, expectedRevision: Int? = nil) {
        perform {
            guard let store = self.store else { throw LedgerError.unavailable("Unlock your vault first.") }
            let result = try await store.resolveMatch(eventID: review.eventID, transactionID: transactionID, expectedRevision: expectedRevision)
            try await self.presentCaptureResult(result)
            await self.processIfAutomatic()
        }
    }

    func resolveCSV(_ review: ReviewRecord, useStatement: Bool, expectedRevision: Int?) {
        perform {
            try await self.store?.resolveCSVReview(eventID: review.eventID, useStatement: useStatement, expectedRevision: expectedRevision)
            try await self.refresh(); await self.processIfAutomatic()
        }
    }

    func mergeStatement(_ transaction: Transaction, other: Transaction) async throws {
        guard let store else { throw LedgerError.unavailable("Unlock your vault first.") }
        guard !saving else { throw LedgerError.unavailable("Wait for the current change to finish.") }
        saving = true; defer { finishSaving() }
        try await store.mergeStatementMatch(transactionID: transaction.id.uuidString, otherID: other.id.uuidString,
            revision: transaction.revision, otherRevision: other.revision)
        try await refresh()
    }

    func dismiss(_ review: ReviewRecord) {
        perform { try await self.store?.dismissReview(review.id); try await self.refresh() }
    }

    func correct(_ review: ReviewRecord, description: String, amount: String, accountID: String, day: String, remember: Bool) async throws {
        guard !saving, let store else { throw LedgerError.unavailable("Wait for the current operation to finish.") }
        guard let account = transactions.accounts.first(where: { $0.id == accountID }) else { throw LedgerError.invalid("Choose an account.") }
        let minor = try ExactMoney.parse(amount, currency: account.currency)
        saving = true
        defer { finishSaving() }
        let result = try await store.correctCapture(eventID: review.eventID, description: description, amountMinor: minor, accountID: accountID, day: day, remember: remember)
        try await presentCaptureResult(result, remembered: remember)
        await processIfAutomatic()
    }

    private func presentCaptureResult(_ result: CaptureResolution, remembered: Bool = false) async throws {
        try await refresh()
        let suffix = remembered ? " Card remembered for future captures." : ""
        switch result {
        case let .created(id), let .linked(id):
            guard let transaction = try await transactions.transaction(id: id) else { throw LedgerError.invalid("The saved transaction is no longer available.") }
            let account = transactions.accountLabel(id: transaction.accountID, fallback: transaction.account)
            let action: String
            if case .created = result { action = "Added to \(account)" }
            else { action = "Linked to an existing transaction in \(account)" }
            // This is a durable import confirmation. Category state can change
            // independently while the message remains visible.
            captureFeedback = WorkspaceFeedback(message: action + "." + suffix, transactionID: id)
        case let .needsReview(reason):
            captureFeedback = WorkspaceFeedback(message: "Capture needs attention: \(TransactionReviewIssue.title(for: reason))." + suffix, needsAttention: true)
        }
    }

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
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        AppPreferences.defaults.set(true, forKey: AppPreferences.Key.captureFolderWritable)
        cleanupMessage = nil
        folderBookmark = bookmark
        AppPreferences.defaults.set(bookmark, forKey: AppPreferences.Key.captureFolderBookmark)
        AppPreferences.defaults.set(exact, forKey: AppPreferences.Key.captureFolderIsExact)
        AppPreferences.defaults.set(url.path, forKey: AppPreferences.Key.captureFolderPath)
        folderName = url.lastPathComponent
        Task { await folder.reset(); await updateQueueCount(); await processIfAutomatic() }
    }

    func updateQueueCount() async {
        guard let store else { return }
        do {
            if let folderBookmark {
                let scan = try await folder.scan(bookmark: folderBookmark, store: store, readFiles: false, exactFolder: AppPreferences.defaults.bool(forKey: AppPreferences.Key.captureFolderIsExact))
                pendingCaptures = scan.pending; waitingCaptures = scan.waiting
                pendingFileWork = try await store.pendingFileCleanups().count + store.receiptImageRequests().count
            } else { pendingCaptures = 0; waitingCaptures = 0; pendingFileWork = 0 }
            try await refresh(); countError = nil; countUpdatedAt = Date()
            backgroundStatus = QueueBackgroundService.status
        } catch is CancellationError {} catch { countError = error.localizedDescription }
    }

    func processIfAutomatic() async {
        if !showingSetup && processingMode.automaticallyProcesses { await sync(automatic: true) }
        else { await updateQueueCount() }
    }

    func sync(automatic: Bool = false, scope: QueueProcessingScope = .all) async {
        guard !stopping, !Task.isCancelled, let activeStore = store else { return }
        if automatic {
            guard !showingSetup, processingMode.automaticallyProcesses, !Task.isCancelled else { return }
            // A review can become ready while a save or an earlier batch is running.
            // Remember that wakeup and resume once both operations have finished.
            if saving || processing || changingProcessingMode {
                automaticProcessingRequested = true
                return
            }
            await updateQueueCount()
            guard queueCount > 0 else { return }
            if saving || processing || changingProcessingMode {
                automaticProcessingRequested = true
                return
            }
        }
        guard !stopping, self.store === activeStore, !processing, !saving, !changingProcessingMode, !Task.isCancelled,
              !automatic || processingMode.automaticallyProcesses else { return }
        processing = true; processingScope = scope.importsCaptures ? .captures : .suggestions
        let task = Task { await self.processQueuePass(scope: scope) }
        processingTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        processingTask = nil; processing = false; processingScope = nil
        if !stopping && scope == .captures && processingMode.automaticallyProcesses { automaticProcessingRequested = true }
        resumeAutomaticProcessingIfNeeded()
    }

    func resumeAutomaticProcessingIfNeeded() {
        guard automaticProcessingRequested, !saving, !processing, !changingProcessingMode else { return }
        automaticProcessingRequested = false
        guard !stopping, !Task.isCancelled, !showingSetup, processingMode.automaticallyProcesses, let store else { return }
        automaticResumeTask = Task { [weak self] in
            guard let self, self.store === store, !Task.isCancelled else { return }
            await self.processIfAutomatic()
        }
    }

    private func processQueuePass(scope: QueueProcessingScope) async {
        guard let store else { return }
        if scope.importsCaptures {
            do { try await importCaptureFiles(store: store) }
            catch is CancellationError {}
            catch { status = "Capture import needs attention"; errorMessage = error.localizedDescription }
        }
        // A folder problem must not prevent suggestions for transactions already saved.
        if scope.suggestsCategories && !Task.isCancelled {
            processingScope = .suggestions
            do { try await classifier.suggestPendingCategories(store: store) }
            catch is CancellationError {}
            catch { classifier.classifierStatus = "Category suggestions need attention"; errorMessage = error.localizedDescription }
        }
        await updateQueueCount()
        await classifier.releaseClassifierResources()
    }

    private func importCaptureFiles(store: LedgerStore) async throws {
        if let folderBookmark {
            // Drain the files present at the start; retries respect their persisted deadlines.
            var remaining = Int.max
            repeat {
                try Task.checkCancellation()
                let scan = try await folder.scan(bookmark: folderBookmark, store: store, readFiles: true, exactFolder: AppPreferences.defaults.bool(forKey: AppPreferences.Key.captureFolderIsExact))
                if remaining == Int.max { remaining = scan.pending }
                for entry in scan.files.prefix(remaining) {
                    try Task.checkCancellation()
                    try await store.ingestCapture(data: entry.data, deliveryPath: entry.path)
                    remaining -= 1
                }
                lastSync = Date(); status = scan.waiting == 0 ? "Capture folder checked" : "Waiting for \(scan.waiting) iCloud files"
                if scan.files.count < 200 { break }
            } while remaining > 0
            try await folder.importReceiptImages(bookmark: folderBookmark, store: store, exactFolder: AppPreferences.defaults.bool(forKey: AppPreferences.Key.captureFolderIsExact))
            let failed = try await folder.cleanStoredFiles(bookmark: folderBookmark, store: store, exactFolder: AppPreferences.defaults.bool(forKey: AppPreferences.Key.captureFolderIsExact))
            cleanupMessage = failed == 0 ? nil : "Saved safely in the vault. Reconnect the capture folder to remove \(failed) queued files."
        }
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
            defer { changingProcessingMode = false; resumeAutomaticProcessingIfNeeded() }
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

    func retryFailures() {
        perform { try await self.store?.retryQueue(); try await self.store?.retryClassificationFailures(); await self.folder.reset(); await self.updateQueueCount(); await self.processIfAutomatic() }
    }
}
