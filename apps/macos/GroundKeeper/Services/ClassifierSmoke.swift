import AppKit
import Foundation
import GroundKeeperCore

/// End-to-end smoke mode for the actual signed app/XPC pair, not a development
/// interpreter. Invoke the app executable with --classifier-smoke.
@MainActor enum ClassifierSmoke {
    static func run() async {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300) {
            FileHandle.standardError.write(Data("Classifier smoke process deadline exceeded\n".utf8))
            exit(124)
        }
        let client = ClassifierClient()
        do {
            if let index = CommandLine.arguments.firstIndex(of: "--classifier-draft-smoke") {
                guard AppPreferences.isSetupPreview, CommandLine.arguments.indices.contains(index + 1) else {
                    throw LedgerError.invalid("Draft smoke requires --setup-preview and an existing sandbox-readable model package path.")
                }
                var package = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
                if CommandLine.arguments.contains("--classifier-saved-model-smoke") {
                    // Read only the existing package grant. All test preferences and
                    // transactions still belong to the disposable preview workspace.
                    guard let bookmark = UserDefaults.standard.data(forKey: "classifierModelBookmark") else {
                        throw LedgerError.unavailable("No saved local model package; use the package picker.")
                    }
                    var stale = false
                    package = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                    guard !stale else { throw LedgerError.unavailable("Saved model grant is stale; use the package picker.") }
                }
                let access = package.startAccessingSecurityScopedResource()
                defer { if access { package.stopAccessingSecurityScopedResource() } }
                if CommandLine.arguments.contains("--classifier-model-picker") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
                    panel.directoryURL = package.deletingLastPathComponent()
                    panel.message = "Choose the existing local package for the fictional draft suggestion test."
                    guard await panel.begin() == .OK, let selected = panel.url else { throw CancellationError() }
                    package = selected
                }
                try await verifyDraftSuggestions(package: package)
                write(["event": "draft_suggestion_smoke_passed", "checks": "new_draft, existing_edit, no_ledger_mutation, worker_released"])
                exit(0)
            }
            try await verifyConnectionBoundary()
            let handshake = try await client.handshake()
            try await client.verifyProtocolErrors()
            let search = MerchantSearchClient()
            try await search.handshake()
            write(["event": "merchant_search_runtime_verified"])
            if CommandLine.arguments.contains("--merchant-search-live-smoke") {
                let query = MerchantSearchQuery.make(merchant: "Staples", description: "Staples", locality: "Waterloo Ontario")!
                let evidence = try await search.search(query)
                write(["event": "merchant_search_live", "outcome": evidence.outcome, "sources": evidence.context?.results.count ?? 0, "diagnostic": evidence.diagnostic ?? "none"])
                guard evidence.outcome == "matched" else { throw ClassifierBridgeError.unavailable }
            }
            await search.shutdown()
            if CommandLine.arguments.contains("--classifier-lifecycle-smoke") {
                let firstPID = await client.processIdentifier
                _ = try await client.probeGPU()
                await client.shutdown()
                try await Task.sleep(for: .seconds(2))
                let fresh = try await client.handshake()
                let secondPID = await client.processIdentifier
                guard let firstPID, let secondPID, firstPID > 0, secondPID > 0,
                      firstPID != secondPID, fresh.loadedModel == nil else { throw ClassifierBridgeError.invalidResponse }
                await client.shutdown()
                write(["event": "lifecycle_smoke_passed", "previous_pid": firstPID, "fresh_pid": secondPID])
                exit(0)
            }
            if CommandLine.arguments.contains("--classifier-connection-smoke") {
                write(["event": "connection_smoke_passed", "runtime": handshake.runtime ?? [:]])
                exit(0)
            }
            let cancelled = Task { try await client.probeGPU() }
            cancelled.cancel()
            do { _ = try await cancelled.value; throw ClassifierBridgeError.invalidResponse }
            catch is CancellationError { write(["event": "cancellation_verified"]) }
            let probe = try await client.probeGPU()
            guard probe.mlx?.value == 32, probe.laya?.value == 32 else { throw ClassifierBridgeError.invalidResponse }
            write(["event": "gpu_verified", "runtime": handshake.runtime ?? [:],
                   "mlx_device": probe.mlx?.device ?? "", "torch_device": probe.laya?.device ?? ""])
            if CommandLine.arguments.contains("--shortcut-smoke") {
                let model = try await client.prepareShortcut(name: "GK Categorize Cloud")
                let result = try await client.classify(ClassifierInput(description: "TIM HORTONS", direction: "debit", currency: "CAD"),
                    model: model, partID: "synthetic-shortcut", revision: 1, jobID: "synthetic-shortcut")
                write(["event": "shortcut_verified", "type": result.decision?.type ?? "", "category": result.decision?.category ?? "none"])
                try await client.releaseModel()
            }
            if let index = CommandLine.arguments.firstIndex(of: "--classifier-model-picker"),
               CommandLine.arguments.indices.contains(index + 1) {
                let url = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
                let panel = NSOpenPanel()
                panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
                panel.directoryURL = url.deletingLastPathComponent()
                panel.message = "Select the model package for this fictional-transaction test: \(url.lastPathComponent)"
                guard panel.runModal() == .OK, let selected = panel.url else { throw CancellationError() }
                var package = selected
                var ownedRoot: URL?
                if CommandLine.arguments.contains("--classifier-installed-model-smoke") {
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("installed-model-smoke-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    package = root.appendingPathComponent(selected.lastPathComponent)
                    try FileManager.default.copyItem(at: selected, to: package)
                    ownedRoot = root
                }
                defer { if let ownedRoot { try? FileManager.default.removeItem(at: ownedRoot) } }
                do {
                    _ = try await client.prepareModel(at: package, timeoutMS: 100)
                    throw ClassifierBridgeError.invalidResponse
                } catch ClassifierBridgeError.worker(let code, _) {
                    guard code == "deadline_exceeded" else { throw ClassifierBridgeError.worker(code, "Deadline smoke check failed") }
                    write(["event": "deadline_verified"])
                }
                let start = Date()
                let model = try await client.prepareModel(at: package)
                write(["event": "model_loaded", "model_id": model.modelID, "device": model.device,
                       "load_seconds": Date().timeIntervalSince(start)])
                for iteration in 0..<3 {
                    let start = Date()
                    let result = try await client.classify(ClassifierInput(description: "TIM HORTONS", direction: "debit", currency: "CAD"),
                        model: model, partID: "smoke-part", revision: 1, jobID: "smoke-\(iteration)")
                    write(["event": "classified", "iteration": iteration, "seconds": Date().timeIntervalSince(start),
                           "type": result.decision?.type ?? "", "category": result.decision?.category ?? "none",
                           "review": result.decision?.review ?? false])
                }
                try await client.releaseModel()
                if ownedRoot != nil {
                    // Match the saved selection used after closing provider setup
                    // and after the XPC process is recreated.
                    let bookmark = try package.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                    await client.shutdown()
                    var stale = false
                    let restored = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                    guard !stale else { throw ClassifierBridgeError.invalidResponse }
                    let access = restored.startAccessingSecurityScopedResource()
                    defer { if access { restored.stopAccessingSecurityScopedResource() } }
                    let reloaded = try await client.prepareModel(at: restored)
                    guard reloaded == model else { throw ClassifierBridgeError.invalidResponse }
                    _ = try await client.classify(ClassifierInput(description: "FICTIONAL CAFE", direction: "debit", currency: "CAD"), model: reloaded, partID: "owned-package-reload", revision: 1)
                    try await client.releaseModel()
                    write(["event": "installed_model_reload_verified"])
                }
                write(["event": "model_released"])
            }
            write(["event": "smoke_passed"])
            exit(0)
        } catch {
            write(["event": "smoke_failed", "error": error.localizedDescription])
            exit(1)
        }
    }
    private static func verifyDraftSuggestions(package: URL) async throws {
        let workspace = AppWorkspace()
        await workspace.start()
        workspace.processingMode = .manual
        guard let store = workspace.store else { throw LedgerError.unavailable("Preview vault did not open.") }
        workspace.useInstalledModel(package)
        while workspace.saving { try await Task.sleep(for: .milliseconds(50)) }
        guard workspace.errorMessage == nil, workspace.classifierProvider == "local" else {
            throw LedgerError.invalid(workspace.errorMessage ?? "Local provider setup failed.")
        }
        try await store.addAccount(name: "Fictional draft test", currency: "CAD")
        let account = try await store.snapshot().accounts[0].id
        try await store.save(TransactionEdit(description: "FICTIONAL CAFE", amountMinor: -1250, currency: "CAD",
            occurredOn: "2026-10-01", accountID: account, type: "expense", category: nil, needsReview: true, notes: ""))
        let saved = try await store.snapshot().transactions[0]
        var edit = Transaction(saved)
        edit.notes = "Fictional lunch"
        try await store.save(edit.edit)
        let before = try await store.snapshot().transactions[0]
        var newDraft = Transaction()
        newDraft.merchant = "FICTIONAL CAFE coffee and sandwich"
        for draft in [newDraft, Transaction(before)] {
            let suggestion = try await workspace.suggestCategory(for: draft)
            try suggestion.decision.validateSuggestion()
            let after = try await store.snapshot()
            guard after.transactions.count == 1, after.transactions[0].revision == before.revision,
                  after.transactions[0].category == before.category,
                  !workspace.processing, workspace.model == nil else {
                throw LedgerError.invalid("Suggestion changed the ledger or retained classifier resources.")
            }
            write(["event": "draft_suggestion_verified", "draft_revision": draft.revision, "type": suggestion.decision.type,
                   "category": suggestion.decision.category ?? "none"])
        }
        await workspace.stop()
    }

    private static func verifyConnectionBoundary() async throws {
        func connection() -> NSXPCConnection {
            let value = NSXPCConnection(serviceName: "com.groundkeeper.macos.classifier")
            value.remoteObjectInterface = NSXPCInterface(with: ClassifierXPCService.self)
            value.activate()
            return value
        }
        func rejected(_ connection: NSXPCConnection, nonce: String) async throws {
            let data = try JSONSerialization.data(withJSONObject: ["protocol_version": 1,
                "request_id": UUID().uuidString, "operation": "handshake", "connection_nonce": nonce])
            let response: Data = try await withCheckedThrowingContinuation { continuation in
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in continuation.resume(throwing: error) } as! ClassifierXPCService
                proxy.request(data) { continuation.resume(returning: $0) }
            }
            let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
            guard (object?["error"] as? [String: Any])?["code"] as? String == "unauthorized" else {
                throw ClassifierBridgeError.invalidResponse
            }
        }
        let first = connection(), second = connection()
        defer { first.invalidate(); second.invalidate() }
        try await rejected(first, nonce: "guessed-before-authorization")
        let bookmark = try Bundle.main.bundleURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let nonce: String? = try await withCheckedThrowingContinuation { continuation in
            let proxy = first.remoteObjectProxyWithErrorHandler { error in continuation.resume(throwing: error) } as! ClassifierXPCService
            proxy.authorizeHost(bookmark) { continuation.resume(returning: $0) }
        }
        guard let nonce else { throw ClassifierBridgeError.unavailable }
        try await rejected(first, nonce: "wrong-after-authorization")
        try await rejected(second, nonce: nonce)
        write(["event": "connection_boundary_verified"])
    }
    private static func write(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }
}
