import Foundation
import Testing
@testable import GroundKeeperCore

@Test func walletCategoryIsReadFromOriginalPayloadWithoutDuplicatingTheValue() async throws {
    let (store, _) = try vault()
    let migrationCount = try await store.testRows("SELECT * FROM schema_migrations").count
    try await store.addAccount(name: "Fixture", currency: "CAD")
    var payload = try JSONSerialization.jsonObject(with: capture("wallet-category")) as! [String: Any]
    payload["wallet_category_raw"] = "Food & Drink"
    let original = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
    try await store.ingestCapture(data: original, deliveryPath: "wallet-category.json")
    let review = try await store.snapshot().reviews.first!
    let accountID = try await store.snapshot().accounts[0].id
    try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: accountID)
    try await store.ingestCapture(data: receiptCapture("wallet-receipt", parent: "wallet-category"), deliveryPath: "receipt.json")
    let model = try await receiptModel(store)
    try await store.enqueueClassifications(modelID: model)
    let job = try await store.claimClassification(modelID: model)!
    #expect(job.walletCategoryRaw == "Food & Drink")
    #expect(job.description == "FICTIONAL CAFE")
    #expect(job.receiptContext?.text.contains("MILK") == true)
    let source = try await store.testRows("SELECT e.id,p.payload_json FROM raw_events e JOIN raw_event_payloads p ON p.event_id=e.id WHERE e.source_event_id='wallet-category'")[0]
    #expect(source.text("payload_json") == String(decoding: original, as: UTF8.self))
    let run = try await store.testRows("SELECT input_json,input_sha256 FROM classification_runs")[0]
    let audit = try JSONSerialization.jsonObject(with: Data(run.text("input_json").utf8)) as! [String: Any]
    #expect(audit["wallet_category_raw"] == nil)
    #expect(audit["wallet_category_source_event_id"] as? String == source.text("id"))
    var reconstructed = audit
    reconstructed.removeValue(forKey: "wallet_category_source_event_id")
    reconstructed["wallet_category_raw"] = "Food & Drink"
    let input = try JSONSerialization.data(withJSONObject: reconstructed, options: [.sortedKeys, .withoutEscapingSlashes])
    #expect(run.text("input_sha256") == contentHash(input))
    #expect(try await store.testRows("SELECT * FROM schema_migrations").count == migrationCount)
    #expect(try await store.integrityCheck())
}

@Test func missingInvalidAndNonWalletCategoriesDoNotBlockClassification() async throws {
    let hints: [Any?] = [nil, NSNull(), "", "  ", 42, ["name": "Food"], String(repeating: "界", count: 43), "Food\nDrink", "Food\0", "Food\u{7f}"]
    for (index, hint) in hints.enumerated() {
        let (store, _) = try vault()
        try await store.addAccount(name: "Fixture", currency: "CAD")
        var payload = try JSONSerialization.jsonObject(with: capture("invalid-\(index)")) as! [String: Any]
        payload["wallet_category_raw"] = hint
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await store.ingestCapture(data: data, deliveryPath: "invalid.json")
        let snapshot = try await store.snapshot()
        let review = snapshot.reviews.first!
        try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: snapshot.accounts[0].id)
        let model = try await receiptModel(store)
        try await store.enqueueClassifications(modelID: model)
        let job = try await store.claimClassification(modelID: model)
        #expect(job != nil && job?.walletCategoryRaw == nil)
    }
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    var bank = try JSONSerialization.jsonObject(with: capture("bank-category", wallet: false)) as! [String: Any]
    bank["wallet_category_raw"] = "Food & Drink"
    try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: bank), deliveryPath: "bank.json")
    let snapshot = try await store.snapshot()
    let review = snapshot.reviews.first!
    try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: snapshot.accounts[0].id)
    let model = try await receiptModel(store)
    try await store.enqueueClassifications(modelID: model)
    #expect(try await store.claimClassification(modelID: model)?.walletCategoryRaw == nil)
}
