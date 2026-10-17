#if DEBUG
import Foundation
import GroundKeeperCore

/// Exercises app scheduling and scanner inventory against fictional files and a temporary vault.
@MainActor enum QueueSmoke {
    static func run() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { exit(124) }
        do {
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
            print("queue_smoke_passed: manual inventory, 205-file drain, restart count, automatic mode, retry backoff, CSV gating")
            exit(0)
        } catch { print("queue_smoke_failed: \(error.localizedDescription)"); exit(1) }
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw LedgerError.invalid(message) }
    }
}
#endif
