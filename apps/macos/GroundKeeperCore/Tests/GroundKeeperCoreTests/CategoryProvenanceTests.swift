import Foundation
import Testing
@testable import GroundKeeperCore

private func edit(_ row: LedgerTransaction) -> TransactionEdit {
    .init(id: row.id, revision: row.revision, description: row.description, amountMinor: row.amountMinor,
          currency: row.currency, occurredOn: row.occurredOn, accountID: row.accountID,
          type: row.type, category: row.category, needsReview: row.needsReview, notes: row.notes)
}

@Test func exactModelAttributionSurvivesEditsProviderChangesAndReopen() async throws {
    for (provider, name, title) in [("ollama", "gemma3:4b", "Ollama · gemma3:4b"),
                                  ("qwen_mlx", "gk-qwen-v2", "GroundKeeper Qwen · gk-qwen-v2"),
                                  ("laya_mps", "gk-laya-v2", "GroundKeeper Laya · gk-laya-v2"),
                                  ("apple_shortcut", "GK Categorize On-Device", "Apple Intelligence · GK Categorize On-Device")] {
        let (store, url) = try vault()
        try await store.addAccount(name: "Fictional card", currency: "CAD")
        try await ingestMapped(store, id: "attribution")
        let model = String(repeating: "a", count: 64)
        try await store.registerModel(id: model, name: name, backend: provider, policy: "groundkeeper-19-v2", configuration: "{}")
        try await store.enqueueClassifications(modelID: model)
        let task = try #require(try await store.claimClassification(modelID: model))
        try await store.completeClassification(task, decision: .init(type: "expense", category: "other", review: true))
        var row = try #require(try await store.snapshot().transactions.first)
        #expect(row.categoryAttribution.explanation == "Category chosen by " + title)
        #expect(row.categoryModelName == name && row.categoryModelProvider == provider)
        var changed = edit(row); changed.notes = "Added a note without choosing a category"
        try await store.save(changed)
        row = try #require(try await store.transaction(id: row.id))
        #expect(row.origin == "model" && row.categoryModelName == name)
        #expect(try await store.testRows("SELECT * FROM category_assignments").count == 2)

        try await store.registerModel(id: String(repeating: "b", count: 64), name: "another-model", backend: "ollama", policy: "groundkeeper-19-v2", configuration: "{}")
        await store.close()
        let reopened = try LedgerStore(url: url)
        row = try #require(try await reopened.transaction(id: row.id))
        #expect(row.categoryAttribution.explanation == "Category chosen by " + title)
        changed = edit(row); changed.confirmCategory = true
        try await reopened.save(changed)
        row = try #require(try await reopened.transaction(id: row.id))
        #expect(row.origin == "user" && row.categoryModelName == nil)
        #expect(row.categoryAttribution.explanation == "Category chosen by user")
        let history = try await reopened.testRows("SELECT a.origin,old.origin AS previous,m.model_name FROM category_assignments a JOIN category_assignments old ON old.id=a.supersedes_id JOIN classification_runs r ON r.id=old.run_id JOIN model_versions m ON m.id=r.model_version_id WHERE a.origin='user'")
        #expect(history.count == 1 && history[0].text("model_name") == name)
        #expect(try await reopened.integrityCheck())
    }
}

@Test func missingCategoriesAreNullAndSearchableInLedgerAndSpending() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fictional account", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    try await ingestMapped(store, id: "no-category")
    #expect(try await store.snapshot().transactions[0].category == nil)
    try await store.save(.init(description: "Unassigned purchase", amountMinor: -2000, currency: "CAD", occurredOn: "2026-10-25", accountID: account, type: "expense", category: nil, needsReview: true, notes: ""))
    try await store.save(.init(description: "Fictional income", amountMinor: 5000, currency: "CAD", occurredOn: "2026-10-25", accountID: account, type: "income", category: nil, needsReview: false, notes: ""))
    #expect(try await store.testRows("SELECT * FROM categories").count == 19)
    #expect(try await store.testRows("SELECT category_id FROM category_assignments WHERE category_id IS NOT NULL").isEmpty)
    var query = LedgerTransactionQuery(); query.category = "none"
    #expect(try await store.transactionPage(query).totalMatches == 3)
    query.search = "None"; query.categoryNames = ["none": "None"]
    #expect(try await store.transactionPage(query).totalMatches == 3)
    var filter = SpendingFilter(range: try .init(start: "2026-10-01", end: "2026-11-01"), timezone: "America/Toronto")
    filter.category = "none"
    let report = try await store.spendingReport(filter)
    #expect(report.totals.gross == 2000 && report.categories.first?.category == "none")
    #expect(try await store.integrityCheck())
}

@Test func aiSuggestionsCannotChooseMissingCategories() throws {
    for type in ["expense", "refund", "unknown"] {
        for category in [nil, "uncategorized", "none"] as [String?] {
            #expect(throws: (any Error).self) { try ClassificationDecision(type: type, category: category, review: true).validateSuggestion() }
        }
        try ClassificationDecision(type: type, category: "other", review: true).validateSuggestion()
    }
    try ClassificationDecision(type: "income", category: nil, review: true).validateSuggestion()
    #expect(CategoryAttribution(origin: "council").explanation == "Category chosen by AI Council")
}
