import Foundation

public struct CouncilMember: Codable, Sendable, Equatable, Identifiable {
    public let id: String, name: String, backend: String
    public let weight: Double
    public init(id: String, name: String, backend: String, weight: Double = 1) {
        self.id = id; self.name = name; self.backend = backend; self.weight = weight
    }
    public var title: String {
        switch backend { case "qwen_mlx": "Qwen"; case "laya_mps": "Laya"; default: "Apple Intelligence" }
    }
}

public struct CouncilConfiguration: Codable, Sendable, Equatable, Identifiable {
    public static let algorithm = "council-equal-v2"
    public let id: String
    public let members: [CouncilMember]
    public init(members: [CouncilMember]) throws {
        guard members.count == 3, Set(members.map(\.id)).count == 3,
              Set(members.map(\.backend)) == ["qwen_mlx", "laya_mps", "apple_shortcut"],
              members.allSatisfy({ $0.weight == 1 && $0.id.count == 64 }) else {
            throw LedgerError.invalid("Council requires Qwen, Laya and Apple Intelligence with equal weights.")
        }
        self.members = members.sorted { $0.backend < $1.backend }
        id = "council:" + contentHash(Data((try json(self.members) + "|" + Self.algorithm).utf8))
    }
}

/// The actual provider input; audit JSON may replace the Wallet value with its immutable source reference.
public struct CouncilInput: Codable, Sendable, Equatable {
    public let description: String, direction: String, currency: String
    public var transactionNotes: String?
    public var receiptContext: ReceiptContext?
    public var walletCategoryRaw: String?
    public var merchantContext: MerchantContext?
    enum CodingKeys: String, CodingKey {
        case description, direction, currency
        case transactionNotes = "transaction_notes"
        case receiptContext = "receipt_context", walletCategoryRaw = "wallet_category_raw", merchantContext = "merchant_context"
    }
    public init(description: String, direction: String, currency: String, receiptContext: ReceiptContext? = nil,
                walletCategoryRaw: String? = nil, merchantContext: MerchantContext? = nil, transactionNotes: String? = nil) {
        self.transactionNotes = transactionNotes
        self.description = description; self.direction = direction; self.currency = currency
        self.receiptContext = receiptContext; self.walletCategoryRaw = walletCategoryRaw; self.merchantContext = merchantContext
    }
}

public struct CouncilVote: Codable, Sendable {
    public let member: CouncilMember
    public let disposition: String
    public let decision: ClassificationDecision?
    public let errorCode: String?
    public init(member: CouncilMember, disposition: String, decision: ClassificationDecision? = nil, errorCode: String? = nil) {
        self.member = member; self.disposition = disposition; self.decision = decision; self.errorCode = errorCode
    }
}

public struct CouncilResult: Codable, Sendable {
    public let decision: ClassificationDecision?
    public let reason: String
    public let degraded: Bool
    public let votes: [CouncilVote]
    public var title: String {
        switch reason {
        case "unanimous": "All models agree"
        case "majority": degraded ? "Partial council · two models agree" : "Models disagree · two agree"
        default: "No council consensus"
        }
    }
    public static func resolve(_ votes: [CouncilVote]) throws -> Self {
        _ = try CouncilConfiguration(members: votes.map(\.member))
        let valid = try votes.filter { vote in
            guard ["valid", "failed", "timeout", "unavailable", "invalid", "skipped"].contains(vote.disposition) else {
                throw LedgerError.invalid("Invalid Council member outcome.")
            }
            if vote.disposition == "valid" {
                guard let decision = vote.decision else { throw LedgerError.invalid("Missing Council decision.") }
                try decision.validateSuggestion()
                return true
            }
            guard vote.decision == nil else { throw LedgerError.invalid("Failed member cannot vote.") }
            return false
        }
        // Vote for the complete decision. Never synthesize a type/category pair from separate head winners.
        let groups = Dictionary(grouping: valid) { "\($0.decision!.type)|\($0.decision!.category ?? "<nil>")" }
        let winner = groups.values.first { $0.count >= 2 }
        let decision = winner?.first?.decision
        return .init(decision: decision, reason: winner == nil ? "no_consensus" : valid.count == 3 && winner!.count == 3 ? "unanimous" : "majority",
                     degraded: valid.count < 3, votes: votes)
    }
}

extension ClassificationDecision {
    public func validateSuggestion() throws {
        let categories: Set<String> = ["groceries", "dining", "local_transport", "vehicle", "housing", "utilities", "shopping", "medical", "personal_care", "fitness", "entertainment", "software", "education", "travel", "insurance", "financial", "taxes", "gifts", "other"]
        guard review, category.map({ categories.contains($0) }) ?? true else { throw LedgerError.invalid("Invalid classifier suggestion.") }
        switch type {
        case "expense", "refund": guard category != nil else { throw LedgerError.invalid("AI spending decisions require a category.") }
        case "unknown": guard category == "other" else { throw LedgerError.invalid("Unknown requires Other.") }
        case "income", "transfer", "card_payment", "loan_principal", "cash_movement", "balance_adjustment":
            guard category == nil else { throw LedgerError.invalid("This transaction type cannot have a spending category.") }
        default: throw LedgerError.invalid("Unknown transaction type.")
        }
    }
}
