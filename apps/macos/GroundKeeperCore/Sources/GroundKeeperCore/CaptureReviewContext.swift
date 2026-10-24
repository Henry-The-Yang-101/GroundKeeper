import Foundation

/// Latest parsed facts and the immutable source used to review a capture.
public struct CaptureReviewContext: Sendable {
    public let description: String
    public let amountMinor: Int64?
    public let currency: String?
    public let day: String
    public let accountID: String?
    public let accountName: String?
    public let payload: String
}

extension LedgerStore {
    public func captureReviewContext(eventID: String) throws -> CaptureReviewContext {
        guard let row = try db.query("""
            SELECT o.description,o.amount_minor,o.currency,o.occurred_on,o.account_id,a.name AS account_name,p.payload_json
            FROM raw_events e JOIN raw_event_payloads p ON p.event_id=e.id
            JOIN event_observations o ON o.id=(SELECT id FROM event_observations WHERE event_id=e.id ORDER BY parsed_at_ms DESC,rowid DESC LIMIT 1)
            LEFT JOIN accounts a ON a.id=o.account_id WHERE e.id=? AND e.is_test=0
            """, [.text(eventID)]).first else {
            throw LedgerError.invalid("The original capture details are unavailable. Refresh Sync and try again.")
        }
        return CaptureReviewContext(description: row.text("description"), amountMinor: row["amount_minor"]?.int,
            currency: row["currency"]?.string, day: row.text("occurred_on"), accountID: row["account_id"]?.string,
            accountName: row["account_name"]?.string, payload: row.text("payload_json"))
    }
}
