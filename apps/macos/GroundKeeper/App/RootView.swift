import SwiftUI

struct RootView: View {
    @Environment(AppWorkspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        // A native Table's ideal size can otherwise expand the entire split view
        // beyond the host window. Read the proposal here instead of screen bounds.
        GeometryReader { geometry in
            NavigationSplitView {
                SidebarView(selection: $workspace.selectedTab, reviewCount: workspace.reviewCount, queueCount: workspace.queueCount)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 280)
            } detail: {
                selectedPage
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .navigationTitle(workspace.selectedTab?.title ?? "Home")
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Label(workspace.ready ? "Local vault" : "Opening vault", systemImage: "internaldrive")
                                .font(.caption).foregroundStyle(AppStyle.muted)
                                .padding(.horizontal, 10)
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
            .background(AppStyle.pageBackground)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 760, minHeight: 560)
        .overlay(alignment: .bottom) { WorkspaceFeedbackView() }
        .sheet(item: $workspace.editor) { transaction in
            TransactionEditor(transaction: transaction, onSave: workspace.save).vaultSheet()
        }
        .sheet(isPresented: $workspace.showingImportPreview) {
            ImportPreviewView().vaultSheet()
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
