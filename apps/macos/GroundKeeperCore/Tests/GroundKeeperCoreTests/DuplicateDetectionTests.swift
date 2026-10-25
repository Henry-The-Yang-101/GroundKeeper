import Foundation
import Testing
@testable import GroundKeeperCore

private func mappedStore() async throws -> (LedgerStore, URL) {
    let (store, url) = try vault()
    try await store.addAccount(name: "Fictional card", currency: "CAD")
    try await ingestMapped(store, id: "wallet-mapping")
    // Map the complementary source without creating another purchase.
    let bankData = try capture("bank-mapping", wallet: false, test: true)
    try await store.ingestCapture(data: bankData, deliveryPath: "bank-mapping.json")
    let bank = try CaptureParser.decode(bankData)
    try await store.confirmMapping(sourceID: bank.sourceID, label: bank.label,
                                  accountID: try await store.snapshot().accounts[0].id)
    return (store, url)
}

@Test(arguments: [0, 299, 300, 301, 3600, 86400, 172800])
func duplicateWindowIsInclusiveAndMandatory(seconds: Int) async throws {
    let (store, _) = try await mappedStore()
    let timestamp = try CaptureParser.timestamp("2026-10-17T10:00:00-04:00").0
    let time = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(timestamp) / 1000 + Double(seconds)))
    try await store.ingestCapture(data: capture("bank", wallet: false, time: time), deliveryPath: "bank.json")
    let state = try await store.snapshot()
    #expect(state.transactions.count == (seconds <= 300 ? 1 : 2))
    #expect(state.reviews.isEmpty)
    if seconds <= 300 {
        #expect(state.transactions[0].sourceLabel == "Bank App Automation + Wallet Automation")
    }
}

@Test func midnightAndReverseArrivalUseAbsoluteCaptureTimes() async throws {
    let (store, _) = try await mappedStore()
    try await store.ingestCapture(data: capture("bank-midnight", wallet: false, time: "2026-10-18T00:01:00-04:00"), deliveryPath: "bank-midnight.json")
    try await store.ingestCapture(data: capture("wallet-midnight", time: "2026-10-18T03:58:00Z"), deliveryPath: "wallet-midnight.json")
    #expect(try await store.snapshot().transactions.count == 2) // mapping purchase + midnight pair
    #expect(try await store.snapshot().reviews.isEmpty)
}

@Test func sameSourceKindsStaySeparateEvenAcrossDifferentApps() async throws {
    let (store, _) = try await mappedStore()
    try await store.ingestCapture(data: capture("wallet-two"), deliveryPath: "wallet-two.json")
    var bank = try JSONSerialization.jsonObject(with: capture("different-wallet-app")) as! [String: Any]
    bank["app"] = "Another Wallet app"
    try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: bank), deliveryPath: "another.json")
    let review = try #require(try await store.snapshot().reviews.first)
    try await store.confirmMapping(sourceID: review.sourceID, label: review.label,
                                  accountID: try await store.snapshot().accounts[0].id)
    #expect(try await store.snapshot().transactions.count == 3)
    #expect(try await store.snapshot().reviews.isEmpty)
}

@Test func csvRepeatedRowsAndManualEntriesStaySeparateFromCaptures() async throws {
    let (store, _) = try await mappedStore()
    let accountID = try await store.snapshot().accounts[0].id
    try await store.save(.init(description: "FICTIONAL CAFE", amountMinor: -1250, currency: "CAD", occurredOn: "2026-10-17",
                               accountID: accountID, type: "expense", category: "dining", needsReview: false, notes: ""))
    var mapping = CSVMapping(); mapping.accountID = accountID
    let csv = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-17,FICTIONAL CAFE,-12.50\n2026-10-17,FICTIONAL CAFE,-12.50\n2026-10-18,FICTIONAL CAFE,-12.50\n".utf8), filename: "repeats.csv")
    #expect(try await store.importCSV(csv, mapping: mapping) == 3)
    let state = try await store.snapshot()
    #expect(state.transactions.count == 5)
    #expect(state.reviews.isEmpty)
    #expect(state.transactions.filter { $0.sourceLabel == "Imported from CSV" }.count == 3)
    #expect(state.transactions.contains { $0.sourceLabel == "Manually input" })
    let wallet = try #require(state.transactions.first { $0.sources == "apple_wallet" })
    try await store.save(.init(id: wallet.id, revision: wallet.revision, description: wallet.description,
        amountMinor: wallet.amountMinor, currency: wallet.currency, occurredOn: wallet.occurredOn, accountID: wallet.accountID,
        type: "expense", category: "dining", needsReview: false, notes: "Edited"))
    #expect(try await store.snapshot().transactions.first { $0.id == wallet.id }?.sourceLabel == "Wallet Automation")
}

@Test func ambiguousAutomationsOnlyOfferEligibleCandidatesAndRevalidateUserLink() async throws {
    let (store, _) = try await mappedStore()
    try await store.ingestCapture(data: capture("wallet-two"), deliveryPath: "wallet-two.json")
    try await store.ingestCapture(data: capture("bank", wallet: false), deliveryPath: "bank.json")
    let review = try #require(try await store.snapshot().reviews.first { $0.reason == "possible_duplicate" })
    #expect(review.candidates.count == 2)
    let candidate = review.candidates[0]
    // A candidate that no longer meets the timestamp rule cannot be linked from a stale UI.
    _ = try await store.testRows("UPDATE raw_events SET captured_at_ms=captured_at_ms-600000 WHERE id IN (SELECT event_id FROM transaction_event_links WHERE transaction_id='\(candidate)')")
    await #expect(throws: (any Error).self) { try await store.resolveMatch(eventID: review.eventID, transactionID: candidate) }
    try await store.resolveMatch(eventID: review.eventID, transactionID: review.candidates[1])
    #expect(try await store.snapshot().reviews.isEmpty)
    #expect(try await store.snapshot().transactions.count == 2)
}

extension LedgerStore {
    /// Reproduce an old importer holding a CSV observation behind a duplicate flag.
    func stageLegacyDuplicate(transactionID: String, candidates: [String]) throws -> String {
        let link = try db.query("SELECT * FROM transaction_event_links WHERE transaction_id=?", [.text(transactionID)]).first!
        try db.query("DELETE FROM transaction_event_links WHERE id=?", [.text(link.text("id"))])
        try db.query("UPDATE transactions SET state='deleted' WHERE id=?", [.text(transactionID)])
        try review(eventID: link.text("event_id"), reason: "possible_duplicate", candidates: candidates)
        return link.text("event_id")
    }
}

@Test func reopeningRepairsLegacyCSVDuplicatesOnceAndPreservesEvidence() async throws {
    var (store, url) = try await mappedStore()
    let wallet = try await store.snapshot().transactions[0]
    var mapping = CSVMapping(); mapping.accountID = wallet.accountID!
    let csv = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-19,FICTIONAL CAFE,-12.50\n".utf8), filename: "legacy.csv")
    try await store.importCSV(csv, mapping: mapping)
    let imported = try #require(try await store.snapshot().transactions.first { $0.sources == "csv" })
    let eventID = try await store.stageLegacyDuplicate(transactionID: imported.id, candidates: [wallet.id])
    let payload = try await store.testRows("SELECT payload_json FROM raw_event_payloads WHERE event_id='\(eventID)'")[0].text("payload_json")
    await store.close()
    store = try LedgerStore(url: url)
    #expect(try await store.snapshot().transactions.count == 2)
    #expect(try await store.snapshot().reviews.isEmpty)
    #expect(try await store.snapshot().transactions.contains { $0.sources == "csv" && $0.occurredOn == "2026-10-19" })
    #expect(try await store.testRows("SELECT payload_json FROM raw_event_payloads WHERE event_id='\(eventID)'")[0].text("payload_json") == payload)
    #expect(try await store.importCSV(csv, mapping: mapping) == 0)
    #expect(try await store.integrityCheck())
    await store.close()
    store = try LedgerStore(url: url)
    #expect(try await store.snapshot().transactions.count == 2)
}

@Test func reopeningKeepsEligibleAmbiguityAndPrunesStaleCandidates() async throws {
    var (store, url) = try await mappedStore()
    try await store.ingestCapture(data: capture("wallet-two"), deliveryPath: "wallet-two.json")
    try await store.ingestCapture(data: capture("bank", wallet: false), deliveryPath: "bank.json")
    let review = try #require(try await store.snapshot().reviews.first { $0.reason == "possible_duplicate" })
    await store.close()
    store = try LedgerStore(url: url)
    #expect(try await store.snapshot().reviews.first?.candidates.count == 2)
    _ = try await store.testRows("UPDATE raw_events SET captured_at_ms=captured_at_ms-600000 WHERE id IN (SELECT event_id FROM transaction_event_links WHERE transaction_id='\(review.candidates[0])')")
    await store.close()
    store = try LedgerStore(url: url)
    #expect(try await store.snapshot().reviews.first?.candidates == [review.candidates[1]])
    #expect(try await store.snapshot().transactions.count == 2)
    try await store.resolveMatch(eventID: review.eventID, transactionID: review.candidates[1])
    #expect(try await store.snapshot().reviews.isEmpty)
    #expect(try await store.integrityCheck())
}

@Test(arguments: [true, false])
func reopeningSeparatesLegacySameSourceAndDistantAutomationFlags(wallet: Bool) async throws {
    var (store, url) = try await mappedStore()
    let existing = try await store.snapshot().transactions[0]
    let data = try capture("legacy", wallet: wallet, time: wallet ? "2026-10-17T10:00:00-04:00" : "2026-10-18T10:00:00-04:00")
    try await store.ingestCapture(data: data, deliveryPath: "legacy.json")
    let separate = try #require(try await store.snapshot().transactions.first { $0.id != existing.id })
    _ = try await store.stageLegacyDuplicate(transactionID: separate.id, candidates: [existing.id])
    if wallet {
        try await store.ingestCapture(data: receiptCapture("legacy-receipt", parent: "legacy"), deliveryPath: "legacy-receipt.json")
    }
    await store.close()
    store = try LedgerStore(url: url)
    let state = try await store.snapshot()
    #expect(state.transactions.count == 2)
    #expect(state.reviews.isEmpty)
    #expect(state.transactions.contains { $0.sourceLabel == (wallet ? "Wallet Automation" : "Bank App Automation") })
    if wallet {
        let restored = try #require(state.transactions.first { $0.id != existing.id })
        #expect(try await store.receipts(transactionID: restored.id).count == 1)
    }
    #expect(try await store.integrityCheck())
}
