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
                                      policy: "groundkeeper-18-v1", configuration: "{}", select: index == 0)
        if index == 0 { try await store.enqueueClassifications(modelID: member.id) }
    }
    #expect(try await store.snapshot().pendingJobs == 1)
    #expect(try await store.testRows("SELECT model_id FROM classification_jobs WHERE status='pending'")[0].text("model_id") == councilMembers[0].id)
    #expect(try await store.integrityCheck())
}
