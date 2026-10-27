import SwiftUI
import GroundKeeperCore

struct ReceiptEvidenceView: View {
    @Environment(ReceiptWorkspace.self) private var receiptState
    @Environment(\.dismiss) private var dismiss
    let transactionID: String
    let title: String
    @State private var note = ""
    @State private var savedNote = ""
    @State private var revision = 0
    @State private var records: [ReceiptRecord] = []
    @State private var images: [String: NSImage] = [:]
    @State private var lastRemovedID: String?
    @State private var error: String?
    @State private var busy = false
    @State private var loading = true
    @State private var showingDiscard = false
    private var dirty: Bool { note != savedNote }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Notes & receipts", subtitle: title)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Notes").font(.headline)
                    TextField("What was this transaction for?", text: $note, axis: .vertical)
                        .lineLimit(4...10).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Transaction notes")
                        .disabled(loading || busy)
                    HStack {
                        Text("Notes help your selected models categorize this transaction.")
                            .font(.caption).foregroundStyle(AppStyle.muted)
                        Spacer()
                        Button("Save notes") { Task { await saveNotes() } }
                            .disabled(!dirty || busy || loading)
                    }
                    if note.utf8.count > 1600 {
                        Text("Long notes are shortened for classification; the full note stays saved here.").font(.caption).foregroundStyle(AppStyle.muted)
                    }
                    Divider()
                    Text("Receipts").font(.headline)
                    ReceiptImportControls { data in
                        Task { await perform { try await receiptState.addReceiptImage(transactionID: transactionID, data: data) } }
                    }.disabled(busy || loading)
                    if loading { ProgressView("Loading notes and receipts…").controlSize(.small) }
                    else if busy { ProgressView("Updating transaction…").controlSize(.small) }
                    if !loading && records.isEmpty { Text("No receipts attached.").foregroundStyle(AppStyle.muted) }
                    ForEach(records) { receipt in
                        VStack(alignment: .leading, spacing: 10) {
                            if let image = images[receipt.id] {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 280)
                                    .accessibilityLabel("Receipt image")
                            }
                            if receipt.imageState == "pending" { Text("Waiting for the receipt image from iCloud.").font(.caption) }
                            if receipt.imageState == "invalid" { Text("The queued image could not be imported. Add the image again to retry.").font(.caption) }
                            DisclosureGroup("Receipt text") {
                                Text(receipt.text.isEmpty ? "No text was recognized. You can describe the purchase in Notes." : receipt.text)
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                            HStack {
                                if receipt.imageState == "stored" {
                                    Button("Read image again") {
                                        Task { await perform { try await receiptState.reprocessReceipt(id: receipt.id) } }
                                    }
                                }
                                Spacer()
                                Button("Remove receipt", role: .destructive) {
                                    Task {
                                        await perform {
                                            try await receiptState.setReceiptRemoved(id: receipt.id, transactionID: transactionID, removed: true)
                                            lastRemovedID = receipt.id
                                        }
                                    }
                                }
                            }.disabled(busy)
                            Divider()
                        }
                    }
                    if let id = lastRemovedID {
                        HStack {
                            Text("Receipt removed from this transaction and classifier context.").font(.caption)
                            Button("Undo") {
                                Task {
                                    await perform {
                                        try await receiptState.setReceiptRemoved(id: id, transactionID: transactionID, removed: false)
                                        lastRemovedID = nil
                                    }
                                }
                            }.disabled(busy)
                        }
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Button("Reload saved notes and receipts") { Task { await load(replaceNote: true) } }.disabled(busy)
                    }
                }.padding(24)
            }
            SheetFooter {
                Spacer()
                Button("Done") {
                    if dirty { showingDiscard = true } else { dismiss() }
                }.keyboardShortcut(.cancelAction).disabled(busy)
            }
        }
        .frame(width: 650, height: 620)
        .interactiveDismissDisabled(dirty || busy)
        .confirmationDialog("Save your notes before closing?", isPresented: $showingDiscard, titleVisibility: .visible) {
            Button("Save notes and close") { Task { if await saveNotes() { dismiss() } } }
            Button("Discard note changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) { }
        }
        .task(id: transactionID) { await load(replaceNote: true) }
    }
    @discardableResult private func saveNotes() async -> Bool {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await receiptState.saveTransactionNote(transactionID: transactionID, text: note, revision: revision)
            savedNote = note
            await load(replaceNote: true)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func perform(_ operation: () async throws -> Void) async {
        // Save the visible note first so receipt edits cannot invalidate its revision.
        if dirty, !(await saveNotes()) { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await operation(); await load(replaceNote: true) }
        catch { self.error = error.localizedDescription }
    }
    private func load(replaceNote: Bool) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let current = try await receiptState.transactionNote(transactionID: transactionID)
            revision = current.revision
            if replaceNote { note = current.text; savedNote = current.text }
            records = try await receiptState.receiptRecords(transactionID: transactionID)
            images = [:]
            for receipt in records where receipt.imageState == "stored" {
                if let data = try await receiptState.receiptImage(id: receipt.id), let image = NSImage(data: data) { images[receipt.id] = image }
            }
        } catch { self.error = error.localizedDescription }
    }
}
