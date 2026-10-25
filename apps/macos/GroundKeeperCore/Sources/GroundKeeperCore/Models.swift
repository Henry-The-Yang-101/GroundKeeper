import Foundation

public struct Account: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let currency: String
}
public struct CardAccountMapping: Identifiable, Sendable, Equatable {
    public let id: String, sourceID: String, sourceName: String, label: String, accountID: String
}
public struct LedgerTransaction: Identifiable, Sendable {
    public let id: String
    public let partID: String
    public let revision: Int
    public let description: String
    public let amountMinor: Int64
    public let currency: String
    public let occurredOn: String
    public let accountID: String?
    public let accountName: String
    public let type: String
    public let category: String?
    public let needsReview: Bool
    public let notes: String
    public let sources: String
    public let origin: String

    /// Source evidence is independent of who selected the category or edited it.
    public var sourceLabel: String {
        let kinds = Set(sources.split(separator: ",").map(String.init))
        let labels = [("bank_notification", "Bank App Automation"), ("apple_wallet", "Wallet Automation"),
                      ("manual", "Manually input"), ("csv", "Imported from CSV")]
        let known = labels.filter { kinds.contains($0.0) }.map { $0.1 }
        return known.isEmpty ? "Manually input" : known.joined(separator: " + ")
    }
}
public struct TransactionEdit: Sendable {
    public var id: String, revision: Int, description: String, amountMinor: Int64, currency: String
    public var occurredOn: String, accountID: String?, type: String, category: String?, needsReview: Bool, notes: String
    public init(id: String = UUID().uuidString, revision: Int = 0, description: String, amountMinor: Int64,
                currency: String, occurredOn: String, accountID: String?, type: String, category: String?, needsReview: Bool, notes: String) {
        self.id = id; self.revision = revision; self.description = description; self.amountMinor = amountMinor
        self.currency = currency; self.occurredOn = occurredOn; self.accountID = accountID; self.type = type
        self.category = category; self.needsReview = needsReview; self.notes = notes
    }
}
public struct ReviewRecord: Identifiable, Sendable {
    public let id: String, eventID: String, reason: String, sourceID: String, label: String, description: String
    public let candidates: [String]
}
public struct QueueRecord: Identifiable, Sendable {
    public let id: String, path: String, state: String, error: String
    public let attempts: Int
}
public struct LedgerSnapshot: Sendable {
    public let transactions: [LedgerTransaction], accounts: [Account], reviews: [ReviewRecord], queue: [QueueRecord]
    public let cardMappings: [CardAccountMapping]
    public let totalTransactions: Int, pendingJobs: Int, failedJobs: Int
}
public struct CaptureEnvelope: Codable, Sendable {
    public let schemaVersion: Int
    public let eventID: String
    public let source: String
    public let capturedAt: String
    public let app: String?
    public let note: String?
    let receipt: ReceiptEnvelope.Payload?
    public let inputShape: String?
    public let isTest: Bool?
    public let title: String?, subtitle: String?, body: String?
    public let merchant: String?, amount: String?, cardOrPass: String?, name: String?, transaction: String?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", eventID = "event_id", source, capturedAt = "captured_at", app
        case inputShape = "input_shape", isTest = "is_test", title, subtitle, body, merchant, amount
        case cardOrPass = "card_or_pass", name, transaction, note, receipt
    }
    var sourceKind: String { source == "wallet_transaction" ? "apple_wallet" : "bank_notification" }
    var sourceID: String { "capture:" + contentHash(Data("\(sourceKind)|\(app ?? "")".utf8)) }
    // CIBC's card line below the app heading is the notification Title;
    // Subtitle carries the merchant. Do not use the merchant as a card key.
    var label: String { (source == "wallet_transaction" ? cardOrPass : title) ?? "" }
}
struct Observation: Codable, Sendable {
    var description: String
    var amount: Int64?
    var currency: String?
    var day: String
    var captured: Int64
    var offset: Int
    var accountID: String?
    var label: String
    var lifecycle: String
    var error: String?
    var dateOnly = false
    var externalID: String?
}
public struct CSVMapping: Codable, Sendable, Equatable {
    public var dateColumn = 0, descriptionColumn = 1, amountColumn = 2
    public var creditColumn: Int? = nil
    public var externalIDColumn: Int? = nil
    public var dateFormat = "yyyy-MM-dd"
    public var positiveMeansDebit = false
    public var decimalComma = false
    public var accountID = "", currency = "CAD"
    public init() {}
}
public struct CSVPreviewRow: Identifiable, Sendable {
    public let id: Int
    public let description: String, day: String
    public let amountMinor: Int64?
    public let error: String?
}
public struct CSVDocument: Sendable {
    public let filename: String, hash: String
    public let headers: [String], rows: [[String]]
    public init(data: Data, filename: String, delimiter: Character = ",") throws {
        guard data.count <= 20_000_000, let text = String(data: data, encoding: .utf8) else { throw LedgerError.invalid("Choose a UTF-8 CSV smaller than 20 MB.") }
        let records = try CSVParser.parse(text, delimiter: delimiter)
        guard let header = records.first, header.count >= 3 else { throw LedgerError.invalid("CSV requires a header and at least three columns.") }
        self.filename = filename; hash = contentHash(data); headers = header; rows = Array(records.dropFirst())
    }
    public func preview(_ mapping: CSVMapping) -> [CSVPreviewRow] {
        rows.enumerated().map { index, row in
            do {
                let observation = try CSVParser.observation(row, mapping: mapping, width: headers.count)
                return CSVPreviewRow(id: index + 2, description: observation.description, day: observation.day, amountMinor: observation.amount, error: nil)
            } catch { return CSVPreviewRow(id: index + 2, description: row.indices.contains(mapping.descriptionColumn) ? row[mapping.descriptionColumn] : "", day: "", amountMinor: nil, error: error.localizedDescription) }
        }
    }
}
public struct ClassificationTask: Sendable {
    public let id: String, runID: String, partID: String, revision: Int, description: String, direction: String, currency: String
    public let receiptContext: ReceiptContext?
    public let walletCategoryRaw: String?
}
public struct ClassificationDecision: Codable, Sendable {
    public let type: String, category: String?, review: Bool
    public init(type: String, category: String?, review: Bool) { self.type = type; self.category = category; self.review = review }
}

public enum QueueProcessingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case background, whileOpen, manual
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .background: "Automatically in the background"
        case .whileOpen: "Only while GroundKeeper is open"
        case .manual: "Only when I click Process queue"
        }
    }
    public var automaticallyProcesses: Bool { self != .manual }
}
public struct CaptureDeliveryState: Sendable {
    public let terminal: Bool
    public let nextAttemptMS: Int64
}
