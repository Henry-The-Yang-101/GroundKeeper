import SwiftUI
import GroundKeeperCore

struct TransactionReceiptEditor: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(ReceiptWorkspace.self) private var receiptState
    @Binding var transaction: Transaction
    @Binding var loading: Bool
    @State private var records: [ReceiptRecord] = []
    @State private var images: [String: NSImage] = [:]
    @State private var error: String?

    var body: some View {
        Section {
            ReceiptImportControls { transaction.newReceiptImages.append(DraftReceiptImage(data: $0)) }
            if loading { ProgressView("Loading receipts…").controlSize(.small) }
            if !loading && records.isEmpty && transaction.newReceiptImages.isEmpty {
                Text("No receipts attached.").foregroundStyle(AppStyle.muted)
            }
            ForEach(records) { receipt in
                if transaction.removedReceiptIDs.contains(receipt.id) {
                    HStack {
                        Text("Receipt will be removed when you save.").font(.caption).foregroundStyle(AppStyle.muted)
                        Spacer()
                        Button("Undo") { transaction.removedReceiptIDs.removeAll { $0 == receipt.id } }
                    }
                } else {
                    ReceiptPreview(receipt: receipt, image: images[receipt.id])
                    Button("Remove receipt", systemImage: "trash", role: .destructive) { transaction.removedReceiptIDs.append(receipt.id) }
                }
            }
            ForEach(transaction.newReceiptImages) { receipt in
                VStack(alignment: .leading, spacing: 8) {
                    if let image = NSImage(data: receipt.data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                            .accessibilityLabel("New receipt image")
                    }
                    HStack {
                        Text("New receipt · \(ByteCountFormatter.string(fromByteCount: Int64(receipt.data.count), countStyle: .binary))")
                            .font(.caption).foregroundStyle(AppStyle.muted)
                        Spacer()
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            transaction.newReceiptImages.removeAll { $0.id == receipt.id }
                        }
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Reload receipts") { Task { await load() } }
            }
        } header: {
            Text("Receipts").font(VaultTypography.section)
        } footer: {
            Text("Receipt changes apply when you save the transaction. Removed receipts are kept in the vault’s history and excluded from categorization.")
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        guard transaction.revision > 0 else { return }
        do {
            records = try await receiptState.receiptRecords(transactionID: transaction.id.uuidString)
            images = [:]
            for receipt in records where receipt.imageState == "stored" {
                if let data = try await receiptState.receiptImage(id: receipt.id) { images[receipt.id] = NSImage(data: data) }
            }
        } catch { self.error = error.localizedDescription }
    }
}
