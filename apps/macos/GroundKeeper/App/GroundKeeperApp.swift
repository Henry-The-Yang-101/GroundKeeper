import SwiftUI

@main
struct GroundKeeperApp: App {
    @State private var workspace = PreviewWorkspace()
    @AppStorage("appearance") private var appearance = AppAppearance.system

    var body: some Scene {
        Window("GroundKeeper", id: "main") {
            RootView()
                .environment(workspace)
                .preferredColorScheme(appearance.colorScheme)
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
            CommandMenu("Navigate") {
                ForEach(AppTab.allCases) { tab in
                    Button(tab.title) { workspace.selectedTab = tab }
                        .keyboardShortcut(KeyEquivalent(tab.shortcut))
                }
            }
        }
    }
}
