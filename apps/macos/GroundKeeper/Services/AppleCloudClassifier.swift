import Foundation
import FoundationModels
import GroundKeeperCore
import Security

/// Native Apple PCC only. No XPC, Python, Shortcuts, or automatic provider fallback.
@MainActor enum AppleCloudClassifier {
    static let backend = "apple_pcc"
    static var hasEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, "com.apple.developer.private-cloud-compute" as CFString, nil) as? Bool) == true
    }
    static var unavailableReason: String? {
        guard #available(macOS 27.0, *) else { return "Native Private Cloud Compute requires macOS 27 or later." }
        guard hasEntitlement else { return "This build needs Apple’s approved Private Cloud Compute entitlement and provisioning profile. Local models and manual categorization remain available." }
        switch PrivateCloudComputeLanguageModel().availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "Private Cloud Compute is unavailable on this device or in this region."
        case .unavailable: return "Apple Intelligence is not ready. Check Apple Intelligence in System Settings and try again."
        }
    }
    static var quotaStatus: String {
        guard #available(macOS 27.0, *), hasEntitlement else { return "Apple manages the user’s daily PCC allowance. No GroundKeeper API key is needed." }
        let quota = PrivateCloudComputeLanguageModel().quotaUsage
        let reset = quota.resetDate.map { " Resets \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
        if quota.isLimitReached { return "Your daily Private Cloud Compute limit is reached." + reset }
        if case .belowLimit(let info) = quota.status, info.isApproachingLimit { return "You are approaching your daily Private Cloud Compute limit." + reset }
        return "Private Cloud Compute is within your daily allowance."
    }
    static var hasQuotaOptions: Bool {
        guard #available(macOS 27.0, *), hasEntitlement else { return false }
        return PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion != nil
    }
    static func showQuotaOptions() {
        if #available(macOS 27.0, *), hasEntitlement { PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion?.show() }
    }
    static func prepare() throws -> ClassifierModel {
        if let reason = unavailableReason { throw AppleCloudError(code: "pcc_unavailable", message: reason, retryable: false) }
        // Apple manages server weights. Record the API, prompt, policy and OS build, not a fabricated weight version.
        let configuration = [NativeClassificationPolicy.version, NativeClassificationPolicy.promptVersion,
                             NativeClassificationPolicy.instructions, ProcessInfo.processInfo.operatingSystemVersionString].joined(separator: "\n")
        return ClassifierModel(modelID: "Apple Private Cloud Compute", backend: backend,
            manifestSHA256: contentHash(Data(configuration.utf8)), policyVersion: NativeClassificationPolicy.version, device: "private_cloud_compute")
    }
    static func checkRequestAvailability() throws {
        _ = try prepare()
        if #available(macOS 27.0, *), PrivateCloudComputeLanguageModel().quotaUsage.isLimitReached { throw AppleCloudError.quota }
    }
    static func classify(_ input: ClassifierInput) async throws -> ClassificationDecision {
        try Task.checkCancellation()
        _ = try prepare()
        let prompt = try NativeClassificationPolicy.input(description: input.description, direction: input.direction, currency: input.currency)
        guard #available(macOS 27.0, *) else { throw AppleCloudError.unavailable }
        do {
            return try await withThrowingTaskGroup(of: ClassificationDecision.self) { group in
                group.addTask { try await request(prompt) }
                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    throw AppleCloudError(code: "deadline_exceeded", message: "Apple Private Cloud Compute exceeded its request deadline.", retryable: true)
                }
                defer { group.cancelAll() }
                guard let decision = try await group.next() else { throw AppleCloudError.unavailable }
                return decision
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let safe = error as? AppleCloudError { throw safe }
            throw safeError(error)
        }
    }
    @available(macOS 27.0, *)
    static func safeError(_ error: any Error) -> AppleCloudError {
        // Never expose framework debug descriptions or transcripts containing financial input.
        if let pcc = error as? PrivateCloudComputeLanguageModel.Error {
            switch pcc {
            case .quotaLimitReached: return AppleCloudError.quota
            case .networkFailure: return AppleCloudError(code: "pcc_network", message: "Private Cloud Compute could not connect. Check your internet connection.", retryable: true)
            case .serviceUnavailable: return AppleCloudError(code: "pcc_service", message: "Private Cloud Compute is temporarily unavailable.", retryable: true)
            @unknown default: return AppleCloudError.unavailable
            }
        }
        if case LanguageModelError.rateLimited = error { return AppleCloudError(code: "pcc_rate_limited", message: "Apple is limiting requests temporarily. GroundKeeper will retry with backoff.", retryable: true) }
        return AppleCloudError(code: "pcc_generation_failed", message: "Apple could not categorize this transaction. Check availability or review it manually.", retryable: false)
    }
    @available(macOS 27.0, *)
    private static func request(_ prompt: String) async throws -> ClassificationDecision {
        let model = PrivateCloudComputeLanguageModel()
        guard !model.quotaUsage.isLimitReached else { throw AppleCloudError.quota }
        // Fresh session per transaction: no history or unrelated records reach the service.
        let session = LanguageModelSession(model: model, instructions: NativeClassificationPolicy.instructions)
        let response = try await session.respond(to: prompt, generating: CloudDecision.self,
            options: GenerationOptions(temperature: 0, maximumResponseTokens: 160),
            contextOptions: ContextOptions(reasoningLevel: .light))
        try Task.checkCancellation()
        do { return try NativeClassificationPolicy.decision(type: response.content.type, category: response.content.category) }
        catch { throw AppleCloudError(code: "invalid_output", message: "Apple returned a category outside GroundKeeper’s policy. Review this transaction manually.", retryable: false) }
    }

}

struct AppleCloudError: Error, LocalizedError, Sendable {
    let code: String
    let message: String
    let retryable: Bool
    var errorDescription: String? { message }
    static let unavailable = Self(code: "pcc_unavailable", message: "Private Cloud Compute is unavailable. Check Apple Intelligence and this build’s PCC entitlement.", retryable: false)
    static let quota = Self(code: "pcc_quota_exceeded", message: "Your daily Private Cloud Compute limit is reached. Check the reset time or Apple’s access options in Settings, then retry the queue.", retryable: false)
}

@available(macOS 27.0, *)
@Generable private struct CloudDecision {
    @Guide(description: "Transaction type under the provided GroundKeeper policy", .anyOf(NativeClassificationPolicy.types))
    var type: String
    @Guide(description: "Expense category code, or null for nonexpense types; unknown must use uncategorized", .anyOf(NativeClassificationPolicy.categories))
    var category: String?
}
