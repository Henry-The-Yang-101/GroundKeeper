import Foundation
import Testing
@testable import GroundKeeperCore

let councilMembers = [CouncilMember(id: String(repeating: "a", count: 64), name: "Fixture Qwen", backend: "qwen_mlx"),
                      CouncilMember(id: String(repeating: "b", count: 64), name: "Fixture Laya", backend: "laya_mps"),
                      CouncilMember(id: String(repeating: "c", count: 64), name: "Fixture Apple", backend: "apple_shortcut")]
let diningDecision = ClassificationDecision(type: "expense", category: "dining", review: true)
let shoppingDecision = ClassificationDecision(type: "expense", category: "shopping", review: true)

@Test func councilEqualVotingRequiresTwoCompleteMatchingDecisions() throws {
    func votes(_ decisions: [ClassificationDecision?]) -> [CouncilVote] {
        zip(councilMembers, decisions).map { CouncilVote(member: $0.0, disposition: $0.1 == nil ? "unavailable" : "valid", decision: $0.1) }
    }
    let unanimous = try CouncilResult.resolve(votes([diningDecision, diningDecision, diningDecision]))
    #expect(unanimous.reason == "unanimous" && !unanimous.degraded && unanimous.decision?.review == true)
    let majority = try CouncilResult.resolve(votes([diningDecision, shoppingDecision, diningDecision]))
    #expect(majority.reason == "majority" && majority.decision?.category == "dining" && !majority.degraded)
    let partial = try CouncilResult.resolve(votes([diningDecision, diningDecision, nil]))
    #expect(partial.degraded && partial.decision?.category == "dining")
    #expect(try CouncilResult.resolve(votes([diningDecision, nil, nil])).decision == nil)
    #expect(try CouncilResult.resolve(votes([diningDecision, shoppingDecision, nil])).decision == nil)
    let refund = ClassificationDecision(type: "refund", category: "dining", review: true)
    #expect(try CouncilResult.resolve(votes([diningDecision, shoppingDecision, refund])).decision == nil)
    for permutation in [[0, 1, 2], [2, 0, 1], [1, 2, 0]] {
        let original = votes([diningDecision, shoppingDecision, diningDecision])
        #expect(try CouncilResult.resolve(permutation.map { original[$0] }).decision?.category == "dining")
    }
}

@Test func councilRejectsInvalidMembersAndDecisions() throws {
    #expect(throws: (any Error).self) { try CouncilConfiguration(members: Array(councilMembers.prefix(2))) }
    var members = councilMembers
    members[0] = CouncilMember(id: members[0].id, name: "Qwen", backend: "qwen_mlx", weight: 2)
    #expect(throws: (any Error).self) { try CouncilConfiguration(members: members) }
    let invalid = ClassificationDecision(type: "transfer", category: "dining", review: true)
    #expect(throws: (any Error).self) {
        try CouncilResult.resolve(councilMembers.map { CouncilVote(member: $0, disposition: "valid", decision: invalid) })
    }
    #expect(throws: (any Error).self) {
        try ClassificationDecision(type: "expense", category: "dining", review: false).validateSuggestion()
    }
}

@Test func councilRegistrationDoesNotRetireTheSelectedModelsJobs() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "council-register")
    for (index, member) in councilMembers.enumerated() {
        try await store.registerModel(id: member.id, name: member.name, backend: member.backend,
                                      policy: "groundkeeper-19-v2", configuration: "{}", select: index == 0)
        if index == 0 { try await store.enqueueClassifications(modelID: member.id) }
    }
    #expect(try await store.snapshot().pendingJobs == 1)
    #expect(try await store.testRows("SELECT model_id FROM classification_jobs WHERE status='pending'")[0].text("model_id") == councilMembers[0].id)
    #expect(try await store.integrityCheck())
}

actor FixtureCouncilEngine: CouncilEngine {
    var prepared: [String] = []
    var inputs: [(String, CouncilInput)] = []
    let decisions: [String: ClassificationDecision]
    let failures: [String: CouncilProviderFailure]
    let cancelBackend: String?
    init(decisions: [String: ClassificationDecision] = [:], failures: [String: CouncilProviderFailure] = [:], cancelBackend: String? = nil) {
        self.decisions = decisions; self.failures = failures; self.cancelBackend = cancelBackend
    }
    func prepare(_ member: CouncilMember) async throws { prepared.append(member.backend) }
    func classify(_ input: CouncilInput, member: CouncilMember, task: ClassificationTask) async throws -> ClassificationDecision {
        inputs.append((member.backend, input))
        if member.backend == cancelBackend { throw CancellationError() }
        if let failure = failures[member.backend] { throw failure }
        return decisions[member.backend] ?? diningDecision
    }
}

func councilFixture(count: Int = 1, receipt: Bool = false) async throws -> (LedgerStore, URL, CouncilConfiguration) {
    let (store, url) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    for index in 0..<count { try await ingestMapped(store, id: "council-\(index)") }
    if receipt { try await store.ingestCapture(data: receiptCapture("council-receipt", parent: "council-0"), deliveryPath: "receipt.json") }
    for member in councilMembers {
        try await store.registerModel(id: member.id, name: member.name, backend: member.backend, policy: "groundkeeper-19-v2", configuration: "{}", select: false)
    }
    let config = try CouncilConfiguration(members: councilMembers)
    try await store.registerCouncil(config)
    try await store.enqueueCouncil(configID: config.id)
    return (store, url, config)
}

func bindNoCouncilSearch(_ store: LedgerStore, _ task: ClassificationTask) async throws {
    _ = try await store.bindMerchantSearch(.init(query: nil, outcome: "disabled"), to: task)
}

@Test func councilPersistsMemberProvenanceAndOnlyParentAssigns() async throws {
    let (store, _, config) = try await councilFixture(count: 3)
    let engine = FixtureCouncilEngine(decisions: ["laya_mps": shoppingDecision])
    #expect(try await store.unqueuedClassificationCount() == 0)
    #expect(try await CouncilRunner.runBatch(store: store, configuration: config, engine: engine, search: { try await bindNoCouncilSearch(store, $0) }) == 3)
    #expect(await engine.prepared == ["qwen_mlx", "laya_mps", "apple_shortcut"])
    #expect(try await store.testRows("SELECT * FROM classification_runs").count == 12)
    #expect(try await store.testRows("SELECT * FROM council_votes").count == 9)
    #expect(try await store.testRows("SELECT * FROM category_assignments WHERE origin='model'").isEmpty)
    let snapshot = try await store.snapshot()
    #expect(snapshot.pendingJobs == 0 && snapshot.failedJobs == 0)
    #expect(snapshot.transactions.allSatisfy { $0.origin == "council" && $0.category == "dining" && $0.needsReview })
    let report = try await store.councilReport(transactionID: snapshot.transactions[0].id)!
    #expect(report.result.reason == "majority" && report.result.votes.count == 3)
    #expect(try await store.integrityCheck())
}

@Test func councilFreezesOneSearchAndRedactsAppleReceipts() async throws {
    let (store, _, config) = try await councilFixture(receipt: true)
    try await store.setReceiptCloudConsent(false)
    try await store.enqueueCouncil(configID: config.id)
    try await store.setMerchantSearchSettings(.init(enabled: true))
    let context = MerchantContext(results: [.init(title: "Fictional Cafe", body: "A cafe.", url: "https://example.org/cafe")])
    let engine = FixtureCouncilEngine()
    try await CouncilRunner.runBatch(store: store, configuration: config, engine: engine, search: { task in
        _ = try await store.bindMerchantSearch(.init(query: nil, outcome: "matched", context: context), to: task)
    })
    let inputs = await engine.inputs
    #expect(inputs.count == 3 && inputs.allSatisfy { $0.1.merchantContext == context })
    #expect(inputs.filter { $0.0 != "apple_shortcut" }.allSatisfy { $0.1.receiptContext != nil })
    #expect(inputs.first { $0.0 == "apple_shortcut" }?.1.receiptContext == nil)
    let rows = try await store.testRows("SELECT * FROM council_member_inputs")
    #expect(Set(rows.map { $0.text("input_sha256") }).count == 2)
    for row in rows {
        // No Wallet hint in this fixture: audit and actual input are identical.
        let object = try JSONSerialization.jsonObject(with: Data(row.text("input_json").utf8))
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(contentHash(data) == row.text("input_sha256"))
    }
    let transaction = try await store.snapshot().transactions[0]
    #expect(try await store.councilReport(transactionID: transaction.id)?.receiptSharedWithApple == false)
    try await store.clearMerchantSearchCache()
    #expect(try await store.councilReport(transactionID: transaction.id)?.search?.context == context)
    #expect(try await store.integrityCheck())
}

@Test func councilIncludesAppleReceiptContextByDefault() async throws {
    let (store, _, config) = try await councilFixture(receipt: true)
    try await store.enqueueCouncil(configID: config.id)
    let engine = FixtureCouncilEngine()
    try await CouncilRunner.runBatch(store: store, configuration: config, engine: engine, search: { try await bindNoCouncilSearch(store, $0) })
    #expect(await engine.inputs.allSatisfy { $0.1.receiptContext != nil })
    let transaction = try await store.snapshot().transactions[0]
    #expect(try await store.councilReport(transactionID: transaction.id)?.receiptSharedWithApple == true)
}

@Test func councilFailureIsDegradedAndQuotaIsNotRetriedAcrossTheBatch() async throws {
    let (store, _, config) = try await councilFixture(count: 3)
    let engine = FixtureCouncilEngine(failures: ["apple_shortcut": .init(disposition: "unavailable", code: "shortcut_rate_limited")])
    try await CouncilRunner.runBatch(store: store, configuration: config, engine: engine, search: { try await bindNoCouncilSearch(store, $0) })
    #expect(await engine.inputs.filter { $0.0 == "apple_shortcut" }.count == 1)
    let snapshot = try await store.snapshot()
    #expect(snapshot.transactions.allSatisfy { $0.origin == "council" && $0.needsReview })
    for transaction in snapshot.transactions {
        let report = try await store.councilReport(transactionID: transaction.id)!
        #expect(report.result.degraded && report.result.decision?.category == "dining")
        #expect(report.result.votes.contains { $0.errorCode == "shortcut_rate_limited" })
    }
}

@Test func councilNoConsensusLeavesAssignmentAndRequiresExplicitRetry() async throws {
    let (store, _, config) = try await councilFixture()
    let engine = FixtureCouncilEngine(decisions: ["laya_mps": shoppingDecision], failures: ["apple_shortcut": .init(disposition: "timeout", code: "deadline_exceeded")])
    try await CouncilRunner.runBatch(store: store, configuration: config, engine: engine, search: { try await bindNoCouncilSearch(store, $0) })
    let snapshot = try await store.snapshot()
    #expect(snapshot.transactions[0].origin == "system" && snapshot.failedJobs == 1)
    #expect(try await store.councilReport(transactionID: snapshot.transactions[0].id)?.result.decision == nil)
    try await store.enqueueCouncil(configID: config.id)
    #expect(try await store.claimCouncil(configID: config.id) == nil)
    try await store.retryClassificationFailures()
    let retry = try await store.claimCouncil(configID: config.id)!
    #expect(try await store.savedCouncilSearch(for: retry)?.outcome == "disabled")
    try await store.releaseClassification(retry)
}

@Test func councilCancellationReleasesChildrenWithoutConsumingRetry() async throws {
    let (store, _, config) = try await councilFixture(count: 2)
    let engine = FixtureCouncilEngine(cancelBackend: "laya_mps")
    do {
        try await CouncilRunner.runBatch(store: store, configuration: config, engine: engine, search: { try await bindNoCouncilSearch(store, $0) })
        Issue.record("Cancellation was swallowed")
    } catch is CancellationError {}
    #expect(try await store.testRows("SELECT * FROM classification_runs WHERE status='running'").isEmpty)
    #expect(try await store.testRows("SELECT * FROM classification_jobs WHERE status='pending' AND attempts=0").count == 2)
    #expect(try await store.snapshot().transactions.allSatisfy { $0.origin == "system" })
    #expect(try await store.integrityCheck())
}

@Test func councilLateResultCannotOverwriteAUserEdit() async throws {
    let (store, _, config) = try await councilFixture()
    let task = try await store.claimCouncil(configID: config.id)!
    for member in config.members {
        let child = try await store.startCouncilMember(member, task: task)
        try await store.recordCouncilVote(.init(member: member, disposition: "valid", decision: diningDecision), memberRunID: child.runID, task: task)
    }
    let original = try await store.snapshot().transactions[0]
    try await store.save(.init(id: original.id, revision: original.revision, description: "User correction", amountMinor: original.amountMinor, currency: original.currency,
                              occurredOn: original.occurredOn, accountID: original.accountID, type: "expense", category: "shopping", needsReview: false, notes: "Confirmed"))
    _ = try await store.completeCouncil(task, configuration: config)
    let after = try await store.snapshot().transactions[0]
    #expect(after.origin == "user" && after.category == "shopping" && !after.needsReview)
    #expect(try await store.testRows("SELECT status FROM classification_jobs")[0].text("status") == "obsolete")
}

@Test func councilInterruptedRunsRecoverAndKeepEvidence() async throws {
    let (store, url, config) = try await councilFixture()
    let task = try await store.claimCouncil(configID: config.id)!
    try await bindNoCouncilSearch(store, task)
    _ = try await store.startCouncilMember(config.members[0], task: task)
    await store.close()
    let reopened = try LedgerStore(url: url)
    #expect(try await reopened.testRows("SELECT * FROM classification_runs WHERE status='running'").isEmpty)
    let retried = try await reopened.claimCouncil(configID: config.id)!
    #expect(retried.runID != task.runID)
    #expect(try await reopened.savedCouncilSearch(for: retried)?.outcome == "disabled")
    #expect(try await reopened.integrityCheck())
}

@Test func councilSearchCannotChangeAfterBindingOrOnRetry() async throws {
    let (store, _, config) = try await councilFixture()
    try await store.setMerchantSearchSettings(.init(enabled: true))
    let task = try await store.claimCouncil(configID: config.id)!
    let first = MerchantContext(results: [.init(title: "First", body: "Original evidence", url: "https://example.org/first")])
    let second = MerchantContext(results: [.init(title: "Second", body: "Changed evidence", url: "https://example.org/second")])
    #expect(try await store.bindMerchantSearch(.init(query: nil, outcome: "matched", context: first), to: task) == first)
    let before = try await store.testRows("SELECT input_sha256 FROM classification_runs WHERE id='\(task.runID)'")[0].text("input_sha256")
    #expect(try await store.bindMerchantSearch(.init(query: nil, outcome: "matched", context: second), to: task) == first)
    try await store.releaseClassification(task)
    let retried = try await store.claimCouncil(configID: config.id)!
    #expect(try await store.savedCouncilSearch(for: retried)?.context == first)
    #expect(try await store.testRows("SELECT input_sha256 FROM classification_runs WHERE id='\(retried.runID)'")[0].text("input_sha256") == before)
    try await store.setMerchantSearchSettings(.init(enabled: false))
    let member = try await store.startCouncilMember(config.members[0], task: retried)
    #expect(member.input.merchantContext == nil)
}

@Test func councilPreservesModelJobsWhenUpgradingVersionSix() async throws {
    let (store, url) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    try await ingestMapped(store, id: "migration-seven")
    let model = try await receiptModel(store)
    try await store.enqueueClassifications(modelID: model)
    let before = try await store.testRows("SELECT * FROM classification_jobs")[0]
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/GroundKeeperCore/Resources/002-processing.sql")
    let script = try String(contentsOf: source, encoding: .utf8)
    let table = String(script[script.range(of: "CREATE TABLE classification_jobs")!.lowerBound..<script.range(of: "CREATE INDEX classification_jobs_ready")!.lowerBound])
        .replacingOccurrences(of: "classification_jobs", with: "legacy_jobs")
    let schema = try String(contentsOf: source.deletingLastPathComponent().appendingPathComponent("001-schema.sql"), encoding: .utf8)
    let triggerStart = schema.range(of: "CREATE TRIGGER validate_council_vote")!.lowerBound
    let triggerEnd = schema.range(of: "\nEND;", range: triggerStart..<schema.endIndex)!.upperBound
    try await store.simulateCouncilPredecessor(table: table, voteTrigger: String(schema[triggerStart..<triggerEnd]))
    await store.close()
    let upgraded = try LedgerStore(url: url)
    let after = try await upgraded.testRows("SELECT * FROM classification_jobs")[0]
    #expect(after.text("id") == before.text("id") && after.text("model_id") == model && after.text("status") == "pending")
    #expect(try await upgraded.claimClassification(modelID: model) != nil)
    #expect(try await upgraded.integrityCheck())
}

extension LedgerStore {
    func simulateCouncilPredecessor(table: String, voteTrigger: String) throws {
        try db.transaction {
            try db.executeScript(table)
            try db.executeScript("ALTER TABLE legacy_jobs ADD COLUMN receipt_context_sha256 TEXT;")
            try db.executeScript("INSERT INTO legacy_jobs SELECT id,part_id,input_revision,model_id,status,attempts,next_attempt_at_ms,run_id,error_code,created_at_ms,updated_at_ms,receipt_context_sha256 FROM classification_jobs;")
            try db.executeScript("DROP TABLE classification_jobs; ALTER TABLE legacy_jobs RENAME TO classification_jobs; CREATE INDEX classification_jobs_ready ON classification_jobs(status,next_attempt_at_ms); DROP TRIGGER validate_council_vote; DROP TABLE council_member_inputs; DELETE FROM schema_migrations WHERE version=7;")
            try db.executeScript(voteTrigger)
        }
    }
}

@Test func councilInvalidAndTimedOutMembersCannotCreateSingleVoteConsensus() async throws {
    let (store, _, config) = try await councilFixture()
    let engine = FixtureCouncilEngine(decisions: ["qwen_mlx": .init(type: "unknown", category: "medical", review: true)], failures: ["laya_mps": .init(disposition: "timeout", code: "deadline_exceeded")])
    try await CouncilRunner.runBatch(store: store, configuration: config, engine: engine, search: { try await bindNoCouncilSearch(store, $0) })
    let transaction = try await store.snapshot().transactions[0]
    let report = try await store.councilReport(transactionID: transaction.id)!
    #expect(report.result.decision == nil && report.result.degraded)
    #expect(report.result.votes.first { $0.member.backend == "qwen_mlx" }?.disposition == "invalid")
    #expect(report.result.votes.first { $0.member.backend == "laya_mps" }?.disposition == "timeout")
    #expect(transaction.origin == "system")
}

@Test func councilSwitchingModesRevivesOnlyEligibleCouncilJobs() async throws {
    let (store, _, config) = try await councilFixture()
    let member = councilMembers[0]
    try await store.registerModel(id: member.id, name: member.name, backend: member.backend, policy: "groundkeeper-19-v2", configuration: "{}")
    #expect(try await store.snapshot().pendingJobs == 0)
    try await store.enqueueClassifications(modelID: member.id)
    try await store.registerCouncil(config)
    try await store.enqueueCouncil(configID: config.id)
    #expect(try await store.snapshot().pendingJobs == 1)
    #expect(try await store.claimClassification(modelID: member.id) == nil)
    #expect(try await store.claimCouncil(configID: config.id) != nil)
    #expect(try await store.integrityCheck())
}

@Test func councilRejectsForgedMemberAndCrossMemberVotes() async throws {
    let (store, _, config) = try await councilFixture()
    let task = try await store.claimCouncil(configID: config.id)!
    let qwen = councilMembers[0], laya = councilMembers[1]
    do {
        _ = try await store.startCouncilMember(.init(id: qwen.id, name: qwen.name, backend: "apple_shortcut"), task: task)
        Issue.record("Forged provider accepted")
    } catch LedgerError.conflict {}
    let child = try await store.startCouncilMember(qwen, task: task)
    do {
        try await store.recordCouncilVote(.init(member: laya, disposition: "valid", decision: diningDecision), memberRunID: child.runID, task: task)
        Issue.record("Cross-member vote accepted")
    } catch {}
    #expect(try await store.testRows("SELECT * FROM council_votes").isEmpty)
    #expect(try await store.testRows("SELECT status FROM classification_runs WHERE id='\(child.runID)'")[0].text("status") == "running")
    try await store.recordCouncilVote(.init(member: qwen, disposition: "valid", decision: diningDecision), memberRunID: child.runID, task: task)
    #expect(try await store.integrityCheck())
}

@Test func councilRetainsTheOriginalSuggestionAfterUserConfirmation() async throws {
    let (store, _, config) = try await councilFixture()
    try await CouncilRunner.runBatch(store: store, configuration: config, engine: FixtureCouncilEngine(), search: { try await bindNoCouncilSearch(store, $0) })
    let transaction = try await store.snapshot().transactions[0]
    try await store.save(.init(id: transaction.id, revision: transaction.revision, description: transaction.description, amountMinor: transaction.amountMinor, currency: transaction.currency,
                              occurredOn: transaction.occurredOn, accountID: transaction.accountID, type: "expense", category: "shopping", needsReview: false, notes: "User corrected"))
    let report = try await store.councilReport(transactionID: transaction.id)!
    #expect(!report.isCurrentRevision && report.result.decision?.category == "dining")
    #expect(try await store.snapshot().transactions[0].category == "shopping")
}

@Test func councilWalletHintUsesImmutableEvidenceWithoutCopyingItsValueIntoAudit() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    var payload = try JSONSerialization.jsonObject(with: capture("council-wallet")) as! [String: Any]
    payload["wallet_category_raw"] = "Food/Drink"
    try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: payload), deliveryPath: "wallet.json")
    let snapshot = try await store.snapshot(), mapping = snapshot.reviews[0]
    try await store.confirmMapping(sourceID: mapping.sourceID, label: mapping.label, accountID: snapshot.accounts[0].id)
    for member in councilMembers {
        try await store.registerModel(id: member.id, name: member.name, backend: member.backend, policy: "groundkeeper-19-v2", configuration: "{}", select: false)
    }
    let config = try CouncilConfiguration(members: councilMembers)
    try await store.registerCouncil(config)
    try await store.enqueueCouncil(configID: config.id)
    let task = try await store.claimCouncil(configID: config.id)!
    try await bindNoCouncilSearch(store, task)
    for member in config.members {
        let child = try await store.startCouncilMember(member, task: task)
        #expect(child.input.walletCategoryRaw == "Food/Drink")
        let audit = try await store.testRows("SELECT input_json,input_sha256 FROM classification_runs WHERE id='\(child.runID)'")[0]
        let object = try JSONSerialization.jsonObject(with: Data(audit.text("input_json").utf8)) as! [String: Any]
        #expect(object["wallet_category_raw"] == nil && object["wallet_category_source_event_id"] != nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(contentHash(try encoder.encode(child.input)) == audit.text("input_sha256"))
    }
}
