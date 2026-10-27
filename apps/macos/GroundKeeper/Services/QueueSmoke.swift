import Foundation
import ServiceManagement
import GroundKeeperCore
import Observation
import Synchronization

/// Exercises app scheduling and scanner inventory against fictional files and a temporary vault.
@MainActor enum QueueSmoke {
    static func run() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { exit(124) }
        do {
            if CommandLine.arguments.contains("--adhoc-release-smoke") {
                try check(!QueueBackgroundService.isSupported, "Ad hoc release is missing its background capability marker")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-smoke-" + UUID().uuidString)
            let inbox = directory.appendingPathComponent("inbox")
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            for index in 0..<205 {
                let payload: [String: Any] = ["schema_version": 2, "event_id": "test-\(index)", "source": "wallet_transaction", "captured_at": "2026-10-17T10:00:00-04:00", "input_shape": "wallet_transaction_fields", "is_test": true, "merchant": "FICTIONAL CAFE", "amount": "CAD 12.50", "card_or_pass": "Test card"]
                let url = inbox.appendingPathComponent("\(index).json")
                try JSONSerialization.data(withJSONObject: payload).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: url.path)
            }
            let store = try LedgerStore(url: directory.appendingPathComponent("test.sqlite"))
            let bookmark = try inbox.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let workspace = AppWorkspace()
            workspace.configureQueueSmoke(store: store, bookmark: bookmark, mode: .manual)
            if !QueueBackgroundService.isSupported {
                workspace.captureState.changeProcessingMode(.background)
                try check(workspace.captureState.processingMode == .manual && workspace.errorMessage != nil, "Unavailable background mode changed preferences")
                workspace.errorMessage = nil
                print("adhoc_background_gate_verified")
            }
            await workspace.captureState.processIfAutomatic()
            try check(workspace.captureState.countError == nil, workspace.captureState.countError ?? "inventory error")
            try check(workspace.captureState.queueCount == 205, "Inventory must include files beyond the 200-file batch")
            try check(try await store.snapshot().queue.isEmpty, "Manual inventory ingested files")
            await workspace.captureState.sync(automatic: true)
            try check(try await store.snapshot().queue.isEmpty, "Automatic call bypassed manual mode")
            await workspace.captureState.sync()
            try check(workspace.captureState.queueCount == 0, "Manual processing did not drain the backlog")
            try check(try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty, "Committed JSON files remained in the queue")
            let assets = inbox.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=")!
            try png.write(to: assets.appendingPathComponent("fixture.png"))
            let receipt: [String: Any] = ["schema_version": 3, "source": "receipt_attachment", "event_id": "fixture-receipt",
                "captured_at": "2026-10-20T10:00:00-04:00", "target": ["source": "wallet_transaction", "app": "Wallet", "event_id": "future-payment"],
                "receipt": ["ocr": ["producer": "apple_shortcuts", "text": "Fictional receipt"], "image": ["path": "assets/fixture.png"]]]
            let receiptFile = inbox.appendingPathComponent("receipt.json")
            try JSONSerialization.data(withJSONObject: receipt).write(to: receiptFile)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: receiptFile.path)
            await workspace.captureState.sync()
            try check(!FileManager.default.fileExists(atPath: receiptFile.path), "Receipt JSON was not drained")
            try check(!FileManager.default.fileExists(atPath: assets.appendingPathComponent("fixture.png").path), "Stored receipt image was not drained")
            try check(try await store.pendingFileCleanups().isEmpty, "File cleanup was not acknowledged")
            try check(try await store.captureDeliveryStates().count == 206, "Receipt delivery was not persisted")
            try check(try await store.snapshot().transactions.isEmpty, "Test captures created transactions")
            let fresh = CaptureFolder()
            let inventory = try await fresh.scan(bookmark: bookmark, store: store, readFiles: false)
            try check(inventory.pending == 0, "Restart inventory counted completed files")
            workspace.showingSetup = false
            workspace.captureState.processingMode = .whileOpen
            let idleProcessingChanged = Mutex(false)
            withObservationTracking { _ = workspace.captureState.processing } onChange: { idleProcessingChanged.withLock { $0 = true } }
            await workspace.captureState.processIfAutomatic()
            try check(!idleProcessingChanged.withLock { $0 }, "Idle polling briefly locked settings")
            let malformed = inbox.appendingPathComponent("malformed.json")
            try Data("broken".utf8).write(to: malformed)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: malformed.path)
            workspace.captureState.processingMode = .whileOpen
            await workspace.captureState.processIfAutomatic()
            try check(try await store.snapshot().queue.contains { $0.path == "malformed.json" && $0.attempts == 1 }, "While-open mode did not process")
            await workspace.captureState.sync()
            try check(try await store.snapshot().queue.first { $0.path == "malformed.json" }?.attempts == 1, "Backoff was bypassed")
            try FileManager.default.removeItem(at: malformed)
            workspace.captureState.processingMode = .manual
            try await store.addAccount(name: "Fictional account", currency: "CAD")
            var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
            let document = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-17,FICTIONAL CAFE,-12.50\n".utf8), filename: "fixture.csv")
            _ = try await workspace.transactionState.importCSV(document, mapping: mapping, skipped: [])
            await workspace.captureState.processIfAutomatic()
            try check(workspace.captureState.pendingJobs == 0 && workspace.captureState.unqueuedJobs == 1 && workspace.classifier.model == nil, "CSV import bypassed manual classification mode")
            workspace.classifier.classifierProvider = "manual"
            workspace.captureState.processingMode = .whileOpen
            let manualProcessingChanged = Mutex(false)
            withObservationTracking { _ = workspace.captureState.processing } onChange: { manualProcessingChanged.withLock { $0 = true } }
            await workspace.captureState.processIfAutomatic()
            try check(!manualProcessingChanged.withLock { $0 }, "Manual categorization backlog briefly locked settings")
            try check(try await store.integrityCheck(), "Integrity check failed")
            await workspace.stop()
            try await captureReviewFlow(in: directory)
            if CommandLine.arguments.contains("--background-smoke-agent") {
                guard Bundle.main.bundleIdentifier == "com.groundkeeper.macos.queue-smoke" else {
                    throw LedgerError.unavailable("Background diagnostics require an isolated test copy")
                }
                try Data("passed".utf8).write(to: backgroundResult, options: .atomic)
            }
            print("queue_smoke_passed: manual inventory, 205-file JSON drain, receipt-image drain, restart count, automatic mode, retry backoff, CSV gating, separate import and suggestion actions, immediate account confirmation, deferred automatic resumption")
            exit(0)
        } catch { print("queue_smoke_failed: \(error.localizedDescription)"); exit(1) }
    }
    private static func captureReviewFlow(in directory: URL) async throws {
        let inbox = directory.appendingPathComponent("review-flow/inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let store = try LedgerStore(url: directory.appendingPathComponent("review-flow.sqlite"))
        try await store.addAccount(name: "Fictional review account", currency: "CAD")
        let accountID = try await store.snapshot().accounts[0].id
        let bookmark = try inbox.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let workspace = AppWorkspace()
        workspace.configureQueueSmoke(store: store, bookmark: bookmark, mode: .manual)
        // An unconfigured Council fails before loading any model or using a network.
        // That failure makes an attempted suggestion pass observable in this fixture.
        workspace.classifier.classifierProvider = "council"
        try writeCapture("first", to: inbox)
        await workspace.captureState.sync(scope: .captures)
        try check(workspace.captureState.reviews.count == 1 && workspace.transactionState.totalTransactions == 0, "Import did not request an account")
        try check(workspace.errorMessage == nil, "Import unexpectedly attempted classification")
        let first = workspace.captureState.reviews[0]
        workspace.captureState.assignAccount(first, accountID: accountID, remember: false)
        try await waitUntil { !workspace.saving }
        try check(workspace.transactionState.totalTransactions == 1 && workspace.transactionState.transactions.count == 1, "Account choice did not immediately refresh Transactions")
        try check(workspace.captureState.captureFeedback?.transactionID == workspace.transactionState.transactions[0].id.uuidString, "Account choice did not expose the saved transaction")
        try check(workspace.captureState.captureFeedback?.needsAttention == false && workspace.captureState.reviews.isEmpty, "Saved capture remained unresolved")
        try check(workspace.errorMessage == nil && workspace.captureState.unqueuedJobs == 1, "Manual account choice attempted classification")

        try writeCapture("second", to: inbox)
        await workspace.captureState.sync(scope: .suggestions)
        try check(workspace.errorMessage?.contains("Set up Council") == true, "Explicit suggestions did not reach the selected provider")
        try check(workspace.captureState.pendingCaptures == 1 && workspace.captureState.reviews.isEmpty, "Suggest categories imported a capture")
        try check(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("second.json").path), "Suggest categories consumed a capture file")
        try check(workspace.transactionState.totalTransactions == 1, "Suggestion failure removed a saved transaction")

        workspace.errorMessage = nil
        await workspace.captureState.sync(scope: .captures)
        try check(workspace.errorMessage == nil && workspace.captureState.reviews.count == 1, "Capture-only import ran inference")
        workspace.captureState.processingMode = .whileOpen
        workspace.captureState.assignAccount(workspace.captureState.reviews[0], accountID: accountID, remember: false)
        // There is no timer in this workspace: only the post-save wakeup can run.
        try await waitUntil { !workspace.saving && !workspace.captureState.processing && workspace.errorMessage != nil }
        try check(workspace.errorMessage?.contains("Set up Council") == true, "Automatic processing was lost during account confirmation")
        try check(workspace.transactionState.totalTransactions == 2 && workspace.captureState.reviews.isEmpty, "Classifier failure blocked account confirmation")

        // A queued automatic wakeup must honor a switch back to manual processing.
        workspace.errorMessage = nil
        try writeCapture("third", to: inbox)
        workspace.perform {
            await workspace.captureState.processIfAutomatic()
            workspace.captureState.processingMode = .manual
        }
        try await waitUntil { !workspace.saving }
        await Task.yield()
        try check(workspace.errorMessage == nil && workspace.transactionState.totalTransactions == 2, "Deferred work bypassed manual mode")
        try check(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("third.json").path), "Manual mode consumed a deferred capture")
        try check(try await store.integrityCheck(), "Review flow damaged the vault")
        workspace.captureState.processingMode = .whileOpen
        workspace.perform {
            await workspace.captureState.processIfAutomatic()
            await workspace.stop()
        }
        try await waitUntil { !workspace.saving }
        await Task.yield()
        try check(!workspace.ready && !workspace.captureState.processing && workspace.errorMessage == nil, "Deferred processing outlived the open vault")
        try check(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("third.json").path), "Closing the vault consumed deferred work")
    }
    private static func writeCapture(_ id: String, to inbox: URL) throws {
        let payload: [String: Any] = ["schema_version": 2, "event_id": id, "source": "wallet_transaction",
            "captured_at": "2026-10-17T10:00:00-04:00", "input_shape": "wallet_transaction_fields",
            "merchant": "FICTIONAL REVIEW CAFE", "amount": "CAD 12.50", "card_or_pass": "Fictional card"]
        let url = inbox.appendingPathComponent(id + ".json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: url.path)
    }
    private static func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LedgerError.invalid("Timed out waiting for the capture review flow")
    }
    private static var backgroundResult: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("groundkeeper-queue-smoke-result.txt")
    }
    static func backgroundRegistration() async {
        // This path is available only in a disposable copy with a separate container
        // and launchd label. It never registers or unregisters the user's real agent.
        guard Bundle.main.bundleIdentifier == "com.groundkeeper.macos.queue-smoke" else { exit(2) }
        let service = QueueBackgroundService.service
        var passed = false
        do {
            try FileManager.default.createDirectory(at: backgroundResult.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: backgroundResult)
            try service.register()
            print("background_registration_status=\(service.status.rawValue)")
            for _ in 0..<120 {
                if (try? String(contentsOf: backgroundResult, encoding: .utf8)) == "passed" { passed = true; break }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch { print("background_smoke_error: \(error.localizedDescription)") }
        do { try await service.unregister() }
        catch { print("background_smoke_cleanup_failed: \(error.localizedDescription)"); exit(1) }
        try? FileManager.default.removeItem(at: backgroundResult)
        print(passed ? "background_smoke_passed: launchd started the sandboxed app and processed the fictional queue" : "background_smoke_failed: agent did not finish; check Login Items approval and system logs")
        exit(passed ? 0 : 1)
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw LedgerError.invalid(message) }
    }
}
