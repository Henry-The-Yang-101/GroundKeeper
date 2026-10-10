import SwiftUI

struct RootView: View {
    @Environment(PreviewWorkspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        NavigationSplitView {
            SidebarView(selection: $workspace.selectedTab, reviewCount: workspace.reviewCount)
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
        } detail: {
            selectedPage
                .navigationTitle(workspace.selectedTab?.title ?? "Home")
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Text("Sample data")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("Fictional transactions. Changes are kept only for this session.")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            workspace.editor = Transaction()
                        } label: {
                            Label("Add transaction", systemImage: "plus")
                        }
                        .help("Add a sample transaction (⌘N)")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .sheet(item: $workspace.editor) { transaction in
            TransactionEditor(transaction: transaction, onSave: workspace.save)
        }
        .sheet(isPresented: $workspace.showingImportPreview) {
            ImportPreviewView()
        }
    }

    @ViewBuilder private var selectedPage: some View {
        switch workspace.selectedTab ?? .home {
        case .home: HomeView()
        case .fullInsights: FullInsightsView()
        case .sync: SyncView()
        case .settings: SettingsView()
        }
    }
}

#Preview("Light") {
    RootView().environment(PreviewWorkspace()).preferredColorScheme(.light)
}

#Preview("Dark") {
    RootView().environment(PreviewWorkspace()).preferredColorScheme(.dark)
}
