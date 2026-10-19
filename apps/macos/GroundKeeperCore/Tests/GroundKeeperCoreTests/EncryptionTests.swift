import Foundation
import Testing
@testable import GroundKeeperCore

@Test func encryptedVaultRoundTripAndRotation() async throws {
    let (store, url) = try vault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try await store.addAccount(name: "Private account sentinel", currency: "CAD")
    try await store.ingestCapture(data: capture("encrypted-round-trip"), deliveryPath: "capture.json")
    let before = try await store.snapshot()
    let first = "a long 'quoted' 🔑 passphrase"
    try await store.changeEncryption(to: first)
    #expect(try await store.integrityCheck())
    #expect(try await store.snapshot().accounts.count == before.accounts.count)
    #expect(throws: LedgerError.self) { try LedgerStore(url: url, passphrase: first) }
    await store.close()
    let bytes = try Data(contentsOf: url)
    #expect(!bytes.starts(with: Data("SQLite format 3".utf8)))
    #expect(bytes.range(of: Data("Private account sentinel".utf8)) == nil)
    #expect(throws: LedgerError.self) { try LedgerStore(url: url) }
    #expect(throws: LedgerError.self) { try LedgerStore(url: url, passphrase: "incorrect") }
    let reopened = try LedgerStore(url: url, passphrase: first)
    #expect(try await reopened.snapshot().reviews.count == before.reviews.count)
    try await reopened.verifyPassphrase(first)
    await #expect(throws: LedgerError.self) { try await reopened.verifyPassphrase("wrong-current-passphrase") }
    try await reopened.changeEncryption(to: "another sufficiently long passphrase")
    await reopened.close()
    #expect(throws: LedgerError.self) { try LedgerStore(url: url, passphrase: first) }
    let rotated = try LedgerStore(url: url, passphrase: "another sufficiently long passphrase")
    #expect(try await rotated.integrityCheck())
    try await rotated.changeEncryption(to: nil)
    await rotated.close()
    #expect(try Data(contentsOf: url).starts(with: Data("SQLite format 3".utf8)))
    let plain = try LedgerStore(url: url)
    #expect(try await plain.snapshot().accounts.first?.name == "Private account sentinel")
    #expect(try await plain.snapshot().reviews.count == before.reviews.count)
    await plain.close()
}

@Test func rejectsWeakConversionWithoutChangingOriginal() async throws {
    let (store, url) = try vault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try await store.addAccount(name: "Preserved", currency: "CAD")
    await #expect(throws: LedgerError.self) { try await store.changeEncryption(to: "short") }
    #expect(try await store.snapshot().accounts.first?.name == "Preserved")
    #expect(try await store.integrityCheck())
    await store.close()
}

@Test func createsEncryptedVaultDirectly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("vault.sqlite")
    let store = try LedgerStore(url: url, passphrase: "a sufficiently long passphrase")
    try await store.addAccount(name: "Encrypted from creation", currency: "CAD")
    await store.close()
    #expect(!((try Data(contentsOf: url)).starts(with: Data("SQLite format 3".utf8))))
}
