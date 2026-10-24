import Foundation
import GroundKeeperCore

enum VaultAccess {
    static func root() throws -> URL {
        if CommandLine.arguments.contains("--setup-preview") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("GroundKeeper-Setup-Preview-\(AppPreferences.previewSessionID)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("GroundKeeper", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    static var isEncrypted: Bool {
        guard let url = try? root().appendingPathComponent("vault.sqlite"),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let file = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 16) else { return true }
        return !header.isEmpty && !header.starts(with: Data("SQLite format 3\0".utf8))
    }
    static func open(passphrase: String? = nil) throws -> (LedgerStore, URL) {
        let url = try root().appendingPathComponent("vault.sqlite")
        return (try LedgerStore(url: url, passphrase: passphrase), url)
    }
}

actor CaptureFolder {
    struct Entry: Sendable { let path: String; let data: Data }
    struct Scan: Sendable { let files: [Entry]; let waiting: Int; let pending: Int }
    private var hashes: [String: (fingerprint: String, hash: String)] = [:]
    func reset() { hashes.removeAll() }
    /// Inventory is read-only. Only an explicit processing pass requests iCloud downloads.
    func scan(bookmark: Data, store: LedgerStore, readFiles: Bool, exactFolder: Bool = false) async throws -> Scan {
        var stale = false
        let root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        guard !stale, root.startAccessingSecurityScopedResource() else { throw LedgerError.unavailable("Reconnect the capture folder to renew access.") }
        defer { root.stopAccessingSecurityScopedResource() }
        let inbox = exactFolder || root.lastPathComponent == "inbox" ? root : root.appendingPathComponent("inbox", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
        let urls = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: Array(keys), options: [])
            .filter { (!$0.lastPathComponent.hasPrefix(".") && $0.pathExtension.lowercased() == "json") || ($0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent.lowercased().hasSuffix(".json.icloud")) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let states = try await store.captureDeliveryStates()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var files: [Entry] = [], waiting = 0, pending = 0
        for url in urls {
            try Task.checkCancellation()
            if url.lastPathComponent.hasPrefix(".") && url.lastPathComponent.lowercased().hasSuffix(".json.icloud") {
                let originalName = String(url.lastPathComponent.dropFirst().dropLast(".icloud".count))
                if readFiles { try? FileManager.default.startDownloadingUbiquitousItem(at: inbox.appendingPathComponent(originalName)) }
                waiting += 1; pending += 1; continue
            }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            if let download = values.ubiquitousItemDownloadingStatus, download != .current {
                if readFiles { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
                waiting += 1; pending += 1; continue
            }
            guard let modified = values.contentModificationDate, Date().timeIntervalSince(modified) >= 2 else { waiting += 1; pending += 1; continue }
            let fingerprint = "\(modified.timeIntervalSince1970):\(values.fileSize ?? 0)"
            let path = url.lastPathComponent
            var data: Data?
            var hash = hashes[path].flatMap { $0.fingerprint == fingerprint ? $0.hash : nil }
            if hash == nil {
                data = try? read(url)
                guard let data else { waiting += 1; pending += 1; continue }
                hash = contentHash(data); hashes[path] = (fingerprint, hash!)
            }
            let id = contentHash(Data("\(path)|\(hash!)".utf8))
            if states[id]?.terminal == true { continue }
            pending += 1
            guard readFiles, files.count < 200, (states[id]?.nextAttemptMS ?? 0) <= now else { continue }
            if data == nil { data = try? read(url) }
            if let data { files.append(Entry(path: path, data: data)) } else { waiting += 1 }
        }
        let present = Set(urls.map(\.lastPathComponent))
        hashes = hashes.filter { present.contains($0.key) }
        return Scan(files: files, waiting: waiting, pending: pending)
    }
    private func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?, result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result {
                let handle = try FileHandle(forReadingFrom: coordinated); defer { try? handle.close() }
                return try handle.read(upToCount: 65_537) ?? Data()
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw LedgerError.unavailable("Capture file could not be read.") }
        return try result.get()
    }
    /// Read only explicitly referenced assets inside the same user-granted inbox.
    func importReceiptImages(bookmark: Data, store: LedgerStore, exactFolder: Bool) async throws {
        var stale = false
        let root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        guard !stale, root.startAccessingSecurityScopedResource() else { throw LedgerError.unavailable("Reconnect the capture folder.") }
        defer { root.stopAccessingSecurityScopedResource() }
        let inbox = (exactFolder || root.lastPathComponent == "inbox" ? root : root.appendingPathComponent("inbox")).resolvingSymlinksInPath()
        for image in try await store.receiptImageRequests() {
            try Task.checkCancellation()
            let url = inbox.appendingPathComponent(image.path)
            guard url.resolvingSymlinksInPath().path.hasPrefix(inbox.path + "/"),
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                try await store.markReceiptImageInvalid(id: image.id); continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey]) else { continue }
            if let status = values.ubiquitousItemDownloadingStatus, status != .current {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url); continue
            }
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 8_388_608 else {
                try await store.markReceiptImageInvalid(id: image.id); continue
            }
            var error: NSError?, data: Data?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
                if let handle = try? FileHandle(forReadingFrom: coordinated) {
                    defer { try? handle.close() }
                    data = try? handle.read(upToCount: 8_388_609)
                }
            }
            guard error == nil, let data else { continue }
            do {
                try await store.storeReceiptImage(id: image.id, data: data)
                if try await store.receiptNeedsOCR(id: image.id), let result = try? await ReceiptOCR.recognize(data) {
                    try await store.addReceiptOCR(id: image.id, text: result.text, producer: result.producer)
                }
            }
            catch LedgerError.invalid { try await store.markReceiptImageInvalid(id: image.id) }
        }
    }
}
