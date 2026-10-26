import Foundation
import Testing
@testable import GroundKeeperCore

@Test func capturedLocationFollowsLinkedPaymentAndSurvivesReplay() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    var payload = try #require(JSONSerialization.jsonObject(with: detailedCapture("location")) as? [String: Any])
    payload["location"] = ["latitude": 43.4723, "longitude": -80.5449, "horizontal_accuracy_m": 12, "label": "Fictional shop", "measured_at": "2026-10-26T09:30:01-04:00"]
    payload["location_status"] = "available"
    let data = try JSONSerialization.data(withJSONObject: payload)
    try await store.ingestCapture(data: data, deliveryPath: "location.json")
    let review = try #require(try await store.snapshot().reviews.first)
    let account = try #require(try await store.snapshot().accounts.first)
    try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: account.id)
    let transaction = try #require(try await store.transactionPage(.init()).transactions.first)
    #expect(transaction.location?.latitude == 43.4723)
    #expect(transaction.location?.accuracyMeters == 12)
    #expect(transaction.location?.measuredAtMS == (try CaptureParser.timestamp("2026-10-26T09:30:01-04:00")).0)
    #expect(transaction.location?.origin == "phone_capture")
    #expect(try await store.testRows("SELECT location_status FROM raw_events").first?.text("location_status") == "available")
    try await store.ingestCapture(data: data, deliveryPath: "replay.json")
    #expect(try await store.testRows("SELECT id FROM geotags").count == 1)
    let model = try await receiptModel(store)
    try await store.enqueueClassifications(modelID: model)
    #expect(try await store.claimClassification(modelID: model) != nil)
    let run = try #require(try await store.testRows("SELECT input_json FROM classification_runs").first)
    let input = try #require(JSONSerialization.jsonObject(with: Data(run.text("input_json").utf8)) as? [String: Any])
    #expect(input["location"] == nil && input["location_status"] == nil)
    #expect(!run.text("input_json").contains("43.4723"))
    #expect(try await store.integrityCheck())
}

@Test(arguments: ["not_requested", "denied", "unavailable", "timeout"])
func capturesWithoutLocationStillCreatePayments(status: String) async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    var payload = try #require(JSONSerialization.jsonObject(with: detailedCapture("no-location-" + status)) as? [String: Any])
    payload["location_status"] = status
    payload["location"] = NSNull()
    try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: payload), deliveryPath: status + ".json")
    let review = try #require(try await store.snapshot().reviews.first)
    let account = try #require(try await store.snapshot().accounts.first)
    try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: account.id)
    #expect(try await store.transactionPage(.init()).transactions.count == 1)
    #expect(try await store.testRows("SELECT location_status FROM raw_events").first?.text("location_status") == status)
    #expect(try await store.testRows("SELECT id FROM geotags").isEmpty)
    #expect(try await store.testRows("SELECT state FROM queue_items").first?.text("state") == "imported")
}

@Test func locationStatusDefaultsRemainCompatibleAndContradictionsAreRejected() throws {
    var payload = try #require(JSONSerialization.jsonObject(with: detailedCapture("status")) as? [String: Any])
    #expect(try CaptureParser.decode(JSONSerialization.data(withJSONObject: payload)).resolvedLocationStatus == "not_requested")
    payload["location_status"] = "available"
    #expect(throws: LedgerError.self) { try CaptureParser.decode(JSONSerialization.data(withJSONObject: payload)) }
    payload["location"] = ["latitude": 0, "longitude": 0]
    for status in ["not_requested", "denied", "unavailable", "timeout", "unknown"] {
        payload["location_status"] = status
        #expect(throws: LedgerError.self) { try CaptureParser.decode(JSONSerialization.data(withJSONObject: payload)) }
    }
    payload.removeValue(forKey: "location_status")
    #expect(try CaptureParser.decode(JSONSerialization.data(withJSONObject: payload)).resolvedLocationStatus == "available")
}

@Test func legacyLocationStatusIsInferredAndMeasurementFallsBackToCaptureTime() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    var payload = try #require(JSONSerialization.jsonObject(with: detailedCapture("legacy-location")) as? [String: Any])
    payload["location"] = ["latitude": 0, "longitude": 0]
    try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: payload), deliveryPath: "legacy.json")
    let review = try #require(try await store.snapshot().reviews.first)
    let account = try #require(try await store.snapshot().accounts.first)
    try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: account.id)
    let location = try #require(try await store.transactionPage(.init()).transactions.first?.location)
    #expect(location.latitude == 0 && location.longitude == 0)
    let capturedAt = try #require(payload["captured_at"] as? String)
    #expect(location.measuredAtMS == (try CaptureParser.timestamp(capturedAt)).0)
    #expect(try await store.testRows("SELECT location_status FROM raw_events").first?.text("location_status") == "available")
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

@Test(arguments: [true, false])
func linkedCaptureLocationsPreferWalletToLaterBankAlert(walletFirst: Bool) async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Fixture", currency: "CAD")
    for wallet in (walletFirst ? [true, false] : [false, true]) {
        var payload = try #require(JSONSerialization.jsonObject(with: detailedCapture(wallet ? "wallet-geo" : "bank-geo", wallet: wallet)) as? [String: Any])
        payload["location"] = ["latitude": wallet ? 43.4723 : 44, "longitude": wallet ? -80.5449 : -81,
                               "measured_at": wallet ? "2026-10-17T10:00:01-04:00" : "2026-10-17T10:01:01-04:00"]
        if !wallet { payload["captured_at"] = "2026-10-17T10:01:00-04:00" }
        try await store.ingestCapture(data: JSONSerialization.data(withJSONObject: payload), deliveryPath: wallet ? "wallet.json" : "bank.json")
        let snapshot = try await store.snapshot()
        let review = try #require(snapshot.reviews.first { $0.reason == "account_mapping_required" })
        let account = try #require(snapshot.accounts.first)
        try await store.confirmMapping(sourceID: review.sourceID, label: review.label, accountID: account.id)
    }
    let page = try await store.transactionPage(.init())
    #expect(page.transactions.count == 1)
    #expect(page.transactions.first?.location?.latitude == 43.4723)
    #expect(try await store.testRows("SELECT id FROM geotags").count == 2)
}
