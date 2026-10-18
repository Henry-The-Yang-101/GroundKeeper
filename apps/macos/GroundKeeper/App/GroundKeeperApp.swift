import SwiftUI

struct GroundKeeperApp: App {
    @NSApplicationDelegateAdaptor(GroundKeeperLifecycle.self) private var lifecycle
    @State private var workspace = AppWorkspace()
    @AppStorage("appearance") private var appearance = AppAppearance.system

    var body: some Scene {
        Window("GroundKeeper", id: "main") {
            RootView()
                .environment(workspace)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    lifecycle.workspace = workspace
                    if CommandLine.arguments.contains("--classifier-smoke") || CommandLine.arguments.contains("--classifier-connection-smoke") { await ClassifierSmoke.run() }
                    else if CommandLine.arguments.contains("--ledger-smoke") { await LedgerSmoke.run() }
                    else { await workspace.start() }
                }
        }
        .defaultSize(width: 1140, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Transaction…", systemImage: "plus") {
                    workspace.editor = Transaction()
                }
                .keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { workspace.selectedTab = .settings }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .textEditing) {
                Button("Find Transactions…") {
                    workspace.showTransactions()
                    workspace.focusTransactionSearch = true
                }
                .keyboardShortcut("f")
            }
            CommandMenu("Navigate") {
                ForEach(AppTab.allCases) { tab in
                    Button(tab.title) { workspace.selectedTab = tab }
                        .keyboardShortcut(KeyEquivalent(tab.shortcut))
                }
            }
        }
    }
}

/// Finish cancellation and persist the job handoff before releasing the foreground lease.
@MainActor final class GroundKeeperLifecycle: NSObject, NSApplicationDelegate {
    weak var workspace: AppWorkspace?
    private var terminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await workspace.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
