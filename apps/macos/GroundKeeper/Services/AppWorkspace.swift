import AppKit
import Observation
import SwiftUI
import GroundKeeperCore

@MainActor @Observable final class AppWorkspace: WorkspaceComponent {
    let session = WorkspaceSession()
    let transactionState: TransactionWorkspace
    let classifier: ClassifierWorkspace
    let captureState: CaptureWorkspace
    let merchantState: MerchantWorkspace
    let receiptState: ReceiptWorkspace
    let vault: VaultWorkspace
    var showingSetup: Bool { get { vault.showingSetup } set { vault.showingSetup = newValue } }
    var reviewingSetup: Bool { get { vault.reviewingSetup } set { vault.reviewingSetup = newValue } }
    var encrypted: Bool { get { vault.encrypted } set { vault.encrypted = newValue } }
    var unlocking: Bool { get { vault.unlocking } set { vault.unlocking = newValue } }
    var selectedTab: AppTab? = .home
    var insightsSection: InsightsSection = .transactions
    var transactions: [Transaction] { get { transactionState.transactions } set { transactionState.transactions = newValue } }
    var recentTransactions: [Transaction] { get { transactionState.recentTransactions } set { transactionState.recentTransactions = newValue } }
    var matchingTransactions: Int { get { transactionState.matchingTransactions } set { transactionState.matchingTransactions = newValue } }
    var transactionQuery: LedgerTransactionQuery { get { transactionState.transactionQuery } set { transactionState.transactionQuery = newValue } }
    var transactionReviewCount: Int { get { transactionState.transactionReviewCount } set { transactionState.transactionReviewCount = newValue } }
    var accounts: [Account] { get { transactionState.accounts } set { transactionState.accounts = newValue } }
    var cardMappings: [CardAccountMapping] { get { captureState.cardMappings } set { captureState.cardMappings = newValue } }
    var reviews: [ReviewRecord] { get { captureState.reviews } set { captureState.reviews = newValue } }
    var queue: [QueueRecord] { get { captureState.queue } set { captureState.queue = newValue } }
    var totalTransactions: Int { get { transactionState.totalTransactions } set { transactionState.totalTransactions = newValue } }
    var reportingRevision: Int64 { get { transactionState.reportingRevision } set { transactionState.reportingRevision = newValue } }
    var processingMode: QueueProcessingMode { get { captureState.processingMode } set { captureState.processingMode = newValue } }
    var backgroundStatus: String { get { captureState.backgroundStatus } set { captureState.backgroundStatus = newValue } }
    var changingProcessingMode: Bool { get { captureState.changingProcessingMode } set { captureState.changingProcessingMode = newValue } }
    var pendingCaptures: Int { get { captureState.pendingCaptures } set { captureState.pendingCaptures = newValue } }
    var waitingCaptures: Int { get { captureState.waitingCaptures } set { captureState.waitingCaptures = newValue } }
    var unqueuedJobs: Int { get { captureState.unqueuedJobs } set { captureState.unqueuedJobs = newValue } }
    var countError: String? { get { captureState.countError } set { captureState.countError = newValue } }
    var countUpdatedAt: Date? { get { captureState.countUpdatedAt } set { captureState.countUpdatedAt = newValue } }
    var pendingFileWork: Int { get { captureState.pendingFileWork } set { captureState.pendingFileWork = newValue } }
    var cleanupMessage: String? { get { captureState.cleanupMessage } set { captureState.cleanupMessage = newValue } }
    var captureFolderNeedsReconnect: Bool { captureState.captureFolderNeedsReconnect }
    var queueCount: Int { captureState.queueCount }
    var suggestionCount: Int { captureState.suggestionCount }
    var importButtonTitle: String { captureState.importButtonTitle }
    var suggestionButtonTitle: String { captureState.suggestionButtonTitle }
    var processingDescription: String { captureState.processingDescription }
    var pendingJobs: Int { get { captureState.pendingJobs } set { captureState.pendingJobs = newValue } }
    var failedJobs: Int { get { captureState.failedJobs } set { captureState.failedJobs = newValue } }
    var shareReceiptContextWithApple: Bool { get { receiptState.shareReceiptContextWithApple } set { receiptState.shareReceiptContextWithApple = newValue } }
    var merchantSearchEnabled: Bool { get { merchantState.merchantSearchEnabled } set { merchantState.merchantSearchEnabled = newValue } }
    var merchantSearchLocality: String { get { merchantState.merchantSearchLocality } set { merchantState.merchantSearchLocality = newValue } }
    var merchantSearchStatus: String { get { merchantState.merchantSearchStatus } set { merchantState.merchantSearchStatus = newValue } }
    var page: Int { get { transactionState.page } set { transactionState.page = newValue } }
    var reviewOnly: Bool { get { transactionState.reviewOnly } set { transactionState.reviewOnly = newValue } }
    var focusTransactionSearch: Bool { get { transactionState.focusTransactionSearch } set { transactionState.focusTransactionSearch = newValue } }
    var editor: Transaction? { get { transactionState.editor } set { transactionState.editor = newValue } }
    var showingImportPreview: Bool { get { transactionState.showingImportPreview } set { transactionState.showingImportPreview = newValue } }
    var captureFeedback: WorkspaceFeedback? { get { captureState.captureFeedback } set { captureState.captureFeedback = newValue } }
    var status: String { get { session.status } set { session.status = newValue } }
    var vaultPath: String { get { vault.vaultPath } set { vault.vaultPath = newValue } }
    var folderName: String { get { captureState.folderName } set { captureState.folderName = newValue } }
    var shortcutName: String { get { classifier.shortcutName } set { classifier.shortcutName = newValue } }
    var classifierProvider: String { get { classifier.classifierProvider } set { classifier.classifierProvider = newValue } }
    var classifierStatus: String { get { classifier.classifierStatus } set { classifier.classifierStatus = newValue } }
    var ollama: OllamaClassifier { classifier.ollama }
    var processing: Bool { get { captureState.processing } set { captureState.processing = newValue } }
    var processingScope: QueueProcessingScope? { get { captureState.processingScope } set { captureState.processingScope = newValue } }
    var councilConfiguration: CouncilConfiguration? { get { classifier.councilConfiguration } set { classifier.councilConfiguration = newValue } }
    var councilQwenURL: URL? { get { classifier.councilQwenURL } set { classifier.councilQwenURL = newValue } }
    var councilLayaURL: URL? { get { classifier.councilLayaURL } set { classifier.councilLayaURL = newValue } }
    var model: ClassifierModel? { get { classifier.model } set { classifier.model = newValue } }
    var lastSync: Date? { get { captureState.lastSync } set { captureState.lastSync = newValue } }
    // Views observe readiness through this reference, including setup resumed on a later page.
    var client: ClassifierClient { classifier.client }
    var folderBookmark: Data? { get { captureState.folderBookmark } set { captureState.folderBookmark = newValue } }
    var stopping: Bool { get { captureState.stopping } set { captureState.stopping = newValue } }
    init(isBackgroundAgent: Bool = false) {
        transactionState = TransactionWorkspace(session: session)
        classifier = ClassifierWorkspace(session: session)
        merchantState = MerchantWorkspace(session: session)
        receiptState = ReceiptWorkspace(session: session)
        captureState = CaptureWorkspace(session: session, transactions: transactionState, classifier: classifier)
        vault = VaultWorkspace(session: session, captureState: captureState, isBackgroundAgent: isBackgroundAgent)
        vault.didOpen = { [weak self] store in
            guard let self else { throw CancellationError() }
            try await self.prepareOpenedVault(store)
        }
        vault.willClose = { [weak self] in
            await self?.classifier.releaseClassifierResources()
            await self?.merchantState.shutdown()
        }
        vault.didLock = { [weak self] in self?.clearLockedState() }
        captureState.isSetup = { [weak self] in self?.showingSetup ?? true }
        captureState.isEncrypted = { [weak self] in self?.encrypted ?? false }
        classifier.isProcessing = { [weak self] in self?.processing ?? false }
        classifier.setProcessing = { [weak self] in self?.processing = $0 }
        classifier.pendingSuggestionCount = { [weak self] in self?.suggestionCount ?? 0 }
        classifier.contextForJob = { [weak self] job, store in try await self?.merchantState.merchantContext(for: job, store: store) }
        session.refresh = { [weak self] in try await self?.refresh() }
        session.processAutomatically = { [weak self] in await self?.captureState.processIfAutomatic() }
        session.didFinishSaving = { [weak self] in self?.captureState.resumeAutomaticProcessingIfNeeded() }
        session.canReleaseResources = { [weak self] in self.map { !$0.processing && !$0.classifying } ?? true }
        session.releaseResources = { [weak self] in await self?.classifier.releaseClassifierResources() }
    }
    var classifying: Bool { get { classifier.classifying } set { classifier.classifying = newValue } }
    var reviewCount: Int { transactionReviewCount + reviews.count }

    func configureQueueSmoke(store: LedgerStore, bookmark: Data, mode: QueueProcessingMode) {
        self.store = store; folderBookmark = bookmark; processingMode = mode; showingSetup = false
    }

    func refresh() async throws {
        guard let result = try await transactionState.refreshSnapshot() else { return }
        let snapshot = result.ledger
        reviews = snapshot.reviews; queue = snapshot.queue; cardMappings = snapshot.cardMappings
        unqueuedJobs = result.unqueuedJobs
        pendingJobs = snapshot.pendingJobs; failedJobs = snapshot.failedJobs
    }

    func showTransactions(needingReview: Bool = false) {
        reviewOnly = needingReview; insightsSection = .transactions; selectedTab = .fullInsights
    }

    var hasCaptureFolder: Bool { captureState.hasCaptureFolder }
    var captureFolderPath: String { captureState.captureFolderPath }

    private func prepareOpenedVault(_ store: LedgerStore) async throws {
        if InterfacePreview.isEnabled {
            try await InterfacePreview.seed(store)
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
            try await CouncilPreview.seed(store)
            showingSetup = false; showTransactions()
        }
        #endif
        shareReceiptContextWithApple = try await store.receiptCloudConsent()
        let searchSettings = try await store.merchantSearchSettings()
        merchantSearchEnabled = searchSettings.enabled; merchantSearchLocality = searchSettings.locality
        if InterfacePreview.isEnabled && CommandLine.arguments.contains("--merchant-search-preview") {
            showingSetup = false; selectedTab = .settings
            try await store.setMerchantSearchSettings(.init(enabled: true, locality: "Waterloo Ontario"))
            merchantSearchEnabled = true; merchantSearchLocality = "Waterloo Ontario"
            merchantSearchStatus = "Using cached DuckDuckGo context · fictional preview"
        }
        folderBookmark = AppPreferences.defaults.data(forKey: AppPreferences.Key.captureFolderBookmark)
        if folderBookmark != nil { folderName = "Saved capture folder" }
        try await classifier.restoreSelection()
        try await refresh()
        captureState.startMonitoring()
    }

    private func clearLockedState() {
        transactions = []; accounts = []; cardMappings = []; reviews = []; queue = []; editor = nil; showingImportPreview = false; captureFeedback = nil
        totalTransactions = 0; matchingTransactions = 0; transactionReviewCount = 0; recentTransactions = []; model = nil
    }
}
