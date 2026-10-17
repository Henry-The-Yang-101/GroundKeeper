import AppKit
import GroundKeeperCore

/// Synthetic, temporary database only. Optional real XPC inference through a selected package.
@MainActor enum LedgerSmoke {
    static func run() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { exit(124) }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-smoke-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try LedgerStore(url: directory.appendingPathComponent("test.sqlite"))
            try await store.addAccount(name: "Fictional smoke account", currency: "CAD")
            var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
            let csv = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-17,FICTIONAL CAFE,-12.50\n".utf8), filename: "fictional.csv")
            let first = try await store.importCSV(csv, mapping: mapping), replay = try await store.importCSV(csv, mapping: mapping)
            guard first == 1, replay == 0 else { throw LedgerError.invalid("Import replay check failed.") }
            if CommandLine.arguments.contains("--ledger-model-picker") {
                let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                panel.message = "Choose a model for one fictional ledger-to-XPC classification."
                if let index = CommandLine.arguments.firstIndex(of: "--ledger-model-picker"), CommandLine.arguments.indices.contains(index + 1) {
                    panel.directoryURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                }
                let selection = await panel.begin()
                guard selection == .OK, let url = panel.url else { throw CancellationError() }
                let client = ClassifierClient(), model = try await client.prepareModel(at: url)
                try await store.registerModel(id: model.manifestSHA256, name: model.modelID, backend: model.backend, policy: model.policyVersion, configuration: "{}")
                try await store.enqueueClassifications(modelID: model.manifestSHA256)
                guard let job = try await store.claimClassification(modelID: model.manifestSHA256) else { throw LedgerError.invalid("No classification job.") }
                let response = try await client.classify(ClassifierInput(description: job.description, direction: job.direction, currency: job.currency), model: model, partID: job.partID, revision: job.revision, jobID: job.id)
                guard let decision = response.decision else { throw ClassifierBridgeError.invalidResponse }
                try await store.completeClassification(job, decision: ClassificationDecision(type: decision.type, category: decision.category, review: decision.review))
                let snapshot = try await store.snapshot()
                guard snapshot.transactions[0].origin == "model", snapshot.transactions[0].needsReview else { throw LedgerError.invalid("Model result was not persisted.") }
                try await client.releaseModel()
                print("ledger_xpc_classification_passed")
            }
            guard try await store.integrityCheck() else { throw LedgerError.invalid("Integrity check failed.") }
            print("ledger_smoke_passed")
            exit(0)
        } catch { print("ledger_smoke_failed: \(error.localizedDescription)"); exit(1) }
    }
}
