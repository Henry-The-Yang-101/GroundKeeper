import SwiftUI
import GroundKeeperCore

struct SyncView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(CaptureWorkspace.self) private var captureState
    @Environment(TransactionWorkspace.self) private var transactionState
    @State private var viewedTransaction: Transaction?
    var body: some View {
        PageContent {
            PageHeading(title: "Sync")
            Surface {
                SectionHeading(title: "iCloud capture folder", detail: captureState.captureFolderPath)
                    .textSelection(.enabled)
                    .help(captureState.captureFolderPath)
                Text(session.status).foregroundStyle(AppStyle.muted)
                if let last = captureState.lastSync { Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                HStack {
                    Button("Connect folder…", action: captureState.selectFolder)
                    Button("Retry failed work", action: captureState.retryFailures)
                }.disabled(!session.ready || session.saving)
                QueueControls(showsReviewGuidance: false)
                CaptureFolderInfoButton()
            }
            Surface {
                HStack {
                    SectionHeading(title: "Bank statements", detail: "Map columns, validate exact amounts, and import your history.")
                    Button("Import CSV…") { transactionState.showingImportPreview = true }.disabled(transactionState.accounts.isEmpty)
                }
                if transactionState.accounts.isEmpty { Text("Add an account in Settings before importing.").font(.caption) }
            }
            Surface {
                SectionHeading(title: "Review captures", detail: "\(captureState.reviews.count) open items shown")
                if let result = captureState.captureFeedback {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(result.message, systemImage: result.needsAttention ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.callout)
                            .accessibilityAddTraits(.updatesFrequently)
                        HStack {
                            if let id = result.transactionID {
                                Button("View transaction") {
                                    Task {
                                        do {
                                            guard let transaction = try await transactionState.transaction(id: id) else {
                                                session.errorMessage = "This transaction is no longer available."
                                                return
                                            }
                                            viewedTransaction = transaction
                                        } catch { session.errorMessage = error.localizedDescription }
                                    }
                                }
                            }
                            Button("Dismiss message") { captureState.captureFeedback = nil }.buttonStyle(.borderless)
                        }
                    }.padding(.vertical, 6)
                }
                if captureState.reviews.isEmpty { Text("No capture issues to review.").foregroundStyle(AppStyle.muted) }
                ForEach(captureState.reviews) { review in
                    CaptureReviewRow(review: review)
                    Divider()
                }
            }
            Surface {
                SectionHeading(title: "Activity", detail: "\(captureState.pendingJobs) classification jobs pending · \(captureState.failedJobs) failed")
                if captureState.queue.isEmpty {
                    Label("No recent capture activity", systemImage: "tray")
                        .foregroundStyle(AppStyle.muted)
                }
                ForEach(captureState.queue) { item in
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
        .sheet(item: $viewedTransaction) { transaction in
            TransactionDetailView(transaction: transaction).vaultSheet()
        }
    }
}
private struct CaptureFolderInfoButton: View {
    @Environment(CaptureWorkspace.self) private var captureState
    @State private var showingInfo = false

    var body: some View {
        Button("About capture processing", systemImage: "info.circle") { showingInfo.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.body)
            .foregroundStyle(AppStyle.muted)
            .help("About capture processing")
            .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Capture processing").font(.headline).foregroundStyle(AppStyle.text)
                    Text(QueueControls.reviewGuidance)
                    Text(captureState.processingDescription)
                    Text("Imported JSON and receipt images are removed from iCloud after they are safely stored in your local vault. Invalid files stay in the queue for review.")
                    if captureState.captureFolderNeedsReconnect {
                        Text("Reconnect this folder once to allow GroundKeeper to remove processed files.")
                        Button("Reconnect capture folder…", action: captureState.selectFolder)
                    }
                    if let message = captureState.cleanupMessage { Text(message) }
                }
                .font(.callout)
                .foregroundStyle(AppStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
                .frame(width: 400, alignment: .leading)
            }
    }
}

private struct CaptureReviewRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(CaptureWorkspace.self) private var captureState
    @Environment(TransactionWorkspace.self) private var transactionState
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
            Text(TransactionReviewIssue.title(for: review.reason)).font(.callout).foregroundStyle(AppStyle.muted)
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
                        ForEach(transactionState.accounts) { Text("\($0.displayName(in: transactionState.accounts)) · \($0.currency)").tag($0.id) }
                    }
                }
                RememberCardChoice(label: review.label, remember: $rememberCard)
                Button("Continue import") {
                    captureState.assignAccount(review, accountID: accountID, remember: rememberCard)
                }.disabled(accountID.isEmpty)
                if transactionState.accounts.isEmpty { Text("Add an account in Settings first.").font(.caption).foregroundStyle(AppStyle.muted) }
            }
            if ["possible_duplicate", "statement_match"].contains(review.reason) {
                Text("Compare with existing transactions").font(.headline)
                if review.reason == "statement_match" {
                    Text("The account and amount match within seven days. Check the merchant and date before linking. The source is held out of spending until you decide.")
                        .font(.caption).foregroundStyle(AppStyle.muted)
                }
                ForEach(candidates) { candidate in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.description).fontWeight(.medium)
                            Text("\((Decimal(candidate.amountMinor) / 100).formatted(.currency(code: candidate.currency))) \(candidate.currency) · \(candidate.day)")
                            Text("Account: \(transactionState.accountLabel(id: candidate.accountID, fallback: candidate.accountName))").font(.caption)
                            Button("Link to this transaction") { captureState.resolve(review, transactionID: candidate.id, expectedRevision: candidate.revision) }
                                .disabled(context == nil)
                                .accessibilityLabel("Link capture to \(candidate.description), \(candidate.day), \(transactionState.accountLabel(id: candidate.accountID, fallback: candidate.accountName))")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if context != nil && candidates.count < review.candidates.count {
                    Text("Some suggested transactions are no longer available. Refresh Sync before deciding.")
                        .font(.caption).foregroundStyle(AppStyle.muted)
                }
                Button("Keep as a separate transaction") { captureState.resolve(review, transactionID: nil) }
                    .disabled(context == nil)
            }
            if ["external_id_conflict", "csv_mapping_changed"].contains(review.reason) {
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Saved entry: \(candidate.description)").fontWeight(.medium)
                        Text("\((Decimal(candidate.amountMinor) / 100).formatted(.currency(code: candidate.currency))) \(candidate.currency) · \(candidate.day)")
                    }.font(.callout)
                }
                Text("Use statement details replaces the saved description, amount, and date. A changed direction reopens category review. Keep saved details retains the entry and records this statement as evidence.")
                    .font(.caption).foregroundStyle(AppStyle.muted)
                HStack {
                    Button("Use statement details") { captureState.resolveCSV(review, useStatement: true, expectedRevision: candidates.first?.revision) }
                    Button("Keep saved details") { captureState.resolveCSV(review, useStatement: false, expectedRevision: candidates.first?.revision) }
                }.disabled(context == nil || candidates.isEmpty)
            }
            if !["possible_duplicate", "statement_match", "external_id_conflict", "csv_mapping_changed", "event_identity_collision"].contains(review.reason) {
                Button("Correct capture details…") { correcting = true }
            }
            Button("Dismiss review") { captureState.dismiss(review) }.font(.caption)
        }.disabled(session.saving)
        .sheet(isPresented: $correcting) { CaptureCorrection(review: review).vaultSheet() }
        .task(id: "\(review.id)|\(transactionState.reportingRevision)") {
            do {
                guard let store = session.store else { throw LedgerError.unavailable("Open the vault to review this capture.") }
                context = try await store.captureReviewContext(eventID: review.eventID)
                candidates = try await store.reviewCandidates(reviewID: review.id)
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
    @Environment(WorkspaceSession.self) private var session
    @Environment(CaptureWorkspace.self) private var captureState
    @Environment(TransactionWorkspace.self) private var transactionState
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
                    ForEach(transactionState.accounts) { Text("\($0.displayName(in: transactionState.accounts)) · \($0.currency)").tag($0.id) }
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
                        do { try await captureState.correct(review, description: description, amount: signedAmount, accountID: accountID, day: day, remember: rememberCard); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(context == nil || isDebit == nil || saving || session.saving || accountID.isEmpty || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || TransactionInput.positiveAmount(amount) == nil)
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
                    guard let store = session.store else { throw LedgerError.unavailable("Open the vault to review this capture.") }
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
    @Environment(TransactionWorkspace.self) private var transactionState
    let context: CaptureReviewContext
    var body: some View {
        Section(context.sourceKind == "csv" ? "Statement source" : "Original capture") {
            LabeledContent("Date", value: context.day)
            if let amount = context.amountMinor, let currency = context.currency {
                LabeledContent("Amount", value: "\((Decimal(amount) / 100).formatted(.currency(code: currency))) \(currency)")
            } else {
                LabeledContent("Amount", value: "Could not be parsed — check source below")
            }
            LabeledContent("Account", value: transactionState.accountLabel(id: context.accountID, fallback: context.accountName ?? "Not assigned"))
            DisclosureGroup("Preserved source evidence") {
                Text(context.payload).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
