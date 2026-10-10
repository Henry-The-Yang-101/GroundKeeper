import Foundation

/// Fixed, fictional fixtures for layout and interaction previews, never financial analysis.
enum SampleData {
    static func date(_ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
    }

    static let transactions: [Transaction] = [
        Transaction(merchant: "Vincenzo’s", date: date(10), amount: 64.28, category: .groceries, needsReview: false, source: "Wallet · sample"),
        Transaction(merchant: "Amazon", date: date(10), amount: 38.49, category: .uncategorized, notes: "Choose a category based on what you purchased.", source: "Bank alert · sample"),
        Transaction(merchant: "Balzac’s Coffee", date: date(9), amount: 6.75, category: .dining, needsReview: false, source: "Wallet · sample"),
        Transaction(merchant: "Grand River Transit", date: date(9), amount: 3.75, category: .transport, needsReview: false, source: "Wallet · sample"),
        Transaction(merchant: "Farm Boy", date: date(8), amount: 52.16, category: .groceries, needsReview: false, source: "Wallet · sample"),
        Transaction(merchant: "Interac e-Transfer", date: date(8), amount: 75, account: "Chequing", kind: .adjustment, notes: "Confirm the purpose and transaction type.", source: "Bank alert · sample"),
        Transaction(merchant: "GitHub", date: date(7), amount: 5.50, category: .software, needsReview: false, source: "Manual entry"),
        Transaction(merchant: "WatCard", date: date(6), amount: 24.80, category: .uncategorized, notes: "Was this food, printing, or something else?", source: "Wallet · sample"),
        Transaction(merchant: "Uniqlo", date: date(5), amount: 29.90, kind: .refund, category: .shopping, needsReview: false, source: "Bank alert · sample"),
        Transaction(merchant: "Payroll", date: date(2), amount: 850, account: "Chequing", kind: .income, needsReview: false, source: "Manual entry"),
    ]

    struct SpendingPoint: Identifiable {
        let day: Int
        let amount: Double
        var id: Int { day }
        var date: Date { SampleData.date(day) }
    }

    static let dailySpending: [SpendingPoint] = [
        .init(day: 1, amount: 112), .init(day: 2, amount: 38),
        .init(day: 3, amount: 76), .init(day: 4, amount: 24),
        .init(day: 5, amount: 95), .init(day: 6, amount: 49),
        .init(day: 7, amount: 18), .init(day: 8, amount: 132),
        .init(day: 9, amount: 62), .init(day: 10, amount: 136.50),
    ]

    struct CategoryTotal: Identifiable {
        let category: SpendingCategory
        let amount: Double
        var id: SpendingCategory { category }
    }

    static let categories: [CategoryTotal] = [
        .init(category: .groceries, amount: 286.40),
        .init(category: .dining, amount: 184.60),
        .init(category: .shopping, amount: 142.75),
        .init(category: .transport, amount: 68.25),
        .init(category: .software, amount: 35.50),
        .init(category: .uncategorized, amount: 25),
    ]
}
