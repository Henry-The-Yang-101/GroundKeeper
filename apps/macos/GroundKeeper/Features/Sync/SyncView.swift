import SwiftUI
import GroundKeeperCore

struct SyncView: View {
    @Environment(AppWorkspace.self) private var workspace
    var body: some View {
        PageContent {
            PageHeading(title: "Sync", subtitle: "Capture on your iPhone. Review on your Mac.")
            Surface {
                SectionHeading(title: "iCloud capture folder", detail: workspace.folderName)
                Text(workspace.status).foregroundStyle(AppStyle.muted)
                if let last = workspace.lastSync { Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                HStack {
                    Button("Connect folder…", action: workspace.selectFolder)
                    Button("Retry failed work", action: workspace.retryFailures)
                }.disabled(!workspace.ready || workspace.saving)
                QueueControls()
                Text(workspace.processingDescription).font(.caption).foregroundStyle(AppStyle.muted)
                Text("Files stay in iCloud; committed delivery IDs prevent re-importing them. Test captures never become transactions.").font(.caption).foregroundStyle(AppStyle.muted)
            }
            Surface {
                HStack {
                    SectionHeading(title: "Bank statements", detail: "Map columns, validate exact amounts, and import your history.")
                    Button("Import CSV…") { workspace.showingImportPreview = true }.disabled(workspace.accounts.isEmpty)
                }
                if workspace.accounts.isEmpty { Text("Add an account in Settings before importing.").font(.caption) }
            }
            Surface {
                SectionHeading(title: "Review captures", detail: "\(workspace.reviews.count) open items shown")
                if workspace.reviews.isEmpty { Text("No capture issues to review.").foregroundStyle(AppStyle.muted) }
                ForEach(workspace.reviews) { review in
                    CaptureReviewRow(review: review)
                    Divider()
                }
            }
            Surface {
                SectionHeading(title: "Activity", detail: "\(workspace.pendingJobs) classification jobs pending · \(workspace.failedJobs) failed")
                if workspace.queue.isEmpty {
                    Label("No recent capture activity", systemImage: "tray")
                        .foregroundStyle(AppStyle.muted)
                }
                ForEach(workspace.queue) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.path).lineLimit(1)
                            if !item.error.isEmpty { Text(item.error.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(AppStyle.muted) }
                        }
                        Spacer()
                        Text("\(item.state) · \(item.attempts) attempts").font(.caption)
                    }
                }
            }
        }
    }
}
private struct CaptureReviewRow: View {
    @Environment(AppWorkspace.self) private var workspace
    let review: ReviewRecord
    @State private var accountID = ""
    @State private var correcting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(review.description.isEmpty ? "Unparsed capture" : review.description).fontWeight(.medium)
            Text(review.reason.replacingOccurrences(of: "_", with: " ")).font(.callout).foregroundStyle(AppStyle.muted)
            if !review.label.isEmpty { Text("Card label: \(review.label)").font(.caption) }
            if ["account_mapping_required", "currency_required"].contains(review.reason) {
                HStack {
                    Picker("Confirmed account", selection: $accountID) {
                        Text("Choose account").tag("")
                        ForEach(workspace.accounts) { Text("\($0.name) · \($0.currency)").tag($0.id) }
                    }
                    Button("Confirm mapping") { workspace.map(review, accountID: accountID) }.disabled(accountID.isEmpty)
                }
            }
            if review.reason == "possible_duplicate" {
                ForEach(review.candidates, id: \.self) { id in
                    let record = workspace.transactions.first { $0.id.uuidString == id }
                    Button("Link to \(record?.merchant ?? "transaction") · \(record?.date.formatted(date: .abbreviated, time: .omitted) ?? String(id.prefix(8)))") { workspace.resolve(review, transactionID: id) }
                }
                Button("Keep as a separate transaction") { workspace.resolve(review, transactionID: nil) }
            }
            if !["possible_duplicate", "event_identity_collision"].contains(review.reason) {
                Button("Correct capture details…") { correcting = true }
            }
            Button("Dismiss review") { workspace.dismiss(review) }.font(.caption)
        }.disabled(workspace.saving)
        .sheet(isPresented: $correcting) { CaptureCorrection(review: review).vaultSheet() }
    }
}

private struct CaptureCorrection: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let review: ReviewRecord
    @State private var description = ""
    @State private var amount = ""
    @State private var accountID = ""
    @State private var day = ""
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct capture details").font(VaultTypography.sheet)
            Text("Original source evidence is preserved. Enter a negative amount for money out, positive for money in.").foregroundStyle(AppStyle.muted)
            Form {
                TextField("Description", text: $description)
                TextField("Signed amount", text: $amount)
                TextField("Date (YYYY-MM-DD)", text: $day)
                Picker("Account", selection: $accountID) {
                    Text("Choose account").tag("")
                    ForEach(workspace.accounts) { Text("\($0.name) · \($0.currency)").tag($0.id) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(saving)
                Spacer()
                Button("Save correction") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await workspace.correct(review, description: description, amount: amount, accountID: accountID, day: day); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(saving || accountID.isEmpty).buttonStyle(.brass)
            }
        }.padding(24).frame(width: 520).onAppear { description = review.description }
    }
}
