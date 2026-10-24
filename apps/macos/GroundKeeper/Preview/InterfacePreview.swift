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
                needsReview: CommandLine.arguments.contains("--spending-preview") ? false : example.3, notes: "Fictional UI preview record."
            ))
        }
        try await store.addAccount(name: "Travel card · Demo", currency: "CAD")
        if CommandLine.arguments.contains("--spending-preview") {
            let calendar = try ReportCalendar()
            let month = calendar.calendar.dateInterval(of: .month, for: Date())!.start
            for offset in -2...0 {
                let start = calendar.calendar.date(byAdding: .month, value: offset, to: month)!
                let numberOfDays = offset == 0 ? calendar.calendar.component(.day, from: Date()) : 28
                for day in 0..<numberOfDays {
                    let date = calendar.calendar.date(byAdding: .day, value: day, to: start)!
                    for category in ["groceries", "dining", "local_transport"] {
                        let amount: Int64 = category == "groceries" ? 1800 : category == "dining" ? (offset == 0 ? 1600 : 800) : 350
                        try await store.save(TransactionEdit(description: category == "groceries" ? "Fictional Market" : category == "dining" ? "Neighbourhood Café" : "City Transit",
                                                              amountMinor: -amount, currency: "CAD", occurredOn: calendar.day(date), accountID: account.id,
                                                              type: "expense", category: category, needsReview: false, notes: "Fictional spending preview."))
                    }
                }
            }
        }
        if CommandLine.arguments.contains("--spending-preview") {
            let calendar = try ReportCalendar()
            let today = calendar.day(Date())
            // Distinct branches remain separate until the walkthrough confirms a group.
            for (name, amount) in [("Neighbourhood Café 002", Int64(950)), ("Neighbourhood Café 003", 1100), ("Neighbourhood Café", 12500)] {
                try await store.save(TransactionEdit(description: name, amountMinor: -amount, currency: "CAD", occurredOn: today,
                                                    accountID: account.id, type: "expense", category: "dining", needsReview: false, notes: "Fictional merchant preview."))
            }
        }
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
