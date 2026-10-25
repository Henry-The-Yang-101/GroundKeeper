import Charts
import SwiftUI
import GroundKeeperCore

/// Report ranges end at the next midnight, so automatic ticks can repeat one date.
@AxisContentBuilder
func reportDateAxis(range: ReportRange, calendar: ReportCalendar, desiredCount: Int = 5) -> some AxisContent {
    if calendar.count(range) == 1 {
        AxisMarks(values: [calendar.date(range.start)]) { _ in
            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
        }
    } else {
        AxisMarks(values: .automatic(desiredCount: desiredCount)) { _ in
            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
        }
    }
}

struct ReportTrendChart: View {
    let report: SpendingReport
    let open: (SpendingFilter, String) -> Void
    @State private var mode = "Histogram"
    @State private var selectedDay: Date?
    private var calendar: ReportCalendar { try! ReportCalendar(timezone: report.filter.timezone, weekStart: report.filter.weekStart) }
    private var selected: SpendingBucket? {
        guard let selectedDay else { return nil }
        let day = calendar.day(selectedDay)
        return report.buckets.first { $0.start <= day && day < $0.end }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Spending over time", detail: "\(report.bucketUnit) · \(report.filter.currency)")
            Picker("Chart view", selection: $mode) {
                Text("Histogram").tag("Histogram"); Text("Cumulative").tag("Cumulative"); Text("Table").tag("Table")
            }.pickerStyle(.segmented).labelsHidden().tint(AppStyle.controlAccent).frame(maxWidth: 320)
            if mode == "Table" {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(report.buckets) { bucket in
                            Button { openBucket(bucket) } label: {
                                HStack {
                                    Text(calendar.date(bucket.start), format: .dateTime.month(.abbreviated).day().year())
                                    Spacer()
                                    Text("\(bucket.purchases) \(bucket.purchases == 1 ? "purchase" : "purchases")").foregroundStyle(AppStyle.muted)
                                    Text(ReportFormat.money(bucket.net, report.filter.currency)).monospacedDigit().frame(minWidth: 95, alignment: .trailing)
                                }.padding(.vertical, 10).contentShape(Rectangle())
                            }.buttonStyle(VaultRowButtonStyle())
                        }
                    }
                }.frame(maxHeight: 300)
            } else {
                Chart {
                    ForEach(report.buckets) { bucket in
                        if mode == "Cumulative" {
                            LineMark(x: .value("Date", calendar.date(bucket.start)), y: .value("Cumulative spending", Double(bucket.cumulative) / 100))
                                .foregroundStyle(AppStyle.accent)
                                .accessibilityLabel(bucket.start)
                                .accessibilityValue(ReportFormat.money(bucket.cumulative, report.filter.currency))
                        } else {
                            BarMark(x: .value("Date", calendar.date(bucket.start), unit: report.bucketUnit == "Monthly" ? .month : report.bucketUnit == "Weekly" ? .weekOfYear : .day),
                                    y: .value("Net spending", Double(bucket.net) / 100), width: .ratio(0.9))
                                .foregroundStyle(AppStyle.accent.opacity(selected == nil || selected?.id == bucket.id ? 0.85 : 0.35))
                                .accessibilityLabel(bucket.start)
                                .accessibilityValue("\(ReportFormat.money(bucket.net, report.filter.currency)), \(bucket.purchases) \(bucket.purchases == 1 ? "purchase" : "purchases")")
                        }
                    }
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(AppStyle.muted.opacity(0.3))
                    if let selected {
                        RuleMark(x: .value("Selected date", calendar.date(selected.start))).foregroundStyle(AppStyle.muted.opacity(0.4))
                    }
                }
                .chartXScale(domain: calendar.date(report.filter.range.start)...calendar.date(report.filter.range.end))
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis { reportDateAxis(range: report.filter.range, calendar: calendar) }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartXSelection(value: $selectedDay)
                .environment(\.timeZone, calendar.calendar.timeZone)
                .environment(\.calendar, calendar.calendar)
                .frame(height: 240)
                if let selected {
                    ViewThatFits(in: .horizontal) {
                        HStack { selectionText(selected); Spacer(); Button("View transactions") { openBucket(selected) } }
                        VStack(alignment: .leading, spacing: 8) { selectionText(selected); Button("View transactions") { openBucket(selected) } }
                    }
                } else {
                    Text("Select a bar or point to inspect it. Table offers exact values and keyboard access.")
                        .font(.caption).foregroundStyle(AppStyle.muted)
                }
            }
        }
        .onChange(of: report.filter) { selectedDay = nil }
    }
    private func selectionText(_ bucket: SpendingBucket) -> some View {
        Text("\(bucket.start) · \(ReportFormat.money(mode == "Cumulative" ? bucket.cumulative : bucket.net, report.filter.currency))\(mode == "Cumulative" ? " so far" : "")")
            .font(.caption).monospacedDigit()
    }
    private func openBucket(_ bucket: SpendingBucket) {
        var filter = report.filter
        filter.range = try! ReportRange(start: mode == "Cumulative" ? filter.range.start : bucket.start, end: bucket.end)
        filter.baseline = nil
        open(filter, mode == "Cumulative" ? "Cumulative spending" : "Spending · \(bucket.start)")
    }
}

struct ReportCategoryChart: View {
    let report: SpendingReport
    let open: (SpendingFilter, String) -> Void
    @State private var trends = false
    private var calendar: ReportCalendar { try! ReportCalendar(timezone: report.filter.timezone, weekStart: report.filter.weekStart) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Where it went", detail: "Net spending · \(report.filter.currency)")
            Picker("Category view", selection: $trends) { Text("Breakdown").tag(false); Text("Over time").tag(true) }
                .pickerStyle(.segmented).labelsHidden().tint(AppStyle.controlAccent).frame(maxWidth: 240)
            if trends {
                Chart(report.categoryBuckets) { bucket in
                    BarMark(x: .value("Date", calendar.date(bucket.start), unit: report.bucketUnit == "Monthly" ? .month : report.bucketUnit == "Weekly" ? .weekOfYear : .day), y: .value("Net spending", Double(bucket.net) / 100))
                        .foregroundStyle(by: .value("Category", ReportFormat.category(bucket.category)))
                        .accessibilityLabel("\(bucket.start), \(ReportFormat.category(bucket.category))")
                        .accessibilityValue(ReportFormat.money(bucket.net, report.filter.currency))
                }
                .chartForegroundStyleScale(range: [AppStyle.accent, Color.teal.opacity(0.7), Color.brown.opacity(0.7), Color.indigo.opacity(0.65), Color.gray, Color.orange.opacity(0.65)])
                .chartXScale(domain: calendar.date(report.filter.range.start)...calendar.date(report.filter.range.end))
                .chartXAxis { reportDateAxis(range: report.filter.range, calendar: calendar, desiredCount: 4) }
                .environment(\.calendar, calendar.calendar).environment(\.timeZone, calendar.calendar.timeZone)
                .chartYScale(domain: .automatic(includesZero: true)).frame(height: 240)
                Text("Stacked by category. Select a category below for exact amounts and supporting transactions.")
                    .font(.caption).foregroundStyle(AppStyle.muted)
            } else {
            Chart(report.categories) { category in
                BarMark(x: .value("Net spending", Double(category.net) / 100), y: .value("Category", ReportFormat.category(category.category)))
                    .foregroundStyle(AppStyle.accent.opacity(0.85)).cornerRadius(3)
                    .accessibilityLabel(ReportFormat.category(category.category))
                    .accessibilityValue(ReportFormat.money(category.net, report.filter.currency))
            }
            .chartYScale(domain: report.categories.map { ReportFormat.category($0.category) })
            .chartXScale(domain: .automatic(includesZero: true))
            // macOS chart value selection follows hover, including while the page scrolls.
            // Present supporting transactions only after an explicit click inside the plot.
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let plot = geometry[plotFrame]
                            guard plot.contains(location),
                                  let selected = proxy.value(atY: location.y - plot.minY, as: String.self),
                                  let category = report.categories.first(where: { ReportFormat.category($0.category) == selected }) else { return }
                            openCategory(category.category)
                        }
                }
            }
            .frame(height: CGFloat(max(1, report.categories.count)) * 34 + 30)
            }
            ForEach(report.categories) { category in
                Button { openCategory(category.category) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ReportFormat.category(category.category)).fontWeight(.medium)
                            Text("\(category.purchases) \(category.purchases == 1 ? "purchase" : "purchases")\(category.reviewCount > 0 ? " · \(category.reviewCount) \(category.reviewCount == 1 ? "needs" : "need") review" : "")")
                                .font(.caption).foregroundStyle(AppStyle.muted)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(ReportFormat.money(category.net, report.filter.currency)).monospacedDigit()
                            if report.totals.gross > 0 {
                                Text("\((Decimal(category.gross) / Decimal(report.totals.gross)).formatted(.percent.precision(.fractionLength(0)))) of purchase spending")
                                    .font(.caption).foregroundStyle(AppStyle.muted)
                                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(VaultRowButtonStyle())
            }
            Text("Category amounts include refunds. Percentages show each category’s share of purchase spending before refunds. Purchases split across categories appear in each relevant row; the overall purchase count counts each once.")
                .font(.caption).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func openCategory(_ category: String) {
        var filter = report.filter; filter.category = category
        open(filter, ReportFormat.category(category))
    }
}

struct ReportComparison: View {
    let report: SpendingReport
    let open: (SpendingFilter, String) -> Void
    var body: some View {
        if let previous = report.previous, let baseline = report.filter.baseline {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "Compared with before")
                Text(ReportFormat.change(report.totals.net, previous.net, currency: report.filter.currency)).font(.title3.weight(.medium))
                Chart {
                    BarMark(x: .value("Period", "Previous"), y: .value("Net spending", Double(previous.net) / 100))
                        .foregroundStyle(AppStyle.muted.opacity(0.5)).cornerRadius(4)
                        .accessibilityValue(ReportFormat.money(previous.net, report.filter.currency))
                    BarMark(x: .value("Period", "Selected"), y: .value("Net spending", Double(report.totals.net) / 100))
                        .foregroundStyle(AppStyle.accent).cornerRadius(4)
                        .accessibilityValue(ReportFormat.money(report.totals.net, report.filter.currency))
                }.chartYScale(domain: .automatic(includesZero: true)).frame(height: 170)
                periodRow("Selected", range: report.filter.range, net: report.totals.net)
                periodRow("Previous", range: baseline, net: previous.net)
                if let calendar = try? ReportCalendar(timezone: report.filter.timezone), calendar.count(report.filter.range) != calendar.count(baseline) {
                    Text("These calendar periods have different lengths: \(calendar.count(report.filter.range)) and \(calendar.count(baseline)) days. Automatic change findings are paused for this comparison.")
                        .font(.caption).foregroundStyle(AppStyle.muted)
                }
                if report.firstDay == nil || report.firstDay! > baseline.start {
                    Text("Recorded history starts after the comparison period begins. Earlier spending may be missing.")
                        .font(.caption).foregroundStyle(AppStyle.muted)
                }
                if previous.uncertain { Text("The previous period also contains pending, unreviewed, or unclassified entries.").font(.caption).foregroundStyle(AppStyle.muted) }
                ForEach(drivers.prefix(3), id: \.0) { code, change in
                    Button {
                        var filter = report.filter; filter.category = code; open(filter, ReportFormat.category(code))
                    } label: {
                        HStack {
                            Text(ReportFormat.category(code)); Spacer()
                            Text("\(change >= 0 ? "+" : "−")\((abs(change) / 100).formatted(.currency(code: report.filter.currency)))").monospacedDigit()
                        }
                    }.buttonStyle(.borderless)
                }
            }
        }
    }
    private var drivers: [(String, Decimal)] {
        let current = Dictionary(uniqueKeysWithValues: report.categories.map { ($0.category, $0.net) })
        let old = Dictionary(uniqueKeysWithValues: report.previousCategories.map { ($0.category, $0.net) })
        return Set(current.keys).union(old.keys).map { ($0, Decimal(current[$0] ?? 0) - Decimal(old[$0] ?? 0)) }
            .filter { $0.1 != 0 }.sorted { abs($0.1) == abs($1.1) ? $0.0 < $1.0 : abs($0.1) > abs($1.1) }
    }
    private func periodRow(_ title: String, range: ReportRange, net: Int64) -> some View {
        Button {
            var filter = report.filter; filter.range = range; filter.baseline = nil; open(filter, title + " period")
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(ReportFormat.range(range, timezone: report.filter.timezone)).font(.caption).foregroundStyle(AppStyle.muted)
                }
                Spacer()
                Text(ReportFormat.money(net, report.filter.currency)).monospacedDigit()
            }.padding(.vertical, 5)
        }.buttonStyle(.borderless)
    }
}
