import SwiftUI
import GroundKeeperCore

struct ReceiptEvidenceView: View {
    @Environment(AppWorkspace.self) private var workspace
    let transactionID: String
    @State private var notes: [CaptureNote] = []
    @State private var records: [ReceiptRecord] = []
    @State private var images: [String: NSImage] = [:]
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Captured note · \(note.app)").font(.headline)
                    Text(note.text).textSelection(.enabled)
                }
            }
            if records.isEmpty { Text("No receipt is attached to this purchase.").foregroundStyle(AppStyle.muted) }
            ForEach(records) { receipt in
                DisclosureGroup("Receipt · \(receipt.imageState == "stored" ? "image saved" : receipt.imageState == "pending" ? "waiting for image" : "text")") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let image = images[receipt.id] { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 280) }
                        Text(receipt.text).font(.caption.monospaced()).textSelection(.enabled)
                        Text(receipt.producer).font(.caption2).foregroundStyle(AppStyle.muted)
                        if receipt.imageState == "stored" {
                            Button("Read image again on this Mac") {
                                busy = true
                                Task {
                                    defer { busy = false }
                                    do { try await workspace.reprocessReceipt(id: receipt.id); await load() }
                                    catch { self.error = error.localizedDescription }
                                }
                            }.disabled(busy || workspace.processing)
                        }
                        if receipt.imageState == "invalid" { Text("The image could not be imported. Receipt text is retained.").font(.caption).foregroundStyle(AppStyle.muted) }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.task(id: transactionID) { await load() }
    }
    private func load() async {
        do {
            notes = try await workspace.captureNotes(transactionID: transactionID)
            records = try await workspace.receiptRecords(transactionID: transactionID)
            for receipt in records where receipt.imageState == "stored" {
                if let data = try await workspace.receiptImage(id: receipt.id), let image = NSImage(data: data) { images[receipt.id] = image }
            }
        } catch { self.error = error.localizedDescription }
    }
}
