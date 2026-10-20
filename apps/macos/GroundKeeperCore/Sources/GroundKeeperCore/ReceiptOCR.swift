import Foundation
import Vision

public struct ReceiptOCRResult: Codable, Sendable {
    public let text: String
    public let producer: String
    public let elapsedMS: Double
    public let tableCount: Int
}
public enum ReceiptOCR {
    /// Local Apple OCR. No model provider or network access is involved.
    public static func recognize(_ data: Data) async throws -> ReceiptOCRResult {
        guard !data.isEmpty, data.count <= 8_388_608 else { throw LedgerError.invalid("Receipt image must be smaller than 8 MiB.") }
        let start = ContinuousClock.now
        let text: String, producer: String, tableCount: Int
        if #available(macOS 26, *) {
            let result = try await RecognizeDocumentsRequest().perform(on: data)
            text = result.map { $0.document.text.transcript }.joined(separator: "\n")
            tableCount = result.reduce(0) { $0 + $1.document.tables.count }
            producer = "apple_vision_documents"
        } else {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            try VNImageRequestHandler(data: data).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            producer = "apple_vision"; tableCount = 0
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_768 else {
            throw LedgerError.invalid("The receipt text is empty or exceeds 32 KiB. Choose a clearer or shorter image.")
        }
        let duration = start.duration(to: .now).components
        return ReceiptOCRResult(text: text, producer: producer, elapsedMS: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15, tableCount: tableCount)
    }
}
