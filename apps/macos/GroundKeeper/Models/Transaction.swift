import Foundation

/// Presentation data only. No persistence, classification, or reconciliation behavior.
struct Transaction: Identifiable, Equatable {
    var id = UUID()
    var merchant = ""
    var date = Date()
    var amount: Decimal = 0
    var currency = "CAD"
    var account = "Everyday card"
    var kind: TransactionKind = .purchase
    var category: SpendingCategory = .uncategorized
    var needsReview = true
    var notes = ""
    var source = "Manual entry"

    var formattedAmount: String {
        amount.formatted(.currency(code: currency))
    }
}

enum TransactionKind: String, CaseIterable, Identifiable {
    case purchase = "Purchase"
    case refund = "Refund"
    case income = "Income"
    case transfer = "Transfer"
    case cardPayment = "Card payment"
    case loanPrincipal = "Loan principal"
    case cashMovement = "Cash movement"
    case adjustment = "Adjustment"

    var id: Self { self }
    var usesCategory: Bool { self == .purchase || self == .refund }
}

enum SpendingCategory: String, CaseIterable, Identifiable {
    case groceries = "Groceries"
    case dining = "Dining & takeout"
    case transport = "Local transport"
    case vehicle = "Vehicle expenses"
    case housing = "Housing & home upkeep"
    case utilities = "Utilities & communications"
    case shopping = "Shopping & household goods"
    case health = "Medical & health"
    case personalCare = "Personal care"
    case fitness = "Fitness & sports"
    case entertainment = "Entertainment & hobbies"
    case software = "Software & digital services"
    case education = "Education"
    case travel = "Travel & accommodation"
    case insurance = "Insurance"
    case fees = "Financial fees & interest"
    case taxes = "Taxes & government charges"
    case gifts = "Gifts & donations"
    case uncategorized = "Uncategorized"
    case other = "Other"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .groceries: "basket"
        case .dining: "cup.and.saucer"
        case .transport: "tram"
        case .vehicle: "car"
        case .housing: "house"
        case .utilities: "bolt"
        case .shopping: "bag"
        case .health: "cross.case"
        case .personalCare: "comb"
        case .fitness: "figure.run"
        case .entertainment: "play.rectangle"
        case .software: "laptopcomputer"
        case .education: "book"
        case .travel: "airplane"
        case .insurance: "umbrella"
        case .fees: "percent"
        case .taxes: "building.columns"
        case .gifts: "gift"
        case .uncategorized: "questionmark"
        case .other: "ellipsis"
        }
    }
}
