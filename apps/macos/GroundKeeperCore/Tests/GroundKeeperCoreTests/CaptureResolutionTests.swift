import Foundation
import Testing
@testable import GroundKeeperCore

@Test func choosingAccountReturnsSavedTransactionBeforeClassification() async throws {
    let (store, url) = try vault()
    try await store.addAccount(name: "Fictional card", currency: "CAD")
    try await store.ingestCapture(data: capture("account-choice"), deliveryPath: "capture.json")
    let snapshot = try await store.snapshot()
    let review = try #require(snapshot.reviews.first)
    let result = try await store.assignCaptureAccount(eventID: review.eventID, accountID: snapshot.accounts[0].id)
    guard case let .created(id) = result else { Issue.record("Account confirmation did not save the capture"); return }
    let page = try await store.transactionPage(.init())
    #expect(page.transactions.map(\.id) == [id])
    #expect(page.transactions[0].category == nil && page.transactions[0].needsReview)
    #expect(try await store.snapshot().pendingJobs == 0)
    #expect(try await store.unqueuedClassificationCount() == 1)
    #expect(try await store.snapshot().reviews.isEmpty)
    await store.close()
    let reopened = try LedgerStore(url: url)
    #expect(try await reopened.transaction(id: id)?.accountID == snapshot.accounts[0].id)
    // Repeating the action cannot create a second transaction.
    await #expect(throws: (any Error).self) {
        try await reopened.assignCaptureAccount(eventID: review.eventID, accountID: snapshot.accounts[0].id)
    }
    #expect(try await reopened.snapshot().totalTransactions == 1)
}

@Test func choosingAccountReportsComplementaryCaptureLink() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional card", currency: "CAD")
    try await ingestMapped(store, id: "wallet")
    let original = try #require(try await store.snapshot().transactions.first)
    try await store.ingestCapture(data: capture("bank", wallet: false), deliveryPath: "bank.json")
    let review = try #require(try await store.snapshot().reviews.first)
    let result = try await store.assignCaptureAccount(eventID: review.eventID, accountID: original.accountID!)
    #expect(result == .linked(transactionID: original.id))
    #expect(try await store.snapshot().totalTransactions == 1)
    #expect(try await store.snapshot().reviews.isEmpty)
}

@Test(arguments: [true, false])
func accountChoiceKeepsStatementDecisionExplicit(link: Bool) async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional card", currency: "CAD")
    var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
    let csv = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-17,FICTIONAL CAFE,-12.50\n".utf8), filename: "statement.csv")
    try await store.importCSV(csv, mapping: mapping)
    let original = try #require(try await store.snapshot().transactions.first)
    try await store.ingestCapture(data: capture("wallet"), deliveryPath: "wallet.json")
    let review = try #require(try await store.snapshot().reviews.first)
    let result = try await store.assignCaptureAccount(eventID: review.eventID, accountID: mapping.accountID, remember: true)
    #expect(result == .needsReview(reason: "statement_match"))
    #expect(try await store.snapshot().totalTransactions == 1)
    #expect(try await store.snapshot().reviews.map(\.reason) == ["statement_match"])
    let resolved = try await store.resolveMatch(eventID: review.eventID, transactionID: link ? original.id : nil, expectedRevision: link ? original.revision : nil)
    if link {
        #expect(resolved == .linked(transactionID: original.id))
    } else {
        guard case let .created(id) = resolved else { Issue.record("Separate capture was not saved"); return }
        #expect(id != original.id)
    }
    #expect(try await store.snapshot().totalTransactions == (link ? 1 : 2))
    #expect(try await store.snapshot().reviews.isEmpty)
    #expect(try await store.integrityCheck())
}

@Test func accountChoiceReportsCurrencyIssueAndCorrectionReturnsSavedTransaction() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional USD card", currency: "USD")
    try await store.ingestCapture(data: capture("currency", amount: "CAD 12.50"), deliveryPath: "currency.json")
    let snapshot = try await store.snapshot()
    let review = try #require(snapshot.reviews.first)
    let accountID = snapshot.accounts[0].id
    #expect(try await store.assignCaptureAccount(eventID: review.eventID, accountID: accountID) == .needsReview(reason: "currency_mismatch"))
    #expect(try await store.snapshot().transactions.isEmpty)
    #expect(try await store.snapshot().reviews.map(\.reason) == ["currency_mismatch"])
    let corrected = try await store.correctCapture(eventID: review.eventID, description: "Corrected purchase", amountMinor: -1250, accountID: accountID, day: "2026-10-17")
    guard case let .created(id) = corrected else { Issue.record("Correction did not save the capture"); return }
    #expect(try await store.transaction(id: id)?.currency == "USD")
    #expect(try await store.snapshot().reviews.isEmpty)
    #expect(try await store.integrityCheck())
}
