import Foundation
import Testing
@testable import GroundKeeperCore

@Test func modelArchivePartsRejectCorruptionAndPreserveEarlierParts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("part"), archive = root.appendingPathComponent("archive")
    let first = Data("first verified part".utf8), second = Data(repeating: 37, count: 2_000_000)
    try first.write(to: source); FileManager.default.createFile(atPath: archive.path, contents: nil)
    let output = try FileHandle(forWritingTo: archive); defer { try? output.close() }
    try ModelInstallFiles.appendVerifiedPart(source, to: output, expectedBytes: Int64(first.count), sha256: contentHash(first))
    try second.write(to: source)
    #expect(throws: LedgerError.self) { try ModelInstallFiles.appendVerifiedPart(source, to: output, expectedBytes: Int64(second.count), sha256: contentHash(first)) }
    #expect(try Data(contentsOf: archive) == first)
    #expect(throws: LedgerError.self) { try ModelInstallFiles.appendVerifiedPart(source, to: output, expectedBytes: 10, sha256: contentHash(second)) }
    #expect(try Data(contentsOf: archive) == first)
    #expect(throws: LedgerError.self) { try ModelInstallFiles.appendVerifiedPart(source, to: output, expectedBytes: Int64(second.count + 1), sha256: contentHash(second)) }
    try ModelInstallFiles.appendVerifiedPart(source, to: output, expectedBytes: Int64(second.count), sha256: contentHash(second))
    #expect(try Data(contentsOf: archive) == first + second)
}
