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
        if CommandLine.arguments.contains("--recording-preview") {
            try await RecordingPreview.seed(store)
            return
        }
        if CommandLine.arguments.contains("--transaction-preview") {
            try await TransactionPreview.seed(store)
            return
        }
        if CommandLine.arguments.contains("--spending-preview") {
            try await SpendingPreview.seed(store)
            return
        }
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
        if CommandLine.arguments.contains("--category-preview") {
            var mapping = CSVMapping(); mapping.accountID = account.id
            let document = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-22,Fictional Ollama suggestion,-15.50\n".utf8), filename: "category-preview.csv")
            _ = try await store.importCSV(document, mapping: mapping)
            let identity = String(repeating: "a", count: 64)
            try await store.registerModel(id: identity, name: "gemma3:4b", backend: "ollama", policy: "groundkeeper-19-v2", configuration: "{\"fictional_preview\":true}")
            try await store.enqueueClassifications(modelID: identity)
            if let task = try await store.claimClassification(modelID: identity) {
                try await store.completeClassification(task, decision: .init(type: "expense", category: "dining", review: true))
            }
            try await store.save(.init(description: "Fictional purchase with no category", amountMinor: -3400, currency: "CAD",
                                      occurredOn: "2026-10-23", accountID: account.id, type: "expense", category: nil, needsReview: true, notes: "Fictional UI preview record."))
        }
        try await store.addAccount(name: "Travel card · Demo", currency: "CAD")
        // Real capture-review controls, backed by the disposable preview vault.
        for (id, wallet, card) in [("preview-wallet", true, "Everyday card · 1234"),
                                   ("preview-bank", false, "CIBC Dividend Visa Card, 5678")] {
            var payload: [String: Any] = [
                "schema_version": 2, "event_id": id, "captured_at": "2026-10-20T10:00:00-04:00",
                "source": wallet ? "wallet_transaction" : "bank_notification",
                "app": wallet ? "Wallet" : "CIBC Banking",
                "input_shape": wallet ? "wallet_transaction_fields" : "notification_fields"
            ]
            if wallet {
                payload.merge(["card_or_pass": card, "merchant": "Fictional Café", "amount": "$8.50"]) { _, new in new }
            } else {
                payload.merge(["title": card, "subtitle": "Fictional Bookshop", "body": "$24.00"]) { _, new in new }
            }
            try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: payload), deliveryPath: id + ".json")
        }
    }
}
