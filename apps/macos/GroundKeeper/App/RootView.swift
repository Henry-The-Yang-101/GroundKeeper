import SwiftUI

struct RootView: View {
    @Environment(AppWorkspace.self) private var workspace

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
                        Text(workspace.ready ? "Local vault" : "Opening vault")
                            .font(.caption).foregroundStyle(.secondary)
                            .help(workspace.status)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            workspace.editor = Transaction()
                        } label: {
                            Label("Add transaction", systemImage: "plus")
                        }
                        .help("Add a transaction (⌘N)")
                        .disabled(!workspace.ready)
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
        .alert("GroundKeeper needs attention", isPresented: Binding(get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } })) {
            Button("OK") { workspace.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? "") }
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
    RootView().environment(AppWorkspace()).preferredColorScheme(.light)
}

#Preview("Dark") {
    RootView().environment(AppWorkspace()).preferredColorScheme(.dark)
}
