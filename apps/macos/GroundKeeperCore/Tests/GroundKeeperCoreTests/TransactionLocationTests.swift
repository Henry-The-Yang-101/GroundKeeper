import Foundation
import Testing
@testable import GroundKeeperCore

@Test func capturedLocationFollowsLinkedPaymentAndSurvivesReplay() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    var payload = try #require(JSONSerialization.jsonObject(with: detailedCapture("location")) as? [String: Any])
    payload["location"] = ["latitude": 43.4723, "longitude": -80.5449, "horizontal_accuracy_m": 12, "label": "Fictional shop"]
    let data = try JSONSerialization.data(withJSONObject: payload)
    try await store.ingestCapture(data: data, deliveryPath: "location.json")
    let review = try #require(try await store.snapshot().reviews.first)
    let account = try #require(try await store.snapshot().accounts.first)
    try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: account.id)
    let transaction = try #require(try await store.transactionPage(.init()).transactions.first)
    #expect(transaction.location?.latitude == 43.4723)
    #expect(transaction.location?.accuracyMeters == 12)
    try await store.ingestCapture(data: data, deliveryPath: "replay.json")
    #expect(try await store.testRows("SELECT id FROM geotags").count == 1)
    #expect(try await store.integrityCheck())
}

@Test func invalidAndLegacyCaptureLocationsAreRejected() throws {
    var payload = try #require(JSONSerialization.jsonObject(with: detailedCapture("invalid-location")) as? [String: Any])
    for location in [["latitude": 91, "longitude": 0], ["latitude": 0, "longitude": -181], ["latitude": 0, "longitude": 0, "horizontal_accuracy_m": -1]] {
        payload["location"] = location
        #expect(throws: LedgerError.self) { try CaptureParser.decode(JSONSerialization.data(withJSONObject: payload)) }
    }
    payload["location"] = ["latitude": 0, "longitude": 0]
    #expect(try CaptureParser.decode(JSONSerialization.data(withJSONObject: payload)).location?.latitude == 0)
    payload["schema_version"] = 2
    #expect(throws: LedgerError.self) { try CaptureParser.decode(JSONSerialization.data(withJSONObject: payload)) }
}
