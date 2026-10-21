import Foundation
import Testing
@testable import GroundKeeperCore

@Test func oneTimeAccountDoesNotRememberOrResolveOtherCaptures() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional card", currency: "CAD")
    try await store.ingestCapture(data: capture("first", amount: "$12.50"), deliveryPath: "first.json")
    let initial = try await store.snapshot()
    let review = try #require(initial.reviews.first)
    try await store.ingestCapture(data: capture("second"), deliveryPath: "second.json")
    try await store.assignCaptureAccount(eventID: review.eventID, accountID: initial.accounts[0].id)
    let assigned = try await store.snapshot()
    #expect(assigned.transactions.count == 1)
    #expect(assigned.transactions[0].amountMinor == -1250)
    #expect(assigned.cardMappings.isEmpty)
    #expect(assigned.reviews.count == 1)
    try await store.ingestCapture(data: capture("third"), deliveryPath: "third.json")
    #expect(try await store.snapshot().reviews.count == 2)
}

@Test func rememberedCardPersistsAndOnlyAffectsFutureImportsFromExactSource() async throws {
    var (store, url) = try vault()
    try await store.addAccount(name: "Fictional card", currency: "CAD")
    try await store.ingestCapture(data: capture("first"), deliveryPath: "first.json")
    let initial = try await store.snapshot()
    let review = try #require(initial.reviews.first)
    try await store.ingestCapture(data: capture("pending"), deliveryPath: "pending.json")
    try await store.assignCaptureAccount(eventID: review.eventID, accountID: initial.accounts[0].id, remember: true)
    #expect(try await store.snapshot().reviews.count == 1)
    await store.close()
    store = try LedgerStore(url: url)
    #expect(try await store.snapshot().cardMappings.count == 1)
    // Older capture timestamp arriving later still uses the current saved rule.
    try await store.ingestCapture(data: capture("late", time: "2026-10-15T10:00:00-04:00"), deliveryPath: "late.json")
    #expect(try await store.snapshot().transactions.count == 2)
    // The same label from a bank is a different source, not a guessed identity.
    try await store.ingestCapture(data: capture("bank", wallet: false), deliveryPath: "bank.json")
    #expect(try await store.snapshot().reviews.count == 2)
    var other = try #require(JSONSerialization.jsonObject(with: capture("different-card")) as? [String: Any])
    other["card_or_pass"] = "Another card"
    try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: other), deliveryPath: "other.json")
    #expect(try await store.snapshot().reviews.count == 3)
}

@Test func mappingEditRemovalAndRecreationPreserveTransactionsAndEvidence() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "First account", currency: "CAD")
    try await store.addAccount(name: "Second account", currency: "CAD")
    let accounts = try await store.snapshot().accounts
    let original = try capture("first")
    try await store.ingestCapture(data: original, deliveryPath: "first.json")
    let first = try #require(try await store.snapshot().reviews.first)
    try await store.assignCaptureAccount(eventID: first.eventID, accountID: accounts[0].id, remember: true)
    let originalTransaction = try #require(try await store.snapshot().transactions.first)
    let mapping = try #require(try await store.snapshot().cardMappings.first)
    try await store.updateCardMapping(id: mapping.id, accountID: accounts[1].id)
    try await store.ingestCapture(data: capture("second"), deliveryPath: "second.json")
    let edited = try await store.snapshot()
    #expect(edited.transactions.first { $0.id == originalTransaction.id }?.accountID == accounts[0].id)
    #expect(edited.transactions.first { $0.id != originalTransaction.id }?.accountID == accounts[1].id)
    try await store.removeCardMapping(id: edited.cardMappings[0].id)
    #expect(try await store.snapshot().cardMappings.isEmpty)
    try await store.ingestCapture(data: capture("third"), deliveryPath: "third.json")
    let third = try #require(try await store.snapshot().reviews.first)
    try await store.assignCaptureAccount(eventID: third.eventID, accountID: accounts[0].id, remember: true)
    #expect(try await store.snapshot().cardMappings.count == 1)
    #expect(try await store.testRows("SELECT * FROM source_account_mappings").count == 3)
    #expect(try await store.testRows("SELECT payload_json FROM raw_event_payloads WHERE event_id='\(first.eventID)'")[0].text("payload_json") == String(decoding: original, as: UTF8.self))
    #expect(try await store.integrityCheck())
}

@Test func cibcUsesCardTitleAndKeepsMerchantSubtitle() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional Visa", currency: "CAD")
    let data = Data("""
        {"schema_version":2,"event_id":"cibc","source":"bank_notification","captured_at":"2026-10-17T10:00:00-04:00",
         "app":"CIBC Banking","input_shape":"notification_fields","title":"CIBC Dividend Visa Card, 1234",
         "subtitle":"FICTIONAL SHOP","body":"$13.32"}
        """.utf8)
    try await store.ingestCapture(data: data, deliveryPath: "cibc.json")
    let initial = try await store.snapshot()
    let review = try #require(initial.reviews.first)
    #expect(review.label == "CIBC Dividend Visa Card, 1234")
    #expect(review.description == "FICTIONAL SHOP")
    try await store.assignCaptureAccount(eventID: review.eventID, accountID: initial.accounts[0].id, remember: true)
    let saved = try await store.snapshot()
    #expect(saved.cardMappings[0].label == review.label)
    #expect(saved.cardMappings[0].sourceName == "CIBC Banking")
    #expect(saved.transactions[0].description == "FICTIONAL SHOP")
    #expect(saved.transactions[0].amountMinor == -1332)
}

@Test func blankCardsCannotBeRememberedAndCorrectionsCanOptIn() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional account", currency: "CAD")
    let accountID = try await store.snapshot().accounts[0].id
    var missing = try #require(JSONSerialization.jsonObject(with: capture("missing")) as? [String: Any])
    missing["card_or_pass"] = "  "
    try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: missing), deliveryPath: "missing.json")
    let review = try #require(try await store.snapshot().reviews.first)
    do {
        try await store.assignCaptureAccount(eventID: review.eventID, accountID: accountID, remember: true)
        Issue.record("Blank card description was remembered")
    } catch {}
    #expect(try await store.snapshot().transactions.isEmpty)
    try await store.assignCaptureAccount(eventID: review.eventID, accountID: accountID)
    #expect(try await store.snapshot().cardMappings.isEmpty)
    try await store.ingestCapture(data: capture("bad-amount", amount: "Purchase declined"), deliveryPath: "bad.json")
    let correction = try #require(try await store.snapshot().reviews.first)
    do {
        try await store.assignCaptureAccount(eventID: correction.eventID, accountID: accountID, remember: true)
        Issue.record("Malformed capture created a mapping")
    } catch {}
    #expect(try await store.snapshot().cardMappings.isEmpty)
    try await store.correctCapture(eventID: correction.eventID, description: "Corrected purchase", amountMinor: -1250,
                                   accountID: accountID, day: "2026-10-17", remember: true)
    #expect(try await store.snapshot().cardMappings.count == 1)
    #expect(try await store.snapshot().transactions.count == 2)
}

@Test func dismissingCaptureDoesNotCreateMappingOrGetReplayedByAnotherChoice() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional account", currency: "CAD")
    try await store.ingestCapture(data: capture("dismiss"), deliveryPath: "dismiss.json")
    let dismissed = try #require(try await store.snapshot().reviews.first)
    try await store.dismissReview(dismissed.id)
    #expect(try await store.snapshot().cardMappings.isEmpty)
    try await store.ingestCapture(data: capture("remember"), deliveryPath: "remember.json")
    let state = try await store.snapshot()
    try await store.assignCaptureAccount(eventID: state.reviews[0].eventID, accountID: state.accounts[0].id, remember: true)
    #expect(try await store.snapshot().transactions.count == 1)
    #expect(try await store.snapshot().reviews.isEmpty)
    #expect(try await store.testRows("SELECT * FROM transaction_event_links WHERE event_id='\(dismissed.eventID)'").isEmpty)
}
