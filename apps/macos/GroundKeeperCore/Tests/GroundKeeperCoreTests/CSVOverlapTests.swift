import Foundation
import Testing
@testable import GroundKeeperCore

private func csv(_ names: String, ending: String = "\n") throws -> CSVDocument {
    let lines = ["Date,Description,Amount"] + names.map { "2026-10-17,FICTIONAL \($0),-12.50" }
    return try CSVDocument(data: Data((lines.joined(separator: ending) + ending).utf8), filename: "fictional.csv")
}

private func csvAccount(_ store: LedgerStore, name: String = "Fictional") async throws -> CSVMapping {
    try await store.addAccount(name: name, currency: "CAD")
    var mapping = CSVMapping()
    mapping.accountID = try #require(try await store.snapshot().accounts.first { $0.name == name }).id
    return mapping
}

@Test func consecutiveCSVOverlapProducesTheUnionAndRetainsEvidenceAfterReopening() async throws {
    let (store, url) = try vault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let mapping = try await csvAccount(store)
    try await store.importCSV(csv("CDE"), mapping: mapping)
    let saved = try await store.snapshot().transactions
    let incoming = try csv("ABCD")
    #expect(try await store.importCSV(incoming, mapping: mapping) == 4) // Source records, including linked overlaps.
    let snapshot = try await store.snapshot()
    #expect(snapshot.totalTransactions == 5 && snapshot.reviews.isEmpty)
    #expect(Set(snapshot.transactions.map(\.description)) == Set("ABCDE".map { "FICTIONAL \($0)" }))
    for transaction in saved {
        #expect(try await store.transaction(id: transaction.id) != nil)
        let evidence = try await store.transactionEvidence(id: transaction.id)
        #expect(evidence.sources.count == (transaction.description == "FICTIONAL E" ? 1 : 2))
    }
    #expect(try await store.testRows("SELECT * FROM import_rows WHERE status='duplicate'").count == 2)
    #expect(try await store.csvImportHistory(hash: incoming.hash, accountID: mapping.accountID)?.importedRows == [2, 3, 4, 5])
    #expect(try await store.integrityCheck())
    await store.close()
    let reopened = try LedgerStore(url: url)
    #expect(try await reopened.importCSV(incoming, mapping: mapping) == 0)
    try await reopened.importCSV(csv("ABCDE", ending: "\r\n"), mapping: mapping)
    #expect(try await reopened.snapshot().totalTransactions == 5)
    #expect(try await reopened.integrityCheck())
    await reopened.close()
}

@Test(arguments: [("ABCDE", "ZBCDY", 7), ("ABCDE", "BCD", 5), ("CDE", "ABCD", 5), ("CD", "ABCDE", 5), ("A", "AB", 2)])
func csvOverlapAllowsInteriorContainedAndSingleRowBlocks(example: (String, String, Int)) async throws {
    let (store, _) = try vault()
    let mapping = try await csvAccount(store)
    try await store.importCSV(csv(example.0), mapping: mapping)
    try await store.importCSV(csv(example.1), mapping: mapping)
    #expect(try await store.snapshot().totalTransactions == example.2)
    #expect(try await store.integrityCheck())
    await store.close()
}

@Test(arguments: [("AB", "AXBY", 5), ("ABC", "AC", 4), ("ABC", "CBA", 5)])
func csvOverlapDoesNotCollectScatteredOrReversedMatches(example: (String, String, Int)) async throws {
    let (store, _) = try vault()
    let mapping = try await csvAccount(store)
    try await store.importCSV(csv(example.0), mapping: mapping)
    try await store.importCSV(csv(example.1), mapping: mapping)
    #expect(try await store.snapshot().totalTransactions == example.2)
    #expect(try await store.testRows("SELECT * FROM import_rows WHERE status='duplicate'").count == 1)
    await store.close()
}

@Test(arguments: [("AAB", "AAAB", 4), ("AB", "ABAB", 4), ("AA", "AAA", 3)])
func csvOverlapPreservesRepeatedPurchaseCounts(example: (String, String, Int)) async throws {
    let (store, _) = try vault()
    let mapping = try await csvAccount(store)
    try await store.importCSV(csv(example.0), mapping: mapping)
    try await store.importCSV(csv(example.1), mapping: mapping)
    #expect(try await store.snapshot().totalTransactions == example.2)
    // Re-encoding the larger export must not use multiple prior files to cover
    // several identical incoming purchases with one saved purchase.
    try await store.importCSV(csv(example.1, ending: "\r\n"), mapping: mapping)
    #expect(try await store.snapshot().totalTransactions == example.2)
    #expect(try await store.integrityCheck())
    await store.close()
}

@Test func csvOverlapCombinesCompatibleBlocksFromSeveralEarlierFiles() async throws {
    let (store, _) = try vault()
    let mapping = try await csvAccount(store)
    for names in ["AB", "BC", "ABC", "XABCY"] { try await store.importCSV(csv(names), mapping: mapping) }
    #expect(try await store.snapshot().totalTransactions == 5)
    #expect(try await store.integrityCheck())
    await store.close()
}

@Test func csvOverlapRequiresExactFactsAndTheSameAccount() async throws {
    let (store, _) = try vault()
    let mapping = try await csvAccount(store)
    try await store.importCSV(csv("A"), mapping: mapping)
    for row in ["2026-10-18,FICTIONAL A,-12.50", "2026-10-17,FICTIONAL A,-12.51", "2026-10-17,fictional A,-12.50", "2026-10-17,FICTIONAL A,12.50"] {
        let document = try CSVDocument(data: Data("Date,Description,Amount\n\(row)\n".utf8), filename: "different.csv")
        try await store.importCSV(document, mapping: mapping)
    }
    let other = try await csvAccount(store, name: "Other fictional account")
    try await store.importCSV(csv("A"), mapping: other)
    #expect(try await store.snapshot().totalTransactions == 6)
    #expect(try await store.testRows("SELECT * FROM import_rows WHERE status='duplicate'").isEmpty)
    await store.close()
}

@Test func csvOverlapUsesSourceFactsAndPreservesSavedEdits() async throws {
    let (store, _) = try vault()
    let mapping = try await csvAccount(store)
    try await store.importCSV(csv("AB"), mapping: mapping)
    let saved = try #require(try await store.snapshot().transactions.first { $0.description == "FICTIONAL A" })
    try await store.save(.init(id: saved.id, revision: saved.revision, description: "My edited description", amountMinor: -1300, currency: "CAD", occurredOn: "2026-10-16", accountID: mapping.accountID, type: "expense", category: "dining", needsReview: false, notes: "Keep my note"))
    // A later approved correction can also have changed the statement date.
    _ = try await store.testRows("UPDATE transactions SET posted_on='2026-10-18' WHERE id='\(saved.id)'")
    try await store.importCSV(csv("ABC"), mapping: mapping)
    let edited = try #require(try await store.transaction(id: saved.id))
    #expect(edited.description == "My edited description" && edited.amountMinor == -1300 && edited.occurredOn == "2026-10-16")
    #expect(edited.notes == "Keep my note" && edited.category == "dining" && !edited.categoryNeedsReview)
    #expect(edited.postedOn == "2026-10-18")
    #expect(try await store.snapshot().totalTransactions == 3)
    #expect(try await store.integrityCheck())
    await store.close()
}

@Test func csvOverlapDoesNotBridgeSkippedRowsInEitherFile() async throws {
    for skippedInPrevious in [true, false] {
        let (store, _) = try vault()
        let mapping = try await csvAccount(store)
        try await store.importCSV(csv(skippedInPrevious ? "AXB" : "AB"), mapping: mapping, skipped: skippedInPrevious ? [3] : [])
        try await store.importCSV(csv(skippedInPrevious ? "AB" : "AXB"), mapping: mapping, skipped: skippedInPrevious ? [] : [3])
        #expect(try await store.snapshot().totalTransactions == 3)
        #expect(try await store.testRows("SELECT * FROM import_rows WHERE status='duplicate'").count == 1)
        await store.close()
    }
}

@Test func csvOverlapResumesSkippedRowsWithoutReusingAnAcceptedTarget() async throws {
    let (store, _) = try vault()
    let mapping = try await csvAccount(store)
    try await store.importCSV(csv("A"), mapping: mapping)
    let document = try csv("AA")
    try await store.importCSV(document, mapping: mapping, skipped: [2])
    #expect(try await store.snapshot().totalTransactions == 1)
    try await store.importCSV(document, mapping: mapping)
    #expect(try await store.snapshot().totalTransactions == 2)
    #expect(try await store.importCSV(document, mapping: mapping) == 0)
    await store.close()
}

@Test func csvOverlapKeepsReliableBankIDsAndTheirConflictReviews() async throws {
    let (store, _) = try vault()
    var mapping = try await csvAccount(store); mapping.externalIDColumn = 3
    for (record, amount) in [("bank-1", "-12.50"), ("bank-2", "-12.50"), ("bank-1", "-15.00")] {
        let document = try CSVDocument(data: Data("Date,Description,Amount,ID\n2026-10-17,FICTIONAL A,\(amount),\(record)\n".utf8), filename: "ids.csv")
        try await store.importCSV(document, mapping: mapping)
    }
    #expect(try await store.snapshot().totalTransactions == 2)
    #expect(try await store.snapshot().reviews.map(\.reason) == ["external_id_conflict"])
    await store.close()
}

@Test func csvOverlapIgnoresDeletedOrMovedTransactionsAndRollsBackInvalidImports() async throws {
    let (store, _) = try vault()
    let mapping = try await csvAccount(store)
    try await store.importCSV(csv("AB"), mapping: mapping)
    let a = try #require(try await store.snapshot().transactions.first { $0.description == "FICTIONAL A" })
    try await store.delete(id: a.id, revision: a.revision)
    let b = try #require(try await store.snapshot().transactions.first)
    let other = try await csvAccount(store, name: "Other fictional account")
    try await store.save(.init(id: b.id, revision: b.revision, description: b.description, amountMinor: b.amountMinor, currency: "CAD", occurredOn: b.occurredOn, accountID: other.accountID, type: "expense", category: nil, needsReview: true, notes: ""))
    try await store.importCSV(csv("ABC"), mapping: mapping)
    #expect(try await store.snapshot().totalTransactions == 4)
    let before = try await store.testRows("SELECT * FROM raw_events").count
    let invalid = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-17,FICTIONAL A,-12.50\n2026-10-17,Broken,no\n".utf8), filename: "invalid.csv")
    await #expect(throws: (any Error).self) { try await store.importCSV(invalid, mapping: mapping) }
    #expect(try await store.testRows("SELECT * FROM raw_events").count == before)
    #expect(try await store.integrityCheck())
    await store.close()
}

@Test func csvSequenceIndexHandlesLargeIdenticalExports() {
    let index = CSVSequenceIndex(Array(repeating: 0, count: 50_000))
    let match = index.longestMatch(Array(repeating: 0, count: 49_999), rowNumbers: Array(2...50_000))
    #expect(match?.incoming == 0..<49_999 && match?.previous == 0..<49_999)
}

@Test func csvSequenceIndexMatchesAnExhaustiveContiguousSearch() {
    let sequences = (0..<81).map { number in (0..<4).map { position in (number / Int(pow(3.0, Double(position)))) % 3 } }
    for incoming in sequences {
        let index = CSVSequenceIndex(incoming)
        for previous in sequences {
            var expected = 0
            for i in incoming.indices {
                for j in previous.indices {
                    var length = 0
                    while i + length < incoming.count && j + length < previous.count && incoming[i + length] == previous[j + length] { length += 1 }
                    expected = max(expected, length)
                }
            }
            let match = index.longestMatch(previous.map(Optional.some), rowNumbers: Array(2..<previous.count + 2))
            #expect((match?.incoming.count ?? 0) == expected)
            if let match { #expect(Array(incoming[match.incoming]) == Array(previous[match.previous])) }
        }
    }
}
