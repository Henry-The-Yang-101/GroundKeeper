import Foundation
import Testing
@testable import GroundKeeperCore

@Test func reportEvidenceIdentifiesAccountsAndLoadsOffPageTransactions() async throws {
    let (store, url) = try vault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    for name in ["Fictional A", "Fictional B"] { try await store.addAccount(name: name, currency: "CAD") }
    let accounts = try await store.snapshot().accounts
    var ids: [String] = []
    for (index, account) in accounts.enumerated() {
        let edit = TransactionEdit(description: "Same merchant", amountMinor: -1000, currency: "CAD", occurredOn: "2026-10-0\(index+1)",
            accountID: account.id, type: "expense", category: "dining", needsReview: false, notes: "Account-specific note \(index)")
        try await store.save(edit); ids.append(edit.id)
    }
    let filter = SpendingFilter(range: try ReportRange(start: "2026-10-01", end: "2026-11-01"), timezone: "America/Toronto")
    let rows = try await store.spendingEntries(filter)
    #expect(Set(rows.map(\.accountName)) == Set(accounts.map(\.name)))
    #expect(Set(rows.compactMap(\.accountID)) == Set(accounts.map(\.id)))
    let page = try await store.snapshot(limit: 1)
    let offPage = try #require(rows.first { entry in !page.transactions.contains { $0.id == entry.id } })
    let record = try #require(try await store.transaction(id: offPage.id))
    #expect(record.accountID == offPage.accountID && record.accountName == offPage.accountName && !record.notes.isEmpty)
    let revision = try await store.spendingRevision()
    try await store.save(TransactionEdit(id: record.id, revision: record.revision, description: "Edited from evidence", amountMinor: record.amountMinor,
        currency: record.currency, occurredOn: record.occurredOn, accountID: record.accountID, type: "expense", category: "groceries", needsReview: false, notes: "Updated note"))
    #expect(try await store.spendingRevision() > revision)
    #expect(try await store.spendingEntries(filter).contains { $0.id == record.id && $0.description == "Edited from evidence" })
    let updated = try #require(try await store.transaction(id: record.id))
    try await store.delete(id: updated.id, revision: updated.revision)
    #expect(try await store.transaction(id: record.id) == nil)
    await store.close()
}

@Test func reportEvidenceDistinguishesLegacyDuplicateAccountNames() async throws {
    let (store, url) = try vault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    for name in ["Fictional A", "Fictional B"] { try await store.addAccount(name: name, currency: "CAD") }
    let accounts = try await store.snapshot().accounts
    for account in accounts {
        try await store.save(TransactionEdit(description: "Same merchant", amountMinor: -1000, currency: "CAD", occurredOn: "2026-10-01",
            accountID: account.id, type: "expense", category: "dining", needsReview: false, notes: ""))
    }
    _ = try await store.testRows("UPDATE accounts SET name='Fictional shared name'")
    let legacyAccounts = try await store.snapshot().accounts
    let filter = SpendingFilter(range: try ReportRange(start: "2026-10-01", end: "2026-11-01"), timezone: "America/Toronto")
    let rows = try await store.spendingEntries(filter)
    #expect(rows.count == 2 && Set(rows.map(\.accountName)).count == 1)
    #expect(Set(rows.compactMap(\.accountID)) == Set(accounts.map(\.id)))
    var labels: Set<String> = []
    for row in rows {
        let account = try #require(legacyAccounts.first { $0.id == row.accountID })
        labels.insert(account.displayName(in: legacyAccounts))
        #expect(try await store.transaction(id: row.id)?.accountID == account.id)
    }
    #expect(labels.count == 2)
    await store.close()
}
