import Foundation

extension LedgerStore {
    func refreshSpendingFindings(_ filter: SpendingFilter, totals: SpendingTotals, previous: SpendingTotals?,
                                 categories: [SpendingCategoryTotal], previousCategories: [SpendingCategoryTotal],
                                 firstDay: String?, revision: Int64, now: Date, patterns: [PatternCandidate] = []) throws -> [SpendingFinding] {
        let clock = Int64(now.timeIntervalSince1970 * 1000)
        let calendar = try ReportCalendar(timezone: filter.timezone, weekStart: filter.weekStart)
        // A dismissal follows a growing calendar period. A snooze follows the
        // rule and filters across rolling date windows until its expiry.
        var identity = filter
        identity.range = try ReportRange(start: filter.range.start, end: calendar.adding(1, to: filter.range.start))
        identity.baseline = try filter.baseline.map { try ReportRange(start: $0.start, end: calendar.adding(1, to: $0.start)) }
        identity.sensitivity = .balanced
        let scope = contentHash(Data(try json(identity).utf8))
        identity.range = try ReportRange(start: "2000-01-01", end: "2000-01-02"); identity.baseline = nil
        let snoozeScope = "spending-snooze:" + contentHash(Data(try json(identity).utf8))
        var candidates: [SpendingFinding] = []
        // History is observed coverage only. Suppress comparisons when known uncertainty
        // or unequal duration could produce an apparent change.
        if let previous, let baseline = filter.baseline, let firstDay, firstDay <= baseline.start,
           baseline.end <= filter.range.start, calendar.count(filter.range) == calendar.count(baseline),
           !totals.uncertain, !previous.uncertain, totals.purchases >= 3, previous.purchases >= 3 {
            func material(_ current: Int64, _ old: Int64) -> Bool {
                let change = Decimal(current) - Decimal(old)
                return old > 0 && abs(change) >= Decimal(filter.sensitivity.minimumMinor)
                    && abs(change) * 100 / Decimal(old) >= filter.sensitivity.minimumPercent
            }
            func add(_ kind: String, category: String? = nil, current: Int64, old: Int64, count: Int, oldCount: Int) {
                candidates.append(SpendingFinding(id: scope + ":" + kind + ":" + (category ?? "all"),
                                                  preferenceKey: snoozeScope + ":" + kind + ":" + (category ?? "all"), kind: kind, category: category,
                                                  current: current, previous: old, currentCount: count, previousCount: oldCount, revision: revision))
            }
            if material(totals.net, previous.net) {
                add("spending_change", current: totals.net, old: previous.net, count: totals.purchases, oldCount: previous.purchases)
            }
            let oldCategories = Dictionary(uniqueKeysWithValues: previousCategories.map { ($0.category, $0) })
            for category in categories where category.category != "none" {
                if let old = oldCategories[category.category], category.purchases >= 3, old.purchases >= 3, material(category.net, old.net) {
                    add("category_change", category: category.category, current: category.net, old: old.net, count: category.purchases, oldCount: old.purchases)
                }
            }
            // Frequency and ticket-size explanations use gross purchases, excluding refunds.
            if material(totals.gross, previous.gross), totals.purchases != previous.purchases {
                add("purchase_pattern", current: totals.gross, old: previous.gross, count: totals.purchases, oldCount: previous.purchases)
            }
        }
        candidates.sort {
            let left = abs(Decimal($0.current) - Decimal($0.previous)), right = abs(Decimal($1.current) - Decimal($1.previous))
            return left == right ? $0.id < $1.id : left > right
        }
        // Preserve established comparisons, reserving room for different pattern families.
        candidates = Array(candidates.prefix(patterns.isEmpty ? 5 : 2))
        candidates += patterns.prefix(6 - candidates.count).map { candidate in
            SpendingFinding(id: scope + ":" + candidate.key, preferenceKey: snoozeScope + ":" + candidate.key,
                            kind: candidate.kind, category: candidate.pattern.evidenceFilter.category,
                            current: 0, previous: 0, currentCount: 0, previousCount: 0, revision: revision, pattern: candidate.pattern)
        }
        return try db.transaction {
            try db.query("UPDATE insights SET state='stale' WHERE fingerprint LIKE ? AND state='current'", [.text(scope + ":%")])
            var visible: [SpendingFinding] = []
            for finding in candidates {
                let periods = finding.pattern?.evidenceFilter ?? filter
                let preference = try db.query("SELECT value_json FROM (SELECT settings_json AS value_json FROM insight_preferences WHERE id=?)", [.text(finding.id)]).first?.text("value_json")
                let preferenceData = preference.flatMap { $0.data(using: .utf8) }
                let hidden = preferenceData.flatMap { try? JSONDecoder().decode(FindingPreference.self, from: $0) }
                let snoozeJSON = try db.query("SELECT settings_json FROM insight_preferences WHERE id=?", [.text(finding.preferenceKey)]).first?.text("settings_json")
                let snooze = snoozeJSON.flatMap { try? JSONDecoder().decode(FindingPreference.self, from: Data($0.utf8)) }
                let until = snooze?.until ?? hidden?.until
                let state = hidden?.dismissed == true ? "dismissed" : (until ?? 0) > clock ? "snoozed" : "current"
                try db.query("""
                    INSERT INTO insights(id,fingerprint,kind,currency,period_start_on,period_end_on,timezone_id,baseline_start_on,baseline_end_on,
                      metrics_json,caveats_json,rule_version,data_revision,generated_at_ms,state,snoozed_until_ms)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET metrics_json=excluded.metrics_json,data_revision=excluded.data_revision,
                      rule_version=excluded.rule_version,generated_at_ms=excluded.generated_at_ms,state=excluded.state,snoozed_until_ms=excluded.snoozed_until_ms,
                      period_start_on=excluded.period_start_on,period_end_on=excluded.period_end_on,baseline_start_on=excluded.baseline_start_on,baseline_end_on=excluded.baseline_end_on
                    """, [.text(finding.id), .text(finding.id), .text(finding.kind), .text(filter.currency), .text(periods.range.start), .text(periods.range.end),
                           .text(filter.timezone), .optional(periods.baseline?.start), .optional(periods.baseline?.end), .text(try json(finding)),
                           .text("[\"Based on recorded transactions; account history may be incomplete.\"]"), .text(finding.pattern?.ruleVersion ?? "spending-v1"), .integer(revision), .integer(clock), .text(state), .optional(until)])
                try db.query("DELETE FROM insight_evidence WHERE insight_id=?", [.text(finding.id)])
                var evidenceFilter = finding.pattern?.evidenceFilter ?? filter
                if finding.pattern == nil {
                    if let category = finding.category { evidenceFilter.category = category }
                    evidenceFilter.purchasesOnly = finding.kind == "purchase_pattern"
                }
                for row in try reportEvidence(evidenceFilter) {
                    try db.query("INSERT INTO insight_evidence(insight_id,transaction_id,transaction_revision) VALUES (?,?,?)",
                                 [.text(finding.id), .text(row.text("transaction_id")), .integer(row.number("revision"))])
                }
                if state == "current" { visible.append(finding) }
            }
            return visible
        }
    }

    public func setFindingPreference(id: String, dismissed: Bool = false, snoozedUntil: Date? = nil) throws {
        guard let record = try db.query("SELECT metrics_json FROM insights WHERE id=?", [.text(id)]).first else { throw LedgerError.invalid("Refresh this finding first.") }
        let finding = try JSONDecoder().decode(SpendingFinding.self, from: Data(record.text("metrics_json").utf8))
        let preferenceID = snoozedUntil == nil ? id : finding.preferenceKey
        let preference = FindingPreference(dismissed: dismissed, until: snoozedUntil.map { Int64($0.timeIntervalSince1970 * 1000) })
        try db.transaction {
            try db.query("INSERT INTO insight_preferences(id,kind,settings_json,updated_at_ms) VALUES (?,'spending_visibility',?,?) ON CONFLICT(id) DO UPDATE SET settings_json=excluded.settings_json,updated_at_ms=excluded.updated_at_ms",
                         [.text(preferenceID), .text(try json(preference)), .integer(nowMS())])
            try db.query("UPDATE insights SET state=?,snoozed_until_ms=? WHERE id=?",
                         [.text(dismissed ? "dismissed" : snoozedUntil == nil ? "stale" : "snoozed"), .optional(preference.until), .text(id)])
        }
    }

    public func restoreSpendingFindings() throws {
        try db.transaction {
            try db.query("DELETE FROM insight_preferences WHERE kind='spending_visibility'")
            try db.query("UPDATE insights SET state='stale',snoozed_until_ms=NULL WHERE rule_version IN ('spending-v1','patterns-v1')")
        }
    }
}

private struct FindingPreference: Codable { let dismissed: Bool; let until: Int64? }
