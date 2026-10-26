import Foundation

public struct TransactionReviewIssue: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let reason: String
    public var title: String { Self.title(for: reason) }
    public static func title(for reason: String) -> String {
        switch reason {
        case "event_identity_collision": "A capture ID was reused with different data"
        case "external_id_conflict": "The statement conflicts with a saved bank record"
        case "csv_mapping_changed": "A corrected CSV mapping needs approval"
        case "statement_match": "A statement record may match this purchase"
        case "possible_duplicate": "Two captures may describe the same purchase"
        case "account_mapping_required": "Choose an account for this capture"
        case "currency_mismatch": "The capture and account currencies differ"
        default: reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public struct TransactionSourceEvidence: Identifiable, Sendable {
    public let id: String
    public let source: String
    public let kind: String
    public let capturedAtMS: Int64
    public let offsetMinutes: Int
    public let description: String
    public let amountMinor: Int64?
    public let currency: String?
    public let day: String
    public let card: String?
    public let payload: String
}

public struct TransactionHistoryEntry: Identifiable, Sendable {
    public let id: String
    public let changedAtMS: Int64
    public let reason: String
    public let before: String?
    public let after: String?
}

public struct TransactionEvidence: Sendable {
    public let sources: [TransactionSourceEvidence]
    public let history: [TransactionHistoryEntry]
}

extension LedgerStore {
    public func transactionEvidence(id: String) throws -> TransactionEvidence {
        guard try transaction(id: id) != nil else { throw LedgerError.conflict }
        let sources = try db.query("""
            SELECT e.id,s.name,s.kind,e.captured_at_ms,e.captured_offset_minutes,e.external_account_key,
              o.description,o.amount_minor,o.currency,o.occurred_on,p.payload_json
            FROM transaction_event_links l JOIN raw_events e ON e.id=l.event_id
            JOIN sources s ON s.id=e.source_id JOIN event_observations o ON o.id=l.observation_id
            JOIN raw_event_payloads p ON p.event_id=e.id
            WHERE l.transaction_id=? AND l.unlinked_at_ms IS NULL AND e.is_test=0
            ORDER BY e.captured_at_ms,e.id
            """, [.text(id)]).map { r in
                TransactionSourceEvidence(id: r.text("id"), source: r.text("name"), kind: r.text("kind"),
                    capturedAtMS: r.number("captured_at_ms"), offsetMinutes: Int(r.number("captured_offset_minutes")),
                    description: r.text("description"), amountMinor: r["amount_minor"]?.int, currency: r["currency"]?.string,
                    day: r.text("occurred_on"), card: r.text("external_account_key").hasPrefix("label:") ? String(r.text("external_account_key").dropFirst(6)) : nil,
                    payload: r.text("payload_json"))
            }
        let changes = try db.query("""
            SELECT c.* FROM change_log c WHERE (c.entity_type='transaction'
              AND (c.entity_id=? OR c.entity_id IN (SELECT id FROM transactions WHERE merged_into_id=?)))
              OR (c.entity_type='import_batch' AND c.entity_id IN (SELECT i.batch_id FROM import_rows i
                JOIN transaction_event_links l ON l.event_id=i.event_id WHERE l.transaction_id=? AND l.unlinked_at_ms IS NULL))
            ORDER BY c.changed_at_ms DESC,c.id
            """, [.text(id), .text(id), .text(id)]).map { r in
                TransactionHistoryEntry(id: r.text("id"), changedAtMS: r.number("changed_at_ms"), reason: r.text("reason"),
                    before: r["before_json"]?.string, after: r["after_json"]?.string)
            }
        return TransactionEvidence(sources: sources, history: changes)
    }
}
