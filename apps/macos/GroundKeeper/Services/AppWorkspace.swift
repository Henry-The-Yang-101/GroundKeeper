import Foundation
import GroundKeeperCore
import Observation

/// Owns the vault session and component graph; only app navigation lives here.
@MainActor @Observable final class AppWorkspace {
    let session = WorkspaceSession()
    let transactionState: TransactionWorkspace
    let classifier: ClassifierWorkspace
    let captureState: CaptureWorkspace
    let merchantState: MerchantWorkspace
    let receiptState: ReceiptWorkspace
    let vault: VaultWorkspace
    var selectedTab: AppTab? = .home
    var insightsSection: InsightsSection = .transactions
    var reviewCount: Int { transactionState.transactionReviewCount + captureState.reviews.count }

    init(isBackgroundAgent: Bool = false) {
        transactionState = TransactionWorkspace(session: session)
        classifier = ClassifierWorkspace(session: session)
        merchantState = MerchantWorkspace(session: session)
        receiptState = ReceiptWorkspace(session: session)
        captureState = CaptureWorkspace(session: session, transactions: transactionState, classifier: classifier)
        vault = VaultWorkspace(session: session, captureState: captureState, isBackgroundAgent: isBackgroundAgent)
        captureState.isSetup = { [weak vault] in vault?.showingSetup ?? true }
        captureState.isEncrypted = { [weak vault] in vault?.encrypted ?? false }
        classifier.isProcessing = { [weak captureState] in captureState?.processing ?? false }
        classifier.setProcessing = { [weak captureState] in captureState?.processing = $0 }
        classifier.pendingSuggestionCount = { [weak captureState] in captureState?.suggestionCount ?? 0 }
        classifier.contextForJob = { [weak merchantState] job, store in
            try await merchantState?.merchantContext(for: job, store: store)
        }
        session.refresh = { [weak self] in try await self?.refresh() }
        session.processAutomatically = { [weak captureState] in await captureState?.processIfAutomatic() }
        session.didFinishSaving = { [weak captureState] in captureState?.resumeAutomaticProcessingIfNeeded() }
        session.canReleaseResources = { [weak captureState, weak classifier] in
            captureState?.processing != true && classifier?.classifying != true
        }
        session.releaseResources = { [weak classifier] in await classifier?.releaseClassifierResources() }
        vault.didOpen = { [weak self] store in
            guard let self else { throw CancellationError() }
            try await self.prepareOpenedVault(store)
        }
        vault.willClose = { [weak classifier, weak merchantState] in
            await classifier?.releaseClassifierResources()
            await merchantState?.shutdown()
        }
        vault.didLock = { [weak transactionState, weak captureState] in
            transactionState?.clearLockedState()
            captureState?.clearLockedState()
        }
    }

    func configureQueueSmoke(store: LedgerStore, bookmark: Data, mode: QueueProcessingMode) {
        session.store = store
        captureState.folderBookmark = bookmark; captureState.processingMode = mode
        vault.showingSetup = false
    }

    func refresh() async throws {
        guard let result = try await transactionState.refreshSnapshot() else { return }
        captureState.applySnapshot(result)
    }

    func showTransactions(needingReview: Bool = false) {
        transactionState.reviewOnly = needingReview
        insightsSection = .transactions; selectedTab = .fullInsights
    }

    private func prepareOpenedVault(_ store: LedgerStore) async throws {
        if InterfacePreview.isEnabled {
            try await InterfacePreview.seed(store)
            session.status = "Preview vault · fictional transactions"
            captureState.processingMode = .manual
            if CommandLine.arguments.contains("--transaction-preview") || CommandLine.arguments.contains("--recording-preview") {
                vault.showingSetup = false; showTransactions()
            }
            if CommandLine.arguments.contains("--spending-preview") {
                vault.showingSetup = false; selectedTab = .spending
            }
            if CommandLine.arguments.contains("--capture-review-preview") {
                vault.showingSetup = false; selectedTab = .sync
            }
        }
        #if DEBUG
        if InterfacePreview.isEnabled && CommandLine.arguments.contains("--council-preview") {
            try await CouncilPreview.seed(store)
            vault.showingSetup = false; showTransactions()
        }
        #endif
        receiptState.shareReceiptContextWithApple = try await store.receiptCloudConsent()
        let searchSettings = try await store.merchantSearchSettings()
        merchantState.merchantSearchEnabled = searchSettings.enabled
        merchantState.merchantSearchLocality = searchSettings.locality
        if InterfacePreview.isEnabled && CommandLine.arguments.contains("--merchant-search-preview") {
            vault.showingSetup = false; selectedTab = .settings
            try await store.setMerchantSearchSettings(.init(enabled: true, locality: "Waterloo Ontario"))
            merchantState.merchantSearchEnabled = true; merchantState.merchantSearchLocality = "Waterloo Ontario"
            merchantState.merchantSearchStatus = "Using cached DuckDuckGo context · fictional preview"
        }
        captureState.restoreFolder()
        try await classifier.restoreSelection()
        try await refresh()
        captureState.startMonitoring()
    }
}
