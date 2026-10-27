import AppKit
import ServiceManagement
import GroundKeeperCore
import Darwin

/// Both entry points use the same signed executable, container and security-scoped bookmarks.
/// The foreground lease requests handoff; the existing database lock remains authoritative.
final class QueueProcessLease {
    private let descriptor: Int32
    init?() {
        guard let root = try? VaultAccess.root() else { return nil }
        let fd = Darwin.open(root.appendingPathComponent("foreground.ownerlock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); return nil }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    static var foregroundIsRunning: Bool { QueueProcessLease() == nil }
}

enum QueuePreferences {
    static var mode: QueueProcessingMode {
        guard let url = try? VaultAccess.root().appendingPathComponent("queue-processing.json"),
              let data = try? Data(contentsOf: url), let mode = try? JSONDecoder().decode(QueueProcessingMode.self, from: data) else { return .whileOpen }
        return mode
    }
    static func save(_ mode: QueueProcessingMode) throws {
        let url = try VaultAccess.root().appendingPathComponent("queue-processing.json")
        try JSONEncoder().encode(mode).write(to: url, options: .atomic)
    }
}

enum QueueAgentHeartbeat {
    private static var url: URL? { try? VaultAccess.root().appendingPathComponent("queue-agent-heartbeat.json") }
    static func write() {
        guard let url else { return }
        let data = try? JSONEncoder().encode(Date().timeIntervalSince1970)
        try? data?.write(to: url, options: .atomic)
    }
    static var lastSeen: TimeInterval {
        guard let url, let data = try? Data(contentsOf: url), let time = try? JSONDecoder().decode(Double.self, from: data) else { return 0 }
        return time
    }
    static func clear() { if let url { try? FileManager.default.removeItem(at: url) } }
}

@MainActor enum QueueBackgroundService {
    // Ad hoc upgrades failed launchd's launch constraints in release testing.
    // Keep foreground/manual processing available rather than advertising an idle agent.
    static var isSupported: Bool {
        Bundle.main.object(forInfoDictionaryKey: "GKDistributionChannel") as? String != "adhoc"
    }
    static let unsupportedMessage = "Background processing is unavailable in this build. Keep GroundKeeper open or process the queue manually."
    // Retire the original ad-hoc registration before registering the stable Apple-signed service.
    private static let legacyService = SMAppService.agent(plistName: "com.groundkeeper.macos.queue.plist")
    static let service = SMAppService.agent(plistName: "com.groundkeeper.macos.queue-processing.plist")
    private static func removeLegacyRegistration() async throws {
        if legacyService.status != .notRegistered && legacyService.status != .notFound { try await legacyService.unregister() }
    }
    static var status: String {
        guard isSupported else { return unsupportedMessage }
        return switch service.status {
        case .enabled:
            Date().timeIntervalSince1970 - QueueAgentHeartbeat.lastSeen < 30
                ? "Background service running"
                : "Background service registered but not responding. Re-enable it or check app signing."
        case .requiresApproval: "Allow GroundKeeper in System Settings → General → Login Items & Extensions."
        case .notRegistered: "Background service is not enabled"
        case .notFound:
            FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/com.groundkeeper.macos.queue-processing.plist").path)
                ? "Background service has not been registered"
                : "Background service is missing from this app build"
        @unknown default: "Background service status unavailable"
        }
    }
    static func enable() async throws {
        guard isSupported else { throw LedgerError.unavailable(unsupportedMessage) }
        try await removeLegacyRegistration()
        if service.status == .enabled {
            try await service.unregister()
            QueueAgentHeartbeat.clear()
        }
        try service.register()
        guard service.status == .enabled else { return } // macOS may require user approval.
        for _ in 0..<20 {
            if Date().timeIntervalSince1970 - QueueAgentHeartbeat.lastSeen < 10 { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LedgerError.unavailable("macOS registered the background service, but it did not start. Check the app signing identity and GroundKeeper’s permission in Login Items & Extensions. Processing while the app is open and manual processing remain available.")
    }
    static func disable() async throws {
        try await removeLegacyRegistration()
        if service.status != .notRegistered && service.status != .notFound { try await service.unregister() }
        QueueAgentHeartbeat.clear()
    }
}

@MainActor enum QueueAgent {
    static func run() async {
        guard QueueBackgroundService.isSupported, !VaultAccess.isEncrypted else { return }
        var lastHeartbeat = Date.distantPast
        func heartbeat() {
            if Date().timeIntervalSince(lastHeartbeat) >= 5 { QueueAgentHeartbeat.write(); lastHeartbeat = Date() }
        }
        defer { QueueAgentHeartbeat.clear() }
        while !Task.isCancelled && QueuePreferences.mode == .background && !VaultAccess.isEncrypted {
            heartbeat()
            if !QueueProcessLease.foregroundIsRunning {
                // Synchronize bookmarks after the foreground app has released its lease.
                AppPreferences.defaults.synchronize()
                let workspace = AppWorkspace(isBackgroundAgent: true)
                await workspace.vault.start()
                while workspace.ready && !Task.isCancelled && QueuePreferences.mode == .background && !QueueProcessLease.foregroundIsRunning {
                    heartbeat()
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
                await workspace.vault.stop()
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { break }
        }
    }
}

@main enum GroundKeeperEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--background-smoke") {
            Task { await QueueSmoke.backgroundRegistration() }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--queue-smoke") {
            Task { await QueueSmoke.run() }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--queue-agent") {
            // Do not create NSApplication here: registering this process with Launch Services
            // would make Finder reopen the headless agent instead of launching the UI.
            Task { await QueueAgent.run(); exit(0) }
            dispatchMain()
        } else {
            // Held until the UI process exits, including while model work is being cancelled.
            let lease = QueueProcessLease()
            withExtendedLifetime(lease) { GroundKeeperApp.main() }
        }
    }
}
