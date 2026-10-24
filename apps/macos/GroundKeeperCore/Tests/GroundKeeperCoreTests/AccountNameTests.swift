import Foundation
import Testing
@testable import GroundKeeperCore

@Test func accountNamesPreventDuplicatesAndRenamePreservesIdentity() async throws {
    let (store, url) = try vault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try await store.addAccount(name: " Fictional Café ", currency: "CAD")
    await #expect(throws: (any Error).self) { try await store.addAccount(name: "fictional cafe", currency: "CAD", kind: "checking") }
    try await store.addAccount(name: "Fictional Café", currency: "USD")
    try await store.addAccount(name: "Second", currency: "CAD")
    let account = try #require(try await store.snapshot().accounts.first { $0.name == "Fictional Café" && $0.currency == "CAD" })
    try await store.ingestCapture(data: capture("rename"), deliveryPath: "rename.json")
    let review = try #require(try await store.snapshot().reviews.first)
    try await store.assignCaptureAccount(eventID: review.eventID, accountID: account.id, remember: true)
    await #expect(throws: (any Error).self) { try await store.renameAccount(id: account.id, name: "second ") }
    await #expect(throws: (any Error).self) { try await store.renameAccount(id: account.id, name: "\n ") }
    try await store.renameAccount(id: account.id, name: " Every day · 1234 ")
    let renamed = try await store.snapshot()
    #expect(renamed.accounts.first { $0.id == account.id }?.name == "Every day · 1234")
    #expect(renamed.transactions.first?.accountID == account.id && renamed.transactions.first?.accountName == "Every day · 1234")
    #expect(renamed.cardMappings.first?.accountID == account.id)
    var query = LedgerTransactionQuery(); query.accountID = account.id
    #expect(try await store.transactionPage(query).totalMatches == 1)
    // Simulate legacy duplicate names; IDs still distinguish filters and labels.
    _ = try await store.testRows("UPDATE accounts SET name='Every day · 1234' WHERE name='Second'")
    let legacy = try await store.snapshot().accounts
    #expect(Set(legacy.filter { $0.currency == "CAD" }.map { $0.displayName(in: legacy) }).count == 2)
    let other = try #require(legacy.first { $0.currency == "CAD" && $0.id != account.id })
    query.accountID = other.id
    #expect(try await store.transactionPage(query).totalMatches == 0)
    #expect(try await store.integrityCheck())
    await store.close()
}
