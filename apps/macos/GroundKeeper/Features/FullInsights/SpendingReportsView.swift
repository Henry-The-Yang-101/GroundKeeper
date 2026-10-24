import SwiftUI
import GroundKeeperCore

enum ReportFormat {
    static func money(_ minor: Int64, _ currency: String) -> String { (Decimal(minor) / 100).formatted(.currency(code: currency)) }
    static func category(_ code: String) -> String { SpendingCategory.allCases.first { $0.code == code }?.rawValue ?? "Uncategorized" }
    static func range(_ range: ReportRange, timezone: String) -> String {
        guard let calendar = try? ReportCalendar(timezone: timezone) else { return "" }
        var format = Date.FormatStyle(date: .abbreviated, time: .omitted)
        format.timeZone = calendar.calendar.timeZone
        return calendar.date(range.start).formatted(format) + " – " + calendar.date(calendar.adding(-1, to: range.end)).formatted(format)
    }
    static func change(_ current: Int64, _ previous: Int64, currency: String) -> String {
        let delta = Decimal(current) - Decimal(previous)
        let amount = (abs(delta) / 100).formatted(.currency(code: currency))
        if delta == 0 { return "Unchanged" }
        let direction = delta > 0 ? "more" : "less"
        guard previous > 0 else { return "\(amount) \(direction) · no positive baseline" }
        let percent = (abs(delta) / Decimal(previous) * 100).formatted(.number.precision(.fractionLength(0...1)))
        return "\(amount) \(direction) (\(percent)%)"
    }
}

struct ReportDrilldown: Identifiable {
    let id = UUID()
    let title: String
    var filter: SpendingFilter
}

struct SpendingReportsView: View {
    @Environment(AppWorkspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("reportCurrency", store: AppPreferences.defaults) private var currency = "CAD"
    @AppStorage("reportTimezone", store: AppPreferences.defaults) private var timezone = TimeZone.current.identifier
    @AppStorage("reportWeekStart", store: AppPreferences.defaults) private var weekStart = 2
    @AppStorage("reportPending", store: AppPreferences.defaults) private var includePending = true
    @AppStorage("insightSensitivity", store: AppPreferences.defaults) private var sensitivity = InsightSensitivity.balanced
    @State private var period = ReportPeriod.month
    @State private var comparison = "Previous period"
    @State private var accountID = ""
    @State private var category = ""
    @State private var tagID = ""
    @State private var merchantID: String?
    @State private var merchantChoices: [Merchant] = []
    @State private var manageMerchants = false
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -29, to: Date())!
    @State private var customEnd = Date()
    @State private var report: SpendingReport?
    @State private var tags: [ReportTag] = []
    @State private var error: String?
    @State private var loading = false
    @State private var refresh = 0
    @State private var drilldown: ReportDrilldown?
    @State private var lastSelectionKey = ""
    @State private var showAllFindings = false

    private var selectionKey: String {
        [period.rawValue, comparison, currency, timezone, String(weekStart), String(includePending), sensitivity.rawValue,
         accountID, category, tagID, merchantID ?? "all", String(customStart.timeIntervalSince1970), String(customEnd.timeIntervalSince1970)].joined(separator: "|")
    }
    private var loadKey: String { selectionKey + "|\(workspace.reportingRevision)|\(workspace.ready)|\(refresh)" }
    var body: some View {
        ScrollViewReader { scroll in
            reportPage(scroll: scroll)
        }
        .task(id: loadKey) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh += 1 }
        .sheet(isPresented: $manageMerchants) { MerchantManagementSheet().environment(workspace).vaultSheet() }
        .sheet(item: $drilldown) { ReportTransactionsSheet(drilldown: $0).environment(workspace).vaultSheet() }
        .onChange(of: workspace.ready) { if !workspace.ready { report = nil; drilldown = nil; tags = []; merchantChoices = []; manageMerchants = false; merchantID = nil } }
    }

    private func reportPage(scroll: ScrollViewProxy) -> some View {
        PageContent {
            PageHeading(title: "Spending", subtitle: "See where it goes, and what’s changing.")
            controls
            if loading {
                ProgressView("Calculating spending…").frame(maxWidth: .infinity, minHeight: 160)
            } else if let error {
                UnavailableFeature(title: "Report unavailable", symbol: "chart.bar.xaxis", description: error)
                Button("Try again") { refresh += 1 }
            } else if let report {
                ReportSummary(report: report) { drilldown = ReportDrilldown(title: "Recorded spending", filter: report.filter) }
                if report.totals.purchases == 0 && report.totals.refunds == 0 {
                    UnavailableFeature(title: "No spending in this view", symbol: "chart.bar.xaxis",
                                       description: "Try another period or adjust the filters." + (report.totals.uncertain ? " Check the coverage note above for entries that may affect these totals." : ""))
                } else {
                    SpendingDashboardLayout(allowsColumns: !dynamicTypeSize.isAccessibilitySize) {
                        Surface { ReportTrendChart(report: report, open: openReport) }
                            .reportColumn(0)
                        Surface { findings(report) }
                            .reportColumn(1)
                        Surface { ReportPurchaseFrequency(report: report, open: openReport) }
                            .reportColumn(1)
                        Surface { ReportCategoryChart(report: report, open: openReport) }
                            .reportColumn(0)
                        if report.previous != nil {
                            Surface { ReportComparison(report: report, open: openReport) }
                                .reportColumn(1)
                        }
                        Surface {
                            ReportMerchants(report: report, select: { merchantID = $0 }, manage: { manageMerchants = true }, pageSize: 5,
                                            pageChanged: { scroll.scrollTo("report-merchants", anchor: .top) })
                        }
                            .id("report-merchants")
                            .reportColumn(0)
                        Surface { largest(report) }
                            .reportColumn(1)
                    }
                }
                Text("Updated \(report.generatedAt.formatted(date: .omitted, time: .shortened)) · \(timezone) · \(currency). Recorded transactions may not cover every purchase.")
                    .font(.caption).foregroundStyle(AppStyle.muted)
            }
        }
    }

    private func openReport(_ filter: SpendingFilter, _ title: String) {
        drilldown = ReportDrilldown(title: title, filter: filter)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { periodPicker; currencyPicker; Spacer(minLength: 0); refreshButton }
                VStack(alignment: .leading, spacing: 12) { periodPicker; HStack { currencyPicker; Spacer(); refreshButton } }
            }
            if period == .custom {
                ViewThatFits(in: .horizontal) {
                    HStack { startPicker; endPicker }
                    VStack(alignment: .leading) { startPicker; endPicker }
                }
            }
            DisclosureGroup("Filters & reporting preferences") {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .leading)], alignment: .leading, spacing: 12) {
                        AlignedFormField(title: "Account") {
                            Picker("Account", selection: $accountID) {
                                Text("All accounts").tag("")
                                ForEach(workspace.accounts.filter { $0.currency == currency }) { Text($0.displayName(in: workspace.accounts)).tag($0.id) }
                            }
                        }
                        AlignedFormField(title: "Category") {
                            Picker("Category", selection: $category) {
                                Text("All categories").tag("")
                                ForEach(SpendingCategory.allCases) { Text($0.rawValue).tag($0.code) }
                            }
                        }
                        AlignedFormField(title: "Merchant") {
                            Picker("Merchant", selection: $merchantID) {
                                Text("All merchants").tag(String?.none)
                                Text("Unassigned merchant").tag(String?.some(""))
                                ForEach(merchantChoices) { Text($0.name).tag(String?.some($0.id)) }
                            }
                        }
                        if !tags.isEmpty {
                            AlignedFormField(title: "Tag") {
                                Picker("Tag", selection: $tagID) { Text("All tags").tag(""); ForEach(tags) { Text($0.name).tag($0.id) } }
                            }
                        }
                        AlignedFormField(title: "Week starts") {
                            Picker("Week starts", selection: $weekStart) { Text("Monday").tag(2); Text("Sunday").tag(1) }
                        }
                        AlignedFormField(title: "Compare with") {
                            Picker("Compare with", selection: $comparison) {
                                Text("Previous period").tag("Previous period"); Text("Year earlier").tag("Year earlier"); Text("No comparison").tag("None")
                            }
                        }
                        AlignedFormField(title: "Time zone") {
                            Picker("Time zone", selection: $timezone) {
                                ForEach(Array(Set([TimeZone.current.identifier, timezone, "America/Toronto", "America/Vancouver", "America/Edmonton", "America/Winnipeg", "America/Halifax", "America/St_Johns", "UTC"])).sorted(), id: \.self) { Text($0).tag($0) }
                            }
                        }
                        AlignedFormField(title: "Findings") {
                            Picker("Findings", selection: $sensitivity) { ForEach(InsightSensitivity.allCases) { Text($0.rawValue).tag($0) } }
                        }
                    }
                    Toggle("Include pending purchases", isOn: $includePending)
                    HStack {
                        Button("Clear filters", action: clearFilters)
                            .disabled(accountID.isEmpty && category.isEmpty && tagID.isEmpty && merchantID == nil)
                        Button("Merchant names & groups") { manageMerchants = true }
                        Button("Restore hidden findings") {
                            Task { do { try await workspace.restoreFindings(); refresh += 1 } catch { self.error = error.localizedDescription } }
                        }
                    }.buttonStyle(.borderless)
                }.padding(.top, 12)
            }.foregroundStyle(AppStyle.text)
            if !accountID.isEmpty || !category.isEmpty || !tagID.isEmpty || merchantID != nil {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text([workspace.accounts.first { $0.id == accountID }?.name, category.isEmpty ? nil : ReportFormat.category(category), tags.first { $0.id == tagID }?.name, merchantID.map { id in id.isEmpty ? "Unassigned merchant" : merchantChoices.first { $0.id == id }?.name ?? "Merchant" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(AppStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Clear filters", action: clearFilters).buttonStyle(.borderless).fixedSize()
                }
            }
        }
        .onChange(of: currency) { accountID = "" }
    }
    private func clearFilters() { accountID = ""; category = ""; tagID = ""; merchantID = nil }
    private var periodPicker: some View { Picker("Period", selection: $period) { ForEach(ReportPeriod.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 260) }
    private var currencyPicker: some View { Picker("Currency", selection: $currency) { ForEach(ExactMoney.currencies, id: \.self) { Text($0).tag($0) } }.frame(width: 145) }
    private var refreshButton: some View { Button { refresh += 1 } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(loading) }
    private var startPicker: some View { DatePicker("From", selection: $customStart, in: ...Date(), displayedComponents: .date).environment(\.timeZone, TimeZone(identifier: timezone) ?? .current) }
    private var endPicker: some View { DatePicker("Through", selection: $customEnd, in: ...Date(), displayedComponents: .date).environment(\.timeZone, TimeZone(identifier: timezone) ?? .current) }

    private func load() async {
        if lastSelectionKey != selectionKey { report = nil }
        error = nil; loading = report == nil
        do {
            let calendar = try ReportCalendar(timezone: timezone, weekStart: weekStart)
            let context = try await workspace.spendingContext(timezone: timezone)
            let custom = period == .custom ? try ReportRange(start: calendar.day(customStart), end: calendar.adding(1, to: calendar.day(customEnd))) : nil
            let ranges = try calendar.ranges(period, firstDay: context.firstDay, custom: custom)
            let baseline = comparison == "None" || period == .all ? nil : comparison == "Year earlier" ? try calendar.yearEarlier(ranges.0) : ranges.1
            var filter = SpendingFilter(range: ranges.0, baseline: baseline, currency: currency,
                                        accountID: accountID.isEmpty ? nil : accountID, category: category.isEmpty ? nil : category,
                                        tagID: tagID.isEmpty ? nil : tagID, includePending: includePending, timezone: timezone, weekStart: weekStart)
            filter.sensitivity = sensitivity; filter.merchantID = merchantID
            let directory = try await workspace.merchantDirectory()
            let result = try await workspace.spendingReport(filter)
            try Task.checkCancellation()
            tags = context.tags; merchantChoices = directory.merchants; report = result; lastSelectionKey = selectionKey; loading = false
        } catch is CancellationError { return }
        catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription; loading = false }
    }

    private func findings(_ report: SpendingReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(title: "What changed")
                if !report.findings.isEmpty {
                    Text("\(report.findings.count) \(report.findings.count == 1 ? "finding" : "findings")").font(.caption).foregroundStyle(AppStyle.muted).fixedSize()
                }
            }
            Text("Calculated on this Mac").font(.caption).foregroundStyle(AppStyle.muted)
            if report.findings.isEmpty {
                Text("No new findings for this view. Patterns require reviewed data and enough comparable history: at least three purchases per comparison period, eight complete weeks for trends, or eight earlier purchases for an unusual amount. Hidden findings stay hidden.")
                    .foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(report.findings.prefix(showAllFindings ? report.findings.count : 2))) { finding in
                ReportFindingRow(finding: finding, filter: report.filter, open: { filter, title in
                    drilldown = ReportDrilldown(title: title, filter: filter)
                }, hide: { snooze in
                    Task {
                        do { try await workspace.hideFinding(finding.id, snooze: snooze); self.report?.findings.removeAll { $0.id == finding.id } }
                        catch { self.error = error.localizedDescription }
                    }
                })
                if finding.id != report.findings.prefix(showAllFindings ? report.findings.count : 2).last?.id { Divider() }
            }
            if report.findings.count > 2 {
                Button(showAllFindings ? "Show fewer findings" : "Show \(report.findings.count - 2) more \(report.findings.count == 3 ? "finding" : "findings")") {
                    showAllFindings.toggle()
                }.buttonStyle(.borderless)
            }
        }
    }

    private func largest(_ report: SpendingReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Largest purchases", detail: report.filter.currency)
            ForEach(report.largest) { entry in ReportEntryRow(entry: entry, currency: report.filter.currency) }
            Button("View all matching transactions") { drilldown = ReportDrilldown(title: "Recorded spending", filter: report.filter) }.buttonStyle(.borderless)
        }
    }
}

struct ReportSummary: View {
    let report: SpendingReport
    var open: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(ReportFormat.range(report.filter.range, timezone: report.filter.timezone)).font(.callout).foregroundStyle(AppStyle.muted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 20) {
                Metric(label: "Net spending", value: ReportFormat.money(report.totals.net, report.filter.currency))
                Metric(label: "Purchases", value: "\(report.totals.purchases)")
                Metric(label: "Daily average", value: dailyAverage)
                Metric(label: "Average purchase", value: report.totals.averagePurchase.formatted(.currency(code: report.filter.currency)))
            }
            ViewThatFits(in: .horizontal) {
                HStack { grossAndRefunds; Spacer(); if let open { Button("View transactions", action: open).buttonStyle(.borderless) } }
                VStack(alignment: .leading, spacing: 8) { grossAndRefunds; if let open { Button("View transactions", action: open).buttonStyle(.borderless) } }
            }
            if report.totals.uncertain {
                Label(coverage, systemImage: "info.circle").font(.callout).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var grossAndRefunds: some View {
        Text("Purchases \(ReportFormat.money(report.totals.gross, report.filter.currency)) · Refunds \(ReportFormat.money(report.totals.refunds, report.filter.currency))")
            .font(.caption).foregroundStyle(AppStyle.muted)
    }
    private var dailyAverage: String {
        let days = (try? ReportCalendar(timezone: report.filter.timezone).count(report.filter.range)) ?? 1
        return (Decimal(report.totals.net) / 100 / Decimal(max(1, days))).formatted(.currency(code: report.filter.currency))
    }
    private var coverage: String {
        var parts: [String] = []
        if report.totals.pendingCount > 0 { parts.append("\(report.totals.pendingCount) pending, net \(ReportFormat.money(report.totals.pendingNet, report.filter.currency)) (\(report.filter.includePending ? "included" : "excluded"))") }
        if report.totals.reviewCount > 0 { parts.append("\(report.totals.reviewCount) included \(report.totals.reviewCount == 1 ? "entry needs" : "entries need") review") }
        if report.totals.unknownCount > 0 { parts.append("\(report.totals.unknownCount) \(report.totals.unknownCount == 1 ? "entry" : "entries") with unknown type or payment status excluded") }
        return parts.joined(separator: "; ") + ". Totals may change after review."
    }
}
