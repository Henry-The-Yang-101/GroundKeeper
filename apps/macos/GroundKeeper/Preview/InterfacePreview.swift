import Foundation
import GroundKeeperCore

/// Repeatable UI walkthroughs using real persistence, isolated from the user's vault.
enum InterfacePreview {
    static var isEnabled: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--setup-preview") && CommandLine.arguments.contains("--ui-preview")
        #else
        false
        #endif
    }

    static func seed(_ store: LedgerStore) async throws {
        guard isEnabled, try await store.snapshot(limit: 1).accounts.isEmpty else { return }
        try await store.addAccount(name: "Everyday card · Demo", currency: "CAD")
        guard let account = try await store.snapshot(limit: 1).accounts.first else { return }
        let examples: [(String, Int64, String, Bool)] = [
            ("Neighbourhood Café", -850, "dining", false),
            ("City Market", -4620, "groceries", true),
            ("Bookshop", -2400, "shopping", false),
            ("Northside Home & Hardware — weekend supplies", -12649, "housing", true),
            ("Bookshop refund", 1800, "shopping", false),
        ]
        for (index, example) in examples.enumerated() {
            try await store.save(TransactionEdit(
                description: example.0, amountMinor: example.1, currency: "CAD",
                occurredOn: "2026-10-\(20 - index)", accountID: account.id,
                type: example.1 > 0 ? "refund" : "expense", category: example.2,
                needsReview: example.3, notes: "Fictional UI preview record."
            ))
        }
    }
}
