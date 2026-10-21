import Foundation
import Testing
@testable import GroundKeeperCore

private func reportFilter(_ start: String = "2026-10-01", _ end: String = "2026-11-01", baseline: ReportRange? = nil) throws -> SpendingFilter {
    SpendingFilter(range: try ReportRange(start: start, end: end), baseline: baseline, timezone: "America/Toronto")
}
private func purchase(_ store: LedgerStore, account: String, day: String, amount: Int64 = -1000, category: String = "dining", type: String = "expense", review: Bool = false) async throws {
    try await store.save(TransactionEdit(description: "Fictional purchase", amountMinor: amount, currency: "CAD", occurredOn: day,
                                          accountID: account, type: type, category: ["expense", "refund", "unknown"].contains(type) ? category : nil, needsReview: review, notes: ""))
}

@Test func reportsUseWholeLedgerAndExcludeNonspending() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Reports", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    for _ in 0..<510 { try await purchase(store, account: account, day: "2026-10-10", amount: -101) }
    try await purchase(store, account: account, day: "2026-10-11", amount: 500, type: "refund")
    try await purchase(store, account: account, day: "2026-10-11", amount: -99900, type: "card_payment")
    try await purchase(store, account: account, day: "2026-11-01", amount: -9900)
    try await store.addAccount(name: "USD", currency: "USD")
    let usd = try await store.snapshot().accounts.first { $0.currency == "USD" }!.id
    try await store.save(TransactionEdit(description: "USD purchase", amountMinor: -90000, currency: "USD", occurredOn: "2026-10-10", accountID: usd, type: "expense", category: "dining", needsReview: false, notes: ""))
    let filter = try reportFilter(), report = try await store.spendingReport(filter)
    #expect(report.totals.gross == 51510)
    #expect(report.totals.net == 51010)
    #expect(report.totals.purchases == 510)
    #expect(report.categories.reduce(0) { $0 + $1.net } == report.totals.net)
    #expect(report.buckets.reduce(0) { $0 + $1.net } == report.totals.net)
    #expect(report.buckets.last?.cumulative == report.totals.net)
    #expect(report.categoryBuckets.reduce(0) { $0 + $1.net } == report.totals.net)
    var evidence: [SpendingEntry] = []
    for offset in stride(from: 0, to: 600, by: 100) { evidence += try await store.spendingEntries(filter, offset: offset) }
    #expect(evidence.count == 511)
    #expect(evidence.reduce(0) { $0 + $1.net } == report.totals.net)
    #expect(Set(evidence.map(\.id)).count == evidence.count)
}

@Test func reportCalendarHandlesShortMonthsDSTAndCivilDates() throws {
    let calendar = try ReportCalendar(timezone: "America/Toronto")
    let now = calendar.date("2026-03-31")
    let (month, baseline) = try calendar.ranges(.month, now: now)
    #expect(month.start == "2026-03-01" && month.end == "2026-04-01")
    #expect(baseline?.start == "2026-02-01" && baseline?.end == "2026-03-01")
    #expect(calendar.count(try ReportRange(start: "2026-03-07", end: "2026-03-10")) == 3)
    let (week, _) = try calendar.ranges(.week, now: calendar.date("2026-10-21"))
    #expect(week.start == "2026-10-19" && week.end == "2026-10-22")
    let (year, _) = try calendar.ranges(.lastYear, now: calendar.date("2025-02-01"))
    #expect(calendar.count(year) == 366)
    #expect(try calendar.yearEarlier(ReportRange(start: "2024-02-29", end: "2024-03-01")) == ReportRange(start: "2023-02-28", end: "2023-03-01"))
}

@Test func pendingUncertaintyAndKnownInstantsStayVisible() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Reports", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    try await purchase(store, account: account, day: "2026-10-01", amount: -1000)
    let id = try await store.snapshot().transactions[0].id
    _ = try await store.testRows("UPDATE transactions SET lifecycle='pending' WHERE id='\(id)'")
    let pending = try await store.spendingReport(reportFilter())
    #expect(pending.totals.pendingCount == 1 && pending.totals.net == 1000)
    var postedOnly = try reportFilter(); postedOnly.includePending = false
    #expect(try await store.spendingReport(postedOnly).totals.net == 0)
    #expect(try await store.spendingReport(postedOnly).totals.pendingCount == 1)
    // 01:00 UTC Oct 1 is September 30 in Toronto. Unknown/date-only dates never shift.
    let ms = Int64(ISO8601DateFormatter().date(from: "2026-10-01T01:00:00Z")!.timeIntervalSince1970 * 1000)
    _ = try await store.testRows("UPDATE transactions SET lifecycle='posted',time_precision='instant',occurred_at_ms=\(ms),utc_offset_minutes=0 WHERE id='\(id)'")
    #expect(try await store.spendingReport(reportFilter()).totals.net == 0)
    #expect(try await store.spendingReport(reportFilter("2026-09-01", "2026-10-01")).totals.net == 1000)
    try await purchase(store, account: account, day: "2026-10-02", amount: -5000, category: "uncategorized", type: "unknown", review: true)
    let unresolved = try await store.spendingReport(reportFilter())
    #expect(unresolved.totals.net == 0 && unresolved.totals.unknownCount == 1)
    #expect(unresolved.findings.isEmpty)
}

@Test func reportMoneyOverflowFailsAndNegativeRefundDaysRemainExact() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Reports", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    try await purchase(store, account: account, day: "2026-10-01", amount: 1200, type: "refund")
    let refund = try await store.spendingReport(reportFilter())
    #expect(refund.totals.net == -1200 && refund.buckets[0].net == -1200)
    var purchasesOnly = try reportFilter(); purchasesOnly.purchasesOnly = true
    #expect(try await store.spendingEntries(purchasesOnly).isEmpty)
    try await purchase(store, account: account, day: "2026-10-02", amount: -(Int64.max - 1))
    try await purchase(store, account: account, day: "2026-10-03", amount: -2)
    await #expect(throws: (any Error).self) { try await store.spendingReport(reportFilter()) }
}

@Test func findingsPersistEvidenceAndDismissalsAcrossCorrectionsAndReopen() async throws {
    let (store, url) = try vault()
    try await store.addAccount(name: "Reports", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    for day in ["2026-09-01", "2026-09-02", "2026-09-03"] { try await purchase(store, account: account, day: day) }
    for day in ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"] { try await purchase(store, account: account, day: day, amount: -3000) }
    let filter = try reportFilter("2026-10-01", "2026-10-05", baseline: ReportRange(start: "2026-09-01", end: "2026-09-05"))
    let report = try await store.spendingReport(filter)
    #expect(report.findings.count == 3)
    #expect(try await store.testRows("SELECT * FROM insight_evidence").count == 21)
    let finding = try #require(report.findings.first)
    try await store.setFindingPreference(id: finding.id, dismissed: true)
    #expect(try await store.spendingReport(filter).findings.count == 2)
    var growing = filter
    growing.range = try ReportRange(start: "2026-10-01", end: "2026-10-06")
    growing.baseline = try ReportRange(start: "2026-09-01", end: "2026-09-06")
    #expect(try await store.spendingReport(growing).findings.allSatisfy { $0.id != finding.id })
    try await purchase(store, account: account, day: "2026-10-04", amount: -5000)
    #expect(try await store.testRows("SELECT * FROM insights WHERE state='current'").isEmpty)
    #expect(try await store.spendingReport(filter).findings.allSatisfy { $0.id != finding.id })
    await store.close()
    let reopened = try LedgerStore(url: url)
    #expect(try await reopened.spendingReport(filter).findings.allSatisfy { $0.id != finding.id })
    try await reopened.restoreSpendingFindings()
    #expect(try await reopened.spendingReport(filter).findings.count == 3)
    let now = Date()
    try await reopened.setFindingPreference(id: finding.id, snoozedUntil: now.addingTimeInterval(60))
    #expect(try await reopened.spendingReport(filter, now: now).findings.count == 2)
    var moving = filter
    moving.range = try ReportRange(start: "2026-10-02", end: "2026-10-06")
    moving.baseline = try ReportRange(start: "2026-09-01", end: "2026-09-05")
    #expect(try await reopened.spendingReport(moving, now: now).findings.allSatisfy { $0.preferenceKey != finding.preferenceKey })
    #expect(try await reopened.spendingReport(filter, now: now.addingTimeInterval(61)).findings.count == 3)
    // Review flags suppress confident findings, even when amounts have not changed.
    let transaction = try await reopened.snapshot().transactions[0]
    try await reopened.save(TransactionEdit(id: transaction.id, revision: transaction.revision, description: transaction.description,
                                            amountMinor: transaction.amountMinor, currency: "CAD", occurredOn: transaction.occurredOn, accountID: account,
                                            type: "expense", category: "dining", needsReview: true, notes: ""))
    #expect(try await reopened.spendingReport(filter).findings.isEmpty)
}

@Test func splitsAndTagsDoNotMultiplyPurchases() async throws {
    let (store, _) = try vault()
    try await store.addAccount(name: "Reports", currency: "CAD")
    let account = try await store.snapshot().accounts[0].id
    try await purchase(store, account: account, day: "2026-10-02", amount: -10000)
    let transaction = try await store.snapshot().transactions[0]
    try await store.splitReportFixture(transaction)
    let report = try await store.spendingReport(reportFilter())
    #expect(report.totals.purchases == 1 && report.totals.net == 10000)
    #expect(report.categories.count == 2)
    var groceries = try reportFilter(); groceries.category = "groceries"; groceries.tagID = "report-tag"
    #expect(try await store.spendingReport(groceries).totals.net == 6000)
    #expect(try await store.spendingEntries(groceries).first?.net == 6000)
}

extension LedgerStore {
    fileprivate func splitReportFixture(_ transaction: LedgerTransaction) throws {
        try db.transaction {
            try db.query("UPDATE transactions SET state='draft' WHERE id=?", [.text(transaction.id)])
            try db.query("UPDATE transaction_parts SET amount_minor=-4000 WHERE id=?", [.text(transaction.partID)])
            let part = identifier()
            try db.query("INSERT INTO transaction_parts(id,transaction_id,position,amount_minor) VALUES (?,?,1,-6000)", [.text(part), .text(transaction.id)])
            try assign(partID: part, type: "expense", category: "groceries", review: false, origin: "user", runID: nil)
            try db.query("UPDATE transactions SET state='active' WHERE id=?", [.text(transaction.id)])
            try db.query("INSERT INTO tags(id,name) VALUES ('report-tag','Trip')")
            try db.query("INSERT INTO transaction_tags VALUES (?,'report-tag')", [.text(transaction.id)])
            try db.query("INSERT INTO part_tags VALUES (?,'report-tag')", [.text(part)])
        }
    }
}
