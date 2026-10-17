import AppKit
import Observation
import SwiftUI
import GroundKeeperCore

@MainActor @Observable final class AppWorkspace {
    var selectedTab: AppTab? = .home
    var insightsSection: InsightsSection = .transactions
    var transactions: [Transaction] = []
    var accounts: [Account] = []
    var reviews: [ReviewRecord] = []
    var queue: [QueueRecord] = []
    var totalTransactions = 0
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
    var classifierStatus = "Choose a local model in Settings"
    var processing = false
    var saving = false
    var model: ClassifierModel?
    var lastSync: Date?
    @ObservationIgnored private var store: LedgerStore?
    @ObservationIgnored private let client = ClassifierClient()
    @ObservationIgnored private let folder = CaptureFolder()
    @ObservationIgnored private var folderBookmark: Data?
    @ObservationIgnored private var modelURL: URL?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var classifying = false
    @ObservationIgnored private var started = false
    var reviewCount: Int { transactions.filter(\.needsReview).count + reviews.count }
    var ready: Bool { store != nil }

    func start() async {
        guard !started else { return }; started = true
        do {
            let opened = try await Task.detached(priority: .userInitiated) { try VaultAccess.open() }.value
            store = opened.0; vaultPath = opened.1.path; status = "Local database ready"
            folderBookmark = UserDefaults.standard.data(forKey: "captureFolderBookmark")
            if folderBookmark != nil { folderName = "Saved capture folder" }
            try await refresh()
            if let bookmark = UserDefaults.standard.data(forKey: "classifierModelBookmark") {
                do {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                    guard !stale else { throw LedgerError.unavailable("Select the model package again.") }
                    try await loadModel(url)
                } catch { classifierStatus = "Select the model package again to resume classification." }
            }
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.sync()
                    do { try await Task.sleep(for: .seconds(15)) } catch { break }
                }
            }
        } catch { status = "Vault unavailable"; errorMessage = error.localizedDescription; started = false }
    }
    func refresh() async throws {
        guard let store else { return }
        let snapshot = try await store.snapshot(limit: 500, offset: page * 500)
        transactions = snapshot.transactions.map(Transaction.init)
        accounts = snapshot.accounts; reviews = snapshot.reviews; queue = snapshot.queue
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
            try await self.refresh(); await self.classifyPending()
        }
    }
    func resolve(_ review: ReviewRecord, transactionID: String?) {
        perform { try await self.store?.resolveMatch(eventID: review.eventID, transactionID: transactionID); try await self.refresh(); await self.classifyPending() }
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
    func selectFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose your GroundKeeper iCloud Drive folder, or its inbox folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            folderBookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(folderBookmark, forKey: "captureFolderBookmark"); folderName = url.lastPathComponent
            Task { await folder.reset(); await sync() }
        } catch { errorMessage = error.localizedDescription }
    }
    func sync() async {
        guard !processing, let store else { return }
        processing = true; defer { processing = false }
        do {
            if let folderBookmark {
                let scan = try await folder.scan(bookmark: folderBookmark)
                for entry in scan.files {
                    try Task.checkCancellation()
                    try await store.ingestCapture(data: entry.data, deliveryPath: entry.path)
                    if try await store.captureIsTerminal(path: entry.path, hash: contentHash(entry.data)) { await folder.acknowledge(entry) }
                }
                lastSync = Date(); status = scan.waiting == 0 ? "Capture folder checked" : "Waiting for \(scan.waiting) iCloud files"
            }
            try await refresh(); await classifyPending()
        } catch is CancellationError {} catch { status = "Sync needs attention"; errorMessage = error.localizedDescription }
    }
    func retryFailures() {
        perform { try await self.store?.retryQueue(); try await self.store?.retryClassificationFailures(); await self.folder.reset(); await self.sync() }
    }
    func selectModel() {
        guard !classifying, !processing else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a verified GroundKeeper model package. Pending transactions will be classified locally."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            try await self.loadModel(url)
            UserDefaults.standard.set(bookmark, forKey: "classifierModelBookmark")
            await self.classifyPending()
        }
    }
    private func loadModel(_ url: URL) async throws {
        classifierStatus = "Verifying and loading model…"
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
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
            // Yield after a small batch so capture polling and user operations remain responsive.
            for _ in 0..<10 {
                guard let job = try await store.claimClassification(modelID: selectedModel.manifestSHA256) else { break }
                do {
                    let result = try await client.classify(ClassifierInput(description: job.description, direction: job.direction, currency: job.currency),
                        model: selectedModel, partID: job.partID, revision: job.revision, jobID: job.id)
                    guard let decision = result.decision else { throw ClassifierBridgeError.invalidResponse }
                    try await store.completeClassification(job, decision: ClassificationDecision(type: decision.type, category: decision.category, review: decision.review))
                } catch {
                    var code = "worker_unavailable", retryable = true
                    if case ClassifierBridgeError.worker(let workerCode, _) = error {
                        code = workerCode
                        retryable = ["busy", "deadline_exceeded", "model_not_ready", "runtime_failed", "inference_failed"].contains(code)
                    }
                    try await store.failClassification(job, code: code, retryable: retryable)
                    if retryable, let url = modelURL {
                        // Reconnect and prepare without replaying an uncommitted job immediately.
                        do { try await loadModel(url) } catch { model = nil; classifierStatus = "Model unavailable — select it again to resume" }
                    }
                    break
                }
            }
            try await refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    func importCSV(_ document: CSVDocument, mapping: CSVMapping, skipped: Set<Int>) async throws -> Int {
        guard let store else { throw LedgerError.unavailable("Open the vault first.") }
        let count = try await store.importCSV(document, mapping: mapping, skipped: skipped)
        page = 0; try await refresh(); Task { await classifyPending() }; return count
    }
    func changePage(_ value: Int) { page = max(0, value); perform { try await self.refresh() } }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !saving else { return }; saving = true
        Task { defer { saving = false }; do { try await operation() } catch { errorMessage = error.localizedDescription } }
    }
}
