import Foundation
import GroundKeeperCore
import Observation

/// Shared vault access and operation feedback. Feature components own their own
/// observable state; these callbacks are the coordinator's cross-feature events.
@MainActor @Observable final class WorkspaceSession {
    var store: LedgerStore?
    var saving = false
    var errorMessage: String?
    var feedback: WorkspaceFeedback?
    @ObservationIgnored var refresh: @MainActor () async throws -> Void = {}
    @ObservationIgnored var processAutomatically: @MainActor () async -> Void = {}
    @ObservationIgnored var didFinishSaving: @MainActor () -> Void = {}
    @ObservationIgnored var canReleaseResources: @MainActor () -> Bool = { true }
    @ObservationIgnored var releaseResources: @MainActor () async -> Void = {}

    func finishSaving() {
        saving = false
        didFinishSaving()
    }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !saving else { return }
        saving = true
        Task {
            defer { finishSaving() }
            do { try await operation() }
            catch { errorMessage = error.localizedDescription }
            if canReleaseResources() { await releaseResources() }
        }
    }
}

/// Narrow capabilities shared by app-level features, without a dependency on
/// AppWorkspace or ownership of another feature's observable properties.
@MainActor protocol WorkspaceComponent: AnyObject {
    var session: WorkspaceSession { get }
}

extension WorkspaceComponent {
    var store: LedgerStore? {
        get { session.store }
        set { session.store = newValue }
    }
    var ready: Bool { store != nil }
    var saving: Bool {
        get { session.saving }
        set { session.saving = newValue }
    }
    var errorMessage: String? {
        get { session.errorMessage }
        set { session.errorMessage = newValue }
    }
    var feedback: WorkspaceFeedback? {
        get { session.feedback }
        set { session.feedback = newValue }
    }
    func refresh() async throws { try await session.refresh() }
    func processIfAutomatic() async { await session.processAutomatically() }
    func finishSaving() { session.finishSaving() }
    func perform(_ operation: @escaping @MainActor () async throws -> Void) { session.perform(operation) }
}
