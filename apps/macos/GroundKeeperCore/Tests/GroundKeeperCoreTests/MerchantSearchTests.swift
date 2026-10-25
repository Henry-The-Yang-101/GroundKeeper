import Foundation
import Testing
@testable import GroundKeeperCore

@Test func merchantQueryOmitsPaymentDetailsAndRejectsUnsafeFallbacks() throws {
    let query = MerchantSearchQuery.make(merchant: nil, description: "POS FICTIONAL CAFE 12345678 $12.34 REF 999999", locality: "Waterloo Ontario")
    #expect(query?.merchant == "FICTIONAL CAFE")
    #expect(MerchantSearchQuery.make(merchant: nil, description: "POS FICTIONAL CAFE HQ58SX", locality: "")?.merchant == "FICTIONAL CAFE")
    #expect(MerchantSearchQuery.make(merchant: "Fictional Cafe", description: "private transfer", locality: "")?.merchant == "Fictional Cafe")
    for description in ["Interac e-transfer to Person", "email@example.com", "Account 12345678", "https://private.example", "12345678"] {
        #expect(MerchantSearchQuery.make(merchant: nil, description: description, locality: "") == nil)
    }
    #expect(MerchantSearchQuery.make(merchant: "Cafe", description: "Cafe", locality: "43.4,-80.5") == nil)
}

@Test func merchantEvidenceCacheConsentAuditAndCleanup() async throws {
    let (store, _) = try vault()
    #expect(try await store.merchantSearchSettings().enabled)
    try await store.setMerchantSearchSettings(.init(enabled: false))
    #expect(try await !store.merchantSearchSettings().enabled)
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await store.ingestCapture(data: capture("web-evidence"), deliveryPath: "capture.json")
    let snapshot = try await store.snapshot()
    let review = snapshot.reviews.first!
    try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: snapshot.accounts[0].id)
    let model = try await receiptModel(store)
    try await store.enqueueClassifications(modelID: model)
    let task = try await store.claimClassification(modelID: model)!
    let original = try await store.testRows("SELECT payload_json FROM raw_event_payloads")[0].text("payload_json")
    let query = MerchantSearchQuery.make(merchant: "Fictional Cafe", description: task.description, locality: "Waterloo")!
    let context = MerchantContext(results: [.init(title: "Fictional Cafe Waterloo", body: "A cafe in Waterloo.", url: "https://example.org/cafe")])
    let evidence = MerchantSearchEvidence(query: query, outcome: "matched", context: context)
    #expect(try await store.bindMerchantSearch(evidence, to: task) == nil)
    try await store.cacheMerchantSearch(evidence)
    #expect(try await store.cachedMerchantSearch(query) == nil)
    try await store.setMerchantSearchSettings(.init(enabled: true, locality: "Waterloo"))
    try await store.cacheMerchantSearch(evidence)
    #expect(try await store.cachedMerchantSearch(query)?.context == context)
    #expect(try await store.bindMerchantSearch(evidence, to: task) == context)
    let run = try await store.testRows("SELECT input_json,input_sha256,merchant_search_json FROM classification_runs WHERE id='\(task.runID)'")[0]
    let input = try JSONSerialization.jsonObject(with: Data(run.text("input_json").utf8)) as! [String: Any]
    #expect(input["merchant_context"] != nil)
    let wire = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])
    #expect(run.text("input_sha256") == contentHash(wire))
    try await store.clearMerchantSearchCache()
    #expect(try await store.cachedMerchantSearch(query) == nil)
    #expect(try await store.testRows("SELECT input_json FROM classification_runs WHERE id='\(task.runID)'")[0].text("input_json") == run.text("input_json"))
    #expect(try await store.testRows("SELECT payload_json FROM raw_event_payloads")[0].text("payload_json") == original)
    #expect(try await store.integrityCheck())
}
