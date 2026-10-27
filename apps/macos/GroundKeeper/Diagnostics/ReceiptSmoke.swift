import AppKit
import GroundKeeperCore

/// Exercises the actual signed app, receipt queue and XPC worker with fictional evidence.
@MainActor enum ReceiptSmoke {
    /// App receipt operations without a model picker, model weights, or network.
    static func runWorkspace() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { exit(124) }
        guard AppPreferences.isSetupPreview else { print("receipt_workspace_smoke_requires_disposable_preview"); exit(1) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-workspace-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try LedgerStore(url: directory.appendingPathComponent("fixture.sqlite"))
            try await store.addAccount(name: "Fictional receipt account", currency: "CAD")
            var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
            let document = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-20,FICTIONAL RETAILER,-12.50\n".utf8), filename: "fictional.csv")
            _ = try await store.importCSV(document, mapping: mapping)
            let workspace = AppWorkspace()
            workspace.configureQueueSmoke(store: store, bookmark: Data(), mode: .manual)
            try await workspace.session.refresh()
            guard let transaction = workspace.transactionState.transactions.first else { throw LedgerError.invalid("Missing receipt fixture.") }
            let id = transaction.id.uuidString
            let note = try await workspace.receiptState.transactionNote(transactionID: id)
            try await workspace.receiptState.saveTransactionNote(transactionID: id, text: "Fictional receipt note", revision: note.revision)
            guard try await workspace.receiptState.transactionNote(transactionID: id).text == "Fictional receipt note" else { throw LedgerError.invalid("Note did not persist.") }
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=")!
            try await workspace.receiptState.addReceiptImage(transactionID: id, data: png)
            guard let receipt = try await workspace.receiptState.receiptRecords(transactionID: id).first,
                  try await workspace.receiptState.receiptImage(id: receipt.id) != nil else { throw LedgerError.invalid("Receipt image did not persist.") }
            try await workspace.receiptState.setReceiptRemoved(id: receipt.id, transactionID: id, removed: true)
            guard try await workspace.receiptState.receiptRecords(transactionID: id).isEmpty else { throw LedgerError.invalid("Removed receipt remained visible.") }
            try await workspace.receiptState.setReceiptRemoved(id: receipt.id, transactionID: id, removed: false)
            guard try await workspace.receiptState.receiptRecords(transactionID: id).count == 1 else { throw LedgerError.invalid("Receipt restoration failed.") }
            workspace.receiptState.setReceiptSharing(false)
            for _ in 0..<100 where workspace.session.saving { try await Task.sleep(for: .milliseconds(10)) }
            guard !workspace.session.saving, try await !store.receiptCloudConsent(), !workspace.receiptState.shareReceiptContextWithApple else { throw LedgerError.invalid("Receipt sharing preference did not persist.") }
            guard try await store.integrityCheck() else { throw LedgerError.invalid("Receipt fixture integrity failed.") }
            await workspace.vault.stop()
            print("receipt_workspace_smoke_passed: notes, image attachment, removal/restoration, sharing")
            exit(0)
        } catch { print("receipt_workspace_smoke_failed: \(error.localizedDescription)"); exit(1) }
    }

    static func run() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { exit(124) }
        do {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.message = "Choose a model package for the fictional receipt/XPC test. Your ledger is not opened."
            if let index = CommandLine.arguments.firstIndex(of: "--receipt-model-picker"), CommandLine.arguments.indices.contains(index + 1) {
                panel.directoryURL = URL(fileURLWithPath: CommandLine.arguments[index + 1]).deletingLastPathComponent()
            } else if let directory = Bundle.main.object(forInfoDictionaryKey: "GKReceiptSmokeModelsDirectory") as? String {
                panel.directoryURL = URL(fileURLWithPath: directory)
            }
            guard await panel.begin() == .OK, let url = panel.url else { throw CancellationError() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-smoke-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try LedgerStore(url: directory.appendingPathComponent("fixture.sqlite"), passphrase: "fictional-receipt-smoke")
            try await store.addAccount(name: "Fictional receipt account", currency: "CAD")
            let payment: [String: Any] = ["schema_version": 2, "event_id": "fictional-payment", "source": "wallet_transaction", "app": "Wallet",
                "input_shape": "wallet_transaction_fields", "captured_at": "2026-10-20T10:00:00-04:00", "merchant": "FICTIONAL RETAILER", "amount": "CAD 12.50", "card_or_pass": "Fictional card"]
            try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: payment), deliveryPath: "payment.json")
            let snapshot = try await store.snapshot()
            guard let review = snapshot.reviews.first else { throw ClassifierBridgeError.invalidResponse }
            try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: snapshot.accounts[0].id)
            let receipt: [String: Any] = ["schema_version": 3, "event_id": "fictional-receipt", "source": "receipt_attachment", "captured_at": "2026-10-20T10:01:00-04:00",
                "target": ["source": "wallet_transaction", "app": "Wallet", "event_id": "fictional-payment"],
                "receipt": ["ocr": ["producer": "user_text", "text": "MILK 4.99\nBREAD 3.49\nEGGS 4.02"]]]
            try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: receipt), deliveryPath: "receipt.json")
            let client = ClassifierClient(), model = try await client.prepareModel(at: url)
            try await store.registerModel(id: model.manifestSHA256, name: model.modelID, backend: model.backend, policy: model.policyVersion, configuration: "{}")
            try await store.enqueueClassifications(modelID: model.manifestSHA256)
            guard let job = try await store.claimClassification(modelID: model.manifestSHA256), job.receiptContext != nil else { throw ClassifierBridgeError.invalidResponse }
            let result = try await client.classify(ClassifierInput(description: job.description, direction: job.direction, currency: job.currency, receiptContext: job.receiptContext), model: model, partID: job.partID, revision: job.revision, jobID: job.id)
            guard let decision = result.decision, decision.review else { throw ClassifierBridgeError.invalidResponse }
            try await store.completeClassification(job, decision: .init(type: decision.type, category: decision.category, review: decision.review))
            guard try await store.snapshot().transactions.count == 1, try await store.integrityCheck() else { throw ClassifierBridgeError.invalidResponse }
            try await client.releaseModel(); await store.close()
            try FileManager.default.removeItem(at: directory)
            report("receipt_xpc_smoke_passed backend=\(model.backend) category=\(decision.category ?? "null")")
            exit(0)
        } catch { report("receipt_xpc_smoke_failed: \(error.localizedDescription)"); exit(1) }
    }

    private static func report(_ message: String) {
        print(message)
        if Bundle.main.object(forInfoDictionaryKey: "GKReceiptSmoke") as? Bool == true {
            let alert = NSAlert(); alert.messageText = message
            alert.informativeText = "Fictional receipt test. The live ledger was not opened."
            alert.runModal()
        }
    }
}
