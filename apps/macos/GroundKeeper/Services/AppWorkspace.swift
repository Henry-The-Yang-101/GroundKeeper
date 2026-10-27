import AppKit
import Observation
import SwiftUI
import GroundKeeperCore

@MainActor @Observable final class AppWorkspace: WorkspaceComponent {
    let session = WorkspaceSession()
    let transactionState: TransactionWorkspace
    var showingSetup = !InterfacePreview.isEnabled && (!AppPreferences.defaults.bool(forKey: AppPreferences.Key.setupCompleted) || CommandLine.arguments.contains("--setup-preview"))
    var reviewingSetup = false
    var encrypted = VaultAccess.isEncrypted
    var unlocking = false
    var selectedTab: AppTab? = .home
    var insightsSection: InsightsSection = .transactions
    var transactions: [Transaction] { get { transactionState.transactions } set { transactionState.transactions = newValue } }
    var recentTransactions: [Transaction] { get { transactionState.recentTransactions } set { transactionState.recentTransactions = newValue } }
    var matchingTransactions: Int { get { transactionState.matchingTransactions } set { transactionState.matchingTransactions = newValue } }
    var transactionQuery: LedgerTransactionQuery { get { transactionState.transactionQuery } set { transactionState.transactionQuery = newValue } }
    var transactionReviewCount: Int { get { transactionState.transactionReviewCount } set { transactionState.transactionReviewCount = newValue } }
    var accounts: [Account] { get { transactionState.accounts } set { transactionState.accounts = newValue } }
    var cardMappings: [CardAccountMapping] = []
    var reviews: [ReviewRecord] = []
    var queue: [QueueRecord] = []
    var totalTransactions: Int { get { transactionState.totalTransactions } set { transactionState.totalTransactions = newValue } }
    var reportingRevision: Int64 { get { transactionState.reportingRevision } set { transactionState.reportingRevision = newValue } }
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
    var captureFolderNeedsReconnect: Bool { hasCaptureFolder && !AppPreferences.defaults.bool(forKey: AppPreferences.Key.captureFolderWritable) }
    var queueCount: Int { pendingCaptures + pendingFileWork + (classifierProvider == "manual" ? 0 : pendingJobs + unqueuedJobs) }
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
    var pendingJobs = 0
    var failedJobs = 0
    var shareReceiptContextWithApple = true
    var merchantSearchEnabled = true
    var merchantSearchLocality = ""
    var merchantSearchStatus = ""
    var page: Int { get { transactionState.page } set { transactionState.page = newValue } }
    var reviewOnly: Bool { get { transactionState.reviewOnly } set { transactionState.reviewOnly = newValue } }
    var focusTransactionSearch: Bool { get { transactionState.focusTransactionSearch } set { transactionState.focusTransactionSearch = newValue } }
    var editor: Transaction? { get { transactionState.editor } set { transactionState.editor = newValue } }
    var showingImportPreview: Bool { get { transactionState.showingImportPreview } set { transactionState.showingImportPreview = newValue } }
    var captureFeedback: WorkspaceFeedback?
    var status = "Opening local vault…"
    var vaultPath = ""
    var folderName = "Not connected"
    var shortcutName = AppPreferences.defaults.string(forKey: AppPreferences.Key.classifierShortcutName) ?? "GK Categorize Cloud"
    var classifierProvider = AppPreferences.defaults.string(forKey: AppPreferences.Key.classifierProvider) ?? (AppPreferences.defaults.data(forKey: AppPreferences.Key.classifierModelBookmark) == nil ? "manual" : "local")
    var classifierStatus = "Manual categorization until you choose a provider"
    var ollamaModelName = AppPreferences.defaults.string(forKey: AppPreferences.Key.ollamaModelName) ?? ""
    var processing = false
    var processingScope: QueueProcessingScope?
    var councilConfiguration: CouncilConfiguration?
    var councilQwenURL: URL?
    var councilLayaURL: URL?
    var model: ClassifierModel?
    var lastSync: Date?
    // Views observe readiness through this reference, including setup resumed on a later page.
    @ObservationIgnored let client = ClassifierClient()
    @ObservationIgnored let ollama = OllamaClassifier()
    @ObservationIgnored private var ollamaModel: OllamaModel?
    @ObservationIgnored private let merchantSearch = MerchantSearchClient()
    @ObservationIgnored private var merchantSearchTask: Task<MerchantSearchEvidence, any Error>?
    @ObservationIgnored private let folder = CaptureFolder()
    @ObservationIgnored private var folderBookmark: Data?
    @ObservationIgnored private var modelURL: URL?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var automaticProcessingRequested = false
    @ObservationIgnored private var automaticResumeTask: Task<Void, Never>?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private let isBackgroundAgent: Bool
    init(isBackgroundAgent: Bool = false) {
        transactionState = TransactionWorkspace(session: session)
        self.isBackgroundAgent = isBackgroundAgent
        session.refresh = { [weak self] in try await self?.refresh() }
        session.processAutomatically = { [weak self] in await self?.processIfAutomatic() }
        session.didFinishSaving = { [weak self] in self?.resumeAutomaticProcessingIfNeeded() }
        session.canReleaseResources = { [weak self] in self.map { !$0.processing && !$0.classifying } ?? true }
        session.releaseResources = { [weak self] in await self?.releaseClassifierResources() }
        if !QueueBackgroundService.isSupported && processingMode == .background { processingMode = .whileOpen }
    }
    @ObservationIgnored var classifying = false
    @ObservationIgnored private var started = false
    var reviewCount: Int { transactionReviewCount + reviews.count }

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
            if InterfacePreview.isEnabled {
                try await InterfacePreview.seed(opened.0)
                status = "Preview vault · fictional transactions"
                processingMode = .manual
                if CommandLine.arguments.contains("--transaction-preview") || CommandLine.arguments.contains("--recording-preview") {
                    showingSetup = false; showTransactions()
                }
                if CommandLine.arguments.contains("--spending-preview") {
                    showingSetup = false; selectedTab = .spending
                }
                if CommandLine.arguments.contains("--capture-review-preview") {
                    showingSetup = false; selectedTab = .sync
                }
            }
            #if DEBUG
            if InterfacePreview.isEnabled && CommandLine.arguments.contains("--council-preview") {
                try await CouncilPreview.seed(opened.0)
                showingSetup = false; showTransactions()
            }
            #endif
            shareReceiptContextWithApple = try await store?.receiptCloudConsent() ?? true
            let searchSettings = try await store?.merchantSearchSettings() ?? .init()
            merchantSearchEnabled = searchSettings.enabled; merchantSearchLocality = searchSettings.locality
            if InterfacePreview.isEnabled && CommandLine.arguments.contains("--merchant-search-preview") {
                showingSetup = false; selectedTab = .settings
                try await store?.setMerchantSearchSettings(.init(enabled: true, locality: "Waterloo Ontario"))
                merchantSearchEnabled = true; merchantSearchLocality = "Waterloo Ontario"
                merchantSearchStatus = "Using cached DuckDuckGo context · fictional preview"
            }
            folderBookmark = AppPreferences.defaults.data(forKey: AppPreferences.Key.captureFolderBookmark)
            if folderBookmark != nil { folderName = "Saved capture folder" }
            restoreCouncilPackages()
            if classifierProvider == "council" {
                councilConfiguration = try await store?.selectedCouncil()
                classifierStatus = councilConfiguration == nil ? "Council needs setup" : "Council · Qwen, Laya and Apple Intelligence · equal votes"
            }
            else if classifierProvider == "manual" { classifierStatus = "Manual categorization" }
            else if classifierProvider == "ollama" { classifierStatus = "Ollama · \(ollamaModelName) · connects when processing needs it" }
            else if classifierProvider == "shortcut" { classifierStatus = "Saved Shortcut · runs when processing needs it" }
            else if AppPreferences.defaults.data(forKey: AppPreferences.Key.classifierModelBookmark) != nil { classifierStatus = "Saved model · loads when processing needs it" }
            try await refresh()
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    await self.processIfAutomatic()
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
        saving = true; defer { finishSaving() }
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
        transactions = []; accounts = []; cardMappings = []; reviews = []; queue = []; editor = nil; showingImportPreview = false; captureFeedback = nil
        totalTransactions = 0; matchingTransactions = 0; transactionReviewCount = 0; recentTransactions = []; model = nil; status = "Unlock your local vault"
    }
    func finishSetup() {
        guard ready else { return }
        AppPreferences.defaults.set(true, forKey: AppPreferences.Key.setupCompleted)
        AppPreferences.defaults.removeObject(forKey: AppPreferences.Key.setupStep)
        showingSetup = false
        Task { await processIfAutomatic() }
    }

    func refresh() async throws {
        guard let result = try await transactionState.refreshSnapshot() else { return }
        let snapshot = result.ledger
        reviews = snapshot.reviews; queue = snapshot.queue; cardMappings = snapshot.cardMappings
        unqueuedJobs = result.unqueuedJobs
        pendingJobs = snapshot.pendingJobs; failedJobs = snapshot.failedJobs
    }

    func merchantDirectory() async throws -> (merchants: [Merchant], names: [MerchantName]) {
        guard let store else { throw LedgerError.unavailable("Unlock your vault to manage merchants.") }
        let merchants = try await store.merchants(), names = try await store.merchantNames()
        guard self.store === store else { throw CancellationError() }
        return (merchants, names)
    }
    func createMerchant(name: String) async throws -> String {
        guard let store else { throw LedgerError.unavailable("Unlock your vault to manage merchants.") }
        let id = try await store.createMerchant(name: name)
        guard self.store === store else { throw CancellationError() }
        return id
    }
    func groupMerchant(_ name: MerchantName, into merchantID: String?) async throws {
        guard let store else { throw LedgerError.unavailable("Unlock your vault to manage merchants.") }
        if let merchantID { try await store.groupMerchantName(key: name.key, merchantID: merchantID, expectedMerchantID: name.merchantID) }
        else { try await store.restoreMerchantName(key: name.key, expectedMerchantID: name.merchantID) }
        guard self.store === store else { throw CancellationError() }
        try await refresh()
    }
    func transactionMerchant(id: String) async throws -> TransactionMerchant {
        guard let store else { throw LedgerError.unavailable("Unlock your vault to manage merchants.") }
        let result = try await store.transactionMerchant(id: id)
        guard self.store === store else { throw CancellationError() }
        return result
    }
    func setMerchant(_ transaction: TransactionMerchant, merchantID: String?, automatic: Bool) async throws {
        guard let store else { throw LedgerError.unavailable("Unlock your vault to manage merchants.") }
        try await store.setTransactionMerchant(id: transaction.transactionID, merchantID: merchantID, automatic: automatic, expectedRevision: transaction.revision)
        guard self.store === store else { throw CancellationError() }
        try await refresh()
    }
    func showTransactions(needingReview: Bool = false) {
        reviewOnly = needingReview; insightsSection = .transactions; selectedTab = .fullInsights
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
        guard let account = accounts.first(where: { $0.id == accountID }) else { throw LedgerError.invalid("Choose an account.") }
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
            guard let transaction = try await transactionState.transaction(id: id) else { throw LedgerError.invalid("The saved transaction is no longer available.") }
            let account = transactionState.accountLabel(id: transaction.accountID, fallback: transaction.account)
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
    var hasCaptureFolder: Bool { AppPreferences.defaults.data(forKey: AppPreferences.Key.captureFolderBookmark) != nil }
    var captureFolderPath: String { AppPreferences.defaults.string(forKey: AppPreferences.Key.captureFolderPath) ?? folderName }
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
    private func resumeAutomaticProcessingIfNeeded() {
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
            do { try await suggestPendingCategories(store: store) }
            catch is CancellationError {}
            catch { classifierStatus = "Category suggestions need attention"; errorMessage = error.localizedDescription }
        }
        await updateQueueCount()
        await releaseClassifierResources()
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
    private func suggestPendingCategories(store: LedgerStore) async throws {
        try Task.checkCancellation()
        try await refresh()
        guard classifierProvider != "manual", suggestionCount > 0 else { return }
        if classifierProvider == "council" { try await classifyCouncilPending() }
        else if try await store.prepareSelectedClassifications() {
            if model == nil { try await restoreModel() }
            guard model != nil else { throw LedgerError.unavailable("Choose a category provider in Settings before requesting suggestions.") }
            try Task.checkCancellation()
            await classifyPending()
        }
    }
    func setReceiptSharing(_ enabled: Bool) {
        perform {
            try await self.store?.setReceiptCloudConsent(enabled)
            self.shareReceiptContextWithApple = enabled
            try await self.refresh()
        }
    }
    func setMerchantSearch(_ enabled: Bool) {
        if !enabled {
            merchantSearchEnabled = false
            merchantSearchTask?.cancel()
        }
        perform {
            let saved = try await self.store?.merchantSearchSettings() ?? .init()
            try await self.store?.setMerchantSearchSettings(.init(enabled: enabled, locality: enabled ? self.merchantSearchLocality : saved.locality))
            self.merchantSearchEnabled = enabled
            if !enabled {
                await self.merchantSearch.shutdown()
                self.merchantSearchLocality = saved.locality
                self.merchantSearchStatus = "Web context off"
            }
            else { self.merchantSearchStatus = "Enabled for pending and future classifications" }
        }
    }
    func saveMerchantSearchLocality() { setMerchantSearch(merchantSearchEnabled) }
    func clearMerchantSearchCache() {
        perform {
            try await self.store?.clearMerchantSearchCache()
            self.merchantSearchStatus = "Search cache cleared; classification audit evidence retained"
        }
    }
    func merchantContext(for job: ClassificationTask, store: LedgerStore) async throws -> MerchantContext? {
        if let saved = try await store.savedCouncilSearch(for: job) {
            return try await store.bindMerchantSearch(saved, to: job)
        }
        guard merchantSearchEnabled else { return try await store.bindMerchantSearch(.init(query: nil, outcome: "disabled"), to: job) }
        let settings = try await store.merchantSearchSettings()
        guard settings.enabled else { return nil }
        guard let query = try await store.merchantSearchQuery(for: job, locality: settings.locality) else {
            merchantSearchStatus = "No safe merchant query; classifying without web context"
            return try await store.bindMerchantSearch(.init(query: nil, outcome: "unsafe_query"), to: job)
        }
        if let cached = try await store.cachedMerchantSearch(query) {
            guard merchantSearchEnabled else { return nil }
            merchantSearchStatus = cached.context == nil ? "Cached search had no reliable match" : "Using cached DuckDuckGo context"
            return try await store.bindMerchantSearch(cached, to: job)
        }
        let notBefore = try await store.merchantSearchNotBeforeMS()
        if notBefore - Int64(Date().timeIntervalSince1970 * 1000) > 30_000 {
            merchantSearchStatus = "DuckDuckGo search paused; classifying without web context"
            return try await store.bindMerchantSearch(.init(query: query, outcome: "backoff"), to: job)
        }
        while Int64(Date().timeIntervalSince1970 * 1000) < notBefore {
            merchantSearchStatus = "Waiting for DuckDuckGo search spacing…"
            try await Task.sleep(for: .milliseconds(200))
            if try await !store.merchantSearchSettings().enabled { return nil }
        }
        try Task.checkCancellation()
        guard try await store.merchantSearchSettings().enabled else { return nil }
        // Persist a conservative reservation before dispatch, including across process handoffs.
        try await store.setMerchantSearchNotBeforeMS(Int64(Date().timeIntervalSince1970 * 1000) + 45_000)
        guard merchantSearchEnabled else { return nil }
        merchantSearchStatus = "Searching DuckDuckGo…"
        let evidence: MerchantSearchEvidence
        let task = Task { try await merchantSearch.search(query) }
        merchantSearchTask = task
        defer { merchantSearchTask = nil }
        do {
            evidence = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            return nil // The user switched web context off; continue without it.
        }
        catch { evidence = .init(query: query, outcome: "unavailable") }
        let delay: Int64 = evidence.outcome == "blocked" ? 900_000 : evidence.outcome == "unavailable" ? 60_000 : 10_500
        try await store.setMerchantSearchNotBeforeMS(Int64(Date().timeIntervalSince1970 * 1000) + delay)
        if evidence.outcome == "blocked" { await merchantSearch.shutdown() }
        try await store.cacheMerchantSearch(evidence)
        merchantSearchStatus = evidence.context != nil ? "DuckDuckGo context added" : evidence.outcome == "blocked" ? "DuckDuckGo blocked searches; paused for 15 minutes" : "No reliable web context; using transaction evidence"
        return try await store.bindMerchantSearch(evidence, to: job)
    }
    func transactionNote(transactionID: String) async throws -> TransactionNote {
        guard let store else { throw LedgerError.unavailable("Open the vault first.") }
        return try await store.transactionNote(transactionID: transactionID)
    }
    func saveTransactionNote(transactionID: String, text: String, revision: Int) async throws {
        guard let store else { throw LedgerError.unavailable("Open the vault first.") }
        try await store.saveTransactionNote(transactionID: transactionID, text: text, revision: revision)
        try await refresh()
    }
    func addReceiptImage(transactionID: String, data: Data) async throws {
        guard let store else { throw LedgerError.unavailable("Open the vault first.") }
        // A readable image is useful even when OCR finds no text.
        let ocr = try? await ReceiptOCR.recognizeText(data)
        try await store.addReceiptImage(transactionID: transactionID, data: data, ocrText: ocr?.text ?? "", producer: ocr?.producer ?? "apple_vision_documents")
        try await refresh()
    }
    func setReceiptRemoved(id: String, transactionID: String, removed: Bool) async throws {
        guard let store else { throw LedgerError.unavailable("Open the vault first.") }
        try await store.setReceiptRemoved(id: id, transactionID: transactionID, removed: removed)
        try await refresh()
    }
    func captureNotes(transactionID: String) async throws -> [CaptureNote] { try await store?.captureNotes(transactionID: transactionID) ?? [] }
    func receiptRecords(transactionID: String) async throws -> [ReceiptRecord] { try await store?.receipts(transactionID: transactionID) ?? [] }
    func receiptImage(id: String) async throws -> Data? { try await store?.receiptImage(id: id) }
    func reprocessReceipt(id: String) async throws {
        guard let store, let image = try await store.receiptImage(id: id) else { throw LedgerError.invalid("The receipt image is not available yet.") }
        let result = try await ReceiptOCR.recognize(image)
        try await store.addReceiptOCR(id: id, text: result.text, producer: result.producer)
        try await refresh()
    }
    private func restoreModel() async throws {
        if classifierProvider == "manual" || classifierProvider == "council" { return }
        if classifierProvider == "ollama" {
            guard let data = AppPreferences.defaults.data(forKey: AppPreferences.Key.ollamaSelectedModel),
                  let selected = try? JSONDecoder().decode(OllamaModel.self, from: data) else {
                throw LedgerError.unavailable("Choose an installed Ollama model in Settings.")
            }
            try await loadOllama(selected); return
        }
        if classifierProvider == "shortcut" { try await loadShortcut(name: AppPreferences.defaults.string(forKey: AppPreferences.Key.classifierShortcutName) ?? "GK Categorize Cloud"); return }
        guard let bookmark = AppPreferences.defaults.data(forKey: AppPreferences.Key.classifierModelBookmark) else { return }
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
    func stop() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        automaticProcessingRequested = false
        loop?.cancel(); automaticResumeTask?.cancel(); processingTask?.cancel()
        await loop?.value; await automaticResumeTask?.value; await processingTask?.value
        automaticResumeTask = nil
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
            AppPreferences.defaults.set("local", forKey: AppPreferences.Key.classifierProvider)
            AppPreferences.defaults.set(bookmark, forKey: AppPreferences.Key.classifierModelBookmark)
            await self.processIfAutomatic()
        }
    }
    func useOllama(_ selected: OllamaModel) {
        guard !processing, !saving else { return }
        perform {
            try await self.loadOllama(selected)
            AppPreferences.defaults.set(try JSONEncoder().encode(selected), forKey: AppPreferences.Key.ollamaSelectedModel)
            AppPreferences.defaults.set(selected.name, forKey: AppPreferences.Key.ollamaModelName)
            AppPreferences.defaults.set("ollama", forKey: AppPreferences.Key.classifierProvider)
            self.ollamaModelName = selected.name
            self.classifierProvider = "ollama"
            await self.processIfAutomatic()
        }
    }
    private func loadOllama(_ selected: OllamaModel) async throws {
        try await ollama.verify(selected)
        // Release the bundled worker's GPU weights before using Ollama.
        if let model, model.backend != "ollama" { try? await client.releaseModel() }
        await client.shutdown()
        model = nil; modelURL = nil; ollamaModel = nil
        let loaded = ClassifierModel(modelID: selected.name, backend: "ollama", manifestSHA256: selected.identity,
                                     policyVersion: ClassifierClient.policyVersion, device: "Ollama · local")
        try await store?.registerModel(id: loaded.manifestSHA256, name: loaded.modelID, backend: loaded.backend,
            policy: loaded.policyVersion, configuration: String(decoding: JSONEncoder().encode(selected), as: UTF8.self))
        modelURL = nil; ollamaModel = selected; model = loaded
        classifierStatus = "Ollama · \(selected.name) · local"
    }
    func useShortcut() {
        guard !processing, !saving else { return }
        perform {
            let name = self.shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw LedgerError.invalid("Enter a Shortcut name.") }
            self.shortcutName = name
            try await self.loadShortcut(name: name)
            self.classifierProvider = "shortcut"
            AppPreferences.defaults.set(name, forKey: AppPreferences.Key.classifierShortcutName)
            AppPreferences.defaults.set("shortcut", forKey: AppPreferences.Key.classifierProvider)
            await self.processIfAutomatic()
        }
    }
    private func loadShortcut(name: String) async throws {
        model = nil; modelURL = nil
        let loaded = try await client.prepareShortcut(name: name)
        try await store?.registerModel(id: loaded.manifestSHA256, name: loaded.modelID, backend: loaded.backend,
            policy: loaded.policyVersion, configuration: String(decoding: JSONEncoder().encode(loaded), as: UTF8.self))
        model = loaded; classifierStatus = "\(loaded.modelID) · Apple Shortcuts (may use cloud)"
    }
    func useInstalledModel(_ url: URL) {
        guard !processing, !saving else { return }
        perform {
            try await self.loadModel(url)
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            AppPreferences.defaults.set(bookmark, forKey: AppPreferences.Key.classifierModelBookmark)
            AppPreferences.defaults.set("local", forKey: AppPreferences.Key.classifierProvider)
            self.classifierProvider = "local"
            await self.processIfAutomatic()
        }
    }
    func useManualCategorization() {
        guard !processing, !saving else { return }
        classifierProvider = "manual"; model = nil; modelURL = nil
        AppPreferences.defaults.set("manual", forKey: AppPreferences.Key.classifierProvider)
        AppPreferences.defaults.removeObject(forKey: AppPreferences.Key.classifierModelBookmark)
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
        classifying = true; defer { classifying = false }
        do {
            try await store.enqueueClassifications(modelID: selectedModel.manifestSHA256)
            // Process the existing backlog; do not chase newly arriving work forever.
            let limit = (try await store.snapshot(limit: 1)).pendingJobs
            for _ in 0..<limit {
                try Task.checkCancellation()
                guard let job = try await store.claimClassification(modelID: selectedModel.manifestSHA256) else { break }
                do {
                    let context = try await merchantContext(for: job, store: store)
                    let input = ClassifierInput(description: job.description, direction: job.direction, currency: job.currency,
                                                transactionNotes: job.transactionNotes, receiptContext: job.receiptContext, walletCategoryRaw: job.walletCategoryRaw, merchantContext: context)
                    let decision: ClassificationDecision
                    if selectedModel.backend == "ollama" {
                        guard let selected = ollamaModel, selected.identity == selectedModel.manifestSHA256 else { throw OllamaError.modelChanged }
                        decision = try await ollama.classify(inputJSON: JSONEncoder().encode(input), model: selected)
                    } else {
                        let result = try await client.classify(input, model: selectedModel, partID: job.partID, revision: job.revision, jobID: job.id)
                        guard let value = result.decision else { throw ClassifierBridgeError.invalidResponse }
                        decision = ClassificationDecision(type: value.type, category: value.category, review: value.review)
                    }
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
                    if let ollamaError = error as? OllamaError {
                        code = ollamaError.code; retryable = ollamaError.retryable
                    }
                    try await store.failClassification(job, code: code, retryable: retryable)
                    classifierStatus = error.localizedDescription
                    errorMessage = error.localizedDescription
                    if selectedModel.backend == "apple_shortcut" { model = nil }
                    break
                }
            }
            try await refresh()
        } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }

    func releaseClassifierResources() async {
        // Disconnecting lets the service exit, freeing Python and GPU allocator caches too.
        await client.shutdown()
        model = nil; modelURL = nil; ollamaModel = nil
    }
}
