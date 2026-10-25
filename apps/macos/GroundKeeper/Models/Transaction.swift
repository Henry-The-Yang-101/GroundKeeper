import Foundation
import GroundKeeperCore

enum TransactionInput {
    static func positiveAmount(_ text: String) -> Decimal? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = input.components(separatedBy: Locale.current.decimalSeparator ?? ".")
        // Reject numeric prefixes, grouping, signs, and fractions beyond cents.
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ $0.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) }),
              parts.count == 1 || parts[1].count <= 2,
              let amount = try? Decimal(input, format: .number.locale(.current), lenient: false),
              amount > 0, amount.exponent >= -2 else { return nil }
        return amount
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Editable presentation of a persisted account-side transaction.
struct Transaction: Identifiable, Equatable {
    var id = UUID()
    var merchant = ""
    var date = Date()
    var amount: Decimal = 0
    var currency = "CAD"
    var account = "Unassigned"
    var accountID: String?
    var revision = 0
    var isDebit = true
    var kind: TransactionKind = .purchase
    var category: SpendingCategory = .uncategorized
    var needsReview = true
    var notes = ""
    var source = "Manually input"

    var formattedAmount: String {
        (isDebit ? -amount : amount).formatted(.currency(code: currency))
    }
}

enum TransactionKind: String, CaseIterable, Identifiable {
    case unknown = "Unknown"
    case purchase = "Purchase"
    case refund = "Refund"
    case income = "Income"
    case transfer = "Transfer"
    case cardPayment = "Card payment"
    case loanPrincipal = "Loan principal"
    case cashMovement = "Cash movement"
    case adjustment = "Adjustment"

    var id: Self { self }
    var usesCategory: Bool { self == .purchase || self == .refund || self == .unknown }
    var requiredDebit: Bool? {
        switch self {
        case .purchase: true
        case .refund, .income: false
        default: nil
        }
    }
    var directionExplanation: String? {
        switch self {
        case .purchase: "Purchases are money out."
        case .refund: "Refunds are money in and reduce spending."
        case .income: "Income is money in."
        default: nil
        }
    }
    var code: String {
        switch self {
        case .unknown: "unknown"
        case .purchase: "expense"
        case .refund: "refund"
        case .income: "income"
        case .transfer: "transfer"
        case .cardPayment: "card_payment"
        case .loanPrincipal: "loan_principal"
        case .cashMovement: "cash_movement"
        case .adjustment: "balance_adjustment"
        }
    }
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
    var code: String {
        switch self {
        case .transport: "local_transport"
        case .health: "medical"
        case .personalCare: "personal_care"
        case .fees: "financial"
        default: String(describing: self)
        }
    }
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

extension Transaction {
    init(_ stored: LedgerTransaction) {
        self.init()
        id = UUID(uuidString: stored.id)!
        revision = stored.revision; merchant = stored.description; currency = stored.currency
        amount = Decimal(stored.amountMinor.magnitude) / 100; isDebit = stored.amountMinor < 0
        accountID = stored.accountID; account = stored.accountName
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
        date = formatter.date(from: stored.occurredOn) ?? Date()
        kind = TransactionKind.allCases.first { $0.code == stored.type } ?? .unknown
        category = SpendingCategory.allCases.first { $0.code == stored.category } ?? .uncategorized
        needsReview = stored.needsReview; notes = stored.notes; source = stored.sourceLabel
    }
    var edit: TransactionEdit {
        get throws {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
            let minor = try ExactMoney.parse(NSDecimalNumber(decimal: amount).stringValue, currency: currency)
            return TransactionEdit(id: id.uuidString, revision: revision, description: merchant, amountMinor: isDebit ? -minor : minor,
                currency: currency, occurredOn: formatter.string(from: date), accountID: accountID, type: kind.code,
                category: kind == .unknown ? "uncategorized" : kind.usesCategory ? category.code : nil,
                needsReview: needsReview || kind == .unknown || (kind.usesCategory && category == .uncategorized), notes: notes)
        }
    }
}
