import Foundation
import Vision
import ImageIO

public struct ReceiptOCRResult: Codable, Sendable {
    public let text: String
    public let producer: String
    public let elapsedMS: Double
    public let tableCount: Int
}
public enum ReceiptOCR {
    /// Manual attachments need only text, not document/table reconstruction.
    /// Run the established text recognizer off the UI actor so saving remains responsive.
    public static func recognizeText(_ data: Data) async throws -> ReceiptOCRResult {
        try await Task.detached(priority: .userInitiated) {
            try validate(data)
            let start = ContinuousClock.now
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(data: data).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_768 else {
                throw LedgerError.invalid("No readable receipt text was found. The image can still be saved.")
            }
            let duration = start.duration(to: .now).components
            return ReceiptOCRResult(text: text, producer: "apple_vision",
                elapsedMS: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15, tableCount: 0)
        }.value
    }

    private static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 8_388_608 else { throw LedgerError.invalid("Receipt image must be smaller than 8 MiB.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= 32, height >= 32, width <= 20_000, height <= 20_000, width * height <= 40_000_000 else {
            throw LedgerError.invalid("Choose a readable receipt image at least 32 pixels wide and tall.")
        }
    }

    /// Local Apple OCR. No model provider or network access is involved.
    public static func recognize(_ data: Data) async throws -> ReceiptOCRResult {
        try validate(data)
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
