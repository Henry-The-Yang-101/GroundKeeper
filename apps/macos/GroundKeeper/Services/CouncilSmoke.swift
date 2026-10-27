import AppKit
import GroundKeeperCore

/// Exercises provider selection and the actual queue/XPC pipeline against a disposable fictional ledger.
@MainActor enum CouncilSmoke {
    static func run() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { exit(124) }
        guard AppPreferences.isSetupPreview else { print("council_smoke_requires_setup_preview"); exit(1) }
        let workspace = AppWorkspace()
        do {
            guard CouncilClassifierEngine.safeFailure(ClassifierBridgeError.worker("invalid_output", "fixture")).disposition == "invalid",
                  CouncilClassifierEngine.safeFailure(ClassifierBridgeError.timedOut).disposition == "timeout" else {
                throw LedgerError.invalid("Council error mapping failed.")
            }
            if CommandLine.arguments.contains("--checks-only") {
                print("council_error_mapping_passed"); exit(0)
            }
            await workspace.start()
            guard let store = workspace.store else { throw LedgerError.unavailable("Disposable vault did not open.") }
            workspace.showingSetup = false; workspace.processingMode = .manual
            for (backend, title) in [("qwen_mlx", "Qwen"), ("laya_mps", "Laya")] {
                let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                panel.message = "Council smoke: choose \(title) for a fictional transaction in a disposable vault."
                if let index = CommandLine.arguments.firstIndex(of: "--council-smoke-models"), CommandLine.arguments.indices.contains(index + 1) {
                    panel.directoryURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                }
                guard await panel.begin() == .OK, let url = panel.url else { throw CancellationError() }
                workspace.classifier.setCouncilPackage(url, backend: backend)
            }
            guard workspace.classifier.councilReadyToConfigure else { throw LedgerError.invalid("Smoke packages not selected.") }
            workspace.classifier.useCouncil()
            while workspace.saving { try await Task.sleep(for: .milliseconds(100)) }
            guard workspace.classifier.classifierProvider == "council", let configuration = workspace.classifier.councilConfiguration else {
                throw LedgerError.invalid(workspace.errorMessage ?? "Council setup failed.")
            }
            try await store.addAccount(name: "Fictional council account", currency: "CAD")
            var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
            _ = try await store.importCSV(CSVDocument(data: Data("Date,Description,Amount\n2026-10-23,FICTIONAL CAFE,-8.50\n".utf8), filename: "fictional-council.csv"), mapping: mapping)
            await workspace.sync(automatic: true)
            guard try await store.snapshot().pendingJobs == 0 else { throw LedgerError.invalid("Manual mode was bypassed.") }
            await workspace.sync()
            let transaction = try await store.snapshot().transactions[0]
            guard let report = try await store.councilReport(transactionID: transaction.id), report.result.votes.count == 3,
                  report.result.votes.filter({ $0.member.backend != "apple_shortcut" }).allSatisfy({ $0.disposition == "valid" }),
                  try await store.integrityCheck() else {
                throw LedgerError.invalid(workspace.errorMessage ?? "Council pipeline did not complete.")
            }
            guard try await store.selectedCouncil()?.id == configuration.id else { throw LedgerError.invalid("Council selection changed during inference.") }
            for vote in report.result.votes { print("council_member: \(vote.member.title), \(vote.disposition), \(vote.errorCode ?? "none")") }
            print("council_smoke_passed: manual gating, verified local XPC members, Apple outcome, parent persistence, review, integrity; \(report.result.reason)")
            await workspace.stop()
            exit(0)
        } catch {
            await workspace.stop()
            print("council_smoke_failed: \(error.localizedDescription)"); exit(1)
        }
    }
}
