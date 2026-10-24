import Foundation
import Testing
@testable import GroundKeeperCore

@Test func manualEditsRequireConsistentTypeAndDirection() async throws {
    let (store, url) = try vault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try await store.addAccount(name: "Fictional card", currency: "CAD")
    let account = try await store.snapshot().accounts[0]
    for (type, amount) in [("expense", Int64(25000)), ("refund", -25000), ("income", -25000)] {
        let edit = TransactionEdit(description: "Fictional purchase", amountMinor: amount, currency: "CAD",
            occurredOn: "2026-10-24", accountID: account.id, type: type,
            category: type == "income" ? nil : "dining", needsReview: false, notes: "")
        await #expect(throws: (any Error).self) { try await store.save(edit) }
    }
    #expect(try await store.snapshot().totalTransactions == 0)
    for (type, amount) in [("expense", Int64(-25000)), ("refund", 25000), ("income", 25000)] {
        try await store.save(TransactionEdit(description: "Fictional purchase", amountMinor: amount, currency: "CAD",
            occurredOn: "2026-10-24", accountID: account.id, type: type,
            category: type == "income" ? nil : "dining", needsReview: false, notes: ""))
    }
    #expect(try await store.snapshot().totalTransactions == 3)
    #expect(try await store.integrityCheck())
    await store.close()
}
