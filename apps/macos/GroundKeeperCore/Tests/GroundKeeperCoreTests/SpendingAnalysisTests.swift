import Foundation
import Testing
@testable import GroundKeeperCore

@Test func deterministicStatisticsHandleTiesFlatHistoryAndNoise() {
    let increasing = SpendingStatistics.monotonic((1...12).map(Double.init))
    #expect(increasing.tau == 1 && increasing.p < 0.0001)
    #expect(SpendingStatistics.monotonic((1...12).reversed().map(Double.init)).tau == -1)
    #expect(SpendingStatistics.monotonic(Array(repeating: 5, count: 12)).p == 1)
    #expect(abs(SpendingStatistics.monotonic([1, 9, 2, 8, 3, 7, 4, 6]).tau) < 0.3)
    #expect(SpendingStatistics.monotonic([1, 1, 2, 2, 3, 3, 4, 4]).p < 0.01)
    #expect(!SpendingStatistics.unusualHigh(5000, prior: Array(repeating: 1000, count: 7), minimum: 2500))
    #expect(!SpendingStatistics.unusualHigh(19000, prior: Array(repeating: 10000, count: 8), minimum: 2500))
    #expect(SpendingStatistics.unusualHigh(20000, prior: Array(repeating: 10000, count: 8), minimum: 2500))
    #expect(!SpendingStatistics.unusualHigh(4000, prior: [100, 500, 1000, 2000, 4000, 8000, 16000, 32000], minimum: 2500))
    #expect(SpendingStatistics.levelShift([100, 110, 90, 100, 1000, 1010, 990, 1000], minimum: 500, percent: 20) != nil)
    #expect(SpendingStatistics.levelShift([100, 1000, 100, 1000, 100, 1000, 100, 1000], minimum: 500, percent: 20) == nil)
}

private func analysisPurchase(_ store: LedgerStore, _ account: String, _ day: String, _ amount: Int64, name: String = "Fictional Cafe", type: String = "expense") async throws {
    try await store.save(TransactionEdit(description: name, amountMinor: type == "refund" ? amount : -amount, currency: "CAD", occurredOn: day,
                                        accountID: account, type: type, category: "dining", needsReview: false, notes: ""))
}

@Test func weeklyPatternsUseCompleteWeeksAndSuppressMissingCoverage() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Analysis", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    let calendar = try ReportCalendar(timezone: "America/Toronto")
    for i in 0..<12 { try await analysisPurchase(store, account, calendar.adding(i * 7, to: "2026-06-01"), Int64(i + 1) * 10000) }
    let filter = SpendingFilter(range: try ReportRange(start: "2026-06-01", end: "2026-08-24"), timezone: calendar.timezone)
    let report = try await store.spendingReport(filter, now: calendar.date("2026-08-26"))
    let pattern = try #require(report.findings.first { $0.kind == "weekly_trend" }?.pattern)
    #expect(pattern.values["weeks"] == 12 && pattern.values["tau"] == 1)
    #expect(report.findings.filter { $0.kind == "weekly_trend" }.count == 1) // Same evidence isn't repeated by merchant/category.
    let ids = try await store.testRows("SELECT * FROM insight_evidence")
    #expect(ids.count == 12)
    let missing = try #require(try await store.snapshot().transactions.first { $0.occurredOn == "2026-06-29" })
    try await store.delete(id: missing.id, revision: missing.revision)
    #expect(try await store.spendingReport(filter, now: calendar.date("2026-08-26")).findings.allSatisfy { $0.kind != "weekly_trend" && $0.kind != "weekly_shift" })
}

@Test func outlierUsesEarlierMerchantHistoryAndPersistsItsActualEvidenceWindow() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Analysis", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    for i in 1...8 { try await analysisPurchase(store, account, String(format: "2026-09-%02d", i), 1000) }
    try await analysisPurchase(store, account, "2026-10-01", 9000)
    try await analysisPurchase(store, account, "2026-10-02", 1000)
    try await analysisPurchase(store, account, "2026-10-03", 1000)
    try await analysisPurchase(store, account, "2026-10-03", 100000, name: "Other merchant")
    try await analysisPurchase(store, account, "2026-09-09", 50000, type: "refund")
    let filter = SpendingFilter(range: try ReportRange(start: "2026-10-01", end: "2026-10-05"), timezone: "UTC")
    let report = try await store.spendingReport(filter)
    let finding = try #require(report.findings.first { $0.kind == "merchant_outlier" })
    #expect(finding.pattern?.values["amount"] == 9000 && finding.pattern?.values["historyCount"] == 8)
    #expect(finding.pattern?.evidenceFilter.baseline?.end == "2026-10-01")
    let saved = try #require(try await store.testRows("SELECT * FROM insights WHERE kind='merchant_outlier'").first)
    #expect(saved.text("baseline_start_on") == "2026-07-03")
    #expect(try await store.testRows("SELECT * FROM insight_evidence WHERE insight_id='\(finding.id)'").count == 11)
    let repeated = try await store.spendingReport(filter)
    #expect(repeated.findings == report.findings)
    try await store.setFindingPreference(id: finding.id, dismissed: true)
    #expect(try await store.spendingReport(filter).findings.allSatisfy { $0.kind != "merchant_outlier" })
    try await store.restoreSpendingFindings()
    #expect(try await store.spendingReport(filter).findings.contains { $0.kind == "merchant_outlier" })
}

@Test func majorityDenominatorIncludesOtherMerchantsAndRefundsDoNotChangeShare() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Analysis", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    for _ in 0..<8 { try await analysisPurchase(store, account, "2026-10-01", 1000) }
    try await analysisPurchase(store, account, "2026-10-01", 1000, name: "Other A")
    try await analysisPurchase(store, account, "2026-10-01", 1000, name: "Other B")
    try await analysisPurchase(store, account, "2026-10-02", 8000, type: "refund")
    var filter = SpendingFilter(range: try ReportRange(start: "2026-10-01", end: "2026-10-05"), timezone: "UTC")
    let finding = try #require(try await store.spendingReport(filter).findings.first { $0.kind == "merchant_majority" })
    #expect(finding.pattern?.values["share"] == 0.8)
    #expect(try await store.testRows("SELECT * FROM insight_evidence WHERE insight_id='\(finding.id)'").count == 10)
    filter.merchantID = try await store.merchants().first { $0.name == "Fictional Cafe" }!.id
    #expect(try await store.spendingReport(filter).findings.allSatisfy { $0.kind != "merchant_majority" })
}

@Test func shiftsAndFrequencyChangesHaveSeparateComparableEvidence() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Analysis", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    let calendar = try ReportCalendar(timezone: "UTC")
    for i in 0..<8 { try await analysisPurchase(store, account, calendar.adding(i * 7, to: "2026-06-01"), i < 4 ? 1000 : 10000) }
    let filter = SpendingFilter(range: try ReportRange(start: "2026-06-01", end: "2026-07-27"), timezone: "UTC")
    let shift = try #require(try await store.spendingReport(filter, now: calendar.date("2026-08-01")).findings.first { $0.kind == "weekly_shift" })
    #expect(shift.pattern?.values["firstMedian"] == 1000 && shift.pattern?.values["lastMedian"] == 10000)
    #expect(shift.pattern?.evidenceFilter.baseline == nil)
    for _ in 0..<3 { try await analysisPurchase(store, account, "2026-09-01", 2000, name: "Frequency shop") }
    for _ in 0..<6 { try await analysisPurchase(store, account, "2026-10-01", 1000, name: "Frequency shop") }
    try await analysisPurchase(store, account, "2026-10-01", 2000, name: "Other shop")
    let compare = SpendingFilter(range: try ReportRange(start: "2026-10-01", end: "2026-10-05"), baseline: try ReportRange(start: "2026-09-01", end: "2026-09-05"), timezone: "UTC")
    let frequency = try #require(try await store.spendingReport(compare).findings.first { $0.kind == "merchant_change" })
    #expect(frequency.pattern?.values["currentGross"] == frequency.pattern?.values["previousGross"])
    #expect(frequency.pattern?.values["currentCount"] == 6 && frequency.pattern?.values["previousCount"] == 3)
    var overlap = compare; overlap.baseline = overlap.range
    #expect(try await store.spendingReport(overlap).findings.allSatisfy { $0.kind != "merchant_change" })
}
