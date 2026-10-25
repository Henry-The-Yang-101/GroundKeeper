import Foundation
import Testing
@testable import GroundKeeperCore

private final class OllamaFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var mode: String
    init(_ mode: String = "valid") { self.mode = mode }
    func recorded() -> [URLRequest] { lock.withLock { requests } }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        let count = lock.withLock { requests.append(request); return requests.count }
        let path = request.url!.path
        if mode == "timeout" { throw URLError(.timedOut) }
        if mode == "unavailable" { throw URLError(.cannotConnectToHost) }
        if mode == "cancelled" { throw URLError(.cancelled) }
        if mode == "http" { return (500, Data("private dependency error".utf8)) }
        if mode == "oversized" { return (200, Data(repeating: 32, count: 1_048_577)) }
        let digest = String(repeating: mode == "changed" || (mode == "changedAfter" && count > 3) ? "b" : "a", count: 64)
        if path == "/api/tags" {
            let names = mode == "listing" ? ["fixture:latest", "remote:cloud", "alias", "embedding"] : ["fixture:latest"]
            let models: [[String: Any]] = names.map { name in
                var entry: [String: Any] = ["name": name, "digest": digest, "size": 1000, "capabilities": [name == "embedding" ? "embedding" : "completion"]]
                if name == "alias" || mode == "cloudTag" { entry["remote_host"] = "https://ollama.com" }
                return entry
            }
            return (200, try JSONSerialization.data(withJSONObject: ["models": mode == "missing" ? [] : models]))
        }
        if path == "/api/show" {
            var details: [String: Any] = ["capabilities": [mode == "embedding" ? "embedding" : "completion"]]
            if mode == "cloudShow" { details["remote_model"] = "hidden-cloud-alias" }
            return (200, try JSONSerialization.data(withJSONObject: details))
        }
        let content = mode == "invalidOutput" ? "{\"type\":\"income\",\"category\":\"dining\",\"review\":true}" : "{\"type\":\"expense\",\"category\":\"dining\",\"review\":false}"
        return (200, try JSONSerialization.data(withJSONObject: [
            "model": mode == "wrongModel" ? "other" : "fixture:latest", "done": mode != "incomplete",
            "done_reason": mode == "truncated" ? "length" : "stop", "message": ["role": "assistant", "content": content]
        ]))
    }
}
private final class OllamaMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: OllamaFixture] = [:]
    static func client(_ fixture: OllamaFixture) -> OllamaClassifier {
        let id = UUID().uuidString
        lock.withLock { fixtures[id] = fixture }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaMockProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture": id]
        return OllamaClassifier(session: URLSession(configuration: configuration))
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let fixture = Self.lock.withLock { Self.fixtures[request.value(forHTTPHeaderField: "X-Fixture")!]! }
            let (status, data) = try fixture.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Length": String(data.count), "Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private let ollamaModel = OllamaModel(name: "fixture:latest", digest: String(repeating: "a", count: 64), size: 1000)
private let ollamaInput = Data("{\"description\":\"FICTIONAL CAFE\",\"direction\":\"debit\",\"currency\":\"CAD\"}".utf8)

@Test func ollamaDiscoveryExcludesCloudAliasesAndEmbeddings() async throws {
    let client = OllamaMockProtocol.client(OllamaFixture("listing"))
    #expect(try await client.models().map(\.name) == ["fixture:latest"])
    await client.shutdown()
}
@Test func ollamaUsesLocalSchemaAndAlwaysRequiresReview() async throws {
    let fixture = OllamaFixture()
    let client = OllamaMockProtocol.client(fixture)
    let decision = try await client.classify(inputJSON: ollamaInput, model: ollamaModel)
    #expect(decision.type == "expense" && decision.category == "dining" && decision.review)
    let requests = fixture.recorded()
    #expect(requests.map { $0.url!.path } == ["/api/tags", "/api/show", "/api/chat", "/api/tags", "/api/show"])
    #expect(requests.allSatisfy { $0.url!.host == "127.0.0.1" && $0.url!.port == 11434 })
    let chat = requests[2]
    // URLProtocol converts httpBody to a stream; read that stream to inspect the wire payload.
    let stream = chat.httpBodyStream!
    stream.open(); defer { stream.close() }
    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
    let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(body["stream"] as? Bool == false && body["think"] as? Bool == false)
    #expect(body["keep_alive"] as? Int == 0)
    #expect(body["truncate"] as? Bool == false && body["shift"] as? Bool == false)
    #expect((body["format"] as? [String: Any])?["additionalProperties"] as? Bool == false)
    #expect((body["messages"] as? [[String: String]])?.last?["content"] == String(decoding: ollamaInput, as: UTF8.self))
    await client.shutdown()
}
@Test(arguments: ["changed", "missing", "cloudTag", "cloudShow", "embedding"])
func ollamaRejectsUnsafeOrChangedModelBeforeSendingEvidence(_ mode: String) async throws {
    let fixture = OllamaFixture(mode)
    let client = OllamaMockProtocol.client(fixture)
    await #expect(throws: OllamaError.self) { try await client.classify(inputJSON: ollamaInput, model: ollamaModel) }
    #expect(!fixture.recorded().contains { $0.url?.path == "/api/chat" })
    await client.shutdown()
}
@Test(arguments: ["changedAfter", "invalidOutput", "wrongModel", "incomplete", "truncated", "oversized"])
func ollamaRejectsInvalidOrTruncatedResponse(_ mode: String) async throws {
    let client = OllamaMockProtocol.client(OllamaFixture(mode))
    await #expect(throws: OllamaError.self) { try await client.classify(inputJSON: ollamaInput, model: ollamaModel) }
    await client.shutdown()
}
@Test(arguments: ["timeout", "unavailable", "http"])
func ollamaTransportErrorsAreSafeAndRetryable(_ mode: String) async throws {
    let client = OllamaMockProtocol.client(OllamaFixture(mode))
    do { _ = try await client.models(); Issue.record("Expected failure") }
    catch let error as OllamaError {
        #expect(error.retryable)
        #expect(!error.localizedDescription.contains("private dependency error"))
    }
    await client.shutdown()
}
@Test func ollamaCancellationIsNotAProviderFailure() async throws {
    let client = OllamaMockProtocol.client(OllamaFixture("cancelled"))
    await #expect(throws: CancellationError.self) { try await client.models() }
    let cancelled = Task { try await client.models() }; cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    await client.shutdown()
}
@Test(arguments: [
    "{\"type\":\"expense\",\"category\":null,\"review\":true}",
    "{\"type\":\"unknown\",\"category\":null,\"review\":true}",
    "{\"type\":\"income\",\"category\":\"shopping\",\"review\":true}",
    "{\"type\":\"expense\",\"category\":\"invented\",\"review\":true}",
    "{\"type\":\"expense\",\"category\":\"dining\",\"review\":1}",
    "{\"type\":\"expense\",\"category\":\"dining\",\"review\":true,\"explanation\":\"extra\"}",
    "{\"type\":\"expense\",\"review\":true}", "not json"
]) func ollamaDecisionValidation(_ json: String) throws {
    #expect(throws: OllamaError.invalidOutput) { try OllamaClassifier.parseDecision(Data(json.utf8)) }
}
@Test func ollamaIdentityAndQueueSurviveRestartAndProviderSwitching() async throws {
    let (store, url) = try vault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try await store.addAccount(name: "Test card", currency: "CAD")
    try await ingestMapped(store, id: "ollama-fixture")
    let configuration = try JSONEncoder().encode(ollamaModel)
    #expect(try JSONDecoder().decode(OllamaModel.self, from: configuration) == ollamaModel)
    #expect(OllamaModel(name: ollamaModel.name, digest: String(repeating: "b", count: 64), size: 1000).identity != ollamaModel.identity)
    try await store.registerModel(id: ollamaModel.identity, name: ollamaModel.name, backend: "ollama", policy: "groundkeeper-19-v2", configuration: String(decoding: configuration, as: UTF8.self))
    try await store.enqueueClassifications(modelID: ollamaModel.identity)
    let localID = String(repeating: "f", count: 64)
    try await store.registerModel(id: localID, name: "qwen", backend: "qwen_mlx", policy: "groundkeeper-19-v2", configuration: "{}")
    try await store.enqueueClassifications(modelID: localID)
    await store.close()
    let reopened = try LedgerStore(url: url)
    try await reopened.registerModel(id: ollamaModel.identity, name: ollamaModel.name, backend: "ollama", policy: "groundkeeper-19-v2", configuration: String(decoding: configuration, as: UTF8.self))
    try await reopened.enqueueClassifications(modelID: ollamaModel.identity)
    let task = try #require(await reopened.claimClassification(modelID: ollamaModel.identity))
    try await reopened.completeClassification(task, decision: .init(type: "expense", category: "dining", review: true))
    let transaction = try #require(await reopened.snapshot().transactions.first)
    #expect(transaction.category == "dining" && transaction.needsReview)
    let rows = try await reopened.testRows("SELECT provider,execution FROM model_versions WHERE provider='ollama'")
    #expect(rows.count == 1 && rows[0].text("execution") == "local")
    await reopened.close()
}
