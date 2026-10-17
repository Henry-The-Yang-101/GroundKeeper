@preconcurrency import Foundation

@objc(GKClassifierService) protocol ClassifierXPCService {
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void)
    func cancel(_ requestID: String, withReply reply: @escaping (Bool) -> Void)
}
@objc(GKClassifierEvents) protocol ClassifierXPCEvents {
    func event(_ data: Data)
}

struct ClassifierInput: Codable, Sendable {
    let description: String
    let direction: String
    let currency: String?
    enum CodingKeys: String, CodingKey { case description, direction, currency }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(description, forKey: .description)
        try container.encode(direction, forKey: .direction)
        if let currency { try container.encode(currency, forKey: .currency) }
        else { try container.encodeNil(forKey: .currency) }
    }
}

struct ClassifierModel: Codable, Sendable, Equatable {
    let modelID: String
    let backend: String
    let manifestSHA256: String
    let policyVersion: String
    let device: String
    enum CodingKeys: String, CodingKey {
        case modelID = "model_id", backend, manifestSHA256 = "manifest_sha256"
        case policyVersion = "policy_version", device
    }
}
struct ClassifierDecision: Codable, Sendable {
    let type: String
    let category: String?
    let review: Bool
}
struct ClassifierEvent: Decodable, Sendable {
    let requestID: String
    let stage: String
    enum CodingKeys: String, CodingKey { case requestID = "request_id", stage }
}
struct ClassifierResult: Decodable, Sendable {
    let decision: ClassifierDecision?
    let model: ClassifierModel?
    let loadedModel: ClassifierModel?
    let jobID: String?
    let partID: String?
    let transactionRevision: Int?
    let policyVersion: String?
    let backends: [String]?
    let runtime: [String: String]?
    let categories: [String]?
    let types: [String]?
    let mlx: GPUProbe?
    let laya: GPUProbe?
    struct GPUProbe: Decodable, Sendable { let device: String; let value: Double }
    enum CodingKeys: String, CodingKey {
        case decision, model, loadedModel = "loaded_model", jobID = "job_id", partID = "part_id", transactionRevision = "transaction_revision"
        case policyVersion = "policy_version", backends, runtime, categories, types, mlx, laya
    }
}
private struct ClassifierRequest: Encodable, Sendable {
    let protocolVersion = 1
    let requestID = UUID().uuidString
    let operation: String
    var timeoutMS = 60_000
    var packageBookmark: String?
    var jobID: String?
    var partID: String?
    var transactionRevision: Int?
    var policyVersion: String?
    var modelManifestSHA256: String?
    var input: ClassifierInput?
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", requestID = "request_id", operation, timeoutMS = "timeout_ms"
        case packageBookmark = "package_bookmark", jobID = "job_id", partID = "part_id"
        case transactionRevision = "transaction_revision", policyVersion = "policy_version"
        case modelManifestSHA256 = "model_manifest_sha256", input
    }
}
private struct ClassifierResponse: Decodable {
    let protocolVersion: Int
    let requestID: String?
    let status: String
    let result: ClassifierResult?
    let error: RemoteError?
    struct RemoteError: Decodable { let code: String; let message: String }
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", requestID = "request_id", status, result, error
    }
}
private final class ClassifierEventReceiver: NSObject, ClassifierXPCEvents, @unchecked Sendable {
    let receive: @Sendable (Data) -> Void
    init(receive: @escaping @Sendable (Data) -> Void) { self.receive = receive }
    func event(_ data: Data) { receive(data) }
}
enum ClassifierBridgeError: Error, LocalizedError, Sendable {
    case unavailable, timedOut, invalidResponse
    case worker(String, String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Classifier service disconnected. Reconnect and load the model again."
        case .timedOut: "Classifier request exceeded its deadline."
        case .invalidResponse: "Classifier returned an incompatible response."
        case .worker(let code, let message): "\(message) (\(code))"
        }
    }
}

/// Owns connection callbacks/continuations outside actor isolation. NSLock protects
/// the small pending map; no blocking model work executes in the app process.
private final class ClassifierTransport: NSObject, ClassifierXPCEvents, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var pending: [String: (@Sendable (Result<Data, any Error>) -> Void)] = [:]
    private var timers: [String: DispatchWorkItem] = [:]
    let events: AsyncStream<ClassifierEvent>
    private let eventContinuation: AsyncStream<ClassifierEvent>.Continuation

    override init() {
        let pair = AsyncStream<ClassifierEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        events = pair.stream; eventContinuation = pair.continuation
        super.init()
    }
    deinit { connection?.invalidate(); eventContinuation.finish() }

    private func connect() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let new = NSXPCConnection(serviceName: "com.groundkeeper.macos.classifier")
        new.remoteObjectInterface = NSXPCInterface(with: ClassifierXPCService.self)
        new.exportedInterface = NSXPCInterface(with: ClassifierXPCEvents.self)
        // Do not make connection → exportedObject → transport → connection a cycle.
        new.exportedObject = ClassifierEventReceiver { [weak self] data in self?.event(data) }
        new.interruptionHandler = { [weak self, weak new] in if let new { self?.disconnected(expected: new) } }
        new.invalidationHandler = { [weak self, weak new] in if let new { self?.disconnected(expected: new) } }
        connection = new
        new.activate()
        return new
    }
    private func disconnected(expected: NSXPCConnection) {
        lock.lock()
        guard connection === expected else { lock.unlock(); return }
        let old = connection; connection = nil
        let completions = Array(pending.values); pending.removeAll()
        for timer in timers.values { timer.cancel() }; timers.removeAll()
        lock.unlock()
        old?.invalidationHandler = nil; old?.interruptionHandler = nil; old?.invalidate()
        for completion in completions { completion(.failure(ClassifierBridgeError.unavailable)) }
    }
    func invalidate() {
        lock.lock(); let current = connection; lock.unlock()
        if let current { disconnected(expected: current) }
    }
    func event(_ data: Data) {
        guard data.count <= 65536, let value = try? JSONDecoder().decode(ClassifierEvent.self, from: data) else { return }
        eventContinuation.yield(value)
    }
    private func finish(_ id: String, _ result: Result<Data, any Error>) {
        lock.lock()
        let completion = pending.removeValue(forKey: id)
        timers.removeValue(forKey: id)?.cancel()
        lock.unlock()
        completion?(result)
    }
    private func cancel(_ id: String) {
        lock.lock(); let service = connection; lock.unlock()
        (service?.remoteObjectProxyWithErrorHandler { _ in } as? ClassifierXPCService)?.cancel(id) { _ in }
        finish(id, .failure(CancellationError()))
    }
    func send(_ data: Data, id: String, timeoutMS: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let service = connect()
                let timer = DispatchWorkItem { [weak self] in
                    (service.remoteObjectProxyWithErrorHandler { _ in } as? ClassifierXPCService)?.cancel(id) { _ in }
                    self?.finish(id, .failure(ClassifierBridgeError.timedOut))
                }
                lock.lock()
                if pending.count >= 16 {
                    lock.unlock()
                    continuation.resume(throwing: ClassifierBridgeError.worker("busy", "Classifier request queue is full"))
                    return
                }
                pending[id] = { continuation.resume(with: $0) }
                timers[id] = timer
                lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Double(timeoutMS) / 1000 + 1, execute: timer)
                guard let proxy = service.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                    self?.finish(id, .failure(ClassifierBridgeError.unavailable))
                }) as? ClassifierXPCService else {
                    finish(id, .failure(ClassifierBridgeError.unavailable)); return
                }
                proxy.request(data) { [weak self] result in self?.finish(id, .success(result)) }
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: { self.cancel(id) }
    }
}

actor ClassifierClient {
    static let policyVersion = "groundkeeper-18-v1"
    private let transport = ClassifierTransport()
    private var categories = Set<String>()
    private var types = Set<String>()
    var events: AsyncStream<ClassifierEvent> { transport.events }
    func shutdown() { transport.invalidate() }

    private func call(_ request: ClassifierRequest) async throws -> ClassifierResult {
        let data = try JSONEncoder().encode(request)
        guard data.count <= 65536 else { throw ClassifierBridgeError.invalidResponse }
        let responseData = try await transport.send(data, id: request.requestID, timeoutMS: request.timeoutMS)
        try Task.checkCancellation()
        guard responseData.count <= 65536 else { throw ClassifierBridgeError.invalidResponse }
        let response = try JSONDecoder().decode(ClassifierResponse.self, from: responseData)
        guard response.protocolVersion == 1, response.requestID == request.requestID else { throw ClassifierBridgeError.invalidResponse }
        if let error = response.error {
            guard response.status == "failed", response.result == nil else { throw ClassifierBridgeError.invalidResponse }
            throw ClassifierBridgeError.worker(error.code, error.message)
        }
        guard response.status == "succeeded", let result = response.result else { throw ClassifierBridgeError.invalidResponse }
        return result
    }
    func handshake() async throws -> ClassifierResult {
        let result = try await call(ClassifierRequest(operation: "handshake"))
        guard result.policyVersion == Self.policyVersion, let categories = result.categories,
              let types = result.types, categories.contains("uncategorized"), types.contains("unknown") else {
            throw ClassifierBridgeError.invalidResponse
        }
        self.categories = Set(categories); self.types = Set(types)
        return result
    }
    func probeGPU() async throws -> ClassifierResult { try await call(ClassifierRequest(operation: "gpu_probe")) }
    func verifyProtocolErrors() async throws {
        do {
            _ = try await call(ClassifierRequest(operation: "unknown_operation"))
            throw ClassifierBridgeError.invalidResponse
        } catch ClassifierBridgeError.worker(let code, _) {
            guard code == "unsupported_operation" else { throw ClassifierBridgeError.invalidResponse }
        }
    }
    func prepareModel(at url: URL, timeoutMS: Int = 120_000) async throws -> ClassifierModel {
        _ = try await handshake()
        // Transient cross-process bookmarks use options=[]; app-scoped persistent
        // bookmarks cannot be resolved as another process's app-scoped grant.
        let bookmark = try url.bookmarkData(options: [],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        var request = ClassifierRequest(operation: "prepare_model")
        request.timeoutMS = timeoutMS; request.packageBookmark = bookmark.base64EncodedString()
        guard let model = try await call(request).model else { throw ClassifierBridgeError.invalidResponse }
        return model
    }
    func releaseModel() async throws { _ = try await call(ClassifierRequest(operation: "release_model")) }
    func classify(_ input: ClassifierInput, model: ClassifierModel, partID: String, revision: Int,
                  jobID: String = UUID().uuidString) async throws -> ClassifierResult {
        if categories.isEmpty { _ = try await handshake() }
        var request = ClassifierRequest(operation: "classify")
        request.partID = partID; request.jobID = jobID; request.transactionRevision = revision
        request.policyVersion = Self.policyVersion; request.modelManifestSHA256 = model.manifestSHA256; request.input = input
        let result = try await call(request)
        guard result.partID == partID, result.jobID == jobID, result.transactionRevision == revision,
              result.model == model, let decision = result.decision, decision.review else { throw ClassifierBridgeError.invalidResponse }
        guard types.contains(decision.type), decision.category.map({ categories.contains($0) }) ?? true else {
            throw ClassifierBridgeError.invalidResponse
        }
        switch decision.type {
        case "expense": guard decision.category != nil else { throw ClassifierBridgeError.invalidResponse }
        case "unknown": guard decision.category == "uncategorized" else { throw ClassifierBridgeError.invalidResponse }
        case "refund": break
        default: guard decision.category == nil else { throw ClassifierBridgeError.invalidResponse }
        }
        return result
    }
}
