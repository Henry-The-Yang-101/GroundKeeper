import Foundation
import Testing
@testable import GroundKeeperCore

@Test func merchantNormalizationPreservesIdentityEvidence() {
    #expect(MerchantIdentity.key(" Café  012 ") == MerchantIdentity.key("CAFÉ\n012"))
    #expect(MerchantIdentity.key("Café 012") != MerchantIdentity.key("Cafe 012"))
    #expect(MerchantIdentity.key("Cafe 012") != MerchantIdentity.key("Cafe 013"))
    #expect(MerchantIdentity.key("SQ * CAFE") != MerchantIdentity.key("CAFE"))
    #expect(MerchantIdentity.key("A-B") != MerchantIdentity.key("A B"))
    #expect(MerchantIdentity.key("Unknown") == nil)
}

@Test func merchantGroupingIsExplicitReversibleAndSurvivesReopen() async throws {
    let (store, url) = try vault()
    try await store.addAccount(name: "Merchant test", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    func add(_ name: String) async throws {
        try await store.save(TransactionEdit(description: name, amountMinor: -1000, currency: "CAD", occurredOn: "2026-10-01", accountID: account, type: "expense", category: "dining", needsReview: false, notes: ""))
    }
    try await add("CAFE 001"); try await add("Cafe  001"); try await add("CAFE 002")
    let names = try await store.merchantNames()
    #expect(names.count == 2)
    let first = try #require(names.first { $0.transactionCount == 2 })
    let second = try #require(names.first { $0.transactionCount == 1 })
    let transaction = try #require(try await store.snapshot().transactions.first { $0.description == "CAFE 001" })
    try await store.setTransactionMerchant(id: transaction.id, merchantID: nil)
    let revision = try await store.spendingRevision()
    try await store.groupMerchantName(key: first.key, merchantID: second.merchantID, expectedMerchantID: first.merchantID)
    #expect(try await store.spendingRevision() > revision)
    #expect(try await store.transactionMerchant(id: transaction.id).merchantID == nil)
    try await add("cafe 001")
    #expect(try await store.merchantNames().first { $0.key == first.key }?.transactionCount == 2)
    await #expect(throws: LedgerError.self) {
        try await store.groupMerchantName(key: first.key, merchantID: first.merchantID, expectedMerchantID: first.merchantID)
    }
    await store.close()
    let reopened = try LedgerStore(url: url)
    #expect(try await reopened.merchantNames().first { $0.key == first.key }?.merchantID == second.merchantID)
    try await reopened.restoreMerchantName(key: first.key, expectedMerchantID: second.merchantID)
    try await reopened.setTransactionMerchant(id: transaction.id, merchantID: nil, automatic: true)
    #expect(try await reopened.transactionMerchant(id: transaction.id).merchantID == first.merchantID)
    #expect(try await reopened.integrityCheck())
}

@Test func merchantIdentityDoesNotDeduplicateCaptures() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Captures", currency: "CAD")
    try await ingestMapped(store, id: "merchant-w1")
    try await ingestMapped(store, id: "merchant-b1", wallet: false)
    try await ingestMapped(store, id: "merchant-w2")
    #expect(try await store.merchantNames().count == 1)
    #expect(try await store.merchantNames()[0].transactionCount == 2)
}
