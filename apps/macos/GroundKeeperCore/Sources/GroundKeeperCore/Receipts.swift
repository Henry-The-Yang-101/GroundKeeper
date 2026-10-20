import Foundation
import ImageIO

public struct ReceiptContext: Codable, Sendable, Equatable {
    public let version: String
    public let text: String
    public let truncated: Bool
    public let evidenceSHA256: String
    enum CodingKeys: String, CodingKey { case version, text, truncated, evidenceSHA256 = "evidence_sha256" }
    public init(text: String, truncated: Bool = false, evidenceSHA256: String) {
        version = "receipt-context-v1"; self.text = text; self.truncated = truncated; self.evidenceSHA256 = evidenceSHA256
    }
}
struct ReceiptEnvelope: Codable, Sendable {
    let schemaVersion: Int, eventID: String, source: String, capturedAt: String
    let target: Target
    let receipt: Payload
    let isTest: Bool?
    struct Target: Codable, Sendable {
        let source: String, app: String, eventID: String
        enum CodingKeys: String, CodingKey { case source, app, eventID = "event_id" }
        var sourceID: String { "capture:" + contentHash(Data("\(source == "wallet_transaction" ? "apple_wallet" : "bank_notification")|\(app)".utf8)) }
    }
    struct Payload: Codable, Sendable {
        let ocr: OCR
        let image: Image?
    }
    struct OCR: Codable, Sendable { let producer: String, text: String }
    struct Image: Codable, Sendable { let path: String; let sha256: String? }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", eventID = "event_id", source, capturedAt = "captured_at", target, receipt, isTest = "is_test"
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw LedgerError.invalid("receipt_too_large") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 3, value.source == "receipt_attachment",
              validID(value.eventID), validID(value.target.eventID),
              ["wallet_transaction", "bank_notification"].contains(value.target.source),
              !value.target.app.isEmpty, value.target.app.utf8.count <= 128 else { throw LedgerError.invalid("invalid_receipt") }
        try validate(value.receipt)
        _ = try CaptureParser.timestamp(value.capturedAt)
        return value
    }
    static func validate(_ receipt: Payload) throws {
        guard ["apple_shortcuts", "apple_vision", "apple_vision_documents", "user_text"].contains(receipt.ocr.producer),
              receipt.ocr.text.utf8.count <= 32_768, !receipt.ocr.text.contains("\0"),
              !receipt.ocr.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || receipt.image != nil else {
            throw LedgerError.invalid("invalid_receipt")
        }
        if let image = receipt.image {
            guard image.path.range(of: "^assets/[A-Za-z0-9_-]{1,128}\\.(jpg|jpeg|png|heic)$", options: .regularExpression) != nil,
                  image.sha256 == nil || image.sha256!.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw LedgerError.invalid("invalid_receipt_image")
            }
        }
    }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
public struct ReceiptRecord: Identifiable, Sendable {
    public let id: String, text: String, producer: String, imageState: String, imageError: String?
    public let capturedAtMS: Int64
}
public struct ReceiptImageRequest: Sendable {
    public let id: String, path: String, sha256: String?
}

extension LedgerStore {
    func ingestReceipt(data: Data, queueID: String, hash: String) throws {
        let envelope = try ReceiptEnvelope.decode(data)
        try db.transaction {
            if let old = try db.query("SELECT id,payload_sha256 FROM receipt_captures WHERE source_event_id=?", [.text(envelope.eventID)]).first {
                let collision = old.text("payload_sha256") != hash
                try db.query("UPDATE queue_items SET state=?,error_code=? WHERE id=?", [.text(collision ? "quarantined" : "imported"), collision ? .text("event_identity_collision") : .null, .text(queueID)])
                return
            }
            let receiptID = identifier(), captured = try CaptureParser.timestamp(envelope.capturedAt).0
            try db.query("""
                INSERT INTO receipt_captures(id,source_event_id,payload_sha256,payload_json,captured_at_ms,parent_source_id,parent_event_id,image_path,image_sha256,image_state,is_test)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(receiptID), .text(envelope.eventID), .text(hash), .text(String(decoding: data, as: UTF8.self)), .integer(captured),
                       .text(envelope.target.sourceID), .text(envelope.target.eventID), .optional(envelope.receipt.image?.path), .optional(envelope.receipt.image?.sha256),
                       .text(envelope.receipt.image == nil ? "not_requested" : "pending"), .integer(envelope.isTest == true ? 1 : 0)])
            try insertReceiptOCR(receiptID: receiptID, producer: envelope.receipt.ocr.producer, text: envelope.receipt.ocr.text)
            try resolveReceiptLinks()
            try db.query("UPDATE queue_items SET state='imported',error_code=NULL,next_attempt_at_ms=NULL WHERE id=?", [.text(queueID)])
        }
    }
    /// The phone's explicit parent identity authorizes this association. Never match on amount alone.
    func resolveReceiptLinks() throws {
        let rows = try db.query("""
            SELECT r.id,e.id AS event_id,l.transaction_id FROM receipt_captures r
            JOIN raw_events e ON e.source_id=r.parent_source_id AND e.source_event_id=r.parent_event_id
            JOIN transaction_event_links l ON l.event_id=e.id AND l.unlinked_at_ms IS NULL
            JOIN transactions t ON t.id=l.transaction_id
            WHERE r.transaction_id IS NULL AND r.is_test=0 AND e.is_test=0 AND t.state='active'
            """)
        for row in rows {
            try db.query("UPDATE receipt_captures SET capture_event_id=?,transaction_id=? WHERE id=? AND transaction_id IS NULL",
                         [.text(row.text("event_id")), .text(row.text("transaction_id")), .text(row.text("id"))])
            try receiptEvidenceChanged(transactionID: row.text("transaction_id"))
        }
    }
    func receiptEvidenceChanged(transactionID: String) throws {
        try db.query("UPDATE transactions SET revision=revision+1,updated_at_ms=? WHERE id=?", [.integer(nowMS()), .text(transactionID)])
        try db.query("UPDATE classification_jobs SET status='obsolete' WHERE status IN ('pending','running') AND part_id IN (SELECT id FROM transaction_parts WHERE transaction_id=?)", [.text(transactionID)])
    }
    func insertReceiptOCR(receiptID: String, producer: String, text: String) throws {
        guard text.utf8.count <= 32_768, !text.contains("\0") else { throw LedgerError.invalid("receipt_text_too_large") }
        try db.query("INSERT OR IGNORE INTO receipt_ocr_runs(id,receipt_id,producer,text,text_sha256,created_at_ms) VALUES (?,?,?,?,?,?)",
                     [.text(identifier()), .text(receiptID), .text(producer), .text(text), .text(contentHash(Data(text.utf8))), .integer(nowMS())])
    }
    public func receipts(transactionID: String) throws -> [ReceiptRecord] {
        try db.query("""
            SELECT r.*,o.text,o.producer FROM receipt_captures r JOIN receipt_ocr_runs o
              ON o.id=(SELECT id FROM receipt_ocr_runs WHERE receipt_id=r.id ORDER BY created_at_ms DESC,rowid DESC LIMIT 1)
            WHERE r.transaction_id=? ORDER BY r.captured_at_ms,r.id
            """, [.text(transactionID)]).map {
                ReceiptRecord(id: $0.text("id"), text: $0.text("text"), producer: $0.text("producer"), imageState: $0.text("image_state"), imageError: $0["image_error"]?.string, capturedAtMS: $0.number("captured_at_ms"))
            }
    }
    public func receiptImageRequests() throws -> [ReceiptImageRequest] {
        try db.query("SELECT id,image_path,image_sha256 FROM receipt_captures WHERE image_state='pending' ORDER BY captured_at_ms LIMIT 20").map {
            ReceiptImageRequest(id: $0.text("id"), path: $0.text("image_path"), sha256: $0["image_sha256"]?.string)
        }
    }
    public func storeReceiptImage(id: String, data: Data) throws {
        guard data.count > 0, data.count <= 8_388_608, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 40_000_000 else {
            throw LedgerError.invalid("invalid_receipt_image")
        }
        let type = CGImageSourceGetType(source) as String? ?? ""
        guard let contentType = ["public.jpeg": "image/jpeg", "public.png": "image/png", "public.heic": "image/heic"][type] else { throw LedgerError.invalid("unsupported_receipt_image") }
        let hash = contentHash(data)
        try db.transaction {
            guard let row = try db.query("SELECT image_sha256 FROM receipt_captures WHERE id=? AND image_state='pending'", [.text(id)]).first else { return }
            guard row["image_sha256"]?.string == nil || row.text("image_sha256") == hash else { throw LedgerError.invalid("receipt_image_hash_mismatch") }
            try db.query("INSERT OR IGNORE INTO receipt_images(receipt_id,content_sha256,content_type,image) VALUES (?,?,?,?)", [.text(id), .text(hash), .text(contentType), .blob(data)])
            try db.query("UPDATE receipt_captures SET image_state='stored',image_error=NULL WHERE id=?", [.text(id)])
        }
    }
    public func markReceiptImageInvalid(id: String) throws {
        try db.query("UPDATE receipt_captures SET image_state='invalid',image_error='invalid_receipt_image' WHERE id=?", [.text(id)])
    }
    public func receiptImage(id: String) throws -> Data? {
        try db.query("SELECT image FROM receipt_images WHERE receipt_id=?", [.text(id)]).first?["image"]?.data
    }
    public func receiptNeedsOCR(id: String) throws -> Bool {
        let row = try db.query("SELECT text FROM receipt_ocr_runs WHERE receipt_id=? ORDER BY created_at_ms DESC,rowid DESC LIMIT 1", [.text(id)]).first
        return row?.text("text").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
    public func addReceiptOCR(id: String, text: String, producer: String = "apple_vision_documents") throws {
        guard ["apple_vision", "apple_vision_documents", "user_text"].contains(producer), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let row = try db.query("SELECT transaction_id FROM receipt_captures WHERE id=?", [.text(id)]).first else { throw LedgerError.invalid("invalid_receipt") }
        try db.transaction {
            let before = try db.query("SELECT count(*) AS n FROM receipt_ocr_runs WHERE receipt_id=?", [.text(id)]).first!.number("n")
            try insertReceiptOCR(receiptID: id, producer: producer, text: text)
            if before != (try db.query("SELECT count(*) AS n FROM receipt_ocr_runs WHERE receipt_id=?", [.text(id)]).first!.number("n")), let transactionID = row["transaction_id"]?.string {
                try receiptEvidenceChanged(transactionID: transactionID)
            }
        }
    }
    public func receiptCloudConsent() throws -> Bool {
        try db.query("SELECT value_json FROM app_settings WHERE key='receipt_cloud_consent'").first?.text("value_json") == "true"
    }
    public func setReceiptCloudConsent(_ enabled: Bool) throws {
        try db.transaction {
            guard enabled != (try receiptCloudConsent()) else { return }
            try db.query("INSERT INTO app_settings(key,value_json,updated_at_ms) VALUES ('receipt_cloud_consent',?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at_ms=excluded.updated_at_ms", [.text(enabled ? "true" : "false"), .integer(nowMS())])
            for row in try db.query("SELECT DISTINCT transaction_id FROM receipt_captures WHERE transaction_id IS NOT NULL") {
                try receiptEvidenceChanged(transactionID: row.text("transaction_id"))
            }
        }
    }
    func receiptContext(transactionID: String) throws -> ReceiptContext? {
        let records = try receipts(transactionID: transactionID)
        let full = records.map { $0.text }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        guard !full.isEmpty else { return nil }
        // Stable, traceable lines; original text remains in the vault. Strip common payment/loyalty identifiers.
        let lines = full.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty && $0.range(of: "(?i)(visa|mastercard|amex|card\\s*(no|number)|a[ui]th\\s*code|loyalty|member\\s*(id|no)|\\*{4,}|https?://|www\\.)", options: .regularExpression) == nil
        }.map { $0.replacingOccurrences(of: "\\b[0-9]{8,}\\b", with: "[identifier]", options: .regularExpression) }.filter { $0 != "[identifier]" }
        var selected = "", truncated = false
        for line in lines {
            let candidate = selected.isEmpty ? line : selected + "\n" + line
            if candidate.utf8.count > 1600 {
                truncated = true
                if selected.isEmpty {
                    selected = String(line.prefix(1600))
                    while selected.utf8.count > 1600 { selected.removeLast() }
                }
                break
            }
            selected = candidate
        }
        guard !selected.isEmpty else { return nil }
        return ReceiptContext(text: selected, truncated: truncated, evidenceSHA256: contentHash(Data(full.utf8)))
    }
}
