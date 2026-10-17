import SwiftUI

@main
struct GroundKeeperApp: App {
    @State private var workspace = AppWorkspace()
    @AppStorage("appearance") private var appearance = AppAppearance.system

    var body: some Scene {
        Window("GroundKeeper", id: "main") {
            RootView()
                .environment(workspace)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    if CommandLine.arguments.contains("--classifier-smoke") { await ClassifierSmoke.run() }
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
