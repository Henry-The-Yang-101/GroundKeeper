import Foundation

public struct CaptureNote: Identifiable, Sendable {
    public let id: String, text: String, app: String
    public let capturedAtMS: Int64
}

extension LedgerStore {
    // Called inside the payment import transaction, before reconciliation. Either
    // the payment and all its evidence commit together, or none of them do.
    func storeCaptureDetails(_ envelope: CaptureEnvelope, eventID: String, data: Data, hash: String) throws {
        if let note = envelope.note {
            try db.query("INSERT INTO capture_notes(event_id,text) VALUES (?,?)", [.text(eventID), .text(note)])
        }
        if let receipt = envelope.receipt {
            let receiptID = identifier()
            // Separate identity namespace from standalone schema-3 receipts.
            let identity = "inline:" + contentHash(Data("\(envelope.sourceID)|\(envelope.eventID)".utf8))
            try db.query("""
                INSERT INTO receipt_captures(id,source_event_id,payload_sha256,payload_json,captured_at_ms,parent_source_id,parent_event_id,image_path,image_sha256,image_state,is_test)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(receiptID), .text(identity), .text(hash), .text(String(decoding: data, as: UTF8.self)),
                       .integer(try CaptureParser.timestamp(envelope.capturedAt).0), .text(envelope.sourceID), .text(envelope.eventID),
                       .optional(receipt.image?.path), .optional(receipt.image?.sha256),
                       .text(receipt.image == nil ? "not_requested" : "pending"), .integer(envelope.isTest == true ? 1 : 0)])
            try insertReceiptOCR(receiptID: receiptID, producer: receipt.ocr.producer, text: receipt.ocr.text)
        }
    }

    public func captureNotes(transactionID: String) throws -> [CaptureNote] {
        try db.query("""
            SELECT n.event_id,n.text,e.captured_at_ms,s.name FROM capture_notes n
            JOIN raw_events e ON e.id=n.event_id JOIN sources s ON s.id=e.source_id
            JOIN transaction_event_links l ON l.event_id=e.id AND l.unlinked_at_ms IS NULL
            WHERE l.transaction_id=? AND e.is_test=0 ORDER BY e.captured_at_ms,e.id
            """, [.text(transactionID)]).map {
                CaptureNote(id: $0.text("event_id"), text: $0.text("text"), app: $0.text("name"), capturedAtMS: $0.number("captured_at_ms"))
            }
    }
}
