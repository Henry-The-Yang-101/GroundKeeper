import Foundation
import GroundKeeperCore

/// Fictional statements, imported and reviewed through the same APIs as ordinary data.
/// The caller must supply the disposable InterfacePreview vault.
enum SpendingPreview {
    static func seed(_ store: LedgerStore, now: Date = Date()) async throws {
        let calendar = try ReportCalendar(timezone: "America/Toronto")
        let today = calendar.day(now)
        let week = calendar.day(calendar.calendar.dateInterval(of: .weekOfYear, for: now)!.start)
        let start = calendar.adding(-24 * 7, to: week)
        try await store.addAccount(name: "Everyday card · Demo", currency: "CAD")
        try await store.addAccount(name: "Travel card · Demo", currency: "CAD")
        let accounts = try await store.snapshot().accounts
        guard let everyday = accounts.first(where: { $0.name == "Everyday card · Demo" }),
              let travel = accounts.first(where: { $0.name == "Travel card · Demo" }) else {
            throw LedgerError.invalid("Could not create fictional demo accounts.")
        }
        var rows: [String: [String]] = [everyday.id: [], travel.id: []]
        let categories = ["Fictional Market": "groceries", "Neighbourhood Café": "dining",
                          "Neighbourhood Café 002": "dining", "Neighbourhood Café 003": "dining",
                          "City Transit": "local_transport", "Fictional Bookshop": "shopping"]
        func add(_ day: String, _ merchant: String, _ amount: Int64, account: String? = nil) {
            let magnitude = abs(amount)
            let decimal = "\(amount < 0 ? "-" : "")\(magnitude / 100).\(String(format: "%02d", magnitude % 100))"
            let target = account ?? everyday.id
            // Stable, distinct bank IDs preserve multiple same-day purchases.
            let id = "demo-\(target == everyday.id ? "everyday" : "travel")-\(rows[target]!.count + 1)"
            rows[target]!.append("\(day),\(merchant),\(decimal),\(id)")
        }
        let days = calendar.count(try ReportRange(start: start, end: calendar.adding(1, to: today)))
        for dayOffset in 0..<days {
            let day = calendar.adding(dayOffset, to: start)
            let weekIndex = dayOffset / 7
            // A sustained four-week grocery level shift, and a gradual café trend.
            add(day, "Fictional Market", weekIndex >= 20 ? -6000 : -1800)
            add(day, "City Transit", -350)
            add(day, "Neighbourhood Café", -Int64(500 + weekIndex * 50))
            if weekIndex >= 16 && dayOffset % 7 < 3 { add(day, "Neighbourhood Café", -650) }
            if dayOffset % 7 == 2 { add(day, "Fictional Bookshop", -2400, account: travel.id) }
            if dayOffset % 14 == 4 { add(day, "Neighbourhood Café 002", -950) }
            if dayOffset % 14 == 6 { add(day, "Neighbourhood Café 003", -1100) }
            if day.hasSuffix("-01") {
                add(day, "Fictional Employer", 320000)
                add(day, "Fictional Account Transfer", -50000)
            }
        }
        add(today, "Neighbourhood Café", -25000) // Unusual relative to earlier café purchases.
        add(today, "Fictional Bookshop", 1800, account: travel.id)
        var imported = 0
        for account in accounts {
            let csv = "date,description,amount,bank_id\n" + rows[account.id]!.joined(separator: "\n") + "\n"
            let document = try CSVDocument(data: Data(csv.utf8), filename: "fictional-spending-demo.csv")
            var mapping = CSVMapping()
            mapping.accountID = account.id
            mapping.externalIDColumn = 3
            imported += try await store.importCSV(document, mapping: mapping)
        }
        // CSV rows remain separate, including repeated merchant/amount combinations.
        guard try await store.snapshot(limit: 1).reviews.isEmpty else {
            throw LedgerError.invalid("Fictional CSV rows should not require duplicate review.")
        }
        let snapshot = try await store.snapshot(limit: 5000)
        guard snapshot.totalTransactions == imported else {
            throw LedgerError.invalid("Fictional statement import did not preserve every purchase.")
        }
        // CSV intentionally has no classification column. Apply explicit fixture decisions
        // as reviewed edits; no model or network is required to generate the reports.
        for entry in snapshot.transactions {
            let type = entry.description == "Fictional Employer" ? "income"
                : entry.description == "Fictional Account Transfer" ? "transfer"
                : entry.amountMinor > 0 ? "refund" : "expense"
            try await store.save(TransactionEdit(
                id: entry.id, revision: entry.revision, description: entry.description,
                amountMinor: entry.amountMinor, currency: entry.currency, occurredOn: entry.occurredOn,
                accountID: entry.accountID, type: type, category: categories[entry.description],
                needsReview: false, notes: "Fictional imported spending demo. Not a real purchase."
            ))
        }
        print("spending_demo_imported transactions=\(imported) start=\(start) end=\(today)")
    }
}
