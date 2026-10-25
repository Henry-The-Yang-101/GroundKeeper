import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One path for Photos, files and camera images. Baking orientation and drawing onto
/// white also strips source metadata and gives transparent images a readable paper color.
public enum ReceiptImageProcessor {
    public static let maximumBytes = 8 * 1024 * 1024
    public static let maximumInputBytes = 128 * 1024 * 1024

    public static func jpeg(_ data: Data, crop: CGRect? = nil) throws -> Data {
        try encode(data, crop: crop, byteLimit: maximumBytes)
    }

    static func encode(_ data: Data, crop: CGRect? = nil, byteLimit: Int) throws -> Data {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              var image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 6000,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw LedgerError.invalid("Choose a readable image smaller than 128 MiB.")
        }
        if let crop {
            guard [crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite),
                  crop.minX >= 0, crop.minY >= 0, crop.maxX <= 1.000001, crop.maxY <= 1.000001,
                  crop.width > 0, crop.height > 0 else { throw LedgerError.invalid("Select a valid crop area.") }
            let rect = CGRect(x: crop.minX * CGFloat(image.width), y: crop.minY * CGFloat(image.height),
                              width: crop.width * CGFloat(image.width), height: crop.height * CGFloat(image.height)).integral
            guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
                throw LedgerError.invalid("The crop area is too small.")
            }
            image = cropped
        }
        var width = image.width, height = image.height
        while width > 0 && height > 0 {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw LedgerError.invalid("This image could not be prepared.")
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let flattened = context.makeImage() else { throw LedgerError.invalid("This image could not be prepared.") }
            for quality in [0.9, 0.8, 0.65, 0.5] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw LedgerError.invalid("JPEG conversion is unavailable.")
                }
                CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), output.length <= byteLimit { return output as Data }
            }
            width = Int(Double(width) * 0.75); height = Int(Double(height) * 0.75)
        }
        throw LedgerError.invalid("This image could not fit within the receipt size limit.")
    }
}
