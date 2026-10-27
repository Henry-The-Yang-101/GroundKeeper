import AppKit
import Foundation
import GroundKeeperCore
import Observation

/// Provider selection and inference resources have one lifetime across queue,
/// draft, and Council requests. Scheduling stays with capture processing.
@MainActor @Observable final class ClassifierWorkspace: WorkspaceComponent {
    let session: WorkspaceSession
    var shortcutName = AppPreferences.defaults.string(forKey: AppPreferences.Key.classifierShortcutName) ?? "GK Categorize Cloud"
    var classifierProvider = AppPreferences.defaults.string(forKey: AppPreferences.Key.classifierProvider) ?? (AppPreferences.defaults.data(forKey: AppPreferences.Key.classifierModelBookmark) == nil ? "manual" : "local")
    var classifierStatus = "Manual categorization until you choose a provider"
    var ollamaModelName = AppPreferences.defaults.string(forKey: AppPreferences.Key.ollamaModelName) ?? ""
    var councilConfiguration: CouncilConfiguration?
    var councilQwenURL: URL?
    var councilLayaURL: URL?
    var model: ClassifierModel?
    @ObservationIgnored let client = ClassifierClient()
    @ObservationIgnored let ollama = OllamaClassifier()
    @ObservationIgnored var ollamaModel: OllamaModel?
    @ObservationIgnored var modelURL: URL?
    @ObservationIgnored var classifying = false

    @ObservationIgnored var isProcessing: @MainActor () -> Bool = { false }
    @ObservationIgnored var setProcessing: @MainActor (Bool) -> Void = { _ in }
    @ObservationIgnored var pendingSuggestionCount: @MainActor () -> Int = { 0 }
    @ObservationIgnored var contextForJob: @MainActor (ClassificationTask, LedgerStore) async throws -> MerchantContext? = { _, _ in nil }
    var processing: Bool {
        get { isProcessing() }
        set { setProcessing(newValue) }
    }

    init(session: WorkspaceSession) { self.session = session }

    func merchantContext(for job: ClassificationTask, store: LedgerStore) async throws -> MerchantContext? {
        try await contextForJob(job, store)
    }

    func restoreSelection() async throws {
        restoreCouncilPackages()
        if classifierProvider == "council" {
            councilConfiguration = try await store?.selectedCouncil()
            classifierStatus = councilConfiguration == nil ? "Council needs setup" : "Council · Qwen, Laya and Apple Intelligence · equal votes"
        }
        else if classifierProvider == "manual" { classifierStatus = "Manual categorization" }
        else if classifierProvider == "ollama" { classifierStatus = "Ollama · \(ollamaModelName) · connects when processing needs it" }
        else if classifierProvider == "shortcut" { classifierStatus = "Saved Shortcut · runs when processing needs it" }
        else if AppPreferences.defaults.data(forKey: AppPreferences.Key.classifierModelBookmark) != nil { classifierStatus = "Saved model · loads when processing needs it" }
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

    func suggestPendingCategories(store: LedgerStore) async throws {
        try Task.checkCancellation()
        try await refresh()
        guard classifierProvider != "manual", pendingSuggestionCount() > 0 else { return }
        if classifierProvider == "council" { try await classifyCouncilPending() }
        else if try await store.prepareSelectedClassifications() {
            if model == nil { try await restoreModel() }
            guard model != nil else { throw LedgerError.unavailable("Choose a category provider in Settings before requesting suggestions.") }
            try Task.checkCancellation()
            await classifyPending()
        }
    }

    func releaseClassifierResources() async {
        // Disconnecting lets the service exit, freeing Python and GPU allocator caches too.
        await client.shutdown()
        model = nil; modelURL = nil; ollamaModel = nil
    }
}
