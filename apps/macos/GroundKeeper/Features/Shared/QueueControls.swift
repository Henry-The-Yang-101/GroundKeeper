import SwiftUI

struct QueueControls: View {
    static let reviewGuidance = "Capture reviews are resolved in Sync. A complete capture is saved immediately after your decision; category suggestions happen separately. In manual mode, Retry failed work requeues failures, then Import captures or Suggest categories runs the relevant work."
    var showsReviewGuidance = true
    @Environment(AppWorkspace.self) private var workspace
    @Environment(ClassifierWorkspace.self) private var classifier
    @State private var showingProviders = false
    @State private var installer = ModelInstaller()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(workspace.importButtonTitle) { Task { await workspace.sync(scope: .captures) } }
                    .disabled(!workspace.hasCaptureFolder || controlsDisabled)
                if classifier.classifierProvider != "manual" {
                    Button(workspace.suggestionButtonTitle) { Task { await workspace.sync(scope: .suggestions) } }
                        .disabled(controlsDisabled || workspace.suggestionCount == 0)
                }
                Button("Refresh count") { Task { await workspace.updateQueueCount() } }.disabled(!workspace.ready || workspace.processing)
            }
            if let error = workspace.countError {
                Text("Queue count unavailable: \(error)").font(.caption).foregroundStyle(AppStyle.muted)
            } else {
                Text("\(workspace.pendingCaptures) capture files to import · \(workspace.suggestionCount) saved transactions awaiting category suggestions")
                    .font(.caption).foregroundStyle(AppStyle.muted)
                if workspace.pendingFileWork > 0 {
                    Text("\(workspace.pendingFileWork) receipt or file cleanup tasks run with Import captures.").font(.caption).foregroundStyle(AppStyle.muted)
                }
                if classifier.classifierProvider == "manual" {
                    Text("Manual categorization is selected. Review saved transactions yourself or choose a provider for suggestions.")
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
            if showsReviewGuidance {
                Text(Self.reviewGuidance).font(.caption).foregroundStyle(AppStyle.muted)
            }
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
    private var controlsDisabled: Bool {
        !workspace.ready || workspace.processing || workspace.changingProcessingMode || workspace.saving
    }
}
