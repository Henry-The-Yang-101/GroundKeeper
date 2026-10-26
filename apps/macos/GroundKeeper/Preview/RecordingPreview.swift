import Foundation
import GroundKeeperCore

/// Fictional recording ledger with a current-month foreground and weekly comparison history.
enum RecordingPreview {
    static func seed(_ store: LedgerStore, now: Date = Date()) async throws {
        let empty = try await store.snapshot(limit: 1)
        guard empty.accounts.isEmpty, empty.totalTransactions == 0 else {
            throw LedgerError.invalid("The recording demo requires an empty preview vault.")
        }
        let calendar = try ReportCalendar(timezone: "America/Toronto")
        let today = calendar.day(now)
        let monthStart = calendar.day(calendar.calendar.dateInterval(of: .month, for: now)!.start)
        let elapsedDays = max(0, calendar.calendar.component(.day, from: now) - 2)
        try await store.addAccount(name: "Everyday Visa · Demo", currency: "CAD")
        try await store.addAccount(name: "Everyday debit · Demo", currency: "CAD")
        let accounts = try await store.snapshot(limit: 1).accounts
        guard let visa = accounts.first(where: { $0.name == "Everyday Visa · Demo" }),
              let debit = accounts.first(where: { $0.name == "Everyday debit · Demo" }) else {
            throw LedgerError.invalid("Could not create recording demo accounts.")
        }
        let examples: [(merchant: String, amount: Int64, category: String)] = [
            ("City Transit", -350, "local_transport"),
            ("Fresh Market", -6240, "groceries"),
            ("Neighbourhood Café", -450, "dining"),
            ("Campus Bookshop", -3899, "shopping"),
            ("Neighbourhood Café", -525, "dining"),
            ("City Transit", -350, "local_transport"),
            ("Fresh Market", -4875, "groceries"),
            ("Campus Café", -1280, "dining"),
            ("Neighbourhood Café", -625, "dining"),
            ("Community Pharmacy", -1849, "shopping"),
            ("Neighbourhood Café", -750, "dining"),
            ("Fresh Market", -7120, "groceries"),
            ("City Transit", -350, "local_transport"),
            ("Campus Bookshop refund", 1500, "shopping"),
            ("Neighbourhood Café", -575, "dining"),
            ("Campus Café", -1425, "dining"),
            ("Neighbourhood Café", -4200, "dining"),
            ("Fresh Market", -5360, "groceries"),
            ("Corner Store", -930, "groceries"),
            ("Neighbourhood Café", -875, "dining"),
        ]
        for (index, example) in examples.enumerated() {
            // Leave today's real queue capture to arrive during recording. On the
            // first of a month, all background entries necessarily share that day.
            let day = calendar.adding(index * elapsedDays / (examples.count - 1), to: monthStart)
            let account = ["groceries", "local_transport"].contains(example.category) ? debit : visa
            let edit = TransactionEdit(description: example.merchant, amountMinor: example.amount, currency: "CAD",
                occurredOn: day, accountID: account.id, type: example.amount > 0 ? "refund" : "expense",
                category: example.category, needsReview: false,
                notes: index == 16 ? "Fictional group order for a study session." : "Fictional recording demo. Not a real purchase.")
            try await store.save(edit)
        }
        // Twelve completed weeks provide a previous-month baseline and enough
        // history for weekly patterns. All amounts and merchants are fictional.
        let currentWeek = calendar.day(calendar.calendar.dateInterval(of: .weekOfYear, for: now)!.start)
        for weeksAgo in (1...12).reversed() {
            let weekStart = calendar.adding(-7 * weeksAgo, to: currentWeek)
            let growth = Int64(12 - weeksAgo)
            let history: [(String, Int64, String)] = [
                ("Fresh Market", weeksAgo <= 4 ? -6400 : -2000, "groceries"),
                ("City Transit", -350, "local_transport"),
                ("Neighbourhood Café", -(500 + growth * 40), "dining"),
                ("Campus Café", -(1200 + growth * 150), "dining"),
                ("Campus Bookshop", -2400, "shopping"),
            ]
            for (offset, example) in history.enumerated() {
                let account = ["groceries", "local_transport"].contains(example.2) ? debit : visa
                try await store.save(TransactionEdit(description: example.0, amountMinor: example.1, currency: "CAD",
                    occurredOn: calendar.adding(offset, to: weekStart), accountID: account.id, type: "expense",
                    category: example.2, needsReview: false, notes: "Fictional weekly recording history. Not a real purchase."))
            }
        }
        let snapshot = try await store.snapshot(limit: 100)
        guard snapshot.totalTransactions == 80, snapshot.transactions.allSatisfy({ $0.occurredOn <= today }) else {
            throw LedgerError.invalid("The recording demo must contain 20 foreground and 60 weekly history transactions.")
        }
        print("recording_demo_seeded transactions=80 foreground=20 historical=60 end=\(today)")
    }
}
