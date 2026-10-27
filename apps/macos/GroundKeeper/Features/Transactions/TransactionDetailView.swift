import SwiftUI
import MapKit
import GroundKeeperCore

struct TransactionDetailView: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(ReceiptWorkspace.self) private var receiptState
    @Environment(CaptureWorkspace.self) private var captureState
    @Environment(TransactionWorkspace.self) private var transactionState
    @Environment(\.dismiss) private var dismiss
    // Seed the sheet once; reload from persistence after editing.
    @State private var transaction: Transaction
    @State private var editor: Transaction?
    @State private var receipts: [ReceiptRecord] = []
    @State private var images: [String: NSImage] = [:]
    @State private var error: String?
    @State private var saveError: String?
    @State private var loading = true
    @State private var evidence: TransactionEvidence?
    @State private var statementMatches: [CaptureReconciliationCandidate] = []
    @State private var merging: Transaction?
    @State private var mergingBusy = false

    init(transaction: Transaction) { _transaction = State(initialValue: transaction) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("View transaction").font(VaultTypography.sheet).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { editor = transaction } label: { Label("Edit", systemImage: "pencil") }
                    .keyboardShortcut("e", modifiers: .command).disabled(loading || error != nil)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summary
                    Divider()
                    details
                    if !transaction.reviewIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(transaction.reviewIssues) { issue in
                                Label(issue.title, systemImage: "exclamationmark.bubble")
                            }
                            Button("Resolve source issues in Sync") { workspace.selectedTab = .sync; dismiss() }
                        }
                    }
                    if !statementMatches.isEmpty { statementReconciliation }
                    if let evidence { TransactionSourceHistoryView(evidence: evidence) }
                    if transaction.hasNote {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Notes", systemImage: "note.text").font(.headline)
                            Text(transaction.notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    location
                    receiptSection
                    if let error {
                        Text(error).foregroundStyle(.red)
                        Button("Try again") { Task { await load() } }
                    }
                }.padding(24)
            }
            SheetFooter {
                Text(transaction.source).font(.caption).foregroundStyle(AppStyle.muted)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 680, height: 700)
        .task { await load() }
        .confirmationDialog("Combine these records into one purchase?", isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } }), titleVisibility: .visible, presenting: merging) { other in
            Button("Combine records") {
                merging = nil; mergingBusy = true
                Task {
                    defer { mergingBusy = false }
                    do { try await captureState.mergeStatement(transaction, other: other); await load() }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { merging = nil }
        } message: { _ in
            Text("Keep this entry’s description, date, and category. Combine notes, receipts, and source evidence; count the purchase once. The other record stays in the vault’s history.")
        }
        .disabled(mergingBusy)
        .onChange(of: workspace.ready) { if !workspace.ready { dismiss() } }
        .sheet(item: $editor, onDismiss: { Task { await load() } }) { current in
            TransactionEditor(transaction: current) { draft in
                Task {
                    do { try await transactionState.saveTransaction(draft); editor = nil }
                    catch { saveError = error.localizedDescription }
                }
            }
            .vaultSheet()
            .alert("Transaction could not be saved", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                CategoryIcon(category: transaction.category)
                VStack(alignment: .leading, spacing: 5) {
                    Text(transaction.merchant).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(transaction.date, format: .dateTime.weekday(.wide).month(.wide).day().year())
                        .foregroundStyle(AppStyle.muted)
                }
                Spacer(minLength: 0)
                if transaction.requiresReview { ReviewBadge() }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(transaction.formattedAmount).font(.system(size: 36, weight: .medium, design: .rounded)).monospacedDigit()
                Text(transaction.currency).foregroundStyle(AppStyle.muted)
                Spacer()
                Label(transaction.isDebit ? "Money out" : "Money in", systemImage: transaction.isDebit ? "arrow.up.right" : "arrow.down.left")
                    .font(.callout).foregroundStyle(AppStyle.muted)
            }
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 16) {
            GridRow {
                detail("Account", transactionState.accountLabel(id: transaction.accountID, fallback: transaction.account))
                detail("Type", transaction.kind.rawValue)
            }
            GridRow {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Category").font(.caption).foregroundStyle(AppStyle.muted)
                    CategoryLabel(transaction: transaction)
                }
                detail("Category review", transaction.needsReview ? "Needs review" : "Reviewed")
            }
            if let postedOn = transaction.postedOn {
                GridRow {
                    detail("Statement date", postedOn)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(AppStyle.muted)
            Text(value).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var location: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Location", systemImage: "mappin.and.ellipse").font(.headline)
            if let location = transaction.location {
                TransactionLocationMap(location: location, merchant: transaction.merchant)
            } else {
                Text("No location recorded.").foregroundStyle(AppStyle.muted)
            }
        }
    }

    private var statementReconciliation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Possible statement match").font(.headline)
            Text("These saved records have the same account and amount within seven days. Combine only if they describe the same purchase.")
                .font(.caption).foregroundStyle(AppStyle.muted)
            ForEach(statementMatches) { match in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(match.description)
                        Text(match.day + " · " + ReportFormat.money(match.amountMinor, match.currency)).font(.caption).foregroundStyle(AppStyle.muted)
                    }
                    Spacer()
                    Button("Combine…") {
                        Task {
                            do {
                                guard let other = try await transactionState.transaction(id: match.id) else { throw LedgerError.conflict }
                                merging = other
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(loading || workspace.saving)
                }
            }
        }
    }

    private var receiptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Receipts", systemImage: "receipt").font(.headline)
            if loading { ProgressView("Loading receipts…").controlSize(.small) }
            else if receipts.isEmpty { Text("No receipts attached.").foregroundStyle(AppStyle.muted) }
            ForEach(receipts) { receipt in
                ReceiptPreview(receipt: receipt, image: images[receipt.id])
            }
        }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            guard let current = try await transactionState.transaction(id: transaction.id.uuidString) else {
                throw LedgerError.invalid("This transaction is no longer available.")
            }
            transaction = current
            guard let store = workspace.store else { throw CancellationError() }
            evidence = try await store.transactionEvidence(id: current.id.uuidString)
            statementMatches = try await store.savedStatementMatches(transactionID: current.id.uuidString)
            receipts = try await receiptState.receiptRecords(transactionID: current.id.uuidString)
            images = [:]
            for receipt in receipts where receipt.imageState == "stored" {
                if let data = try await receiptState.receiptImage(id: receipt.id) { images[receipt.id] = NSImage(data: data) }
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct TransactionLocationMap: View {
    let location: TransactionLocation
    let merchant: String
    private var coordinate: CLLocationCoordinate2D { .init(latitude: location.latitude, longitude: location.longitude) }
    private var locationTitle: String { location.origin == "phone_capture" ? "Phone location at capture" : "Recorded location" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                latitudinalMeters: min(50_000, max(600, (location.accuracyMeters ?? 0) * 4)), longitudinalMeters: min(50_000, max(600, (location.accuracyMeters ?? 0) * 4))))) {
                Marker(location.label ?? locationTitle, coordinate: coordinate).tint(AppStyle.accent)
            }
            .mapControls { MapZoomStepper(); MapCompass() }
            .frame(height: 220).clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel("\(locationTitle) for \(merchant)")
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(locationTitle).font(.caption)
                    if let label = location.label { Text(label) }
                    Text(String(format: "%.5f, %.5f", location.latitude, location.longitude))
                        .font(.caption.monospaced()).textSelection(.enabled)
                    if let accuracy = location.accuracyMeters {
                        Text("Recorded accuracy: about \(accuracy.formatted(.number.precision(.fractionLength(0)))) m").font(.caption)
                    }
                    if let measuredAtMS = location.measuredAtMS {
                        Text(Date(timeIntervalSince1970: Double(measuredAtMS) / 1000), format: .dateTime.month().day().year().hour().minute().second())
                            .font(.caption)
                    }
                }.foregroundStyle(AppStyle.muted)
                Spacer()
                Button("Open in Maps", systemImage: "arrow.up.right.square") {
                    let item = MKMapItem(location: CLLocation(latitude: location.latitude, longitude: location.longitude), address: nil)
                    item.name = location.label ?? locationTitle
                    item.openInMaps()
                }
            }
        }
    }
}

struct ReceiptPreview: View {
    let receipt: ReceiptRecord
    let image: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 380)
                    .background(.white, in: .rect(cornerRadius: 6)).accessibilityLabel("Receipt image")
            } else if receipt.imageState == "pending" {
                Label("Waiting for the receipt image from iCloud.", systemImage: "icloud.and.arrow.down")
                    .foregroundStyle(AppStyle.muted)
            } else if receipt.imageState == "invalid" || receipt.imageState == "stored" {
                Label("Receipt image unavailable. Add the image again in Edit.", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(AppStyle.muted)
            }
            if !receipt.text.isEmpty {
                DisclosureGroup("Receipt text") { Text(receipt.text).font(.callout.monospaced()).textSelection(.enabled) }
            }
        }
    }
}
