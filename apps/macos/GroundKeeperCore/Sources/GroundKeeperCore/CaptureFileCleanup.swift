import Foundation

public struct CaptureFileCleanup: Sendable {
    public let id: String, path: String, sha256: String, kind: String
}
extension LedgerStore {
    static func prepareFileCleanups(db: Database) throws {
        // Imported JSON has a committed immutable payload (including receipts and test captures).
        // Quarantined/conflicting/invalid deliveries are never removed.
        try db.query("""
            INSERT OR IGNORE INTO capture_file_cleanups(id,relative_path,content_sha256,kind)
            SELECT 'json:' || id,relative_path,content_sha256,'json' FROM queue_items WHERE state='imported'
            """)
        try db.query("""
            INSERT OR IGNORE INTO capture_file_cleanups(id,relative_path,content_sha256,kind)
            SELECT 'image:' || r.id,r.image_path,i.content_sha256,'image'
            FROM receipt_captures r JOIN receipt_images i ON i.receipt_id=r.id
            WHERE r.image_path IS NOT NULL AND r.image_state='stored'
            """)
    }
    public func pendingFileCleanups() throws -> [CaptureFileCleanup] {
        try Self.prepareFileCleanups(db: db)
        return try db.query("""
            SELECT c.* FROM capture_file_cleanups c WHERE c.completed_at_ms IS NULL
              AND (c.kind='json' OR NOT EXISTS(SELECT 1 FROM receipt_captures r
                WHERE r.image_path=c.relative_path AND r.image_state='pending'))
            ORDER BY c.kind,c.id
            """).map { CaptureFileCleanup(id: $0.text("id"), path: $0.text("relative_path"), sha256: $0.text("content_sha256"), kind: $0.text("kind")) }
    }
    public func completeFileCleanup(id: String) throws {
        try db.query("UPDATE capture_file_cleanups SET completed_at_ms=?,error_code=NULL WHERE id=?", [.integer(nowMS()), .text(id)])
    }
    public func failFileCleanup(id: String, changed: Bool = false) throws {
        try db.query("UPDATE capture_file_cleanups SET error_code=?,completed_at_ms=? WHERE id=?",
                     [.text(changed ? "file_changed" : "reconnect_folder_for_cleanup"), changed ? .integer(nowMS()) : .null, .text(id)])
    }
}

/// Coordinates hash verification and deletion as one file operation. Only queued
/// copies whose contents were committed to the vault may enter this API.
public enum CaptureQueueFileCleaner {
    public static func removeStoredCopy(_ request: CaptureFileCleanup, inbox: URL) throws -> Bool {
        let valid = request.kind == "json"
            ? request.path.range(of: "^[^/\\\\]+\\.json$", options: [.regularExpression, .caseInsensitive]) != nil && !request.path.hasPrefix(".")
            : request.path.range(of: "^assets/[A-Za-z0-9_-]{1,128}\\.(jpg|jpeg|png|heic)$", options: .regularExpression) != nil
        guard valid else { throw LedgerError.invalid("Unsafe queued file path.") }
        let root = inbox.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(request.path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), file.resolvingSymlinksInPath().path == file.path else {
            throw LedgerError.invalid("Queued file is a symbolic link.")
        }
        var coordinationError: NSError?, result: Result<Bool, Error>?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: &coordinationError) { url in
            result = Result {
                guard FileManager.default.fileExists(atPath: url.path) else { return true }
                let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                      url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
                    throw LedgerError.invalid("Queued file is not a regular file.")
                }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: request.kind == "image" ? 8_388_609 : 65_537) ?? Data()
                guard contentHash(data) == request.sha256 else { return false }
                try FileManager.default.removeItem(at: url)
                return true
            }
        }
        if let coordinationError {
            // A crash after deletion but before acknowledgement is safe to retry.
            if (coordinationError as NSError).code == NSFileNoSuchFileError && !FileManager.default.fileExists(atPath: file.path) { return true }
            throw coordinationError
        }
        guard let result else { throw LedgerError.unavailable("Could not coordinate queue cleanup.") }
        return try result.get()
    }
}
