import Foundation
import GroundKeeperCore

@main struct ReceiptPilot {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, ["ocr", "ingest"].contains(args[1]) else {
            throw LedgerError.invalid("Usage: ReceiptPilot ocr DATASET_DIRECTORY OUTPUT.jsonl | ingest INBOX OUTPUT.json")
        }
        let root = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
        if args[1] == "ocr" {
            let urls = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("img"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let file = try FileHandle(forWritingTo: output); defer { try? file.close() }
            for url in urls {
                var record: [String: Any] = ["id": url.deletingPathExtension().lastPathComponent]
                do {
                    let data = try Data(contentsOf: url), result = try await ReceiptOCR.recognize(data)
                    record.merge(["status": "ok", "text": result.text, "producer": result.producer, "elapsed_ms": result.elapsedMS, "table_count": result.tableCount, "image_sha256": contentHash(data)]) { _, new in new }
                } catch { record["status"] = "failed"; record["error"] = "ocr_failed" }
                try file.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data("\n".utf8))
            }
            print("Processed \(urls.count) receipt images with native Apple OCR.")
        } else {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("GroundKeeper-ReceiptPilot-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let store = try LedgerStore(url: scratch.appendingPathComponent("vault.sqlite"), passphrase: "isolated-receipt-pilot")
            try await store.addAccount(name: "Fictional pilot account", currency: "CAD")
            let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path > $1.path }
            for url in urls { try await store.ingestCapture(data: Data(contentsOf: url), deliveryPath: url.lastPathComponent) }
            let snapshot = try await store.snapshot()
            var mapped = Set<String>()
            for review in snapshot.reviews where review.reason == "account_mapping_required" && mapped.insert(review.sourceID + "|" + review.label).inserted {
                try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: snapshot.accounts[0].id)
            }
            for request in try await store.receiptImageRequests() {
                try await store.storeReceiptImage(id: request.id, data: Data(contentsOf: root.appendingPathComponent(request.path)))
            }
            let model = String(repeating: "a", count: 64)
            try await store.registerModel(id: model, name: "input-contract-only", backend: "qwen_mlx", policy: "groundkeeper-18-v1", configuration: "{}")
            try await store.enqueueClassifications(modelID: model)
            var contexts = 0, receiptCount = 0, imageCount = 0
            while let task = try await store.claimClassification(modelID: model) {
                if task.receiptContext != nil { contexts += 1 }
                try await store.completeClassification(task, decision: .init(type: "unknown", category: "uncategorized", review: true))
            }
            let final = try await store.snapshot(limit: 5000)
            for transaction in final.transactions {
                let receipts = try await store.receipts(transactionID: transaction.id)
                receiptCount += receipts.count; imageCount += receipts.filter { $0.imageState == "stored" }.count
            }
            let report: [String: Any] = ["input_files": urls.count, "transactions": final.totalTransactions, "receipts": receiptCount,
                "jobs_with_receipt_context": contexts, "stored_images": imageCount, "integrity_check": try await store.integrityCheck(),
                "quarantined_files": final.queue.filter { $0.state == "quarantined" }.count,
                "classification": "contract-only fixture; no model inference", "vault": "isolated encrypted temporary vault"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            await store.close()
            try FileManager.default.removeItem(at: scratch)
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        }
    }
}
