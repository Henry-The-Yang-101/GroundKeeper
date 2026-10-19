import Foundation
import CryptoKit

/// Bounded-memory verification for the release catalog's pinned archive parts.
public enum ModelInstallFiles {
    public static func appendVerifiedPart(_ source: URL, to output: FileHandle, expectedBytes: Int64, sha256: String) throws {
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let start = try output.offset()
        do {
            var digest = SHA256(), count: Int64 = 0
            while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation()
                count += Int64(bytes.count)
                guard count <= expectedBytes else { throw LedgerError.invalid("Model download exceeded its expected size.") }
                digest.update(data: bytes); try output.write(contentsOf: bytes)
            }
            guard count == expectedBytes, digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
                throw LedgerError.invalid("A model download failed its integrity check. Nothing was installed; retry the download.")
            }
        } catch {
            try? output.truncate(atOffset: start); try? output.seek(toOffset: start)
            throw error
        }
    }
}
