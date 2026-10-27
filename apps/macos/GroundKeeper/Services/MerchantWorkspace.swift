import Foundation
import GroundKeeperCore
import Observation

/// Merchant grouping and optional web evidence share the active vault session.
@MainActor @Observable final class MerchantWorkspace: WorkspaceComponent {
    let session: WorkspaceSession
    var merchantSearchEnabled = true
    var merchantSearchLocality = ""
    var merchantSearchStatus = ""
    @ObservationIgnored private let merchantSearch = MerchantSearchClient()
    @ObservationIgnored private var merchantSearchTask: Task<MerchantSearchEvidence, any Error>?

    init(session: WorkspaceSession) { self.session = session }

    func shutdown() async {
        merchantSearchTask?.cancel()
        _ = try? await merchantSearchTask?.value
        merchantSearchTask = nil
        await merchantSearch.shutdown()
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
}
