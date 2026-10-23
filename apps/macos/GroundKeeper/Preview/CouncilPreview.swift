import Foundation
import GroundKeeperCore

#if DEBUG
/// Uses the real queue and persistence with deterministic providers. Never invokes XPC or the network.
enum CouncilPreview {
    static func seed(_ store: LedgerStore) async throws {
        guard let account = try await store.snapshot().accounts.first else { return }
        var mapping = CSVMapping(); mapping.accountID = account.id
        let csv = "Date,Description,Amount\n2026-10-23,Council Agreement,-8.50\n2026-10-23,Council Disagreement,-9.50\n2026-10-23,Council Partial,-10.50\n2026-10-23,Council No Consensus,-11.50\n"
        _ = try await store.importCSV(CSVDocument(data: Data(csv.utf8), filename: "council-preview.csv"), mapping: mapping)
        let members = [CouncilMember(id: String(repeating: "a", count: 64), name: "Fictional Qwen", backend: "qwen_mlx"),
                       CouncilMember(id: String(repeating: "b", count: 64), name: "Fictional Laya", backend: "laya_mps"),
                       CouncilMember(id: String(repeating: "c", count: 64), name: "Fictional Apple", backend: "apple_shortcut")]
        for member in members {
            try await store.registerModel(id: member.id, name: member.name, backend: member.backend,
                policy: "groundkeeper-18-v1", configuration: "{}", select: false)
        }
        let configuration = try CouncilConfiguration(members: members)
        try await store.registerCouncil(configuration)
        try await store.setMerchantSearchSettings(.init(enabled: true))
        try await store.enqueueCouncil(configID: configuration.id)
        let context = MerchantContext(results: [.init(title: "Fictional Cafe · preview source", body: "Fictional merchant evidence for interface testing.", url: "https://example.org/cafe")])
        for _ in 0..<4 {
            try await CouncilRunner.runBatch(store: store, configuration: configuration, engine: Engine(), limit: 1, search: { task in
                _ = try await store.bindMerchantSearch(.init(query: nil, outcome: "matched", context: context), to: task)
            })
        }
    }
    private actor Engine: CouncilEngine {
        func prepare(_ member: CouncilMember) async throws {}
        func classify(_ input: CouncilInput, member: CouncilMember, task: ClassificationTask) async throws -> ClassificationDecision {
            if input.description == "Council Partial", member.backend == "apple_shortcut" {
                throw CouncilProviderFailure(disposition: "unavailable", code: "shortcut_rate_limited")
            }
            if input.description == "Council No Consensus", member.backend == "apple_shortcut" {
                throw CouncilProviderFailure(disposition: "timeout", code: "deadline_exceeded")
            }
            let disagrees = ["Council Disagreement", "Council No Consensus"].contains(input.description) && member.backend == "laya_mps"
            return .init(type: "expense", category: disagrees ? "shopping" : "dining", review: true)
        }
    }
}
#endif
