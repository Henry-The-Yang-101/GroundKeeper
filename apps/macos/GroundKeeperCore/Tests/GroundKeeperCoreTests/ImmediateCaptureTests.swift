import Foundation
import Testing
@testable import GroundKeeperCore

@Test(arguments: [true, false])
func reviewedCapturesProduceSpendingFindingsWithoutCSV(wallet: Bool) async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional card", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    for day in 17...19 {
        try await store.save(.init(description: "Earlier purchase", amountMinor: -100, currency: "CAD",
            occurredOn: "2026-09-\(day)", accountID: account, type: "expense", category: "dining", needsReview: false, notes: ""))
        let id = "capture-\(day)"
        try await store.ingestCapture(data: capture(id, wallet: wallet, time: "2026-10-\(day)T10:00:00-04:00"), deliveryPath: id + ".json")
        if let review = try await store.snapshot().reviews.first {
            try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: account)
        }
    }
    let filter = SpendingFilter(range: try .init(start: "2026-10-17", end: "2026-10-20"),
        baseline: try .init(start: "2026-09-17", end: "2026-09-20"), timezone: "America/Toronto")
    #expect(try await store.snapshot().totalTransactions == 6)
    #expect(try await store.spendingReport(filter).totals.unknownCount == 3)
    #expect(try await store.spendingReport(filter).findings.isEmpty)
    for transaction in try await store.snapshot().transactions where transaction.occurredOn.hasPrefix("2026-10") {
        #expect(transaction.lifecycle == "posted")
        #expect(transaction.postedOn == nil)
        try await store.save(.init(id: transaction.id, revision: transaction.revision, description: transaction.description,
            amountMinor: transaction.amountMinor, currency: transaction.currency, occurredOn: transaction.occurredOn,
            accountID: account, type: "expense", category: "dining", needsReview: false, notes: "Reviewed capture"))
    }
    let report = try await store.spendingReport(filter)
    #expect(report.totals.net == 3750 && report.totals.purchases == 3)
    #expect(!report.totals.uncertain)
    #expect(report.findings.contains { $0.kind == "spending_change" })
    #expect(!report.emptyFindingsExplanation.contains("paused"))
    #expect(try await store.spendingEntries(filter).count == 3)
    #expect(try await store.testRows("SELECT id FROM sources WHERE kind='csv'").isEmpty)
    #expect(try await store.integrityCheck())
}

@Test func openingLegacyVaultRecordsExistingCapturesAndPreservesEvidence() async throws {
    var (store, url) = try vault()
    try await store.addAccount(name: "Fictional card", currency: "CAD")
    try await ingestMapped(store, id: "legacy-wallet")
    var original = try await store.snapshot().transactions[0]
    try await store.save(.init(id: original.id, revision: original.revision, description: original.description,
        amountMinor: original.amountMinor, currency: original.currency, occurredOn: original.occurredOn,
        accountID: original.accountID, type: "expense", category: "dining", needsReview: false, notes: "Keep this note"))
    original = try #require(try await store.transaction(id: original.id))
    let payload = try await store.transactionEvidence(id: original.id).sources[0].payload
    let assignment = try await store.testRows("SELECT current_assignment_id FROM transaction_parts")[0].text("current_assignment_id")
    // Reproduce the v11 vault immediately before the new migration.
    _ = try await store.testRows("DROP TRIGGER transactions_no_pending_insert")
    _ = try await store.testRows("DROP TRIGGER transactions_no_pending_update")
    _ = try await store.testRows("DELETE FROM schema_migrations WHERE version=12")
    _ = try await store.testRows("UPDATE transactions SET lifecycle='pending'")
    _ = try await store.testRows("UPDATE event_observations SET lifecycle='pending'")
    await store.close()
    store = try LedgerStore(url: url)
    let migrated = try #require(try await store.transaction(id: original.id))
    #expect(migrated.lifecycle == "posted" && migrated.postedOn == nil)
    #expect(migrated.revision == original.revision + 1)
    #expect(!migrated.needsReview && migrated.category == "dining" && migrated.notes == "Keep this note")
    #expect(try await store.testRows("SELECT current_assignment_id FROM transaction_parts")[0].text("current_assignment_id") == assignment)
    #expect(try await store.transactionEvidence(id: original.id).sources[0].payload == payload)
    #expect(try await store.testRows("SELECT lifecycle FROM event_observations")[0].text("lifecycle") == "pending")
    let filter = SpendingFilter(range: try .init(start: "2026-10-01", end: "2026-11-01"), timezone: "America/Toronto")
    let report = try await store.spendingReport(filter)
    #expect(report.totals.net == 1250 && !report.totals.uncertain)
    await #expect(throws: (any Error).self) {
        _ = try await store.testRows("UPDATE transactions SET lifecycle='pending'")
    }
    #expect(try await store.integrityCheck())
    await store.close()
    store = try LedgerStore(url: url)
    #expect(try await store.transaction(id: original.id)?.revision == migrated.revision)
    #expect(try await store.snapshot().totalTransactions == 1)
}

@Test func legacyHeldCaptureRecordsImmediatelyWhenKeptSeparate() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional card", currency: "CAD")
    var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
    let csv = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-17,FICTIONAL CAFE,-12.50\n".utf8), filename: "fictional.csv")
    try await store.importCSV(csv, mapping: mapping)
    try await ingestMapped(store, id: "held-wallet")
    let review = try #require(try await store.snapshot().reviews.first { $0.reason == "statement_match" })
    _ = try await store.testRows("UPDATE event_observations SET lifecycle='pending' WHERE event_id='\(review.eventID)'")
    try await store.resolveMatch(eventID: review.eventID, transactionID: nil)
    let captured = try #require(try await store.snapshot().transactions.first { $0.sources == "apple_wallet" })
    #expect(captured.lifecycle == "posted" && captured.postedOn == nil)
    #expect(try await store.snapshot().totalTransactions == 2)
    #expect(try await store.snapshot().reviews.isEmpty)
    #expect(try await store.integrityCheck())
}
