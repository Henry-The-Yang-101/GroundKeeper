import Foundation
import GroundKeeperCore

enum VaultAccess {
    static func open() throws -> (LedgerStore, URL) {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("GroundKeeper", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("vault.sqlite")
        return (try LedgerStore(url: url), url)
    }
}

actor CaptureFolder {
    struct Entry: Sendable { let path: String, fingerprint: String; let data: Data }
    struct Scan: Sendable { let files: [Entry]; let waiting: Int }
    private var completed: [String: String] = [:]
    func acknowledge(_ entry: Entry) { completed[entry.path] = entry.fingerprint }
    func reset() { completed.removeAll() }
    func scan(bookmark: Data) throws -> Scan {
        var stale = false
        let root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        guard !stale, root.startAccessingSecurityScopedResource() else { throw LedgerError.unavailable("Reconnect the capture folder to renew access.") }
        defer { root.stopAccessingSecurityScopedResource() }
        let inbox = root.lastPathComponent == "inbox" ? root : root.appendingPathComponent("inbox", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
        let urls = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var files: [Entry] = [], waiting = 0
        for url in urls {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            if let download = values.ubiquitousItemDownloadingStatus, download != .current {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url); waiting += 1; continue
            }
            guard let modified = values.contentModificationDate, Date().timeIntervalSince(modified) >= 2 else { waiting += 1; continue }
            let fingerprint = "\(modified.timeIntervalSince1970):\(values.fileSize ?? 0)"
            if completed[url.lastPathComponent] == fingerprint { continue }
            if files.count >= 200 { waiting += 1; continue }
            var coordinationError: NSError?, readError: Error?, data: Data?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                do {
                    let handle = try FileHandle(forReadingFrom: coordinated); defer { try? handle.close() }
                    data = try handle.read(upToCount: 65_537) ?? Data()
                } catch { readError = error }
            }
            if coordinationError != nil || readError != nil { waiting += 1; continue }
            if let data { files.append(Entry(path: url.lastPathComponent, fingerprint: fingerprint, data: data)) }
        }
        return Scan(files: files, waiting: waiting)
    }
}
