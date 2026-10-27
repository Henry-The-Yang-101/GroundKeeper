import Foundation
import GroundKeeperCore

/// Actual sandbox/network/provider/queue path, using separate preferences and a
/// disposable vault. Requires an already installed local model; never pulls one.
@MainActor enum OllamaSmoke {
    static func run() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) { exit(124) }
        guard AppPreferences.isSetupPreview else { print("ollama_smoke_requires_disposable_preview"); exit(1) }
        do {
            guard let index = CommandLine.arguments.firstIndex(of: "--ollama-model"),
                  CommandLine.arguments.indices.contains(index + 1) else { throw LedgerError.invalid("Pass --ollama-model with an installed model name.") }
            let name = CommandLine.arguments[index + 1]
            let workspace = AppWorkspace()
            await workspace.start()
            workspace.processingMode = .manual
            guard let store = workspace.store else { throw LedgerError.unavailable("Preview vault did not open.") }
            try await store.addAccount(name: "Fictional Ollama smoke card", currency: "CAD")
            var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
            let first = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-20,FICTIONAL CAFE,-12.50\n".utf8), filename: "ollama-first.csv")
            _ = try await workspace.transactionState.importCSV(first, mapping: mapping, skipped: [])
            guard let selected = try await workspace.ollama.models().first(where: { $0.name == name }) else { throw OllamaError.modelUnavailable }
            workspace.useOllama(selected)
            while workspace.saving { try await Task.sleep(for: .milliseconds(50)) }
            guard workspace.classifierProvider == "ollama", workspace.errorMessage == nil else { throw LedgerError.invalid(workspace.errorMessage ?? "Provider selection failed.") }
            let beforeSuggestion = try await store.snapshot()
            var draft = Transaction()
            draft.merchant = "FICTIONAL CAFE"
            let suggested = try await workspace.suggestCategory(for: draft)
            try suggested.decision.validateSuggestion()
            let afterSuggestion = try await store.snapshot()
            guard beforeSuggestion.transactions.count == afterSuggestion.transactions.count,
                  !workspace.processing else { throw LedgerError.invalid("Draft suggestion changed the ledger or left processing locked.") }
            draft.merchant = "   "
            do {
                _ = try await workspace.suggestCategory(for: draft)
                throw ClassifierBridgeError.invalidResponse
            } catch is LedgerError { }
            await workspace.sync()
            let snapshot = try await store.snapshot()
            guard workspace.errorMessage == nil, snapshot.pendingJobs == 0, snapshot.failedJobs == 0,
                  snapshot.transactions.first?.needsReview == true,
                  snapshot.transactions.first?.category != nil else { throw LedgerError.invalid(workspace.errorMessage ?? "Classification queue did not complete.") }
            await workspace.stop()
            // Recreate the workspace to exercise the persisted selection and lazy restore.
            let reopened = AppWorkspace()
            await reopened.start()
            reopened.processingMode = .manual
            guard reopened.classifierProvider == "ollama", reopened.model == nil else { throw LedgerError.invalid("Saved provider did not restore lazily.") }
            let second = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-21,FICTIONAL BOOK SHOP,-9.25\n".utf8), filename: "ollama-second.csv")
            _ = try await reopened.transactionState.importCSV(second, mapping: mapping, skipped: [])
            await reopened.sync()
            guard reopened.errorMessage == nil, reopened.model == nil, reopened.pendingJobs == 0,
                  reopened.failedJobs == 0 else { throw LedgerError.invalid(reopened.errorMessage ?? "Restored Ollama provider did not process the queue.") }
            await reopened.stop()
            print("ollama_smoke_passed: sandboxed_local_connection, provider_selection, queue_classification, mandatory_review, persisted_selection, draft_suggestion_without_saving, empty_description_rejected")
            exit(0)
        } catch { print("ollama_smoke_failed: \(error.localizedDescription)"); exit(1) }
    }
}
