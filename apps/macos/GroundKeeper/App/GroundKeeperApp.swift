import SwiftUI

@main
struct GroundKeeperApp: App {
    var body: some Scene {
        Window("GroundKeeper", id: "main") {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 1000, height: 680)
    }
}
