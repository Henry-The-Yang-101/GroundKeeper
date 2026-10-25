import AppKit
import Foundation
import GroundKeeperCore

extension AppWorkspace {
    var councilReadyToConfigure: Bool { councilQwenURL != nil && councilLayaURL != nil && !shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func restoreCouncilPackages() {
        councilQwenURL = Self.councilPackage("qwen_mlx")
        councilLayaURL = Self.councilPackage("laya_mps")
    }
    private static func councilPackage(_ backend: String) -> URL? {
        guard let bookmark = AppPreferences.defaults.data(forKey: "councilPackage.\(backend)") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale), !stale else { return nil }
        return url
    }
    func chooseCouncilPackage(_ backend: String) {
        guard !processing, !saving else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose the \(backend == "qwen_mlx" ? "Qwen" : "Laya") package for Council. Enable Council to apply this selection."
        if panel.runModal() == .OK, let url = panel.url { setCouncilPackage(url, backend: backend) }
    }
    func setCouncilPackage(_ url: URL, backend: String) {
        guard !processing, !saving, ["qwen_mlx", "laya_mps"].contains(backend) else { return }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("classifier.json"))) as? [String: Any]
            guard manifest?["backend"] as? String == backend else { throw LedgerError.invalid("Choose a \(backend == "qwen_mlx" ? "Qwen" : "Laya") package.") }
            // Draft package choices do not change the active Council configuration.
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            AppPreferences.defaults.set(bookmark, forKey: "councilPackage.\(backend)")
            if backend == "qwen_mlx" { councilQwenURL = url } else { councilLayaURL = url }
        } catch { errorMessage = error.localizedDescription }
    }
    func useCouncil() {
        guard !processing, !saving, councilReadyToConfigure else { return }
        perform {
            guard let store = self.store, let qwen = self.councilQwenURL, let laya = self.councilLayaURL else { return }
            let shortcut = self.shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
            let previousStatus = self.classifierStatus
            var activated = false
            self.model = nil
            var members: [CouncilMember] = []
            defer { self.model = nil; if !activated { self.classifierStatus = previousStatus } }
            for (backend, url) in [("qwen_mlx", qwen), ("laya_mps", laya)] {
                self.classifierStatus = "Council · verifying \(backend == "qwen_mlx" ? "Qwen" : "Laya")…"
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let loaded = try await self.client.prepareModel(at: url)
                guard loaded.backend == backend else { throw LedgerError.invalid("Council package backend does not match.") }
                try await store.registerModel(id: loaded.manifestSHA256, name: loaded.modelID, backend: loaded.backend,
                    policy: loaded.policyVersion, configuration: String(decoding: JSONEncoder().encode(loaded), as: UTF8.self), select: false)
                members.append(CouncilMember(id: loaded.manifestSHA256, name: loaded.modelID, backend: backend))
            }
            self.classifierStatus = "Council · verifying Apple Intelligence Shortcut…"
            let apple = try await self.client.prepareShortcut(name: shortcut)
            try await store.registerModel(id: apple.manifestSHA256, name: apple.modelID, backend: apple.backend,
                policy: apple.policyVersion, configuration: String(decoding: JSONEncoder().encode(apple), as: UTF8.self), select: false)
            members.append(CouncilMember(id: apple.manifestSHA256, name: apple.modelID, backend: apple.backend))
            let configuration = try CouncilConfiguration(members: members)
            try await store.registerCouncil(configuration)
            // Keep the active package bookmarks separate from editable setup choices.
            for backend in ["qwen_mlx", "laya_mps"] {
                AppPreferences.defaults.set(AppPreferences.defaults.data(forKey: "councilPackage.\(backend)"), forKey: "activeCouncilPackage.\(backend)")
            }
            activated = true
            self.councilConfiguration = configuration; self.classifierProvider = "council"
            AppPreferences.defaults.set("council", forKey: "classifierProvider")
            AppPreferences.defaults.set(shortcut, forKey: "activeCouncilShortcut")
            self.shortcutName = shortcut
            self.classifierStatus = "Council · Qwen, Laya and Apple Intelligence · equal votes"
            await self.processIfAutomatic()
        }
    }
    func classifyCouncilPending() async throws {
        guard !classifying, let store else { return }
        guard let configuration = try await store.selectedCouncil() else { throw LedgerError.unavailable("Set up Council in Categorization settings.") }
        classifying = true; defer { classifying = false }
        councilConfiguration = configuration
        var packages: [String: URL] = [:]
        for backend in ["qwen_mlx", "laya_mps"] {
            if let bookmark = AppPreferences.defaults.data(forKey: "activeCouncilPackage.\(backend)") {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale), !stale { packages[backend] = url }
            }
        }
        let engine = CouncilClassifierEngine(client: client, packages: packages,
            shortcut: AppPreferences.defaults.string(forKey: "activeCouncilShortcut") ?? "GK Categorize Cloud")
        try await store.enqueueCouncil(configID: configuration.id)
        var remaining = try await store.snapshot(limit: 1).pendingJobs
        do {
            while remaining > 0 {
                try Task.checkCancellation()
                let processed = try await CouncilRunner.runBatch(store: store, configuration: configuration, engine: engine, limit: min(remaining, 8), search: { task in
                    _ = try await self.merchantContext(for: task, store: store)
                }, stage: { message in await MainActor.run { self.classifierStatus = message } })
                if processed == 0 { break }
                remaining -= processed
                try await refresh()
            }
        } catch { await releaseClassifierResources(); throw error }
        await releaseClassifierResources()
        try await refresh()
    }
    func councilReport(transactionID: String) async throws -> CouncilReport? { try await store?.councilReport(transactionID: transactionID) }
}
