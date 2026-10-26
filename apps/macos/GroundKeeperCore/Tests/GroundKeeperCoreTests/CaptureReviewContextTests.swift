import Foundation
import Testing
@testable import GroundKeeperCore

@Test func captureReviewRetainsHistoricalParsedFactsAndRawEvidence() async throws {
    let (store, _) = try vault()
    let data = try capture("historical", time: "2026-10-01T23:30:00-04:00", amount: "CAD 6.75")
    try await store.ingestCapture(data: data, deliveryPath: "historical.json")
    let review = try #require(try await store.snapshot().reviews.first)
    let context = try await store.captureReviewContext(eventID: review.eventID)
    #expect(context.day == "2026-10-01")
    #expect(context.amountMinor == -675)
    #expect(context.currency == "CAD")
    #expect(context.description == review.description)
    #expect(context.accountID == nil)
    #expect(context.payload == String(decoding: data, as: UTF8.self))
}

@Test func captureReviewKeepsDateAndMappedAccountWhenOnlyAmountFails() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional card", currency: "CAD")
    try await ingestMapped(store, id: "mapping")
    let data = try capture("unreadable", time: "2026-10-03T10:00:00-04:00", amount: "unreadable")
    try await store.ingestCapture(data: data, deliveryPath: "unreadable.json")
    let state = try await store.snapshot()
    let review = try #require(state.reviews.first)
    let context = try await store.captureReviewContext(eventID: review.eventID)
    #expect(context.day == "2026-10-03")
    #expect(context.amountMinor == nil)
    #expect(context.currency == "CAD")
    #expect(context.accountID == state.accounts[0].id)
    #expect(context.accountName == "Fictional card")
    #expect(context.payload == String(decoding: data, as: UTF8.self))
    try await store.correctCapture(eventID: review.eventID, description: context.description, amountMinor: -675,
                                  accountID: try #require(context.accountID), day: context.day)
    let corrected = try #require(try await store.snapshot().transactions.first { $0.occurredOn == "2026-10-03" && $0.amountMinor == -675 })
    #expect(corrected.lifecycle == "posted" && corrected.postedOn == nil)
    #expect(try await store.captureReviewContext(eventID: review.eventID).payload == context.payload)
}

@Test func captureReconciliationShowsCandidateFactsOutsideTheLoadedPage() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional statement account", currency: "CAD")
    // Two separate Wallet purchases make the complementary bank capture ambiguous.
    try await ingestMapped(store, id: "wallet-one")
    try await ingestMapped(store, id: "wallet-two")
    var mapping = CSVMapping()
    mapping.accountID = try await store.snapshot().accounts[0].id
    let csv = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-22,NEWER PURCHASE,-9.00\n".utf8), filename: "fictional.csv")
    try await store.importCSV(csv, mapping: mapping)
    try await ingestMapped(store, id: "matching-capture", wallet: false)
    let review = try #require(try await store.snapshot().reviews.first { $0.reason == "possible_duplicate" })
    let page = try await store.snapshot(limit: 1)
    #expect(!page.transactions.contains { review.candidates.contains($0.id) })
    let source = try await store.captureReviewContext(eventID: review.eventID)
    let candidates = try await store.captureReconciliationCandidates(transactionIDs: review.candidates + [UUID().uuidString])
    let candidate = try #require(candidates.first)
    #expect(candidates.count == 2)
    #expect(candidate.description == "FICTIONAL CAFE")
    #expect(candidate.day == "2026-10-17")
    #expect(candidate.amountMinor == source.amountMinor)
    #expect(candidate.currency == source.currency)
    #expect(candidate.accountID == source.accountID)
    #expect(candidate.accountName == "Fictional statement account")
}
