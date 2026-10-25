import SwiftUI
import GroundKeeperCore

struct SyncView: View {
    @Environment(AppWorkspace.self) private var workspace
    var body: some View {
        PageContent {
            PageHeading(title: "Sync", subtitle: "Capture on your iPhone. Review on your Mac.")
            Surface {
                SectionHeading(title: "iCloud capture folder", detail: workspace.captureFolderPath)
                    .textSelection(.enabled)
                    .help(workspace.captureFolderPath)
                Text(workspace.status).foregroundStyle(AppStyle.muted)
                if let last = workspace.lastSync { Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                HStack {
                    Button("Connect folder…", action: workspace.selectFolder)
                    Button("Retry failed work", action: workspace.retryFailures)
                }.disabled(!workspace.ready || workspace.saving)
                QueueControls()
                Text(workspace.processingDescription).font(.caption).foregroundStyle(AppStyle.muted)
                Text("Imported JSON and receipt images are removed from iCloud after they are safely stored in your local vault. Invalid files stay in the queue for review.").font(.caption).foregroundStyle(AppStyle.muted)
                if workspace.captureFolderNeedsReconnect {
                    Text("Reconnect this folder once to allow GroundKeeper to remove processed files.").font(.caption)
                    Button("Reconnect capture folder…", action: workspace.selectFolder)
                }
                if let message = workspace.cleanupMessage { Text(message).font(.caption).foregroundStyle(AppStyle.muted) }
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
    @State private var rememberCard = false
    @State private var correcting = false
    @State private var context: CaptureReviewContext?
    @State private var candidates: [CaptureReconciliationCandidate] = []
    @State private var contextError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(review.description.isEmpty ? "Unparsed capture" : review.description).fontWeight(.medium)
            Text(review.reason.replacingOccurrences(of: "_", with: " ")).font(.callout).foregroundStyle(AppStyle.muted)
            if !review.label.isEmpty { Text("Card: \(review.label)").font(.caption).textSelection(.enabled) }
            if let context {
                CaptureSourceEvidence(context: context)
            } else if let contextError {
                Text(contextError).font(.caption).foregroundStyle(.red)
            } else {
                ProgressView("Loading capture details…").controlSize(.small)
            }
            if ["account_mapping_required", "currency_required"].contains(review.reason) {
                HStack {
                    Picker("Account", selection: $accountID) {
                        Text("Choose account").tag("")
                        ForEach(workspace.accounts) { Text("\($0.displayName(in: workspace.accounts)) · \($0.currency)").tag($0.id) }
                    }
                }
                RememberCardChoice(label: review.label, remember: $rememberCard)
                Button(rememberCard ? "Use account and remember card" : "Use for this transaction") {
                    workspace.assignAccount(review, accountID: accountID, remember: rememberCard)
                }.disabled(accountID.isEmpty)
                if workspace.accounts.isEmpty { Text("Add an account in Settings first.").font(.caption).foregroundStyle(AppStyle.muted) }
            }
            if review.reason == "possible_duplicate" {
                Text("Compare with existing transactions").font(.headline)
                ForEach(candidates) { candidate in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.description).fontWeight(.medium)
                            Text("\((Decimal(candidate.amountMinor) / 100).formatted(.currency(code: candidate.currency))) \(candidate.currency) · \(candidate.day)")
                            Text("Account: \(workspace.accountLabel(id: candidate.accountID, fallback: candidate.accountName))").font(.caption)
                            Button("Link to this transaction") { workspace.resolve(review, transactionID: candidate.id) }
                                .disabled(context == nil)
                                .accessibilityLabel("Link capture to \(candidate.description), \(candidate.day), \(workspace.accountLabel(id: candidate.accountID, fallback: candidate.accountName))")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if context != nil && candidates.count < review.candidates.count {
                    Text("Some suggested transactions are no longer available. Refresh Sync before deciding.")
                        .font(.caption).foregroundStyle(AppStyle.muted)
                }
                Button("Keep as a separate transaction") { workspace.resolve(review, transactionID: nil) }
                    .disabled(context == nil)
            }
            if !["possible_duplicate", "event_identity_collision"].contains(review.reason) {
                Button("Correct capture details…") { correcting = true }
            }
            Button("Dismiss review") { workspace.dismiss(review) }.font(.caption)
        }.disabled(workspace.saving)
        .sheet(isPresented: $correcting) { CaptureCorrection(review: review).vaultSheet() }
        .task(id: review.id) {
            do {
                guard let store = workspace.store else { throw LedgerError.unavailable("Open the vault to review this capture.") }
                context = try await store.captureReviewContext(eventID: review.eventID)
                candidates = try await store.captureReconciliationCandidates(transactionIDs: review.candidates)
            } catch { contextError = error.localizedDescription }
        }
    }
}

private struct CaptureCorrection: View {
    private struct Draft: Equatable {
        let description: String
        let amount: String
        let accountID: String
        let date: Date
        let isDebit: Bool?
        let rememberCard: Bool
    }
    @Environment(AppWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let review: ReviewRecord
    @State private var description = ""
    @State private var amount = ""
    @State private var accountID = ""
    @State private var date = Date()
    @State private var isDebit: Bool?
    @State private var context: CaptureReviewContext?
    @State private var error: String?
    @State private var saving = false
    @State private var rememberCard = false
    @State private var initialDraft: Draft?
    @State private var showingDiscardConfirmation = false
    private var draft: Draft {
        Draft(description: description, amount: amount, accountID: accountID, date: date,
              isDebit: isDebit, rememberCard: rememberCard)
    }
    private var hasChanges: Bool { initialDraft.map { $0 != draft } ?? false }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Correct capture details", subtitle: "Check the amount, direction, and date against the original capture. Source evidence is preserved.")
            Form {
                if let context { CaptureSourceEvidence(context: context) }
                TextField("Description", text: $description)
                TransactionAmountField(text: $amount)
                if !amount.isEmpty && TransactionInput.positiveAmount(amount) == nil {
                    Text("Use a positive amount, up to two decimal places, and no thousands separators.")
                        .font(.caption).foregroundStyle(.red)
                }
                Picker("Direction", selection: $isDebit) {
                    Text("Choose direction").tag(nil as Bool?)
                    Text("Money out").tag(Optional(true))
                    Text("Money in").tag(Optional(false))
                }
                if isDebit == nil {
                    Text("The source amount could not establish a direction. Choose money out or money in.")
                        .font(.caption).foregroundStyle(AppStyle.muted)
                }
                TransactionDatePicker(date: $date)
                Picker("Account", selection: $accountID) {
                    Text("Choose account").tag("")
                    ForEach(workspace.accounts) { Text("\($0.displayName(in: workspace.accounts)) · \($0.currency)").tag($0.id) }
                }
                if !review.label.isEmpty { Text("Card: \(review.label)").font(.caption).textSelection(.enabled) }
                RememberCardChoice(label: review.label, remember: $rememberCard)
            }.formStyle(.grouped).scrollContentBackground(.hidden).frame(height: 430).disabled(context == nil || saving)
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 16) }
            SheetFooter {
                Button("Cancel") {
                    if hasChanges { showingDiscardConfirmation = true } else { dismiss() }
                }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button("Save correction") {
                    guard let value = TransactionInput.positiveAmount(amount), let isDebit else { return }
                    let signedAmount = NSDecimalNumber(decimal: isDebit ? -value : value).stringValue
                    let day = TransactionInput.day(date)
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await workspace.correct(review, description: description, amount: signedAmount, accountID: accountID, day: day, remember: rememberCard); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(context == nil || isDebit == nil || saving || workspace.saving || accountID.isEmpty || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || TransactionInput.positiveAmount(amount) == nil)
                    .buttonStyle(.brass)
            }
        }.frame(width: 570).interactiveDismissDisabled(saving || hasChanges)
            .confirmationDialog("Discard your capture corrections?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) { }
            }
            .task(id: review.eventID) {
                guard context == nil else { return }
                do {
                    guard let store = workspace.store else { throw LedgerError.unavailable("Open the vault to review this capture.") }
                    let source = try await store.captureReviewContext(eventID: review.eventID)
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.calendar = Calendar(identifier: .gregorian)
                    formatter.dateFormat = "yyyy-MM-dd"
                    guard let sourceDate = formatter.date(from: source.day) else { throw LedgerError.invalid("The source date could not be read.") }
                    description = source.description
                    date = sourceDate
                    accountID = source.accountID ?? ""
                    if let minor = source.amountMinor {
                        amount = (Decimal(minor.magnitude) / 100).formatted(.number.grouping(.never).precision(.fractionLength(2)))
                        isDebit = minor < 0
                    }
                    context = source
                    // The parsed source seeds one edit session. Loading it is not a user change.
                    initialDraft = draft
                } catch { self.error = error.localizedDescription }
            }
    }
}

private struct CaptureSourceEvidence: View {
    @Environment(AppWorkspace.self) private var workspace
    let context: CaptureReviewContext
    var body: some View {
        Section("Original capture") {
            LabeledContent("Date", value: context.day)
            if let amount = context.amountMinor, let currency = context.currency {
                LabeledContent("Amount", value: "\((Decimal(amount) / 100).formatted(.currency(code: currency))) \(currency)")
            } else {
                LabeledContent("Amount", value: "Could not be parsed — check source below")
            }
            LabeledContent("Account", value: workspace.accountLabel(id: context.accountID, fallback: context.accountName ?? "Not assigned"))
            DisclosureGroup("Preserved source evidence") {
                Text(context.payload).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
