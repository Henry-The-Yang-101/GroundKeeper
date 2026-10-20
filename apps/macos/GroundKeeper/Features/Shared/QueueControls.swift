import SwiftUI

struct QueueControls: View {
    @Environment(AppWorkspace.self) private var workspace
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
                Text("\(workspace.pendingCaptures) capture files · \(workspace.pendingJobs + workspace.unqueuedJobs) awaiting classification")
                    .font(.caption).foregroundStyle(AppStyle.muted)
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
    }
}
