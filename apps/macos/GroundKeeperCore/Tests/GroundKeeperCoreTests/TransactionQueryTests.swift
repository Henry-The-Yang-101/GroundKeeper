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
    query.search = "Dining & takeout"; query.categoryNames = ["dining": "Dining & takeout"]
    #expect(try await store.transactionPage(query).totalMatches == 1)
    query.search = "purchase"; query.categoryNames = [:]; query.typeNames = ["expense": "Purchase"]
    #expect(try await store.transactionPage(query, offset: 500).totalMatches == 506)
    query.categoryNames = ["dining": "Dining & takeout"]
    query.search = "Dining & takeout Purchase"
    #expect(try await store.transactionPage(query).transactions.map(\.id) == [olderID])
    let combined = try await store.workspaceSnapshot(query)
    #expect(combined.ledger.totalTransactions == 506 && combined.page.totalMatches == 1 && combined.reviewCount == 1)
    #expect(combined.ledger.transactions.count == 5 && combined.ledger.transactions.first?.occurredOn == "2026-10-24")
    await store.close()
}

@Test func transactionDetailsIncludeLocationAndOnlyActiveReceiptImages() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "details")
    let transaction = try #require(try await store.snapshot().transactions.first)
    #expect(transaction.location == nil && !transaction.hasReceiptImage)
    try await store.seedDetailLocation(transactionID: transaction.id)
    let located = try #require(try await store.transaction(id: transaction.id))
    #expect(located.location?.latitude == 43.4723)
    #expect(located.location?.longitude == -80.5449)
    #expect(located.location?.label == "Fictional shop")
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=")!
    let receipt = try await store.addReceiptImage(transactionID: transaction.id, data: png)
    #expect(try await store.transactionPage(.init()).transactions[0].hasReceiptImage)
    try await store.setReceiptRemoved(id: receipt, transactionID: transaction.id, removed: true)
    #expect(try await store.transaction(id: transaction.id)?.hasReceiptImage == false)
}

extension LedgerStore {
    func seedDetailLocation(transactionID: String) throws {
        try db.query("INSERT INTO geotags(id,transaction_id,latitude,longitude,measured_at_ms,origin,label,created_at_ms) VALUES (?,?,43.4723,-80.5449,1,'import','Fictional shop',1)", [.text(identifier()), .text(transactionID)])
    }
}
