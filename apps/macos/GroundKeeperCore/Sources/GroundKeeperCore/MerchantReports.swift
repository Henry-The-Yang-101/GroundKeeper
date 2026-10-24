import Foundation

public struct SpendingMerchantTotal: Identifiable, Codable, Sendable, Equatable {
    public var id: String { merchantID }
    public let merchantID: String
    public let name: String
    public let gross: Int64
    public let refunds: Int64
    public let net: Int64
    public let purchases: Int
    public let activeDays: Int
    public let reviewCount: Int
    public let firstDay: String?
    public let lastDay: String?
    public var averagePurchase: Decimal { purchases == 0 ? 0 : Decimal(gross) / Decimal(purchases) / 100 }
    public func purchasesPerWeek(in range: ReportRange, calendar: ReportCalendar) -> Double {
        Double(purchases) * 7 / Double(max(1, calendar.count(range)))
    }
    public func averageGap(calendar: ReportCalendar) -> Double? {
        guard purchases > 1, let firstDay, let lastDay else { return nil }
        if firstDay == lastDay { return 0 }
        guard let range = try? ReportRange(start: firstDay, end: lastDay) else { return nil }
        return Double(calendar.count(range)) / Double(purchases - 1)
    }
}

extension LedgerStore {
    func reportMerchants(_ filter: SpendingFilter, range: ReportRange) throws -> [SpendingMerchantTotal] {
        let (source, bindings) = try reportSource(filter, range: range)
        return try db.query(source + """
            SELECT coalesce(i.merchant_id,'') AS merchant_id,coalesce(m.name,'Unassigned merchant') AS name,
              sum(CASE WHEN type_code='expense' THEN abs(amount_minor) ELSE 0 END) AS gross,
              sum(CASE WHEN type_code='refund' THEN abs(amount_minor) ELSE 0 END) AS refunds,sum(net) AS net,
              count(DISTINCT CASE WHEN type_code='expense' THEN transaction_id END) AS purchases,
              count(DISTINCT CASE WHEN type_code='expense' THEN day END) AS days,
              count(DISTINCT CASE WHEN unreviewed THEN transaction_id END) AS reviews,
              min(CASE WHEN type_code='expense' THEN day END) AS first_day,
              max(CASE WHEN type_code='expense' THEN day END) AS last_day
            FROM included i LEFT JOIN merchants m ON m.id=i.merchant_id
            GROUP BY coalesce(i.merchant_id,'') ORDER BY net DESC,merchant_id
            """, bindings).map {
                SpendingMerchantTotal(merchantID: $0.text("merchant_id"), name: $0.text("name"), gross: $0.number("gross"),
                                      refunds: $0.number("refunds"), net: $0.number("net"), purchases: Int($0.number("purchases")),
                                      activeDays: Int($0.number("days")), reviewCount: Int($0.number("reviews")),
                                      firstDay: $0["first_day"]?.string, lastDay: $0["last_day"]?.string)
            }
    }
}
