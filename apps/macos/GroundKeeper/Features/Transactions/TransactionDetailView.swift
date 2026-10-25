import SwiftUI
import MapKit
import GroundKeeperCore

struct TransactionDetailView: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    // Seed the sheet once; reload from persistence after editing.
    @State private var transaction: Transaction
    @State private var editor: Transaction?
    @State private var receipts: [ReceiptRecord] = []
    @State private var images: [String: NSImage] = [:]
    @State private var error: String?
    @State private var saveError: String?
    @State private var loading = true

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
        .sheet(item: $editor, onDismiss: { Task { await load() } }) { current in
            TransactionEditor(transaction: current) { draft in
                Task {
                    do { try await workspace.saveTransaction(draft); editor = nil }
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
                if transaction.needsReview { ReviewBadge() }
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
                detail("Account", workspace.accountLabel(id: transaction.accountID, fallback: transaction.account))
                detail("Type", transaction.kind.rawValue)
            }
            GridRow {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Category").font(.caption).foregroundStyle(AppStyle.muted)
                    CategoryLabel(transaction: transaction)
                }
                detail("Status", transaction.needsReview ? "Needs review" : "Reviewed")
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
            Label("Purchase location", systemImage: "mappin.and.ellipse").font(.headline)
            if let location = transaction.location {
                TransactionLocationMap(location: location, merchant: transaction.merchant)
            } else {
                Text("No location recorded.").foregroundStyle(AppStyle.muted)
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
            guard let current = try await workspace.transaction(id: transaction.id.uuidString) else {
                throw LedgerError.invalid("This transaction is no longer available.")
            }
            transaction = current
            receipts = try await workspace.receiptRecords(transactionID: current.id.uuidString)
            images = [:]
            for receipt in receipts where receipt.imageState == "stored" {
                if let data = try await workspace.receiptImage(id: receipt.id) { images[receipt.id] = NSImage(data: data) }
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct TransactionLocationMap: View {
    let location: TransactionLocation
    let merchant: String
    private var coordinate: CLLocationCoordinate2D { .init(latitude: location.latitude, longitude: location.longitude) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                latitudinalMeters: max(600, (location.accuracyMeters ?? 0) * 4), longitudinalMeters: max(600, (location.accuracyMeters ?? 0) * 4)))) {
                Marker(location.label ?? merchant, coordinate: coordinate).tint(AppStyle.accent)
            }
            .mapControls { MapZoomStepper(); MapCompass() }
            .frame(height: 220).clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel("Recorded purchase location for \(merchant)")
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if let label = location.label { Text(label) }
                    Text(String(format: "%.5f, %.5f", location.latitude, location.longitude))
                        .font(.caption.monospaced()).textSelection(.enabled)
                    if let accuracy = location.accuracyMeters {
                        Text("Recorded accuracy: about \(Int(accuracy.rounded())) m").font(.caption)
                    }
                }.foregroundStyle(AppStyle.muted)
                Spacer()
                Button("Open in Maps", systemImage: "arrow.up.right.square") {
                    let item = MKMapItem(location: CLLocation(latitude: location.latitude, longitude: location.longitude), address: nil)
                    item.name = location.label ?? merchant
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
