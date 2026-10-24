import Foundation

/// A reproducible fact, not generated prose. Values are in minor currency units or counts.
public struct SpendingPattern: Codable, Equatable, Sendable {
    public let ruleVersion: String
    public let title: String
    public let detail: String
    public let method: String
    public let values: [String: Double]
    public let score: Double
    public let evidenceFilter: SpendingFilter
}

struct PatternCandidate {
    let key: String
    let kind: String
    let pattern: SpendingPattern
}

/// Pure statistical building blocks. Money aggregation stays exact in SQL; only detection uses Double.
enum SpendingStatistics {
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), n = sorted.count
        guard n > 0 else { return 0 }
        return n.isMultiple(of: 2) ? sorted[n / 2 - 1] / 2 + sorted[n / 2] / 2 : sorted[n / 2]
    }
    static func mad(_ values: [Double]) -> Double {
        let center = median(values)
        return median(values.map { abs($0 - center) })
    }
    /// Tie-corrected Mann–Kendall test with continuity correction. Not a forecast.
    static func monotonic(_ values: [Double]) -> (tau: Double, p: Double) {
        guard values.count >= 3 else { return (0, 1) }
        var s = 0.0
        for i in 0..<(values.count - 1) {
            for j in (i + 1)..<values.count { s += values[j] > values[i] ? 1 : values[j] < values[i] ? -1 : 0 }
        }
        let n = Double(values.count)
        let ties = Dictionary(grouping: values, by: { $0 }).values.reduce(0.0) {
            let t = Double($1.count); return $0 + t * (t - 1) * (2 * t + 5)
        }
        let variance = (n * (n - 1) * (2 * n + 5) - ties) / 18
        guard variance > 0 else { return (0, 1) }
        let z = max(0, abs(s) - 1) / sqrt(variance)
        return (s / (n * (n - 1) / 2), erfc(z / sqrt(2)))
    }
    static func unusualHigh(_ value: Double, prior: [Double], minimum: Double) -> Bool {
        guard prior.count >= 8 else { return false }
        let center = median(prior), deviation = mad(prior)
        guard value - center >= minimum, value > (prior.max() ?? 0) else { return false }
        // Flat histories have no estimated scale: require a doubling plus the absolute threshold.
        if deviation == 0 { return value >= max(center * 2, center + minimum) }
        return 0.67448975 * (value - center) / deviation >= 3.5
    }
    static func levelShift(_ values: [Double], minimum: Double, percent: Double) -> (Double, Double)? {
        guard values.count >= 8 else { return nil }
        let old = Array(values.suffix(8).prefix(4)), recent = Array(values.suffix(4))
        let a = median(old), b = median(recent), change = abs(b - a)
        guard a > 0, change >= minimum, change / a * 100 >= percent else { return nil }
        // Fixed adjacent windows, no search for the most flattering split. Every recent
        // observation must lie beyond the old window, with a gap larger than typical noise.
        let gap = b > a ? recent.min()! - old.max()! : old.min()! - recent.max()!
        guard gap > max(mad(old), mad(recent)) * 2, gap > 0 else { return nil }
        return (a, b)
    }
}

extension LedgerStore {
    /// Bounded subspace enumeration → eligibility → detectors → comparable ranking → templates.
    func spendingPatterns(_ filter: SpendingFilter, totals: SpendingTotals, previous: SpendingTotals?,
                          merchants: [SpendingMerchantTotal], oldMerchants: [SpendingMerchantTotal],
                          categories: [SpendingCategoryTotal], firstDay: String?, now: Date) throws -> [PatternCandidate] {
        guard !totals.uncertain, totals.purchases >= 3 else { return [] }
        let calendar = try ReportCalendar(timezone: filter.timezone, weekStart: filter.weekStart)
        let minimum = Double(filter.sensitivity.minimumMinor)
        let percent = NSDecimalNumber(decimal: filter.sensitivity.minimumPercent).doubleValue
        func money(_ value: Double) -> String { (value / 100).formatted(.currency(code: filter.currency).locale(Locale(identifier: "en_CA"))) }
        func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_CA"))) }
        var results: [PatternCandidate] = []
        func add(_ kind: String, key: String, title: String, detail: String, method: String, values: [String: Double], quality: Double, share: Double, evidence: SpendingFilter) {
            results.append(PatternCandidate(key: kind + ":" + key, kind: kind, pattern: SpendingPattern(
                ruleVersion: "patterns-v1", title: title, detail: detail, method: method, values: values,
                score: 0.8 * min(1, max(0, quality)) + 0.2 * min(1, max(0, share)), evidenceFilter: evidence)))
        }
        let assigned = merchants.filter { !$0.merchantID.isEmpty && $0.purchases > 0 }
        if filter.merchantID == nil, assigned.count >= 3, totals.purchases >= 10, totals.gross > 0,
           let leader = assigned.sorted(by: { $0.gross == $1.gross ? $0.id < $1.id : $0.gross > $1.gross }).first {
            let share = Double(leader.gross) / Double(totals.gross)
            if share > 0.6 && share < 1 {
                var evidence = filter; evidence.baseline = nil; evidence.purchasesOnly = true
                add("merchant_majority", key: leader.id, title: "Most purchase spending was at \(leader.name)",
                    detail: "\(money(Double(leader.gross))) across \(leader.purchases) purchases: \(number(share * 100))% of recorded purchase spending in this view, before refunds.",
                    method: "Gross purchase share above 60%; at least 3 identified merchants and 10 purchases. Supporting transactions include the denominator.",
                    values: ["share": share, "gross": Double(leader.gross), "totalGross": Double(totals.gross), "count": Double(leader.purchases)], quality: share, share: share, evidence: evidence)
            }
        }
        if let baseline = filter.baseline, let previous, !previous.uncertain, let firstDay, firstDay <= baseline.start,
           baseline.end <= filter.range.start, calendar.count(baseline) == calendar.count(filter.range), merchants.count > 1 {
            let old = Dictionary(uniqueKeysWithValues: oldMerchants.map { ($0.id, $0) })
            for merchant in assigned.prefix(12) {
                guard let prior = old[merchant.id], merchant.purchases >= 3, prior.purchases >= 3, prior.gross > 0 else { continue }
                let change = abs(Double(merchant.gross) - Double(prior.gross))
                let frequencyChanged = abs(merchant.purchases - prior.purchases) >= 3 && Double(abs(merchant.purchases - prior.purchases)) / Double(prior.purchases) >= 0.3
                guard (change >= minimum && change / Double(prior.gross) * 100 >= percent) || frequencyChanged else { continue }
                var evidence = filter; evidence.merchantID = merchant.id; evidence.purchasesOnly = true
                add("merchant_change", key: merchant.id, title: "Purchases at \(merchant.name) changed",
                    detail: "\(merchant.purchases) purchases averaging \(money(Double(merchant.gross) / Double(merchant.purchases))), versus \(prior.purchases) averaging \(money(Double(prior.gross) / Double(prior.purchases))) in the previous equal-length period. Purchase totals were \(money(Double(merchant.gross))) and \(money(Double(prior.gross))), before refunds.",
                    method: "Equal-length, nonoverlapping periods; at least 3 reviewed purchases per period. Frequency and average amount are observations, not causes.",
                    values: ["currentCount": Double(merchant.purchases), "previousCount": Double(prior.purchases), "currentGross": Double(merchant.gross), "previousGross": Double(prior.gross)],
                    quality: 0.75, share: Double(merchant.gross) / Double(max(1, totals.gross)), evidence: evidence)
            }
        }
        var scopes: [(String, String, SpendingFilter, Double)] = [("all", "Recorded purchases", filter, 1)]
        if filter.merchantID == nil {
            for merchant in assigned.prefix(8) where merchant.purchases != totals.purchases || merchant.gross != totals.gross {
                var scope = filter; scope.merchantID = merchant.id
                scopes.append(("merchant:" + merchant.id, merchant.name, scope, Double(merchant.gross) / Double(max(1, totals.gross))))
            }
        }
        if filter.category == nil {
            for category in categories.filter({ $0.category != "uncategorized" && $0.purchases >= 8 && ($0.purchases != totals.purchases || $0.gross != totals.gross) }).prefix(6) {
                var scope = filter; scope.category = category.category
                scopes.append(("category:" + category.category, category.category.capitalized, scope, Double(category.gross) / Double(max(1, totals.gross))))
            }
        }
        // Only complete civil weeks inside the selected range, ending before the current week.
        let week = calendar.calendar.dateInterval(of: .weekOfYear, for: calendar.date(filter.range.start))!
        let start = calendar.day(week.start) == filter.range.start ? filter.range.start : calendar.day(week.end)
        let last = min(filter.range.end, calendar.day(calendar.calendar.dateInterval(of: .weekOfYear, for: now)!.start))
        if start < last {
            let end = calendar.day(calendar.calendar.dateInterval(of: .weekOfYear, for: calendar.date(last))!.start)
            if start < end {
                let range = try ReportRange(start: max(start, calendar.adding(-364, to: end)), end: end)
                for (key, name, scope, share) in scopes where calendar.count(range) >= 56 {
                    var evidence = scope; evidence.range = range; evidence.baseline = nil; evidence.purchasesOnly = true
                    let buckets = try reportBuckets(evidence, range: range, unit: "Weekly")
                    // No inferred zero-activity weeks: absent purchases may mean absent imports.
                    guard buckets.count >= 8, buckets.allSatisfy({ $0.purchases > 0 && calendar.adding(7, to: $0.start) == $0.end }) else { continue }
                    for counts in [false, true] {
                        let values = buckets.map { counts ? Double($0.purchases) : Double($0.net) }
                        let test = SpendingStatistics.monotonic(values)
                        let half = values.count / 2
                        let a = SpendingStatistics.median(Array(values.prefix(half))), b = SpendingStatistics.median(Array(values.suffix(half)))
                        let threshold = counts ? 2.0 : minimum
                        let format: (Double) -> String = counts ? number : money
                        let measure = counts ? "purchase frequency" : "purchase spending"
                        if a > 0, abs(b - a) >= threshold, abs(b - a) / a * 100 >= percent,
                           abs(test.tau) >= 0.65, test.p < 0.01 / Double(scopes.count * 2) {
                            add("weekly_trend", key: key + (counts ? ":count" : ":amount"), title: "\(name): weekly \(measure) trended \(test.tau > 0 ? "up" : "down")",
                                detail: "Across \(values.count) complete weeks (\(range.start) to \(calendar.adding(-1, to: range.end))), the median weekly \(counts ? "count" : "amount") was \(format(a)) in the first half and \(format(b)) in the last half. Based on recorded purchases before refunds; this does not predict future spending.",
                                method: "Tie-corrected Mann–Kendall, |tau| ≥ 0.65, p < 0.01 / tested series; material median change. Serial dependence and missing imports can affect the pattern; no confidence claim.",
                                values: ["firstMedian": a, "lastMedian": b, "weeks": Double(values.count), "tau": test.tau, "p": test.p, "counts": counts ? 1 : 0], quality: abs(test.tau), share: share, evidence: evidence)
                        } else if let (a, b) = SpendingStatistics.levelShift(values, minimum: threshold, percent: percent) {
                            evidence.range = try ReportRange(start: buckets[buckets.count - 8].start, end: range.end)
                            add("weekly_shift", key: key + (counts ? ":count" : ":amount"), title: "\(name): weekly \(measure) moved to a \(b > a ? "higher" : "lower") level",
                                detail: "The last four complete weeks had a median of \(format(b)) per week, versus \(format(a)) in the four before them. Every recent week was \(b > a ? "above" : "below") every earlier week. The newer window begins \(buckets[buckets.count - 4].start); this is an observed level shift, not an exact change date.",
                                method: "Fixed 4-week windows; nonoverlapping value ranges, gap > 2 × either median absolute deviation, and material change. Descriptive rule, not a statistical confidence estimate.",
                                values: ["firstMedian": a, "lastMedian": b, "weeks": 8, "counts": counts ? 1 : 0], quality: 0.85, share: share, evidence: evidence)
                        }
                    }
                }
            }
        }
        // Compare the largest selected purchase with an earlier, nonoverlapping 90-day history.
        // Per-merchant only: a grocery purchase is not compared with rent or airfare.
        if filter.category == nil, filter.tagID == nil {
            let priorRange = try ReportRange(start: calendar.adding(-90, to: filter.range.start), end: filter.range.start)
            for merchant in assigned.prefix(8) {
                var scope = filter; scope.merchantID = merchant.id; scope.purchasesOnly = true
                guard !(try reportTotals(scope, range: priorRange)).uncertain else { continue }
                let (source, bindings) = try reportSource(scope, range: priorRange)
                let rows = try db.query(source + "SELECT transaction_id,sum(net) AS amount FROM included GROUP BY transaction_id ORDER BY transaction_id LIMIT 2001", bindings)
                guard (8...2000).contains(rows.count), let largest = try spendingEntries(scope, limit: 1, largest: true).first else { continue }
                let prior = rows.map { Double($0.number("amount")) }
                guard SpendingStatistics.unusualHigh(Double(largest.net), prior: prior, minimum: minimum) else { continue }
                scope.baseline = priorRange
                let median = SpendingStatistics.median(prior)
                add("merchant_outlier", key: merchant.id, title: "An unusually large purchase at \(merchant.name)",
                    detail: "The \(money(Double(largest.net))) purchase on \(largest.day) was larger than all \(prior.count) recorded purchases in the preceding 90-day comparison window, whose median was \(money(median)). This flags an amount to inspect; it does not establish an error or fraud.",
                    method: "Prior-only merchant baseline (8–2,000 purchases), modified MAD score ≥ 3.5 and material difference. Zero MAD requires at least twice the median. No inference about what was purchased.",
                    values: ["amount": Double(largest.net), "median": median, "historyCount": Double(prior.count)], quality: 0.9, share: Double(largest.net) / Double(max(1, totals.gross)), evidence: scope)
            }
        }
        // Stable ordering and one amount/count pattern per scope keep the feed varied.
        results.sort { $0.pattern.score == $1.pattern.score ? $0.key < $1.key : $0.pattern.score > $1.pattern.score }
        var seen: Set<String> = []
        return results.filter {
            let family = $0.key.replacingOccurrences(of: ":count", with: ":series").replacingOccurrences(of: ":amount", with: ":series")
            return seen.insert(family).inserted
        }
    }
}
