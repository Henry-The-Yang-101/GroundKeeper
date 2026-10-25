import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import GroundKeeperCore

private func sampleReceipt(width: Int = 1200, height: Int = 800, orientation: Int = 1) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

@Test func receiptConversionBakesOrientationCropsAndWritesBoundedJPEG() throws {
    let result = try ReceiptImageProcessor.jpeg(sampleReceipt(orientation: 6), crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    let source = try #require(CGImageSourceCreateWithData(result as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 400 && image.height == 600)
    #expect(result.count <= ReceiptImageProcessor.maximumBytes)
}

@Test func receiptConversionDownsizesUntilTheByteLimitIsMet() throws {
    let result = try ReceiptImageProcessor.encode(sampleReceipt(), byteLimit: 1600)
    #expect(result.count <= 1600)
    let source = try #require(CGImageSourceCreateWithData(result as CFData, nil))
    #expect(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)).width < 1200)
    #expect(throws: LedgerError.self) { try ReceiptImageProcessor.jpeg(Data("invalid".utf8)) }
    #expect(throws: LedgerError.self) { try ReceiptImageProcessor.jpeg(sampleReceipt(), crop: CGRect(x: -0.1, y: 0, width: 1, height: 1)) }
}
