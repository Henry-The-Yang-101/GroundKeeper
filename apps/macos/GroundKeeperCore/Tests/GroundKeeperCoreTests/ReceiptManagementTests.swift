import Foundation
import Testing
@testable import GroundKeeperCore

private let receiptPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=")!

@Test func unreadableReceiptDimensionsAreRejectedBeforeOCR() async {
    await #expect(throws: LedgerError.self) { try await ReceiptOCR.recognize(receiptPNG) }
}

@Test func capturedNotesAreEditableContextWithoutChangingConfirmedCategories() async throws {
    var (store, url) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    let data = try detailedCapture("note", note: "Office supplies for work")
    try await store.ingestCapture(data: data, deliveryPath: "note.json")
    let review = try #require(try await store.snapshot().reviews.first)
    try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: store.snapshot().accounts[0].id)
    let transaction = try #require(try await store.snapshot().transactions.first)
    #expect(transaction.notes == "Office supplies for work")
    let model = try await receiptModel(store)
    try await store.enqueueClassifications(modelID: model)
    let stale = try #require(try await store.claimClassification(modelID: model))
    #expect(stale.transactionNotes == transaction.notes)
    try await store.saveTransactionNote(transactionID: transaction.id, text: "Birthday gift for a friend", revision: transaction.revision)
    try await store.completeClassification(stale, decision: .init(type: "expense", category: "shopping", review: true))
    #expect(try await store.snapshot().transactions[0].origin == "system")
    try await store.enqueueClassifications(modelID: model)
    let current = try #require(try await store.claimClassification(modelID: model))
    #expect(current.transactionNotes == "Birthday gift for a friend")
    try await store.completeClassification(current, decision: .init(type: "expense", category: "gifts", review: true))
    let beforeClear = try await store.transactionNote(transactionID: transaction.id)
    try await store.saveTransactionNote(transactionID: transaction.id, text: "", revision: beforeClear.revision)
    try await store.enqueueClassifications(modelID: model)
    let cleared = try #require(try await store.claimClassification(modelID: model))
    #expect(cleared.transactionNotes == nil)
    await #expect(throws: LedgerError.self) { try await store.saveTransactionNote(transactionID: transaction.id, text: "Stale edit", revision: beforeClear.revision) }
    await store.close(); store = try LedgerStore(url: url)
    try await store.ingestCapture(data: data, deliveryPath: "replayed.json")
    #expect(try await store.transactionNote(transactionID: transaction.id).text.isEmpty)
    #expect(try await store.captureNotes(transactionID: transaction.id)[0].text == "Office supplies for work")
}

@Test func manualReceiptAddRemoveUndoAndReplayKeepEvidenceLinked() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "payment")
    let transaction = try await store.snapshot().transactions[0]
    let id = try await store.addReceiptImage(transactionID: transaction.id, data: receiptPNG, ocrText: "MILK 4.99")
    #expect(try await store.receiptImage(id: id) == receiptPNG)
    #expect(try await store.receipts(transactionID: transaction.id).count == 1)
    let model = try await receiptModel(store)
    try await store.enqueueClassifications(modelID: model)
    let job = try #require(try await store.claimClassification(modelID: model))
    #expect(job.receiptContext?.text == "MILK 4.99")
    try await store.setReceiptRemoved(id: id, transactionID: transaction.id, removed: true)
    #expect(try await store.receipts(transactionID: transaction.id).isEmpty)
    try await store.enqueueClassifications(modelID: model)
    #expect(try await store.claimClassification(modelID: model)?.receiptContext == nil)
    try await store.setReceiptRemoved(id: id, transactionID: transaction.id, removed: false)
    #expect(try await store.receipts(transactionID: transaction.id).count == 1)
    #expect(try await store.receiptImage(id: id) == receiptPNG)
    await #expect(throws: LedgerError.self) { try await store.addReceiptImage(transactionID: transaction.id, data: Data("invalid".utf8)) }
    #expect(try await store.receipts(transactionID: transaction.id).count == 1)
    #expect(try await store.integrityCheck())
}

@Test func queueCleanupRequiresDurableExactCopiesAndSurvivesReopen() async throws {
    var (store, url) = try vault()
    let inbox = url.deletingLastPathComponent().appendingPathComponent("inbox")
    try FileManager.default.createDirectory(at: inbox.appendingPathComponent("assets"), withIntermediateDirectories: true)
    let data = try detailedCapture("queued", note: "Fictional note", receipt: true)
    try data.write(to: inbox.appendingPathComponent("queued.json"))
    try receiptPNG.write(to: inbox.appendingPathComponent("assets/fictional.jpg"))
    try await store.ingestCapture(data: data, deliveryPath: "queued.json")
    // Account review does not block durable raw capture storage or queue acknowledgement.
    let json = try #require(try await store.pendingFileCleanups().first { $0.kind == "json" })
    #expect(try await store.pendingFileCleanups().allSatisfy { $0.kind != "image" })
    #expect(try CaptureQueueFileCleaner.removeStoredCopy(json, inbox: inbox))
    // Crash after unlink and before its database acknowledgement.
    await store.close(); store = try LedgerStore(url: url)
    #expect(try CaptureQueueFileCleaner.removeStoredCopy(json, inbox: inbox))
    try await store.completeFileCleanup(id: json.id)
    let receipt = try #require(try await store.receiptImageRequests().first)
    try await store.storeReceiptImage(id: receipt.id, data: receiptPNG)
    let image = try #require(try await store.pendingFileCleanups().first { $0.kind == "image" })
    try await store.failFileCleanup(id: image.id)
    await store.close(); store = try LedgerStore(url: url)
    #expect(try await store.pendingFileCleanups().contains { $0.id == image.id })
    #expect(try CaptureQueueFileCleaner.removeStoredCopy(image, inbox: inbox))
    try await store.completeFileCleanup(id: image.id)
    #expect(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("assets/fictional.jpg").path))
    #expect(try await store.receiptImage(id: receipt.id) == receiptPNG)
    #expect(try await store.captureReviewContext(eventID: store.snapshot().reviews[0].eventID).payload == String(decoding: data, as: UTF8.self))
    #expect(try await store.pendingFileCleanups().isEmpty)
    try await store.ingestCapture(data: Data("broken".utf8), deliveryPath: "bad.json")
    #expect(try await store.pendingFileCleanups().isEmpty)
}

@Test func queueCleanupDoesNotDeleteChangedOrSymlinkedFiles() async throws {
    let (store, url) = try vault()
    let inbox = url.deletingLastPathComponent().appendingPathComponent("inbox")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let data = try capture("queued", test: true)
    try await store.ingestCapture(data: data, deliveryPath: "queued.json")
    let request = try #require(try await store.pendingFileCleanups().first)
    let file = inbox.appendingPathComponent("queued.json")
    try Data("changed".utf8).write(to: file)
    #expect(try !CaptureQueueFileCleaner.removeStoredCopy(request, inbox: inbox))
    #expect(try Data(contentsOf: file) == Data("changed".utf8))
    try FileManager.default.removeItem(at: file)
    let outside = url.deletingLastPathComponent().appendingPathComponent("outside.json")
    try data.write(to: outside)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
    #expect(throws: LedgerError.self) { try CaptureQueueFileCleaner.removeStoredCopy(request, inbox: inbox) }
    #expect(try Data(contentsOf: outside) == data)
}

@Test func lateContentAddressedReceiptReusesStoredImageAfterQueueDeletion() async throws {
    let (store, _) = try vault()
    let path = "assets/\(contentHash(receiptPNG)).png"
    try await store.ingestCapture(data: receiptCapture("first", image: path), deliveryPath: "first.json")
    let first = try #require(try await store.receiptImageRequests().first)
    try await store.storeReceiptImage(id: first.id, data: receiptPNG)
    try await store.ingestCapture(data: receiptCapture("second", image: path), deliveryPath: "second.json")
    let second = try #require(try await store.receiptImageRequests().first)
    try await store.reuseStoredReceiptImages()
    #expect(try await store.receiptImageRequests().isEmpty)
    #expect(try await store.receiptImage(id: second.id) == receiptPNG)
}

@Test func notesReachEveryCouncilMemberEvenWhenAppleReceiptSharingIsOff() async throws {
    let (store, _, config) = try await councilFixture(receipt: true)
    let transaction = try await store.snapshot().transactions[0]
    try await store.saveTransactionNote(transactionID: transaction.id, text: "Birthday gift", revision: transaction.revision)
    try await store.setReceiptCloudConsent(false)
    try await store.enqueueCouncil(configID: config.id)
    let task = try #require(try await store.claimCouncil(configID: config.id))
    try await bindNoCouncilSearch(store, task)
    for member in config.members {
        let child = try await store.startCouncilMember(member, task: task)
        #expect(child.input.transactionNotes == "Birthday gift")
        if member.backend == "apple_shortcut" { #expect(child.input.receiptContext == nil) }
    }
    let runs = try await store.testRows("SELECT input_json FROM classification_runs")
    #expect(runs.allSatisfy { $0.text("input_json").contains("transaction_notes") })
}

extension LedgerStore {
    func simulateVersionEightReceiptVault() throws {
        try db.executeScript("DROP TABLE capture_note_imports; DROP TABLE capture_file_cleanups; ALTER TABLE receipt_captures DROP COLUMN removed_at_ms; DELETE FROM schema_migrations WHERE version=9; UPDATE transactions SET notes='Existing editable note';")
    }
}
@Test func versionEightUpgradeImportsNotesAndSchedulesOldFileCleanupOnce() async throws {
    var (store, url) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await store.ingestCapture(data: detailedCapture("old-note", note: "Captured note"), deliveryPath: "old.json")
    let review = try #require(try await store.snapshot().reviews.first)
    try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: store.snapshot().accounts[0].id)
    try await store.simulateVersionEightReceiptVault()
    await store.close(); store = try LedgerStore(url: url)
    let transaction = try await store.snapshot().transactions[0]
    #expect(transaction.notes == "Existing editable note\n\nCaptured note")
    #expect(try await store.pendingFileCleanups().count == 1)
    try await store.saveTransactionNote(transactionID: transaction.id, text: "Rewritten note", revision: transaction.revision)
    await store.close(); store = try LedgerStore(url: url)
    #expect(try await store.snapshot().transactions[0].notes == "Rewritten note")
    #expect(try await store.integrityCheck())
}
