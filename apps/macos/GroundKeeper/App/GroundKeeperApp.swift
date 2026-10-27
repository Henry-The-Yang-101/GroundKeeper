import SwiftUI

struct GroundKeeperApp: App {
    @NSApplicationDelegateAdaptor(GroundKeeperLifecycle.self) private var lifecycle
    @State private var workspace = AppWorkspace()
    private var transactionState: TransactionWorkspace { workspace.transactionState }
    @AppStorage(AppPreferences.Key.appearance, store: AppPreferences.defaults) private var appearance = AppAppearance.system

    init() {
        VaultTypography.register()
    }

    var body: some Scene {
        Window("GroundKeeper", id: "main") {
            Group {
                if workspace.encrypted && !workspace.ready { VaultUnlockView() }
                else if workspace.showingSetup { SetupView(reviewMode: workspace.reviewingSetup) }
                else { RootView() }
            }
                .workspaceEnvironment(workspace)
                .defaultAppStorage(AppPreferences.defaults)
                .onChange(of: appearance, initial: true) {
                    // Removing a SwiftUI preferredColorScheme can leave the hosting
                    // view in its last override. AppKit nil restores system inheritance.
                    NSApp.appearance = appearance.appKitAppearance
                }
                .tint(AppStyle.accent)
                .foregroundStyle(AppStyle.text)
                .task {
                    lifecycle.workspace = workspace
                    if AppPreferences.isReceiptSmoke { await ReceiptSmoke.run() }
                    else if CommandLine.arguments.contains("--council-smoke") { await CouncilSmoke.run() }
                    else if CommandLine.arguments.contains("--ollama-smoke") { await OllamaSmoke.run() }
                    else if CommandLine.arguments.contains("--setup-smoke") { await SetupSmoke.run() }
                    else if CommandLine.arguments.contains("--classifier-smoke") || CommandLine.arguments.contains("--classifier-connection-smoke") { await ClassifierSmoke.run() }
                    else if CommandLine.arguments.contains("--ledger-smoke") { await LedgerSmoke.run() }
                    else { await workspace.start() }
                }
        }
        .defaultSize(width: 1140, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Transaction…", systemImage: "plus") {
                    transactionState.editor = Transaction()
                }
                .keyboardShortcut("n").disabled(!workspace.ready || workspace.showingSetup)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { workspace.selectedTab = .settings }
                    .keyboardShortcut(",").disabled(!workspace.ready || workspace.showingSetup)
            }
            CommandGroup(after: .textEditing) {
                Button("Find Transactions…") {
                    workspace.showTransactions()
                    transactionState.focusTransactionSearch = true
                }
                .keyboardShortcut("f").disabled(!workspace.ready || workspace.showingSetup)
            }
            CommandMenu("Navigate") {
                ForEach(AppTab.allCases) { tab in
                    Button(tab.title) { workspace.selectedTab = tab }
                        .keyboardShortcut(KeyEquivalent(tab.shortcut)).disabled(!workspace.ready || workspace.showingSetup)
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
