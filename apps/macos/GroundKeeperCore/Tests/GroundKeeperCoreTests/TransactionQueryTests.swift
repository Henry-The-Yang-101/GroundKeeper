import Foundation
import Testing
@testable import GroundKeeperCore

@Test func transactionQueriesApplyToWholeLedgerBeforePagination() async throws {
    let (store, url) = try vault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try await store.addAccount(name: "Main fictional account", currency: "CAD")
    try await store.addAccount(name: "Other fictional account", currency: "CAD")
    let accounts = try await store.snapshot().accounts
    for index in 0..<505 {
        try await store.save(TransactionEdit(id: String(format: "00000000-0000-0000-0000-%012d", index),
            description: "Recent \(index)", amountMinor: -Int64(index + 1), currency: "CAD", occurredOn: "2026-10-24",
            accountID: accounts[0].id, type: "expense", category: "groceries", needsReview: false, notes: ""))
    }
    let olderID = UUID().uuidString
    try await store.save(TransactionEdit(id: olderID, description: "Café Needle 100%", amountMinor: -99999, currency: "CAD", occurredOn: "2020-01-01",
        accountID: accounts[1].id, type: "expense", category: "dining", needsReview: true, notes: "Historical note"))
    var query = LedgerTransactionQuery()
    let first = try await store.transactionPage(query)
    let second = try await store.transactionPage(query, offset: 500)
    #expect(first.transactions.count == 500 && first.totalMatches == 506)
    #expect(second.transactions.count == 6 && second.transactions.last?.id == olderID)
    #expect(try await store.transactionReviewCount() == 1)
    #expect(try await store.snapshot(limit: 5).transactions.first?.occurredOn == "2026-10-24")
    query.reviewOnly = true
    let review = try await store.transactionPage(query, offset: 500)
    #expect(review.offset == 0 && review.totalMatches == 1 && review.transactions.first?.id == olderID)
    query.reviewOnly = false
    for text in ["cafe needle", "100%", "historical NOTE"] {
        query.search = text
        #expect(try await store.transactionPage(query).transactions.map(\.id) == [olderID])
    }
    query.search = ""
    query.accountID = accounts[1].id
    #expect(try await store.transactionPage(query).totalMatches == 1)
    query.accountID = nil; query.category = "dining"
    #expect(try await store.transactionPage(query).transactions.first?.id == olderID)
    query.category = nil
    query.sort = [LedgerTransactionSort(.amount, descending: true)]
    #expect(try await store.transactionPage(query).transactions.first?.id == olderID)
    query.sort = [LedgerTransactionSort(.date)]
    #expect(try await store.transactionPage(query).transactions.first?.id == olderID)
    query.search = "Dining & takeout"; query.matchingCategoryCodes = ["dining"]
    #expect(try await store.transactionPage(query).totalMatches == 1)
    query.search = "purchase"; query.matchingCategoryCodes = []; query.matchingTypeCodes = ["expense"]
    #expect(try await store.transactionPage(query, offset: 500).totalMatches == 506)
    await store.close()
}
