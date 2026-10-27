import Foundation
import GroundKeeperCore
import Observation

/// Receipt images, OCR, notes, and sharing preferences use the active vault.
@MainActor @Observable final class ReceiptWorkspace: WorkspaceComponent {
    let session: WorkspaceSession
    var shareReceiptContextWithApple = true

    init(session: WorkspaceSession) { self.session = session }

    func setReceiptSharing(_ enabled: Bool) {
        perform {
            try await self.store?.setReceiptCloudConsent(enabled)
            self.shareReceiptContextWithApple = enabled
            try await self.refresh()
        }
    }

    func transactionNote(transactionID: String) async throws -> TransactionNote {
        guard let store else { throw LedgerError.unavailable("Open the vault first.") }
        return try await store.transactionNote(transactionID: transactionID)
    }

    func saveTransactionNote(transactionID: String, text: String, revision: Int) async throws {
        guard let store else { throw LedgerError.unavailable("Open the vault first.") }
        try await store.saveTransactionNote(transactionID: transactionID, text: text, revision: revision)
        try await refresh()
    }

    func addReceiptImage(transactionID: String, data: Data) async throws {
        guard let store else { throw LedgerError.unavailable("Open the vault first.") }
        // A readable image is useful even when OCR finds no text.
        let ocr = try? await ReceiptOCR.recognizeText(data)
        try await store.addReceiptImage(transactionID: transactionID, data: data, ocrText: ocr?.text ?? "", producer: ocr?.producer ?? "apple_vision_documents")
        try await refresh()
    }

    func setReceiptRemoved(id: String, transactionID: String, removed: Bool) async throws {
        guard let store else { throw LedgerError.unavailable("Open the vault first.") }
        try await store.setReceiptRemoved(id: id, transactionID: transactionID, removed: removed)
        try await refresh()
    }

    func captureNotes(transactionID: String) async throws -> [CaptureNote] { try await store?.captureNotes(transactionID: transactionID) ?? [] }

    func receiptRecords(transactionID: String) async throws -> [ReceiptRecord] { try await store?.receipts(transactionID: transactionID) ?? [] }

    func receiptImage(id: String) async throws -> Data? { try await store?.receiptImage(id: id) }

    func reprocessReceipt(id: String) async throws {
        guard let store, let image = try await store.receiptImage(id: id) else { throw LedgerError.invalid("The receipt image is not available yet.") }
        let result = try await ReceiptOCR.recognize(image)
        try await store.addReceiptOCR(id: id, text: result.text, producer: result.producer)
        try await refresh()
    }
}
