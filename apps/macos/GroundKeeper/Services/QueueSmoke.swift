import Foundation
import ServiceManagement
import GroundKeeperCore

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
            let bookmark = try inbox.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            let workspace = AppWorkspace()
            workspace.configureQueueSmoke(store: store, bookmark: bookmark, mode: .manual)
            if !QueueBackgroundService.isSupported {
                workspace.changeProcessingMode(.background)
                try check(workspace.processingMode == .manual && workspace.errorMessage != nil, "Unavailable background mode changed preferences")
                workspace.errorMessage = nil
                print("adhoc_background_gate_verified")
            }
            await workspace.processIfAutomatic()
            try check(workspace.countError == nil, workspace.countError ?? "inventory error")
            try check(workspace.queueCount == 205, "Inventory must include files beyond the 200-file batch")
            try check(try await store.snapshot().queue.isEmpty, "Manual inventory ingested files")
            await workspace.sync(automatic: true)
            try check(try await store.snapshot().queue.isEmpty, "Automatic call bypassed manual mode")
            await workspace.sync()
            try check(workspace.queueCount == 0, "Manual processing did not drain the backlog")
            try check(try await store.captureDeliveryStates().count == 205, "Not all captures were processed")
            try check(try await store.snapshot().transactions.isEmpty, "Test captures created transactions")
            let fresh = CaptureFolder()
            let inventory = try await fresh.scan(bookmark: bookmark, store: store, readFiles: false)
            try check(inventory.pending == 0, "Restart inventory counted completed files")
            let malformed = inbox.appendingPathComponent("malformed.json")
            try Data("broken".utf8).write(to: malformed)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: malformed.path)
            workspace.processingMode = .whileOpen
            await workspace.processIfAutomatic()
            try check(try await store.snapshot().queue.contains { $0.path == "malformed.json" && $0.attempts == 1 }, "While-open mode did not process")
            await workspace.sync()
            try check(try await store.snapshot().queue.first { $0.path == "malformed.json" }?.attempts == 1, "Backoff was bypassed")
            workspace.processingMode = .manual
            try await store.addAccount(name: "Fictional account", currency: "CAD")
            var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
            let document = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-17,FICTIONAL CAFE,-12.50\n".utf8), filename: "fixture.csv")
            _ = try await workspace.importCSV(document, mapping: mapping, skipped: [])
            await workspace.processIfAutomatic()
            try check(workspace.pendingJobs == 0 && workspace.unqueuedJobs == 1 && workspace.model == nil, "CSV import bypassed manual classification mode")
            try check(try await store.integrityCheck(), "Integrity check failed")
            await workspace.stop()
            if CommandLine.arguments.contains("--background-smoke-agent") {
                guard Bundle.main.bundleIdentifier == "com.groundkeeper.macos.queue-smoke" else {
                    throw LedgerError.unavailable("Background diagnostics require an isolated test copy")
                }
                try Data("passed".utf8).write(to: backgroundResult, options: .atomic)
            }
            print("queue_smoke_passed: manual inventory, 205-file drain, restart count, automatic mode, retry backoff, CSV gating")
            exit(0)
        } catch { print("queue_smoke_failed: \(error.localizedDescription)"); exit(1) }
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
