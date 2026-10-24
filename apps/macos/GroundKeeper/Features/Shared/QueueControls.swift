import SwiftUI

struct QueueControls: View {
    @Environment(AppWorkspace.self) private var workspace
    @State private var showingProviders = false
    @State private var installer = ModelInstaller()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(workspace.processButtonTitle) { Task { await workspace.sync() } }
                    .disabled(!workspace.ready || workspace.processing || workspace.changingProcessingMode || workspace.saving)
                Button("Refresh count") { Task { await workspace.updateQueueCount() } }.disabled(!workspace.ready || workspace.processing)
            }
            if let error = workspace.countError {
                Text("Queue count unavailable: \(error)").font(.caption).foregroundStyle(AppStyle.muted)
            } else {
                Text("\(workspace.pendingCaptures) capture files · \(workspace.pendingJobs) queued classification jobs · \(workspace.unqueuedJobs) entries without suggestions")
                    .font(.caption).foregroundStyle(AppStyle.muted)
                if workspace.classifierProvider == "manual" {
                    Text("Manual categorization is selected. Process queue imports capture files; automatic category suggestions stay off. Review entries yourself or choose a provider.")
                        .font(.caption).foregroundStyle(AppStyle.muted)
                    HStack {
                        Button("Review transactions") { workspace.showTransactions(needingReview: true) }
                            .disabled(!workspace.ready || workspace.saving)
                        Button("Choose provider…") { showingProviders = true }
                            .disabled(!workspace.ready || workspace.processing || workspace.saving)
                    }
                }
                if workspace.waitingCaptures > 0 {
                    Text("Includes \(workspace.waitingCaptures) files waiting for iCloud or a complete file write.").font(.caption)
                }
                if let date = workspace.countUpdatedAt {
                    Text("Count checked \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(AppStyle.muted)
                }
            }
            Text("Failed work and captures needing your review are listed separately in Sync. In manual mode, retrying marks failures as pending; click Process queue to run them.")
                .font(.caption).foregroundStyle(AppStyle.muted)
        }
        .sheet(isPresented: $showingProviders) {
            VStack(spacing: 0) {
                SheetHeading(title: "Categorization")
                ScrollView { ModelSetupView(installer: installer).padding(.horizontal, 24).padding(.bottom, 24) }
                SheetFooter { Spacer(); SheetDoneButton(disabled: installer.busy || workspace.saving) }
            }.frame(width: 720, height: 730).vaultSheet()
                .interactiveDismissDisabled(installer.busy || workspace.saving)
        }
    }
}
