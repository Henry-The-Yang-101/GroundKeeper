import AppKit
import GroundKeeperCore

/// Disposable location and receipt evidence for the native transaction walkthrough.
enum TransactionPreview {
    static func seed(_ store: LedgerStore) async throws {
        try await store.addAccount(name: "Everyday card · Demo", currency: "CAD")
        guard let account = try await store.snapshot().accounts.first else { throw LedgerError.invalid("Demo account is missing.") }
        let payload: [String: Any] = [
            "schema_version": 4, "event_id": "transaction-detail-demo", "source": "wallet_transaction", "app": "Wallet",
            "captured_at": "2026-10-25T12:30:00-04:00", "input_shape": "wallet_transaction_fields", "merchant": "Campus Coffee · Fictional", "amount": "CAD 12.50",
            "card_or_pass": "Demo card", "note": "Coffee and a sandwich before the study group.",
            "location": ["latitude": 43.4723, "longitude": -80.5449, "horizontal_accuracy_m": 15, "label": "Fictional campus café"]
        ]
        try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: payload), deliveryPath: "transaction-detail-demo.json")
        guard let review = try await store.snapshot().reviews.first else { throw LedgerError.invalid("Demo capture could not be imported.") }
        try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: account.id)
        guard let transaction = try await store.snapshot().transactions.first else { throw LedgerError.invalid("Demo transaction is missing.") }
        let image = try await receiptImage()
        var edit = TransactionEdit(id: transaction.id, revision: transaction.revision, description: transaction.description,
            amountMinor: transaction.amountMinor, currency: "CAD", occurredOn: "2026-10-25", accountID: account.id,
            type: "expense", category: "dining", needsReview: false, notes: transaction.notes)
        edit.receiptAdditions = [.init(image: image, text: "CAMPUS COFFEE\nCoffee 4.50\nSandwich 8.00\nTOTAL CAD 12.50", producer: "user_text")]
        try await store.save(edit)
        for (description, amount, type, category) in [("Bookshop refund", Int64(1800), "refund", "shopping"), ("Monthly transit pass", -10000, "expense", "local_transport")] {
            try await store.save(.init(description: description, amountMinor: amount, currency: "CAD", occurredOn: "2026-10-24",
                accountID: account.id, type: type, category: category, needsReview: false, notes: ""))
        }
    }

    @MainActor private static func receiptImage() throws -> Data {
        let image = NSImage(size: NSSize(width: 700, height: 900), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            let text = "CAMPUS COFFEE\nFICTIONAL DEMO RECEIPT\n\n25 OCT 2026 · 12:30\n\nCoffee             $4.50\nSandwich           $8.00\n\n-----------------------\nTOTAL CAD         $12.50\n\nThank you!"
            (text as NSString).draw(in: NSRect(x: 55, y: 80, width: 590, height: 750), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 30, weight: .regular), .foregroundColor: NSColor.black
            ])
            return true
        }
        guard let data = image.tiffRepresentation else { throw LedgerError.invalid("Could not generate the fictional receipt.") }
        return try ReceiptImageProcessor.jpeg(data)
    }
}
