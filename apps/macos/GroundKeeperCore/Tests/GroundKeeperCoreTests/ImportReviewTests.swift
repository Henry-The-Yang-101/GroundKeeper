import Foundation
import Testing
@testable import GroundKeeperCore

private func statement(_ amount: String = "-12.50", day: String = "2026-10-17", id: String? = nil) throws -> CSVDocument {
    let header = "Date,Description,Amount" + (id == nil ? "" : ",ID")
    let row = "\(day),FICTIONAL CAFE,\(amount)" + (id.map { "," + $0 } ?? "")
    return try CSVDocument(data: Data("\(header)\n\(row)\n".utf8), filename: "fictional.csv")
}

@Test func statementMatchingIsExplicitInBothArrivalOrders() async throws {
    for statementFirst in [true, false] {
        let (store, url) = try vault()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await store.addAccount(name: "Fictional card", currency: "CAD")
        let account = try await store.snapshot().accounts[0]
        var mapping = CSVMapping(); mapping.accountID = account.id
        if statementFirst { try await store.importCSV(statement(), mapping: mapping) }
        try await ingestMapped(store, id: "wallet")
        if !statementFirst { try await store.importCSV(statement(), mapping: mapping) }
        var snapshot = try await store.snapshot()
        #expect(snapshot.transactions.count == 1)
        let review = try #require(snapshot.reviews.first { $0.reason == "statement_match" })
        #expect(review.candidates == [snapshot.transactions[0].id])
        try await store.resolveMatch(eventID: review.eventID, transactionID: review.candidates[0])
        snapshot = try await store.snapshot()
        #expect(snapshot.transactions.count == 1 && snapshot.reviews.isEmpty)
        #expect(snapshot.transactions[0].lifecycle == "posted")
        #expect(snapshot.transactions[0].postedOn == "2026-10-17")
        #expect(snapshot.transactions[0].sources.split(separator: ",").count == 2)
        #expect(try await store.transactionEvidence(id: snapshot.transactions[0].id).sources.count == 2)
        #expect(try await store.integrityCheck())
        await store.close()
    }
}

@Test func distinctStatementPurchaseCanBeKeptSeparateAndStaleMatchesAreRejected() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional", currency: "CAD")
    try await ingestMapped(store, id: "wallet")
    var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
    try await store.importCSV(statement(), mapping: mapping)
    let review = try #require(try await store.snapshot().reviews.first)
    let target = try #require(try await store.transaction(id: review.candidates[0]))
    try await store.delete(id: target.id, revision: target.revision)
    await #expect(throws: (any Error).self) { try await store.resolveMatch(eventID: review.eventID, transactionID: target.id) }
    try await store.resolveMatch(eventID: review.eventID, transactionID: nil)
    #expect(try await store.snapshot().transactions.count == 1)
    #expect(try await store.snapshot().transactions[0].sources == "csv")
    await store.close()
}

@Test func skippedCSVRowsResumeWithoutDuplicatingAcceptedRows() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional", currency: "CAD")
    var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
    let doc = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-17,CAFE A,-12.50\n2026-10-18,CAFE B,-15.00\n".utf8), filename: "resume.csv")
    #expect(try await store.importCSV(doc, mapping: mapping, skipped: [3]) == 1)
    #expect(try await store.csvImportHistory(hash: doc.hash, accountID: mapping.accountID)?.importedRows == [2])
    #expect(try await store.importCSV(doc, mapping: mapping) == 1)
    #expect(try await store.importCSV(doc, mapping: mapping) == 0)
    #expect(try await store.snapshot().totalTransactions == 2)
    #expect(try await store.testRows("SELECT * FROM raw_events").count == 2)
    await store.close()
}

@Test func changedCSVMappingRequiresExplicitReviewAndKeepsSourceEvidence() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional", currency: "CAD")
    var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
    let doc = try statement()
    try await store.importCSV(doc, mapping: mapping)
    let original = try await store.snapshot().transactions[0]
    let evidence = try await store.transactionEvidence(id: original.id).sources[0]
    mapping.positiveMeansDebit = true
    await #expect(throws: (any Error).self) { try await store.importCSV(doc, mapping: mapping) }
    #expect(try await store.importCSV(doc, mapping: mapping, updateExisting: true) == 1)
    #expect(try await store.transaction(id: original.id)?.amountMinor == -1250)
    let review = try #require(try await store.snapshot().reviews.first)
    #expect(review.reason == "csv_mapping_changed" && review.label.isEmpty)
    try await store.resolveCSVReview(eventID: review.eventID, useStatement: true)
    let changed = try #require(try await store.transaction(id: original.id))
    #expect(changed.amountMinor == 1250 && changed.categoryNeedsReview)
    #expect(try await store.transactionEvidence(id: original.id).sources[0].payload == evidence.payload)
    #expect(try await store.transactionEvidence(id: original.id).history.count >= 2)
    #expect(try await store.importCSV(doc, mapping: mapping) == 0)
    #expect(try await store.integrityCheck())
    await store.close()
}

@Test(arguments: [true, false]) func csvIDConflictComparesAndResolvesStatementFacts(useStatement: Bool) async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional", currency: "CAD")
    var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id; mapping.externalIDColumn = 3
    try await store.importCSV(statement(id: "bank-1"), mapping: mapping)
    try await store.importCSV(statement("-15.00", id: "bank-1"), mapping: mapping)
    let review = try #require(try await store.snapshot().reviews.first)
    #expect(review.reason == "external_id_conflict" && review.label.isEmpty && review.candidates.count == 1)
    try await store.resolveCSVReview(eventID: review.eventID, useStatement: useStatement)
    let snapshot = try await store.snapshot()
    #expect(snapshot.transactions.count == 1 && snapshot.reviews.isEmpty)
    #expect(snapshot.transactions[0].amountMinor == (useStatement ? -1500 : -1250))
    #expect(try await store.transactionEvidence(id: snapshot.transactions[0].id).sources.count == 2)
    #expect(try await store.integrityCheck())
    await store.close()
}

@Test func savedStatementDuplicatesMergeWithoutLosingNotesReceiptsOrSourceHistory() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional", currency: "CAD")
    try await ingestMapped(store, id: "wallet")
    let wallet = try await store.snapshot().transactions[0]
    var mapping = CSVMapping(); mapping.accountID = wallet.accountID!
    try await store.importCSV(statement(id: nil), mapping: mapping)
    let review = try #require(try await store.snapshot().reviews.first)
    try await store.resolveMatch(eventID: review.eventID, transactionID: nil)
    var saved = try #require(try await store.snapshot().transactions.first { $0.sources == "csv" })
    try await store.saveTransactionNote(transactionID: saved.id, text: "Statement note", revision: saved.revision)
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=")!
    let receiptID = try await store.addReceiptImage(transactionID: saved.id, data: png, ocrText: "Fictional receipt")
    try await store.seedDetailLocation(transactionID: saved.id)
    saved = try #require(try await store.transaction(id: saved.id))
    #expect(try await store.savedStatementMatches(transactionID: wallet.id).map(\.id) == [saved.id])
    try await store.mergeStatementMatch(transactionID: wallet.id, otherID: saved.id, revision: wallet.revision, otherRevision: saved.revision)
    let merged = try await store.snapshot()
    #expect(merged.transactions.count == 1)
    #expect(merged.transactions[0].notes == "Statement note" && merged.transactions[0].lifecycle == "posted")
    #expect(try await store.transactionEvidence(id: wallet.id).sources.count == 2)
    #expect(try await store.receipts(transactionID: wallet.id).first?.id == receiptID)
    #expect(try await store.receiptImage(id: receiptID) == png)
    #expect(merged.transactions[0].location?.label == "Fictional shop")
    #expect(try await store.transactionEvidence(id: wallet.id).history.contains { $0.reason == "merge_statement" })
    #expect(try await store.savedStatementMatches(transactionID: wallet.id).isEmpty)
    #expect(try await store.integrityCheck())
    await store.close()
}

@Test func unassignedManualSpendingIsQueuedButConfirmedCategoriesAndIncomeAreProtected() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    for (type, category, amount, review) in [("expense", nil, Int64(-100), true), ("expense", "dining", -200, false), ("income", nil, 300, false)] as [(String,String?,Int64,Bool)] {
        try await store.save(.init(description: "Fictional", amountMinor: amount, currency: "CAD", occurredOn: "2026-10-17", accountID: account, type: type, category: category, needsReview: review, notes: ""))
    }
    let model = String(repeating: "a", count: 64)
    try await store.registerModel(id: model, name: "Fixture", backend: "ollama", policy: "groundkeeper-19-v2", configuration: "{}")
    try await store.enqueueClassifications(modelID: model)
    #expect(try await store.snapshot().pendingJobs == 1)
    let task = try #require(try await store.claimClassification(modelID: model))
    try await store.completeClassification(task, decision: .init(type: "expense", category: "dining", review: true))
    #expect(try await store.snapshot().transactions.filter { $0.origin == "user" }.count == 2)
    #expect(try await store.integrityCheck())
    await store.close()
}

@Test func reviewReasonsRemainSeparateFromCategoryReviewAndTimeSurvivesOrdinaryEdits() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional", currency: "CAD")
    try await ingestMapped(store, id: "collision")
    try await store.ingestCapture(data: capture("collision", amount: "CAD 15.00"), deliveryPath: "changed.json")
    let t = try await store.snapshot().transactions[0]
    let instant = try CaptureParser.timestamp("2026-10-17T10:00:00-04:00").0
    _ = try await store.testRows("UPDATE transactions SET time_precision='instant',occurred_at_ms=\(instant),utc_offset_minutes=-240 WHERE id='\(t.id)'")
    try await store.save(.init(id: t.id, revision: t.revision, description: t.description, amountMinor: t.amountMinor, currency: t.currency, occurredOn: t.occurredOn, accountID: t.accountID, type: "expense", category: "dining", needsReview: false, notes: "Just a note"))
    let changed = try #require(try await store.transaction(id: t.id))
    #expect(!changed.categoryNeedsReview && changed.needsReview)
    #expect(changed.reviewIssues.first?.reason == "event_identity_collision")
    #expect(changed.occurredAtMS == instant && changed.utcOffsetMinutes == -240)
    let source = try await store.transactionEvidence(id: t.id).sources[0]
    #expect(source.capturedAtMS == instant && source.card == "Example card")
    await store.close()
}

@Test func draftReceiptContextUsesSavedAndStagedTextAndExcludesRemovedReceipts() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional", currency: "CAD")
    try await ingestMapped(store, id: "receipts")
    let t = try await store.snapshot().transactions[0]
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=")!
    let first = try await store.addReceiptImage(transactionID: t.id, data: png, ocrText: "GROCERIES\nBread 3.00\nVISA 1234567890123456")
    _ = try await store.addReceiptImage(transactionID: t.id, data: png, ocrText: "Shampoo 5.00")
    let context = try #require(try await store.draftReceiptContext(transactionID: t.id, excluding: [first], additionalTexts: ["Notebook 8.00"]))
    #expect(!context.text.contains("Bread") && !context.text.contains("VISA"))
    #expect(context.text.contains("Shampoo") && context.text.contains("Notebook"))
    #expect(ReceiptContext.select(from: [String(repeating: "é", count: 2000)])!.text.utf8.count <= 1600)
    await store.close()
}

extension LedgerStore {
    func stageVersionTenBlankConfirmation() throws {
        let part = try db.query("SELECT id FROM transaction_parts LIMIT 1")[0].text("id")
        try assign(partID: part, type: "expense", category: nil, review: true, origin: "user", runID: nil)
        try db.query("DELETE FROM schema_migrations WHERE version=11")
    }
}

@Test func versionElevenReleasesLegacyBlankConfirmationsWithoutRewritingHistory() async throws {
    let (store, url) = try vault()
    try await store.addAccount(name: "Fictional", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    try await store.save(.init(description: "Fictional", amountMinor: -100, currency: "CAD", occurredOn: "2026-10-17", accountID: account, type: "expense", category: nil, needsReview: true, notes: ""))
    try await store.stageVersionTenBlankConfirmation()
    await store.close()
    let upgraded = try LedgerStore(url: url)
    let row = try await upgraded.snapshot().transactions[0]
    #expect(row.origin == "system" && row.category == nil && row.categoryNeedsReview)
    #expect(try await upgraded.testRows("SELECT * FROM category_assignments WHERE origin='user'").count == 2)
    #expect(try await upgraded.unqueuedClassificationCount() == 1)
    #expect(try await upgraded.integrityCheck())
    await upgraded.close()
}

@Test func statementCorrectionRejectsAStaleSavedEntry() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional", currency: "CAD")
    var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id; mapping.externalIDColumn = 3
    try await store.importCSV(statement(id: "bank-1"), mapping: mapping)
    let old = try await store.snapshot().transactions[0]
    try await store.importCSV(statement("-15.00", id: "bank-1"), mapping: mapping)
    let review = try #require(try await store.snapshot().reviews.first)
    try await store.saveTransactionNote(transactionID: old.id, text: "Newer edit", revision: old.revision)
    await #expect(throws: LedgerError.self) {
        try await store.resolveCSVReview(eventID: review.eventID, useStatement: true, expectedRevision: old.revision)
    }
    #expect(try await store.transaction(id: old.id)?.amountMinor == -1250)
    #expect(try await store.snapshot().reviews.count == 1)
    await store.close()
}

@Test func statementReviewCannotRelabelAnEntryThatMovedToAnotherCurrency() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "CAD", currency: "CAD")
    let cad = try await store.snapshot().accounts[0].id
    var mapping = CSVMapping(); mapping.accountID = cad; mapping.externalIDColumn = 3
    try await store.importCSV(statement(id: "bank-1"), mapping: mapping)
    let t = try await store.snapshot().transactions[0]
    try await store.addAccount(name: "USD", currency: "USD")
    let usd = try #require(try await store.snapshot().accounts.first { $0.currency == "USD" })
    try await store.save(.init(id: t.id, revision: t.revision, description: t.description, amountMinor: t.amountMinor,
        currency: "USD", occurredOn: t.occurredOn, accountID: usd.id, type: "expense", category: "dining", needsReview: false, notes: ""))
    try await store.importCSV(statement("-15.00", id: "bank-1"), mapping: mapping)
    let review = try #require(try await store.snapshot().reviews.first)
    for useStatement in [true, false] {
        await #expect(throws: LedgerError.self) { try await store.resolveCSVReview(eventID: review.eventID, useStatement: useStatement) }
    }
    #expect(try await store.transaction(id: t.id)?.currency == "USD")
    #expect(try await store.transaction(id: t.id)?.amountMinor == -1250)
    #expect(try await store.integrityCheck())
    await store.close()
}

@Test func resolvingAStatementMatchPrunesOtherNowIneligibleSuggestions() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional", currency: "CAD")
    try await ingestMapped(store, id: "wallet")
    var mapping = CSVMapping(); mapping.accountID = try await store.snapshot().accounts[0].id
    let doc = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-17,FICTIONAL CAFE,-12.50\n2026-10-17,ANOTHER CAFE,-12.50\n".utf8), filename: "same-amounts.csv")
    try await store.importCSV(doc, mapping: mapping)
    let reviews = try await store.snapshot().reviews
    #expect(reviews.count == 2)
    let target = try #require(try await store.reviewCandidates(reviewID: reviews[0].id).first)
    try await store.resolveMatch(eventID: reviews[0].eventID, transactionID: target.id)
    #expect(try await store.reviewCandidates(reviewID: reviews[1].id).isEmpty)
    try await store.resolveMatch(eventID: reviews[1].eventID, transactionID: nil)
    #expect(try await store.snapshot().transactions.count == 2)
    #expect(try await store.snapshot().reviews.isEmpty)
    await store.close()
}
