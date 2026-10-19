import Foundation
import FoundationModels
import GroundKeeperCore

/// Disposable routing/error checks. --pcc-live-smoke explicitly adds one fictional cloud request.
@MainActor enum AppleCloudSmoke {
    static func run() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 100) { exit(124) }
        guard AppPreferences.isSetupPreview else { print("pcc_smoke_requires_setup_preview"); exit(1) }
        do {
            AppPreferences.defaults.set("shortcut", forKey: "classifierProvider")
            let workspace = AppWorkspace()
            await workspace.start()
            guard workspace.classifierProvider == "manual",
                  AppPreferences.defaults.string(forKey: "classifierProvider") == "manual" else { throw ClassifierBridgeError.invalidResponse }
            await workspace.stop()
            let input = ClassifierInput(description: "FICTIONAL CAFE", direction: "debit", currency: "CAD")
            let cancelled = Task { try await AppleCloudClassifier.classify(input) }
            cancelled.cancel()
            do { _ = try await cancelled.value; throw ClassifierBridgeError.invalidResponse }
            catch is CancellationError { }
            let client = ClassifierClient()
            let cloud = ClassifierModel(modelID: "Fixture PCC", backend: "apple_pcc", manifestSHA256: String(repeating: "a", count: 64), policyVersion: "groundkeeper-18-v1", device: "private_cloud_compute")
            do {
                _ = try await client.classify(input, model: cloud, partID: "fixture", revision: 1)
                throw LedgerError.invalid("Python client accepted a cloud backend.")
            } catch ClassifierBridgeError.invalidResponse { }
            if #available(macOS 27.0, *) {
                let quota = AppleCloudClassifier.safeError(PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(debugDescription: "PRIVATE FIXTURE")))
                let network = AppleCloudClassifier.safeError(PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "PRIVATE FIXTURE")))
                guard quota.code == "pcc_quota_exceeded", !quota.retryable,
                      network.retryable, !network.message.contains("PRIVATE"), !quota.message.contains("PRIVATE") else { throw ClassifierBridgeError.invalidResponse }
            }
            if !AppleCloudClassifier.hasEntitlement {
                do { _ = try AppleCloudClassifier.prepare(); throw ClassifierBridgeError.invalidResponse }
                catch let error as AppleCloudError { guard error.code == "pcc_unavailable" else { throw error } }
                print("pcc_missing_entitlement_gate_passed; live inference unavailable in this build")
            }
            if CommandLine.arguments.contains("--pcc-live-smoke") {
                let decision = try await AppleCloudClassifier.classify(input)
                guard decision.review else { throw ClassifierBridgeError.invalidResponse }
                print("pcc_live_fictional_request_passed")
            }
            print("pcc_routing_migration_cancellation_and_safe_errors_passed")
            exit(0)
        } catch { print("pcc_smoke_failed: \(error.localizedDescription)"); exit(1) }
    }
}
