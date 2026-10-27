import SwiftUI

struct GroundKeeperApp: App {
    @NSApplicationDelegateAdaptor(GroundKeeperLifecycle.self) private var lifecycle
    @State private var workspace = AppWorkspace()
    private var transactionState: TransactionWorkspace { workspace.transactionState }
    @AppStorage(AppPreferences.Key.appearance, store: AppPreferences.defaults) private var appearance = AppAppearance.system

    private var vault: VaultWorkspace { workspace.vault }

    private var session: WorkspaceSession { workspace.session }

    init() {
        VaultTypography.register()
    }

    var body: some Scene {
        Window("GroundKeeper", id: "main") {
            Group {
                if vault.encrypted && !session.ready { VaultUnlockView() }
                else if vault.showingSetup { SetupView(reviewMode: vault.reviewingSetup) }
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
                    if let run = SmokeDiagnostics.runner(for: .application) { await run() }
                    else { await vault.start() }
                }
        }
        .defaultSize(width: 1140, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Transaction…", systemImage: "plus") {
                    transactionState.editor = Transaction()
                }
                .keyboardShortcut("n").disabled(!session.ready || vault.showingSetup)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { workspace.selectedTab = .settings }
                    .keyboardShortcut(",").disabled(!session.ready || vault.showingSetup)
            }
            CommandGroup(after: .textEditing) {
                Button("Find Transactions…") {
                    workspace.showTransactions()
                    transactionState.focusTransactionSearch = true
                }
                .keyboardShortcut("f").disabled(!session.ready || vault.showingSetup)
            }
            CommandMenu("Navigate") {
                ForEach(AppTab.allCases) { tab in
                    Button(tab.title) { workspace.selectedTab = tab }
                        .keyboardShortcut(KeyEquivalent(tab.shortcut)).disabled(!session.ready || vault.showingSetup)
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
            await workspace.vault.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
