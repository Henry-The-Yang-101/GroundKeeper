import Foundation

/// One dispatch table for GUI diagnostics and pre-AppKit/headless diagnostics.
/// Release packaging verifies the shipped executable through these same runners.
@MainActor enum SmokeDiagnostics {
    enum Phase: Equatable { case headless, application }

    private struct Runner {
        let phase: Phase
        let flags: Set<String>
        var bundleKey: String? = nil
        let run: @MainActor () async -> Void
    }

    private static let runners: [Runner] = [
        Runner(phase: .headless, flags: ["--background-smoke"], run: QueueSmoke.backgroundRegistration),
        Runner(phase: .headless, flags: ["--queue-smoke"], run: QueueSmoke.run),
        Runner(phase: .application, flags: ["--receipt-smoke"], bundleKey: "GKReceiptSmoke", run: ReceiptSmoke.run),
        Runner(phase: .application, flags: ["--receipt-workspace-smoke"], run: ReceiptSmoke.runWorkspace),
        Runner(phase: .application, flags: ["--council-smoke"], run: CouncilSmoke.run),
        Runner(phase: .application, flags: ["--ollama-smoke"], run: OllamaSmoke.run),
        Runner(phase: .application, flags: ["--setup-smoke"], run: SetupSmoke.run),
        Runner(phase: .application, flags: ["--classifier-smoke", "--classifier-connection-smoke"], run: ClassifierSmoke.run),
        Runner(phase: .application, flags: ["--ledger-smoke"], run: LedgerSmoke.run),
    ]

    static func runner(for phase: Phase) -> (@MainActor () async -> Void)? {
        let arguments = Set(CommandLine.arguments)
        return runners.first { runner in
            runner.phase == phase && (
                !runner.flags.isDisjoint(with: arguments) ||
                runner.bundleKey.map { Bundle.main.object(forInfoDictionaryKey: $0) as? Bool == true } == true
            )
        }?.run
    }
}
