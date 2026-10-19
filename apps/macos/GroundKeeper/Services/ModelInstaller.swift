import Foundation
import Darwin
import Observation
import GroundKeeperCore

struct ModelCatalog: Decodable, Sendable {
    struct Model: Decodable, Identifiable, Sendable {
        struct Part: Decodable, Sendable { let name: String; let bytes: Int64; let sha256: String }
        let directory: String
        let model_id: String
        let manifest_sha256: String
        let parts: [Part]
        var id: String { directory }
        var title: String { directory == "laya" ? "Laya" : "Qwen" }
        var downloadBytes: Int64 { parts.reduce(0) { $0 + $1.bytes } }
    }
    let release_tag: String
    let models: [Model]
    static func bundled() throws -> Self {
        guard let root = Bundle.main.resourceURL else { throw LedgerError.unavailable("Setup resources are missing.") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("Setup/models.json")))
    }
}

@MainActor @Observable final class ModelInstaller {
    var busy = false
    var status = "Models are optional. You can install either or both."
    var installed: [String: URL] = [:]
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    func discover() {
        guard let catalog = try? ModelCatalog.bundled(), let root = try? VaultAccess.root() else { return }
        for model in catalog.models {
            let url = root.appendingPathComponent("Models/\(catalog.release_tag)/\(model.directory)")
            if let data = try? Data(contentsOf: url.appendingPathComponent("classifier.json")), contentHash(data) == model.manifest_sha256 {
                installed[model.id] = url
            }
        }
    }
    func cancel() { task?.cancel() }
    func install(_ models: [ModelCatalog.Model]) {
        guard !busy, !models.isEmpty else { return }; busy = true; error = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                let catalog = try ModelCatalog.bundled()
                let root = try VaultAccess.root().appendingPathComponent("Models/\(catalog.release_tag)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let lock = Darwin.open(root.appendingPathComponent(".installer.lock").path, O_CREAT | O_RDWR, 0o600)
                guard lock >= 0 else { throw LedgerError.unavailable("Could not prepare model installation.") }
                defer { flock(lock, LOCK_UN); Darwin.close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw LedgerError.unavailable("Another model installation is in progress.") }
                if let notices = Bundle.main.resourceURL?.appendingPathComponent("Setup/MODEL-NOTICES.txt") {
                    try Data(contentsOf: notices).write(to: root.appendingPathComponent("MODEL-NOTICES.txt"), options: .atomic)
                }
                // A prior app termination can leave only disposable staging directories here.
                for old in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where old.lastPathComponent.hasPrefix(".install-") {
                    try FileManager.default.removeItem(at: old)
                }
                for model in models {
                    try Task.checkCancellation()
                    let destination = root.appendingPathComponent(model.directory)
                    guard !FileManager.default.fileExists(atPath: destination.path) else {
                        throw LedgerError.unavailable("\(model.title) already exists. Choose the installed package, or move an incomplete folder aside in Finder before retrying.")
                    }
                    let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                    guard available > model.downloadBytes * 2 + 3_000_000_000 else { throw LedgerError.unavailable("Free at least 8 GB of disk space before installing this model.") }
                    let staging = root.appendingPathComponent(".install-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let archive = staging.appendingPathComponent("model.tar.gz")
                    FileManager.default.createFile(atPath: archive.path, contents: nil)
                    let output = try FileHandle(forWritingTo: archive)
                    defer { try? output.close() }
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 60
                    configuration.timeoutIntervalForResource = 3600
                    let session = URLSession(configuration: configuration)
                    defer { session.invalidateAndCancel() }
                    for (index, part) in model.parts.enumerated() {
                        status = "Downloading \(model.title) · part \(index + 1) of \(model.parts.count) (\(ByteCountFormatter.string(fromByteCount: part.bytes, countStyle: .file)))"
                        let url = URL(string: "https://github.com/Henry-The-Yang-101/GroundKeeper/releases/download/\(catalog.release_tag)/\(part.name)")!
                        let (temporary, response) = try await session.download(from: url)
                        defer { try? FileManager.default.removeItem(at: temporary) }
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LedgerError.unavailable("The model download is unavailable. Check your connection and retry.") }
                        status = "Verifying \(model.title) · part \(index + 1) of \(model.parts.count)"
                        let verification = Task.detached {
                            try ModelInstallFiles.appendVerifiedPart(temporary, to: output, expectedBytes: part.bytes, sha256: part.sha256)
                        }
                        try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
                    }
                    try output.close()
                    try Task.checkCancellation()
                    status = "Installing \(model.title)…"
                    // Only checksum-pinned release archives reach tar. No downloaded executable is run.
                    try await Self.extract(archive: archive, destination: staging)
                    try Task.checkCancellation()
                    let package = staging.appendingPathComponent(model.directory)
                    let manifest = try Data(contentsOf: package.appendingPathComponent("classifier.json"))
                    guard contentHash(manifest) == model.manifest_sha256 else { throw LedgerError.unavailable("The installed model manifest did not match this release.") }
                    try FileManager.default.moveItem(at: package, to: destination)
                    installed[model.id] = destination
                }
                status = "Installation complete. Choose a model below to use it."
            } catch is CancellationError { status = "Download cancelled. You can retry whenever you are ready." }
            catch {
                if Task.isCancelled { status = "Download cancelled. You can retry whenever you are ready." }
                else { self.error = error.localizedDescription; status = "Installation did not finish." }
            }
        }
    }
    nonisolated private static func extract(archive: URL, destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", destination.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        defer { deadline.cancel() }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { child in
                    if child.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: LedgerError.unavailable("Model extraction stopped. Retry the installation.")) }
                }
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: deadline)
                    if Task.isCancelled { process.terminate() }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { if process.isRunning { process.terminate() } }
    }
}
