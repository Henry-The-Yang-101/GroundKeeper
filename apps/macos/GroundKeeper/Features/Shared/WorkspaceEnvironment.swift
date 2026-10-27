import SwiftUI

/// The same component instances are injected for the app, previews, and demos.
private struct WorkspaceEnvironment: ViewModifier {
    let workspace: AppWorkspace

    func body(content: Content) -> some View {
        content
            .environment(workspace)
            .environment(workspace.session)
            .environment(workspace.receiptState)
            .environment(workspace.merchantState)
            .environment(workspace.captureState)
            .environment(workspace.classifier)
            .environment(workspace.transactionState)
    }
}

extension View {
    func workspaceEnvironment(_ workspace: AppWorkspace) -> some View {
        modifier(WorkspaceEnvironment(workspace: workspace))
    }
}
