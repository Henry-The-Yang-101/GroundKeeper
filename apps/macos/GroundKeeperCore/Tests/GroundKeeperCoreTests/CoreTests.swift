import Foundation
import Testing
@testable import GroundKeeperCore

extension LedgerStore {
    func testRows(_ sql: String) throws -> [Row] { try db.query(sql) }
    func makeRetriesDue() throws { try db.query("UPDATE classification_jobs SET next_attempt_at_ms=0 WHERE status='pending'") }
}
func vault() throws -> (LedgerStore, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("vault.sqlite")
    return (try LedgerStore(url: url), url)
}
func capture(_ id: String, wallet: Bool = true, test: Bool = false, time: String = "2026-10-17T10:00:00-04:00", amount: String = "CAD 12.50") throws -> Data {
    var payload: [String: Any] = ["schema_version": 2, "event_id": id, "source": wallet ? "wallet_transaction" : "bank_notification", "captured_at": time,
        "app": wallet ? "Wallet" : "Example Bank", "input_shape": wallet ? "wallet_transaction_fields" : "notification_fields", "is_test": test]
    if wallet { payload.merge(["merchant": "FICTIONAL CAFE", "amount": amount, "card_or_pass": "Example card"]) { _, new in new } }
    else { payload.merge(["subtitle": "FICTIONAL CAFE", "body": amount, "title": "Example card"]) { _, new in new } }
    return try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
}
func ingestMapped(_ store: LedgerStore, id: String, wallet: Bool = true) async throws {
    try await store.ingestCapture(data: capture(id, wallet: wallet), deliveryPath: id + ".json")
    let snapshot = try await store.snapshot()
    if let review = snapshot.reviews.first(where: { $0.reason == "account_mapping_required" }) {
        try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: snapshot.accounts[0].id)
    }
}
@Test func exactAmountsAndDates() throws {
    #expect(try ExactMoney.parse("CAD 1,234.56", currency: "CAD") == 123456)
    #expect(try ExactMoney.parse("(12.50)", currency: "CAD") == -1250)
    #expect(try ExactMoney.parse("1.234,56", currency: "EUR", decimalComma: true) == 123456)
    for invalid in ["12.345", "12abc", "1,23.00", "9223372036854775807", "USD 5", "1$2", "CADCAD 12", "$12$"] {
        #expect(throws: (any Error).self) { try ExactMoney.parse(invalid, currency: "CAD") }
    }
    #expect(throws: (any Error).self) { try CivilDate.parse("2026-02-30") }
    #expect(throws: (any Error).self) { try CaptureParser.timestamp("2026-10-17T10:00:00") }
}
@Test func csvQuoting() throws {
    let text = "\u{feff}Date,Description,Amount\r\n2026-10-17,\"Cafe, \"\"A\"\"\nLine\",12.50\r\n"
    let rows = try CSVParser.parse(text)
    #expect(rows.count == 2)
    #expect(rows[1][1] == "Cafe, \"A\"\nLine")
    #expect(throws: (any Error).self) { try CSVParser.parse("a,b\n\"unclosed,2") }
}
@Test func migrationsAndPlainSQLite() async throws {
    let (store, url) = try vault()
    #expect(try await store.integrityCheck())
    #expect(try await store.testRows("SELECT * FROM schema_migrations").count == 2)
    let bytes = try Data(contentsOf: url)
    #expect(bytes.starts(with: Data("SQLite format 3".utf8)))
    #expect(throws: (any Error).self) { try LedgerStore(url: url) }
}
@Test func captureReplayCollisionTestFlagAndOneToOneMatching() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Test card", currency: "CAD")
    try await ingestMapped(store, id: "w1")
    try await ingestMapped(store, id: "b1", wallet: false)
    #expect(try await store.snapshot().transactions.count == 1)
    let original = try capture("w1")
    try await store.ingestCapture(data: original, deliveryPath: "renamed.json")
    #expect(try await store.snapshot().transactions.count == 1)
    try await store.ingestCapture(data: capture("w1", amount: "CAD 13.00"), deliveryPath: "collision.json")
    #expect(try await store.snapshot().queue.contains { $0.error == "event_identity_collision" })
    try await store.ingestCapture(data: capture("sample", test: true), deliveryPath: "test.json")
    #expect(try await store.snapshot().transactions.count == 1)
    try await ingestMapped(store, id: "w2")
    #expect(try await store.snapshot().transactions.count == 2)
    try await ingestMapped(store, id: "b2", wallet: false)
    #expect(try await store.snapshot().transactions.count == 2)
    #expect(try await store.integrityCheck())
}
@Test func csvImportAtomicityReplayAndReview() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Test card", currency: "CAD")
    try await ingestMapped(store, id: "w1")
    var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
    let document = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-18,FICTIONAL CAFE,-12.50\n2026-10-19,NEW SHOP,-9.25\n".utf8), filename: "test.csv")
    #expect(try await store.importCSV(document, mapping: mapping) == 2)
    #expect(try await store.snapshot().transactions.count == 2)
    let review = try await store.snapshot().reviews.first { $0.reason == "possible_duplicate" }!
    try await store.resolveMatch(eventID: review.eventID, transactionID: review.candidates[0])
    #expect(try await store.snapshot().transactions.count == 2)
    #expect(try await store.importCSV(document, mapping: mapping) == 0)
    let bad = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-20,GOOD,-1.00\n2026-02-30,BAD,no\n".utf8), filename: "bad.csv")
    do { _ = try await store.importCSV(bad, mapping: mapping); Issue.record("Invalid CSV committed") } catch {}
    #expect(try await store.snapshot().transactions.count == 2)
    #expect(try await store.importCSV(bad, mapping: mapping, skipped: [3]) == 1)
    #expect(try await store.integrityCheck())
}
@Test func staleClassificationCannotOverwriteUserEditAndRecovery() async throws {
    var (store, url) = try vault()
    try await store.addAccount(name: "Test card", currency: "CAD")
    try await ingestMapped(store, id: "w1")
    let model = String(repeating: "a", count: 64)
    try await store.registerModel(id: model, name: "fixture", backend: "qwen_mlx", policy: "groundkeeper-18-v1", configuration: "{}")
    try await store.enqueueClassifications(modelID: model)
    let job = try await store.claimClassification(modelID: model)!
    let record = try await store.snapshot().transactions[0]
    try await store.save(TransactionEdit(id: record.id, revision: record.revision, description: record.description, amountMinor: record.amountMinor, currency: record.currency,
        occurredOn: record.occurredOn, accountID: record.accountID, type: "expense", category: "groceries", needsReview: false, notes: "Confirmed"))
    try await store.completeClassification(job, decision: ClassificationDecision(type: "expense", category: "dining", review: true))
    #expect(try await store.snapshot().transactions[0].category == "groceries")
    try await ingestMapped(store, id: "w2")
    try await store.enqueueClassifications(modelID: model)
    _ = try await store.claimClassification(modelID: model)
    await store.close()
    store = try LedgerStore(url: url)
    #expect(try await store.snapshot().pendingJobs == 1)
    #expect(try await store.claimClassification(modelID: model) != nil)
    #expect(try await store.integrityCheck())
}

@Test func reverseArrivalAndDateOnlyMatchesRequireConfirmation() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Test", currency: "CAD")
    var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
    let csv = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-17,FICTIONAL CAFE,-12.50\n".utf8), filename: "posted.csv")
    try await store.importCSV(csv, mapping: mapping)
    try await ingestMapped(store, id: "late-wallet")
    let review = try await store.snapshot().reviews.first { $0.reason == "possible_duplicate" }!
    #expect(try await store.snapshot().transactions.count == 1)
    try await store.resolveMatch(eventID: review.eventID, transactionID: review.candidates[0])
    #expect(try await store.snapshot().transactions.count == 1)
    let (other, _) = try vault()
    try await other.addAccount(name: "Test", currency: "CAD")
    try await ingestMapped(other, id: "bank-first", wallet: false)
    try await ingestMapped(other, id: "wallet-second")
    #expect(try await other.snapshot().transactions.count == 1)
}
@Test func quarantineAndCorrectionRetainEvidence() async throws {
    let (store, _) = try vault()
    for _ in 0..<3 { try await store.ingestCapture(data: Data("broken".utf8), deliveryPath: "broken.json", forceRetry: true) }
    #expect(try await store.snapshot().queue[0].state == "quarantined")
    try await store.addAccount(name: "Test", currency: "CAD")
    let data = try capture("partial", amount: "$12.50")
    try await store.ingestCapture(data: data, deliveryPath: "partial.json")
    #expect(try await store.snapshot().transactions.isEmpty)
    let snapshot = try await store.snapshot(), review = snapshot.reviews[0]
    try await store.correctCapture(eventID: review.eventID, description: "CORRECTED CAFE", amountMinor: -1250, accountID: snapshot.accounts[0].id, day: "2026-10-17")
    #expect(try await store.snapshot().transactions[0].description == "CORRECTED CAFE")
    #expect(try await store.testRows("SELECT * FROM event_observations").count == 2)
    #expect(try await store.testRows("SELECT payload_json FROM raw_event_payloads")[0].text("payload_json") == String(decoding: data, as: UTF8.self))
}
@Test func classificationRetriesAreBoundedAndSuccessIsIdempotent() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Test", currency: "CAD")
    try await ingestMapped(store, id: "w1")
    let model = String(repeating: "b", count: 64)
    try await store.registerModel(id: model, name: "fixture", backend: "laya_mps", policy: "groundkeeper-18-v1", configuration: "{}")
    try await store.enqueueClassifications(modelID: model)
    for _ in 0..<3 {
        let job = try await store.claimClassification(modelID: model)!
        try await store.failClassification(job, code: "busy", retryable: true)
        try await store.makeRetriesDue()
    }
    #expect(try await store.claimClassification(modelID: model) == nil)
    #expect(try await store.snapshot().failedJobs == 1)
    try await store.retryClassificationFailures()
    let job = try await store.claimClassification(modelID: model)!
    let decision = ClassificationDecision(type: "expense", category: "dining", review: true)
    try await store.completeClassification(job, decision: decision)
    try await store.completeClassification(job, decision: decision)
    #expect(try await store.testRows("SELECT * FROM category_assignments").count == 2)
    #expect(try await store.testRows("SELECT status FROM classification_jobs")[0].text("status") == "succeeded")
}

@Test func queueCountsDoNotEnqueueAndExcludeFinishedWork() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Test", currency: "CAD")
    try await ingestMapped(store, id: "count-me")
    #expect(try await store.unqueuedClassificationCount() == 1)
    #expect(try await store.snapshot().pendingJobs == 0)
    #expect(try await store.testRows("SELECT * FROM classification_jobs").isEmpty)
    let model = String(repeating: "c", count: 64)
    try await store.registerModel(id: model, name: "fixture", backend: "qwen_mlx", policy: "groundkeeper-18-v1", configuration: "{}")
    try await store.enqueueClassifications(modelID: model)
    #expect(try await store.unqueuedClassificationCount() == 0)
    #expect(try await store.snapshot().pendingJobs == 1)
    let job = try await store.claimClassification(modelID: model)!
    try await store.failClassification(job, code: "bad_input", retryable: false)
    #expect(try await store.unqueuedClassificationCount() == 0)
    #expect(try await store.snapshot().pendingJobs == 0)
    #expect(try await store.snapshot().failedJobs == 1)
    try await store.retryClassificationFailures()
    #expect(try await store.snapshot().pendingJobs == 1)
    let retry = try await store.claimClassification(modelID: model)!
    try await store.completeClassification(retry, decision: ClassificationDecision(type: "expense", category: "dining", review: true))
    #expect(try await store.unqueuedClassificationCount() == 0)
    #expect(try await store.snapshot().pendingJobs == 0)
}

@Test func deliberateHandoffDoesNotExhaustRetriesOrAcceptLateReplies() async throws {
    let (store, url) = try vault()
    try await store.addAccount(name: "Test", currency: "CAD")
    try await ingestMapped(store, id: "pause-me")
    let model = String(repeating: "d", count: 64)
    try await store.registerModel(id: model, name: "fixture", backend: "qwen_mlx", policy: "groundkeeper-18-v1", configuration: "{}")
    try await store.enqueueClassifications(modelID: model)
    for _ in 0..<5 {
        let job = try await store.claimClassification(modelID: model)!
        try await store.releaseClassification(job)
        try await store.releaseClassification(job) // idempotent
        try await store.completeClassification(job, decision: ClassificationDecision(type: "expense", category: "dining", review: true))
        #expect(try await store.testRows("SELECT attempts FROM classification_jobs")[0].number("attempts") == 0)
        #expect(try await store.snapshot().transactions[0].origin == "system")
    }
    await store.close()
    let nextOwner = try LedgerStore(url: url)
    #expect(try await nextOwner.claimClassification(modelID: model) != nil)
    #expect(try await nextOwner.integrityCheck())
}

@Test func deliveryInventoryExcludesTerminalsAndPreservesBackoff() async throws {
    let (store, _) = try vault()
    let payload = try capture("terminal", test: true)
    try await store.ingestCapture(data: payload, deliveryPath: "done.json")
    let key = contentHash(Data("done.json|\(contentHash(payload))".utf8))
    #expect(try await store.captureDeliveryStates()[key]?.terminal == true)
    let bad = Data("broken".utf8)
    try await store.ingestCapture(data: bad, deliveryPath: "bad.json")
    let badKey = contentHash(Data("bad.json|\(contentHash(bad))".utf8))
    #expect(try await store.captureDeliveryStates()[badKey]?.terminal == false)
    #expect(try await store.captureDeliveryStates()[badKey]!.nextAttemptMS > nowMS())
    for _ in 0..<2 { try await store.ingestCapture(data: bad, deliveryPath: "bad.json", forceRetry: true) }
    #expect(try await store.captureDeliveryStates()[badKey]?.terminal == true)
    try await store.retryQueue()
    #expect(try await store.captureDeliveryStates()[badKey]?.terminal == false)
}

@Test func switchingToNativePCCReplacesPendingLocalJobs() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "provider-switch")
    let local = String(repeating: "a", count: 64), cloud = String(repeating: "b", count: 64)
    try await store.registerModel(id: local, name: "Local", backend: "qwen_mlx", policy: "groundkeeper-18-v1", configuration: "{}")
    try await store.enqueueClassifications(modelID: local)
    try await store.registerModel(id: cloud, name: "Fixture PCC", backend: "apple_pcc", policy: "groundkeeper-18-v1", configuration: "{}")
    #expect(try await store.claimClassification(modelID: local) == nil)
    try await store.registerModel(id: local, name: "Local", backend: "qwen_mlx", policy: "groundkeeper-18-v1", configuration: "{}")
    try await store.enqueueClassifications(modelID: local)
    let revived = try await store.claimClassification(modelID: local)!
    try await store.releaseClassification(revived)
    try await store.registerModel(id: cloud, name: "Fixture PCC", backend: "apple_pcc", policy: "groundkeeper-18-v1", configuration: "{}")
    try await store.enqueueClassifications(modelID: cloud)
    let job = try await store.claimClassification(modelID: cloud)!
    try await store.completeClassification(job, decision: ClassificationDecision(type: "expense", category: "dining", review: true))
    #expect(try await store.snapshot().transactions[0].category == "dining")
    #expect(try await store.integrityCheck())
}
