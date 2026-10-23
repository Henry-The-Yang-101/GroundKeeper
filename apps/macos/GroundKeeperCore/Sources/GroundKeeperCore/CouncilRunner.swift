import Foundation

public struct CouncilProviderFailure: Error, Sendable {
    public let disposition: String, code: String
    public init(disposition: String, code: String) { self.disposition = disposition; self.code = code }
}
public protocol CouncilEngine: Sendable {
    func prepare(_ member: CouncilMember) async throws
    func classify(_ input: CouncilInput, member: CouncilMember, task: ClassificationTask) async throws -> ClassificationDecision
}

/// Batches model preparation, while each transaction keeps a separate parent and member audit trail.
public enum CouncilRunner {
    @discardableResult public static func runBatch(store: LedgerStore, configuration: CouncilConfiguration, engine: any CouncilEngine,
        limit: Int = 8, search: @Sendable (ClassificationTask) async throws -> Void,
        stage: @Sendable (String) async -> Void = { _ in }) async throws -> Int {
        var tasks: [ClassificationTask] = []
        do {
            for _ in 0..<max(0, min(limit, 8)) {
                try Task.checkCancellation()
                guard let task = try await store.claimCouncil(configID: configuration.id) else { break }
                tasks.append(task)
                await stage("Council · preparing shared merchant evidence")
                try await search(task)
            }
            guard !tasks.isEmpty else { return 0 }
            for backend in ["qwen_mlx", "laya_mps", "apple_shortcut"] {
                let member = configuration.members.first { $0.backend == backend }!
                var preparationFailure: CouncilProviderFailure?
                var prepared = false
                for (index, task) in tasks.enumerated() {
                    try Task.checkCancellation()
                    guard try await store.councilTaskIsCurrent(task) else { continue }
                    await stage("Council · \(member.title) · \(index + 1) of \(tasks.count)")
                    let child = try await store.startCouncilMember(member, task: task)
                    var vote: CouncilVote
                    do {
                        if let preparationFailure { throw preparationFailure }
                        if !prepared {
                            do { try await engine.prepare(member); prepared = true }
                            catch {
                                if error is CancellationError { throw error }
                                preparationFailure = failure(error)
                                throw error
                            }
                        }
                        let decision = try await engine.classify(child.input, member: member, task: task)
                        do { try decision.validateSuggestion() }
                        catch { throw CouncilProviderFailure(disposition: "invalid", code: "invalid_decision") }
                        vote = CouncilVote(member: member, disposition: "valid", decision: decision)
                    } catch {
                        if error is CancellationError { throw error }
                        try Task.checkCancellation()
                        let failed = failure(error)
                        if ["shortcut_rate_limited", "shortcut_unavailable"].contains(failed.code) { preparationFailure = failed }
                        vote = CouncilVote(member: member, disposition: failed.disposition, errorCode: failed.code)
                    }
                    try await store.recordCouncilVote(vote, memberRunID: child.runID, task: task)
                }
            }
            for task in tasks {
                try Task.checkCancellation()
                if try await store.councilTaskIsCurrent(task) {
                    let result = try await store.completeCouncil(task, configuration: configuration)
                    await stage("Council · \(result.title)")
                } else { try await store.releaseClassification(task) }
            }
            return tasks.count
        } catch {
            // Release every claimed transaction, including a child interrupted during inference.
            for task in tasks { try? await store.releaseClassification(task) }
            throw error
        }
    }
    private static func failure(_ error: any Error) -> CouncilProviderFailure {
        (error as? CouncilProviderFailure) ?? .init(disposition: "unavailable", code: "provider_unavailable")
    }
}
