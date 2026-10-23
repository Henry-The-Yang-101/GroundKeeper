import Foundation
import GroundKeeperCore

/// Search uses its own sandbox/process; only query terms cross this boundary.
actor MerchantSearchClient {
    private let transport: ClassifierTransport = {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/GroundKeeperMerchantSearch.xpc")
        let identifier = Bundle(url: url)?.bundleIdentifier ?? "com.groundkeeper.macos.merchant-search"
        return ClassifierTransport(serviceName: identifier)
    }()
    private var idleShutdown: Task<Void, Never>?
    private struct Request: Encodable {
        let protocol_version = 1
        let request_id = UUID().uuidString
        let operation: String
        let timeout_ms = 30_000
        var merchant: String? = nil
        var locality: String? = nil
    }
    private struct Response: Decodable {
        let protocol_version: Int
        let request_id: String
        let status: String
        let result: Result?
        struct Result: Decodable {
            let outcome: String?
            let context: MerchantContext?
            let version: String?
            let ddgs_version: String?
            let diagnostic: String?
        }
    }
    func shutdown() { idleShutdown?.cancel(); idleShutdown = nil; transport.invalidate() }
    private func call(_ request: Request) async throws -> Response.Result {
        idleShutdown?.cancel()
        defer {
            idleShutdown = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await self?.shutdown()
            }
        }
        let data = try await transport.send(JSONEncoder().encode(request), id: request.request_id, timeoutMS: request.timeout_ms)
        try Task.checkCancellation()
        guard data.count <= 65536 else { throw ClassifierBridgeError.invalidResponse }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.protocol_version == 1, response.request_id == request.request_id,
              response.status == "succeeded", let result = response.result else { throw ClassifierBridgeError.unavailable }
        return result
    }
    func handshake() async throws {
        let result = try await call(Request(operation: "search_handshake"))
        guard result.version == "merchant-search-v1", result.ddgs_version == "9.16.0" else { throw ClassifierBridgeError.invalidResponse }
    }
    func search(_ query: MerchantSearchQuery) async throws -> MerchantSearchEvidence {
        var request = Request(operation: "merchant_search")
        request.merchant = query.merchant; request.locality = query.locality
        let result = try await call(request)
        guard let outcome = result.outcome, ["matched", "no_match", "blocked", "unavailable"].contains(outcome),
              (outcome == "matched") == (result.context != nil) else { throw ClassifierBridgeError.invalidResponse }
        try result.context?.validate()
        return .init(query: query, outcome: outcome, context: result.context, diagnostic: result.diagnostic)
    }
}
