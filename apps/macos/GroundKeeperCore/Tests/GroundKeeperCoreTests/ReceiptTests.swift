import Foundation
import Testing
@testable import GroundKeeperCore

extension LedgerStore {
    func simulatePreReceiptVault() throws {
        try db.executeScript("DROP TABLE receipt_images; DROP TABLE receipt_ocr_runs; DROP TABLE receipt_captures; ALTER TABLE classification_jobs DROP COLUMN receipt_context_sha256; ALTER TABLE classification_runs DROP COLUMN context_version; DELETE FROM schema_migrations WHERE version=3;")
    }
}
@Test func existingVersionTwoVaultUpgradesWithoutChangingPurchases() async throws {
    let (store, url) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "existing")
    let before = try await store.snapshot().transactions[0]
    try await store.simulatePreReceiptVault()
    await store.close()
    let upgraded = try LedgerStore(url: url)
    let after = try await upgraded.snapshot().transactions[0]
    #expect(after.id == before.id && after.revision == before.revision && after.amountMinor == before.amountMinor)
    #expect(try await upgraded.testRows("SELECT * FROM schema_migrations").count == 9)
    #expect(try await upgraded.integrityCheck())
}

func receiptCapture(_ id: String, parent: String = "payment", text: String = "MILK 4.99\nBREAD 3.49", image: String? = nil, test: Bool = false) throws -> Data {
    var receipt: [String: Any] = ["ocr": ["producer": "apple_shortcuts", "text": text]]
    if let image { receipt["image"] = ["path": image] }
    return try JSONSerialization.data(withJSONObject: ["schema_version": 3, "source": "receipt_attachment", "event_id": id,
        "captured_at": "2026-10-20T10:00:00-04:00", "is_test": test,
        "target": ["source": "wallet_transaction", "app": "Wallet", "event_id": parent], "receipt": receipt], options: .sortedKeys)
}
func receiptModel(_ store: LedgerStore, backend: String = "qwen_mlx") async throws -> String {
    let model = String(repeating: "a", count: 64)
    try await store.registerModel(id: model, name: "fixture", backend: backend, policy: "groundkeeper-18-v1", configuration: "{}")
    return model
}
@Test func receiptBeforePaymentLinksOnceAndNeverCreatesPurchase() async throws {
    let (store, _) = try vault()
    let data = try receiptCapture("receipt")
    try await store.ingestCapture(data: data, deliveryPath: "r.json")
    #expect(try await store.snapshot().transactions.isEmpty)
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "payment")
    let transaction = try await store.snapshot().transactions[0]
    #expect(try await store.receipts(transactionID: transaction.id).count == 1)
    try await store.ingestCapture(data: data, deliveryPath: "copy.json")
    #expect(try await store.snapshot().transactions.count == 1)
    #expect(try await store.snapshot().transactions[0].revision == transaction.revision)
    try await store.ingestCapture(data: receiptCapture("receipt", text: "DIFFERENT"), deliveryPath: "collision.json")
    #expect(try await store.snapshot().queue.contains { $0.error == "event_identity_collision" })
    #expect(try await store.receipts(transactionID: transaction.id)[0].text == "MILK 4.99\nBREAD 3.49")
    #expect(try await store.integrityCheck())
}
@Test func lateReceiptInvalidatesOldReplyAndRevisitsModelSuggestion() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "payment")
    let model = try await receiptModel(store)
    try await store.enqueueClassifications(modelID: model)
    let stale = try await store.claimClassification(modelID: model)!
    #expect(stale.receiptContext == nil)
    try await store.ingestCapture(data: receiptCapture("receipt"), deliveryPath: "r.json")
    try await store.completeClassification(stale, decision: .init(type: "expense", category: "shopping", review: true))
    #expect(try await store.snapshot().transactions[0].origin == "system")
    try await store.enqueueClassifications(modelID: model)
    let current = try await store.claimClassification(modelID: model)!
    #expect(current.receiptContext?.text.contains("MILK") == true)
    #expect(current.revision > stale.revision)
    try await store.completeClassification(current, decision: .init(type: "expense", category: "groceries", review: true))
    try await store.ingestCapture(data: receiptCapture("receipt2", text: "MILK\nCOAT"), deliveryPath: "r2.json")
    try await store.enqueueClassifications(modelID: model)
    #expect(try await store.claimClassification(modelID: model)?.receiptContext?.text.contains("COAT") == true)
}
@Test func receiptNeverChangesConfirmedCategoryOrMoney() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "payment")
    let t = try await store.snapshot().transactions[0]
    try await store.save(.init(id: t.id, revision: t.revision, description: t.description, amountMinor: t.amountMinor, currency: t.currency, occurredOn: t.occurredOn, accountID: t.accountID, type: "expense", category: "dining", needsReview: false, notes: "Confirmed"))
    try await store.ingestCapture(data: receiptCapture("receipt", text: "TOTAL 9999.99\nMILK"), deliveryPath: "r.json")
    let model = try await receiptModel(store)
    try await store.enqueueClassifications(modelID: model)
    #expect(try await store.claimClassification(modelID: model) == nil)
    let after = try await store.snapshot().transactions[0]
    #expect(after.category == "dining" && after.amountMinor == t.amountMinor && after.currency == t.currency)
}
@Test func cloudReceiptSharingDefaultsOnAndHonorsSavedChoices() async throws {
    let (store, _) = try vault()
    #expect(try await store.receiptCloudConsent())
    try await store.setReceiptCloudConsent(false)
    #expect(try await !store.receiptCloudConsent())
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "payment")
    try await store.ingestCapture(data: receiptCapture("receipt"), deliveryPath: "r.json")
    let model = try await receiptModel(store, backend: "apple_shortcut")
    try await store.enqueueClassifications(modelID: model)
    let privateJob = try await store.claimClassification(modelID: model)!
    #expect(privateJob.receiptContext == nil)
    try await store.completeClassification(privateJob, decision: .init(type: "expense", category: "shopping", review: true))
    try await store.setReceiptCloudConsent(true)
    try await store.enqueueClassifications(modelID: model)
    let shared = try await store.claimClassification(modelID: model)!
    #expect(shared.receiptContext != nil)
    let runs = try await store.testRows("SELECT input_json,context_version FROM classification_runs ORDER BY rowid")
    #expect(!runs[0].text("input_json").contains("MILK"))
    #expect(runs[1].text("input_json").contains("MILK"))
    #expect(runs[1].text("context_version") == "receipt-context-v1")
    try await store.setReceiptCloudConsent(false)
    try await store.completeClassification(shared, decision: .init(type: "expense", category: "groceries", review: true))
    #expect(try await store.snapshot().transactions[0].category == "shopping")
    try await store.enqueueClassifications(modelID: model)
    #expect(try await store.claimClassification(modelID: model)?.receiptContext == nil)
}
@Test func receiptBoundsTestIsolationAndPathTraversal() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "payment")
    for (index, path) in ["../secret.jpg", "/tmp/secret.jpg", "assets/../../secret.jpg"].enumerated() {
        #expect(throws: (any Error).self) { try ReceiptEnvelope.decode(receiptCapture("bad\(index)", image: path)) }
    }
    #expect(throws: (any Error).self) { try ReceiptEnvelope.decode(receiptCapture("long", text: String(repeating: "a", count: 32_769))) }
    try await store.ingestCapture(data: receiptCapture("test", test: true), deliveryPath: "test.json")
    let t = try await store.snapshot().transactions[0]
    #expect(try await store.receipts(transactionID: t.id).isEmpty)
}
@Test func receiptImageFollowsVaultEncryptionAndConversion() async throws {
    let (store, url) = try vault()
    try await store.ingestCapture(data: receiptCapture("image", image: "assets/image.png"), deliveryPath: "image.json")
    let id = try await store.receiptImageRequests()[0].id
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=")!
    try await store.storeReceiptImage(id: id, data: png)
    #expect(try await store.receiptImage(id: id) == png)
    try await store.changeEncryption(to: "fictional-test-passphrase")
    #expect(try await store.receiptImage(id: id) == png)
    await store.close()
    let encrypted = try LedgerStore(url: url, passphrase: "fictional-test-passphrase")
    #expect(try await encrypted.receiptImage(id: id) == png)
    #expect(try await encrypted.integrityCheck())
}
