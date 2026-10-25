import Foundation

public struct TransactionNote: Sendable {
    public let text: String
    public let revision: Int
}

extension LedgerStore {
    static func importCapturedNotes(db: Database) throws {
        let rows = try db.query("""
            SELECT n.event_id,n.text,l.transaction_id FROM capture_notes n
            JOIN transaction_event_links l ON l.event_id=n.event_id AND l.unlinked_at_ms IS NULL
            WHERE NOT EXISTS(SELECT 1 FROM capture_note_imports i WHERE i.event_id=n.event_id)
            ORDER BY l.linked_at_ms,n.event_id
            """)
        for row in rows {
            let id = row.text("transaction_id")
            let before = try db.query("SELECT notes FROM transactions WHERE id=?", [.text(id)]).first!.text("notes")
            let note = row.text("text")
            let combined = before.isEmpty ? note : before == note ? before : before + "\n\n" + note
            try db.query("UPDATE transactions SET notes=? WHERE id=?", [.text(combined), .text(id)])
            try db.query("INSERT INTO capture_note_imports VALUES (?,?)", [.text(row.text("event_id")), .text(id)])
            try receiptEvidenceChanged(db: db, transactionID: id)
        }
    }
    public func transactionNote(transactionID: String) throws -> TransactionNote {
        guard let row = try db.query("SELECT notes,revision FROM transactions WHERE id=? AND state='active'", [.text(transactionID)]).first else {
            throw LedgerError.invalid("This transaction is no longer available.")
        }
        return TransactionNote(text: row.text("notes"), revision: Int(row.number("revision")))
    }
    /// Note-only edits do not confirm or overwrite a category suggestion.
    public func saveTransactionNote(transactionID: String, text: String, revision: Int) throws {
        guard text.utf8.count <= 10000, !text.contains("\0") else { throw LedgerError.invalid("Use a note of at most 10,000 UTF-8 bytes.") }
        try db.transaction {
            let current = try transactionNote(transactionID: transactionID)
            guard current.revision == revision else { throw LedgerError.conflict }
            guard current.text != text else { return }
            try db.query("UPDATE transactions SET notes=? WHERE id=?", [.text(text), .text(transactionID)])
            try receiptEvidenceChanged(transactionID: transactionID)
            try db.query("INSERT INTO change_log(id,operation_id,entity_type,entity_id,actor,reason,changed_at_ms,before_json,after_json) VALUES (?,?,'transaction',?,'user','edit_note',?,?,?)",
                [.text(identifier()), .text(identifier()), .text(transactionID), .integer(nowMS()), .text(try json(["notes": current.text])), .text(try json(["notes": text]))])
        }
    }
    func classifierNotes(transactionID: String) throws -> String? {
        let text = try transactionNote(transactionID: transactionID).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var bounded = String(text.prefix(1600))
        while bounded.utf8.count > 1600 { bounded.removeLast() }
        return bounded
    }
}
