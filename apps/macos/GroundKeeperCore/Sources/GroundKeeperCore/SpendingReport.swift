import Foundation

public struct ReportRange: Codable, Equatable, Sendable {
    public let start: String
    public let end: String // Exclusive civil date.
    public init(start: String, end: String) throws {
        self.start = try CivilDate.parse(start); self.end = try CivilDate.parse(end)
        guard start < end else { throw LedgerError.invalid("Choose an end date after the start date.") }
    }
}

public enum ReportPeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "Today", week = "This week", month = "This month", quarter = "This quarter", year = "This year"
    case lastMonth = "Last month", lastYear = "Last year", days7 = "Last 7 days", days30 = "Last 30 days", days90 = "Last 90 days"
    case all = "All time", custom = "Custom"
    public var id: Self { self }
}

/// Civil dates stay civil dates. Only known instants are converted to the reporting zone.
public struct ReportCalendar: Sendable {
    public let timezone: String
    public let weekStart: Int
    public var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timezone)!
        value.firstWeekday = weekStart; value.minimumDaysInFirstWeek = 1
        return value
    }
    public init(timezone: String = TimeZone.current.identifier, weekStart: Int = 2) throws {
        guard TimeZone(identifier: timezone) != nil, (1...7).contains(weekStart) else { throw LedgerError.invalid("Invalid reporting calendar.") }
        self.timezone = timezone; self.weekStart = weekStart
    }
    public func day(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public func date(_ day: String) -> Date {
        let p = day.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }
    public func adding(_ days: Int, to day: String) -> String { self.day(calendar.date(byAdding: .day, value: days, to: date(day))!) }
    public func count(_ range: ReportRange) -> Int { calendar.dateComponents([.day], from: date(range.start), to: date(range.end)).day! }
    public func yearEarlier(_ range: ReportRange) throws -> ReportRange {
        try ReportRange(start: day(calendar.date(byAdding: .year, value: -1, to: date(range.start))!),
                        end: day(calendar.date(byAdding: .year, value: -1, to: date(range.end))!))
    }
    public func ranges(_ period: ReportPeriod, now: Date = Date(), firstDay: String? = nil, custom: ReportRange? = nil) throws -> (ReportRange, ReportRange?) {
        let today = calendar.startOfDay(for: now), tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        var start = today, end = tomorrow
        var component: Calendar.Component?
        var offset = -1
        switch period {
        case .today: break
        case .week: component = .weekOfYear
        case .month, .lastMonth: component = .month
        case .quarter: component = .month; offset = -3
        case .year, .lastYear: component = .year
        case .days7: start = calendar.date(byAdding: .day, value: -6, to: today)!
        case .days30: start = calendar.date(byAdding: .day, value: -29, to: today)!
        case .days90: start = calendar.date(byAdding: .day, value: -89, to: today)!
        case .all: start = firstDay.map(date) ?? today
        case .custom:
            guard let custom else { throw LedgerError.invalid("Choose a custom date range.") }
            start = date(custom.start); end = date(custom.end)
        }
        if let component {
            start = calendar.dateInterval(of: component, for: today)!.start
            if period == .quarter {
                let month = calendar.component(.month, from: today)
                start = calendar.date(byAdding: .month, value: -((month - 1) % 3), to: start)!
            }
            if period == .lastMonth || period == .lastYear {
                end = start; start = calendar.date(byAdding: component, value: -1, to: start)!
            }
        }
        let current = try ReportRange(start: day(start), end: day(end))
        guard period != .all else { return (current, nil) }
        let baselineStart = component.map { calendar.date(byAdding: $0, value: offset, to: start)! }
            ?? calendar.date(byAdding: .day, value: -count(current), to: start)!
        let baselineEnd: Date
        if period == .lastMonth || period == .lastYear { baselineEnd = start }
        else { baselineEnd = min(start, calendar.date(byAdding: .day, value: count(current), to: baselineStart)!) }
        return (current, try ReportRange(start: day(baselineStart), end: day(baselineEnd)))
    }
}

public struct SpendingFilter: Codable, Equatable, Sendable {
    public var range: ReportRange
    public var baseline: ReportRange?
    public var currency: String
    public var accountID: String?
    public var category: String?
    public var tagID: String?
    public var includePending: Bool
    public var timezone: String
    public var weekStart: Int
    public var sensitivity: InsightSensitivity = .balanced
    public var purchasesOnly = false
    public var merchantID: String? = nil // Empty string selects unassigned merchants.
    public init(range: ReportRange, baseline: ReportRange? = nil, currency: String = "CAD", accountID: String? = nil,
                category: String? = nil, tagID: String? = nil, includePending: Bool = true,
                timezone: String = TimeZone.current.identifier, weekStart: Int = 2) {
        self.range = range; self.baseline = baseline; self.currency = currency; self.accountID = accountID
        self.category = category; self.tagID = tagID; self.includePending = includePending; self.timezone = timezone; self.weekStart = weekStart
    }
}

public enum InsightSensitivity: String, CaseIterable, Identifiable, Codable, Sendable {
    case sensitive = "More findings", balanced = "Balanced", significant = "Larger changes"
    public var id: Self { self }
    var minimumMinor: Int64 { switch self { case .sensitive: 1000; case .balanced: 2500; case .significant: 5000 } }
    var minimumPercent: Decimal { switch self { case .sensitive: 10; case .balanced: 20; case .significant: 30 } }
}

public struct SpendingTotals: Codable, Equatable, Sendable {
    public let gross: Int64
    public let refunds: Int64
    public let net: Int64
    public let purchases: Int
    public let pendingCount: Int
    public let reviewCount: Int
    public let unknownCount: Int
    public let pendingNet: Int64
    public var averagePurchase: Decimal { purchases == 0 ? 0 : Decimal(gross) / Decimal(purchases) / 100 }
    public var uncertain: Bool { pendingCount > 0 || reviewCount > 0 || unknownCount > 0 }
}

public struct SpendingBucket: Identifiable, Equatable, Sendable {
    public var id: String { start }
    public let start: String
    public let end: String
    public let net: Int64
    public let cumulative: Int64
    public let purchases: Int
}

public struct SpendingCategoryTotal: Identifiable, Codable, Equatable, Sendable {
    public var id: String { category }
    public let category: String
    public let gross: Int64
    public let refunds: Int64
    public let net: Int64
    public let purchases: Int
    public let reviewCount: Int
}

public struct SpendingCategoryBucket: Identifiable, Equatable, Sendable {
    public var id: String { start + ":" + category }
    public let start: String
    public let end: String
    public let category: String
    public let net: Int64
}

public struct SpendingEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let day: String
    public let description: String
    public let net: Int64
    public let pending: Bool
    public let needsReview: Bool
}

public struct SpendingFinding: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let preferenceKey: String
    public let kind: String
    public let category: String?
    public let current: Int64
    public let previous: Int64
    public let currentCount: Int
    public let previousCount: Int
    public let revision: Int64
}

public struct SpendingReport: Sendable {
    public let filter: SpendingFilter
    public let totals: SpendingTotals
    public let previous: SpendingTotals?
    public let buckets: [SpendingBucket]
    public let previousBuckets: [SpendingBucket]
    public let categories: [SpendingCategoryTotal]
    public let previousCategories: [SpendingCategoryTotal]
    public let categoryBuckets: [SpendingCategoryBucket]
    public let largest: [SpendingEntry]
    public var findings: [SpendingFinding]
    public let firstDay: String?
    public let revision: Int64
    public var merchants: [SpendingMerchantTotal] = []
    public var previousMerchants: [SpendingMerchantTotal] = []
    public let generatedAt: Date
    public let bucketUnit: String
}

public struct ReportTag: Identifiable, Sendable { public let id: String; public let name: String }
public struct SpendingContext: Sendable { public let firstDay: String?; public let tags: [ReportTag]; public let revision: Int64 }
