import Foundation
import GroundKeeperCore

actor CouncilClassifierEngine: CouncilEngine {
    private let client: ClassifierClient
    private let packages: [String: URL]
    private let shortcut: String
    private var loaded: ClassifierModel?
    private var appleFailure: CouncilProviderFailure?
    init(client: ClassifierClient, packages: [String: URL], shortcut: String) {
        self.client = client; self.packages = packages; self.shortcut = shortcut
    }
    func prepare(_ member: CouncilMember) async throws {
        do {
            if member.backend == "apple_shortcut" {
                if let appleFailure { throw appleFailure }
                loaded = try await client.prepareShortcut(name: shortcut)
            } else {
                guard let url = packages[member.backend] else { throw CouncilProviderFailure(disposition: "unavailable", code: "model_package_unavailable") }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                loaded = try await client.prepareModel(at: url)
            }
            guard let loaded, loaded.manifestSHA256 == member.id, loaded.backend == member.backend,
                  loaded.policyVersion == ClassifierClient.policyVersion else {
                self.loaded = nil
                throw CouncilProviderFailure(disposition: "invalid", code: "model_identity_changed")
            }
        } catch {
            if error is CancellationError { throw error }
            throw Self.safeFailure(error)
        }
    }
    func classify(_ input: CouncilInput, member: CouncilMember, task: ClassificationTask) async throws -> ClassificationDecision {
        guard let loaded, loaded.manifestSHA256 == member.id else { throw CouncilProviderFailure(disposition: "unavailable", code: "model_not_ready") }
        do {
            let result = try await client.classify(ClassifierInput(description: input.description, direction: input.direction, currency: input.currency,
                transactionNotes: input.transactionNotes, receiptContext: input.receiptContext, walletCategoryRaw: input.walletCategoryRaw, merchantContext: input.merchantContext),
                model: loaded, partID: task.partID, revision: task.revision, jobID: task.id)
            guard let decision = result.decision else { throw ClassifierBridgeError.invalidResponse }
            return .init(type: decision.type, category: decision.category, review: decision.review)
        } catch {
            if error is CancellationError { throw error }
            let failure = Self.safeFailure(error)
            if member.backend == "apple_shortcut", ["shortcut_rate_limited", "shortcut_unavailable"].contains(failure.code) { appleFailure = failure }
            throw failure
        }
    }
    static func safeFailure(_ error: any Error) -> CouncilProviderFailure {
        if let failure = error as? CouncilProviderFailure { return failure }
        switch error {
        case ClassifierBridgeError.timedOut: return .init(disposition: "timeout", code: "deadline_exceeded")
        case ClassifierBridgeError.invalidResponse: return .init(disposition: "invalid", code: "invalid_response")
        case ClassifierBridgeError.worker(let code, _):
            let allowed: Set<String> = ["shortcut_rate_limited", "shortcut_unavailable", "deadline_exceeded", "model_not_ready", "runtime_failed", "inference_failed", "invalid_decision", "invalid_output", "model_invalid", "busy"]
            return .init(disposition: code == "deadline_exceeded" ? "timeout" : ["invalid_decision", "invalid_output"].contains(code) ? "invalid" : "unavailable",
                         code: allowed.contains(code) ? code : "provider_unavailable")
        default: return .init(disposition: "unavailable", code: "provider_unavailable")
        }
    }
}
