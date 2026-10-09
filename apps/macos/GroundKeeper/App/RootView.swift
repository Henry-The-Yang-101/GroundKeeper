import SwiftUI

struct RootView: View {
    @State private var selectedTab: AppTab = .home

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $selectedTab)

            selectedPage
        }
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 340, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .background(WindowControls(sidebarWidth: AppLayout.sidebarWidth))
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selectedTab {
        case .home:
            HomeView()
        case .fullInsights:
            FullInsightsView()
        case .sync:
            SyncView()
        case .settings:
            SettingsView()
        }
    }
}

#Preview {
    RootView()
}
