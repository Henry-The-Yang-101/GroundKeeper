import Foundation

extension LedgerStore {
    public func spendingRevision() throws -> Int64 { try db.query("SELECT revision FROM analytics_revision WHERE id=1").first!.number("revision") }

    public func spendingContext(timezone: String = TimeZone.current.identifier) throws -> SpendingContext {
        _ = try ReportCalendar(timezone: timezone)
        let first = try db.query("SELECT min(CASE WHEN time_precision='instant' THEN gk_report_day(occurred_at_ms,?) ELSE occurred_on END) AS day FROM transactions WHERE state='active'", [.text(timezone)]).first?["day"]?.string
        let tags = try db.query("SELECT id,name FROM tags ORDER BY name,id").map { ReportTag(id: $0.text("id"), name: $0.text("name")) }
        return SpendingContext(firstDay: first, tags: tags, revision: try spendingRevision())
    }

    /// One predicate is shared by summaries, charts, findings and paginated evidence.
    func reportSource(_ filter: SpendingFilter, range: ReportRange) throws -> (String, [SQLValue]) {
        let calendar = try ReportCalendar(timezone: filter.timezone, weekStart: filter.weekStart)
        _ = try ReportRange(start: range.start, end: range.end)
        guard ExactMoney.currencies.contains(filter.currency), calendar.count(range) <= 36600 else {
            throw LedgerError.invalid("Choose a supported currency and a range of at most 100 years.")
        }
        var bindings: [SQLValue] = [.text(filter.timezone), .text(filter.currency), .text(range.start), .text(range.end)]
        var predicates = ["currency=?", "day>=?", "day<?"]
        if let account = filter.accountID { predicates.append("account_id=?"); bindings.append(.text(account)) }
        if let merchant = filter.merchantID { predicates.append("coalesce(merchant_id,'')=?"); bindings.append(.text(merchant)) }
        if let category = filter.category { predicates.append("coalesce(category_id,'uncategorized')=?"); bindings.append(.text(category)) }
        if let tag = filter.tagID {
            predicates.append("(EXISTS(SELECT 1 FROM transaction_tags tt WHERE tt.transaction_id=dated.transaction_id AND tt.tag_id=?) OR EXISTS(SELECT 1 FROM part_tags pt WHERE pt.part_id=dated.part_id AND pt.tag_id=?))")
            bindings += [.text(tag), .text(tag)]
        }
        let lifecycle = filter.includePending ? "lifecycle IN ('posted','pending')" : "lifecycle='posted'"
        return ("""
            WITH dated AS (
              SELECT *,CASE WHEN time_precision='instant' THEN gk_report_day(occurred_at_ms,?) ELSE occurred_on END AS day,
                CASE WHEN type_code='expense' THEN abs(amount_minor) WHEN type_code='refund' THEN -abs(amount_minor) ELSE 0 END AS net,
                (needs_review=1 OR has_open_review=1 OR confirmed_at_ms IS NULL) AS unreviewed
              FROM current_transaction_parts
            ), scoped AS (SELECT * FROM dated WHERE \(predicates.joined(separator: " AND "))),
            included AS (SELECT * FROM scoped WHERE \(filter.purchasesOnly ? "type_code='expense'" : "type_code IN ('expense','refund')") AND \(lifecycle))
            """, bindings)
    }

    func reportTotals(_ filter: SpendingFilter, range: ReportRange) throws -> SpendingTotals {
        let (source, bindings) = try reportSource(filter, range: range)
        let r = try db.query(source + """
            SELECT coalesce(sum(CASE WHEN type_code='expense' THEN abs(amount_minor) ELSE 0 END),0) AS gross,
              coalesce(sum(CASE WHEN type_code='refund' THEN abs(amount_minor) ELSE 0 END),0) AS refunds,
              coalesce(sum(net),0) AS net, count(DISTINCT CASE WHEN type_code='expense' THEN transaction_id END) AS purchases,
              count(DISTINCT CASE WHEN unreviewed THEN transaction_id END) AS review_count,
              (SELECT count(DISTINCT transaction_id) FROM scoped WHERE lifecycle='pending' AND type_code IN ('expense','refund')) AS pending_count,
              (SELECT coalesce(sum(net),0) FROM scoped WHERE lifecycle='pending') AS pending_net,
              (SELECT count(DISTINCT transaction_id) FROM scoped WHERE (type_code='unknown' AND lifecycle IN ('pending','posted','unknown')) OR (lifecycle='unknown' AND type_code IN ('expense','refund'))) AS unknown_count
            FROM included
            """, bindings).first!
        return SpendingTotals(gross: r.number("gross"), refunds: r.number("refunds"), net: r.number("net"), purchases: Int(r.number("purchases")),
                              pendingCount: Int(r.number("pending_count")), reviewCount: Int(r.number("review_count")), unknownCount: Int(r.number("unknown_count")), pendingNet: r.number("pending_net"))
    }

    private func reportCategories(_ filter: SpendingFilter, range: ReportRange) throws -> [SpendingCategoryTotal] {
        let (source, bindings) = try reportSource(filter, range: range)
        return try db.query(source + """
            SELECT coalesce(category_id,'uncategorized') AS category,
              sum(CASE WHEN type_code='expense' THEN abs(amount_minor) ELSE 0 END) AS gross,
              sum(CASE WHEN type_code='refund' THEN abs(amount_minor) ELSE 0 END) AS refunds, sum(net) AS net,
              count(DISTINCT CASE WHEN type_code='expense' THEN transaction_id END) AS purchases,
              count(DISTINCT CASE WHEN unreviewed THEN transaction_id END) AS review_count
            FROM included GROUP BY coalesce(category_id,'uncategorized') ORDER BY net DESC,category
            """, bindings).map { SpendingCategoryTotal(category: $0.text("category"), gross: $0.number("gross"), refunds: $0.number("refunds"), net: $0.number("net"), purchases: Int($0.number("purchases")), reviewCount: Int($0.number("review_count"))) }
    }

    func reportBuckets(_ filter: SpendingFilter, range: ReportRange, unit: String) throws -> [SpendingBucket] {
        let (source, bindings) = try reportSource(filter, range: range)
        let calendar = try ReportCalendar(timezone: filter.timezone, weekStart: filter.weekStart)
        // Aggregate in SQL; only one compact row per observed day crosses the store boundary.
        let rows = try db.query(source + "SELECT day,sum(net) AS net,count(DISTINCT CASE WHEN type_code='expense' THEN transaction_id END) AS purchases FROM included GROUP BY day ORDER BY day", bindings)
        let days = Dictionary(uniqueKeysWithValues: rows.map { ($0.text("day"), $0) })
        var result: [SpendingBucket] = [], start = range.start, cumulative: Int64 = 0
        while start < range.end {
            var end: String
            if unit == "Monthly" {
                let month = calendar.calendar.dateInterval(of: .month, for: calendar.date(start))!.end
                end = min(calendar.day(month), range.end)
            } else if unit == "Weekly" {
                end = min(calendar.day(calendar.calendar.dateInterval(of: .weekOfYear, for: calendar.date(start))!.end), range.end)
            } else { end = calendar.adding(1, to: start) }
            var day = start, net: Int64 = 0, count = 0
            while day < end {
                let (sum, overflow) = net.addingReportingOverflow(days[day]?.number("net") ?? 0)
                guard !overflow else { throw LedgerError.invalid("Spending total is too large.") }
                net = sum; count += Int(days[day]?.number("purchases") ?? 0); day = calendar.adding(1, to: day)
            }
            let (sum, overflow) = cumulative.addingReportingOverflow(net)
            guard !overflow else { throw LedgerError.invalid("Spending total is too large.") }
            cumulative = sum
            result.append(SpendingBucket(start: start, end: end, net: net, cumulative: cumulative, purchases: count)); start = end
        }
        return result
    }

    public func spendingEntries(_ filter: SpendingFilter, offset: Int = 0, limit: Int = 100, largest: Bool = false) throws -> [SpendingEntry] {
        let (source, bindings) = try reportSource(filter, range: filter.range)
        return try db.query(source + """
            SELECT i.transaction_id,i.day,t.description,t.account_id,coalesce(ac.name,'Unassigned') AS account_name,sum(i.net) AS net,
              max(i.lifecycle='pending') AS pending,max(i.unreviewed) AS review
            FROM included i JOIN transactions t ON t.id=i.transaction_id LEFT JOIN accounts ac ON ac.id=t.account_id
            \(largest ? "WHERE i.type_code='expense'" : "")
            GROUP BY i.transaction_id,i.day,t.description,t.account_id,ac.name
            ORDER BY \(largest ? "net DESC" : "i.day DESC"),i.transaction_id LIMIT ? OFFSET ?
            """, bindings + [.integer(Int64(max(1, min(limit, 200)))), .integer(Int64(max(0, offset)))]).map {
                SpendingEntry(id: $0.text("transaction_id"), day: $0.text("day"), description: $0.text("description"), accountID: $0["account_id"]?.string, accountName: $0.text("account_name"), net: $0.number("net"), pending: $0.number("pending") == 1, needsReview: $0.number("review") == 1)
            }
    }

    public func spendingReport(_ filter: SpendingFilter, now: Date = Date()) throws -> SpendingReport {
        let calendar = try ReportCalendar(timezone: filter.timezone, weekStart: filter.weekStart)
        let context = try spendingContext(timezone: filter.timezone)
        let history = try db.query("SELECT min(CASE WHEN time_precision='instant' THEN gk_report_day(occurred_at_ms,?) ELSE occurred_on END) AS day FROM transactions WHERE state='active' AND currency=?" + (filter.accountID == nil ? "" : " AND account_id=?"),
                                   [.text(filter.timezone), .text(filter.currency)] + (filter.accountID.map { [.text($0)] } ?? [])).first?["day"]?.string
        let totals = try reportTotals(filter, range: filter.range)
        let previous = try filter.baseline.map { try reportTotals(filter, range: $0) }
        let categories = try reportCategories(filter, range: filter.range)
        let previousCategories = try filter.baseline.map { try reportCategories(filter, range: $0) } ?? []
        let days = calendar.count(filter.range)
        let unit = days > 180 ? "Monthly" : days > 45 ? "Weekly" : "Daily"
        let buckets = try reportBuckets(filter, range: filter.range, unit: unit)
        let merchants = try reportMerchants(filter, range: filter.range)
        let previousMerchants = try filter.baseline.map { try reportMerchants(filter, range: $0) } ?? []
        let patterns = try spendingPatterns(filter, totals: totals, previous: previous, merchants: merchants,
                                           oldMerchants: previousMerchants, categories: categories, firstDay: history, now: now)
        let findings = try refreshSpendingFindings(filter, totals: totals, previous: previous, categories: categories,
                                                  previousCategories: previousCategories, firstDay: history, revision: context.revision, now: now, patterns: patterns)
        return SpendingReport(filter: filter, totals: totals, previous: previous,
                              buckets: buckets,
                              previousBuckets: try filter.baseline.map { try reportBuckets(filter, range: $0, unit: unit) } ?? [],
                              categories: categories, previousCategories: previousCategories,
                              categoryBuckets: try reportCategoryBuckets(filter, buckets: buckets),
                              largest: try spendingEntries(filter, limit: 5, largest: true), findings: findings,
                              firstDay: history, revision: context.revision, merchants: merchants,
                              previousMerchants: previousMerchants, generatedAt: now, bucketUnit: unit)
    }

    private func reportCategoryBuckets(_ filter: SpendingFilter, buckets: [SpendingBucket]) throws -> [SpendingCategoryBucket] {
        let (source, bindings) = try reportSource(filter, range: filter.range)
        let rows = try db.query(source + "SELECT day,coalesce(category_id,'uncategorized') AS category,sum(net) AS net FROM included GROUP BY day,coalesce(category_id,'uncategorized') ORDER BY day", bindings)
        var totals: [String: Int64] = [:], metadata: [String: (SpendingBucket, String)] = [:]
        var index = 0
        for row in rows {
            while index < buckets.count && row.text("day") >= buckets[index].end { index += 1 }
            guard index < buckets.count else { break }
            let bucket = buckets[index], category = row.text("category"), key = bucket.start + ":" + category
            let (sum, overflow) = (totals[key] ?? 0).addingReportingOverflow(row.number("net"))
            guard !overflow else { throw LedgerError.invalid("Spending total is too large.") }
            totals[key] = sum; metadata[key] = (bucket, category)
        }
        return totals.keys.sorted().map { key in
            let (bucket, category) = metadata[key]!
            return SpendingCategoryBucket(start: bucket.start, end: bucket.end, category: category, net: totals[key]!)
        }
    }

    func reportEvidence(_ filter: SpendingFilter) throws -> [Row] {
        var evidence: [String: Row] = [:]
        for range in [filter.range, filter.baseline].compactMap({ $0 }) {
            let (source, bindings) = try reportSource(filter, range: range)
            for row in try db.query(source + "SELECT DISTINCT transaction_id,revision FROM included", bindings) { evidence[row.text("transaction_id")] = row }
        }
        return Array(evidence.values)
    }
}
