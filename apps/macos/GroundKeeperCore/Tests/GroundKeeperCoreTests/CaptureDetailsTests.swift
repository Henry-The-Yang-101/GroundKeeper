import Foundation
import Testing
@testable import GroundKeeperCore

func detailedCapture(_ id: String, wallet: Bool = true, note: String? = nil, receipt: Bool = false, test: Bool = false) throws -> Data {
    var value = try JSONSerialization.jsonObject(with: capture(id, wallet: wallet, test: test)) as! [String: Any]
    value["schema_version"] = 4
    if let note { value["note"] = note }
    if receipt { value["receipt"] = ["ocr": ["producer": "apple_shortcuts", "text": "Coffee beans 12.50"], "image": ["path": "assets/fictional.jpg"]] }
    return try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
}

@Test func captureDetailsSurviveMappingReplayAndBankReconciliation() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    let data = try detailedCapture("details", note: "Coffee for the office ☕\n\"Shared\" purchase", receipt: true)
    try await store.ingestCapture(data: data, deliveryPath: "Fictional_Coffee_Wallet_CAPTURE_2026-10-20_12-00-00-123.json")
    #expect(try await store.snapshot().transactions.isEmpty)
    #expect(try await store.testRows("SELECT * FROM capture_notes").count == 1)
    let review = try await store.snapshot().reviews[0]
    try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: store.snapshot().accounts[0].id)
    let transaction = try await store.snapshot().transactions[0]
    #expect(try await store.captureNotes(transactionID: transaction.id)[0].text == "Coffee for the office ☕\n\"Shared\" purchase")
    #expect(try await store.receipts(transactionID: transaction.id).count == 1)
    #expect(try await store.receiptImageRequests().count == 1)
    try await store.ingestCapture(data: data, deliveryPath: "renamed.json")
    #expect(try await store.snapshot().transactions[0].revision == transaction.revision)
    try await store.ingestCapture(data: detailedCapture("bank", wallet: false, note: "Bank note"), deliveryPath: "bank.json")
    let bankReview = try await store.snapshot().reviews.first { $0.reason == "account_mapping_required" }!
    try await store.confirmMapping(sourceID: bankReview.sourceID, label: bankReview.label, accountID: store.snapshot().accounts[0].id)
    #expect(try await store.snapshot().transactions.count == 1)
    #expect(try await store.captureNotes(transactionID: transaction.id).count == 2)
    try await store.ingestCapture(data: detailedCapture("details", note: "Changed", receipt: true), deliveryPath: "collision.json")
    #expect(try await store.snapshot().queue.contains { $0.error == "event_identity_collision" })
    #expect(try await store.captureNotes(transactionID: transaction.id).count == 2)
    #expect(try await store.integrityCheck())
}

@Test func optionalCaptureDetailsAndTestIsolation() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "old")
    for (id, note, receipt) in [("skip", nil, false), ("note", "Lunch", false), ("receipt", nil, true)] as [(String, String?, Bool)] {
        try await store.ingestCapture(data: detailedCapture(id, note: note, receipt: receipt), deliveryPath: id + ".json")
    }
    #expect(try await store.snapshot().transactions.count == 4)
    try await store.ingestCapture(data: detailedCapture("test", note: "Test only", receipt: true, test: true), deliveryPath: "test.json")
    #expect(try await store.snapshot().transactions.count == 4)
    #expect(try await store.testRows("SELECT * FROM receipt_captures WHERE is_test=1 AND transaction_id IS NOT NULL").isEmpty)
}

@Test func invalidDetailsRejectWholeCapture() async throws {
    let (store, _) = try vault()
    for (index, note) in ["", "   ", "bad\0note", String(repeating: "🦊", count: 2501)].enumerated() {
        try await store.ingestCapture(data: detailedCapture("invalid\(index)", note: note), deliveryPath: "invalid\(index).json")
    }
    var bad = try JSONSerialization.jsonObject(with: detailedCapture("invalid-receipt", note: "Valid note", receipt: true)) as! [String: Any]
    bad["receipt"] = ["ocr": ["producer": "apple_shortcuts", "text": ""], "image": ["path": "../private.jpg"]]
    try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: bad), deliveryPath: "bad-receipt.json")
    #expect(try await store.testRows("SELECT * FROM raw_events").isEmpty)
    #expect(try await store.testRows("SELECT * FROM capture_notes").isEmpty)
    #expect(try await store.testRows("SELECT * FROM receipt_captures").isEmpty)
}

extension LedgerStore {
    func failInlineReceiptForTest() throws {
        try db.executeScript("CREATE TRIGGER fail_inline BEFORE INSERT ON receipt_ocr_runs BEGIN SELECT RAISE(ABORT,'fixture failure'); END;")
    }
    func simulateVersionThree() throws {
        try db.executeScript("DROP TABLE capture_notes; DELETE FROM schema_migrations WHERE version=4;")
    }
}
@Test func evidenceFailureRollsBackPaymentAndNote() async throws {
    let (store, _) = try vault()
    try await store.failInlineReceiptForTest()
    do { try await store.ingestCapture(data: detailedCapture("failure", note: "A note", receipt: true), deliveryPath: "failure.json") } catch {}
    #expect(try await store.testRows("SELECT * FROM raw_events").isEmpty)
    #expect(try await store.testRows("SELECT * FROM capture_notes").isEmpty)
    #expect(try await store.testRows("SELECT * FROM receipt_captures").isEmpty)
    #expect(try await store.snapshot().queue[0].state == "waiting")
}
@Test func versionThreeUpgradePreservesEditableNotesAndReceipts() async throws {
    let (store, url) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "payment")
    try await store.ingestCapture(data: receiptCapture("old-receipt"), deliveryPath: "old-receipt.json")
    let before = try await store.snapshot().transactions[0]
    try await store.simulateVersionThree()
    await store.close()
    let upgraded = try LedgerStore(url: url)
    let after = try await upgraded.snapshot().transactions[0]
    #expect(after.id == before.id && after.revision == before.revision && after.notes == before.notes)
    #expect(try await upgraded.receipts(transactionID: after.id).count == 1)
    #expect(try await upgraded.captureNotes(transactionID: after.id).isEmpty)
    #expect(try await upgraded.integrityCheck())
}
