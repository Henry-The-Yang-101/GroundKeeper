import SwiftUI
import Charts
import GroundKeeperCore

struct ReportMerchants: View {
    let report: SpendingReport
    let select: (String) -> Void
    let manage: () -> Void
    @State private var search = ""
    @State private var page = 0
    private var matches: [SpendingMerchantTotal] { report.merchants.filter { search.isEmpty || $0.name.localizedStandardContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { SectionHeading(title: "Merchants", detail: "\(report.merchants.count) in this view"); Spacer(); Button("Manage groups", action: manage).buttonStyle(.borderless) }
            Text("Counts are recorded purchases, including same-day repeats. Refunds reduce net spending but do not add purchases. Exact statement names stay separate until you confirm a group.")
                .font(.caption).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
            TextField("Find a merchant", text: $search).textFieldStyle(.roundedBorder).onChange(of: search) { page = 0 }
            ForEach(Array(matches.dropFirst(page * 10).prefix(10))) { merchant in
                MerchantReportRow(merchant: merchant, previous: report.previousMerchants.first { $0.id == merchant.id }, report: report) { select(merchant.id) }
                Divider()
            }
            if matches.count > 10 {
                HStack {
                    Button("Previous") { page -= 1 }.disabled(page == 0)
                    Text("Page \(page + 1) of \(max(1, (matches.count + 9) / 10))").font(.caption)
                    Button("Next") { page += 1 }.disabled((page + 1) * 10 >= matches.count)
                }
            }
        }.onChange(of: report.revision) { page = 0 }.onChange(of: report.filter) { page = 0 }
    }
}

private struct MerchantReportRow: View {
    let merchant: SpendingMerchantTotal
    let previous: SpendingMerchantTotal?
    let report: SpendingReport
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Button(merchant.name, action: open).buttonStyle(.borderless).fontWeight(.medium)
                Spacer()
                Text(ReportFormat.money(merchant.net, report.filter.currency)).monospacedDigit()
            }
            Text("\(merchant.purchases) purchases · \(max(0, merchant.purchases - 1)) repeats after the first · Average \(merchant.averagePurchase.formatted(.currency(code: report.filter.currency)))")
                .font(.callout)
            if let calendar = try? ReportCalendar(timezone: report.filter.timezone, weekStart: report.filter.weekStart) {
                Text("\(merchant.purchasesPerWeek(in: report.filter.range, calendar: calendar).formatted(.number.precision(.fractionLength(0...1)))) purchases/week over this period · \(merchant.activeDays) active days" + (merchant.averageGap(calendar: calendar).map { " · Average gap \($0.formatted(.number.precision(.fractionLength(0...1)))) days" } ?? ""))
                    .font(.caption).foregroundStyle(AppStyle.muted)
            }
            if let previous {
                Text("Previous period: \(previous.purchases) purchases · \(ReportFormat.money(previous.net, report.filter.currency)) net")
                    .font(.caption).foregroundStyle(AppStyle.muted)
            }
            if merchant.refunds > 0 { Text("Refunds: \(ReportFormat.money(merchant.refunds, report.filter.currency))").font(.caption).foregroundStyle(AppStyle.muted) }
            if merchant.reviewCount > 0 { Text("\(merchant.reviewCount) entries need review").font(.caption).foregroundStyle(AppStyle.muted) }
        }.padding(.vertical, 4)
    }
}

struct ReportPurchaseFrequency: View {
    let report: SpendingReport
    let open: (SpendingFilter, String) -> Void
    @State private var table = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeading(title: "Purchase frequency", detail: report.bucketUnit + " counts")
                Spacer()
                Toggle("Table", isOn: $table).toggleStyle(.button)
            }
            Text("Recorded purchases per bucket. A zero means no purchase recorded; history may be incomplete.")
                .font(.caption).foregroundStyle(AppStyle.muted)
            if table {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(report.buckets) { bucket in
                            HStack {
                                Button(bucket.start) { show(bucket) }.buttonStyle(.borderless)
                                Spacer(); Text("\(bucket.purchases) purchases").monospacedDigit()
                            }.padding(.vertical, 5)
                        }
                    }
                }.frame(maxHeight: 260)
            } else if let calendar = try? ReportCalendar(timezone: report.filter.timezone) {
                Chart(report.buckets) { bucket in
                    BarMark(x: .value("Period", calendar.date(bucket.start), unit: report.bucketUnit == "Monthly" ? .month : report.bucketUnit == "Weekly" ? .weekOfYear : .day), y: .value("Purchases", bucket.purchases))
                        .foregroundStyle(AppStyle.controlAccent)
                        .accessibilityLabel(bucket.start).accessibilityValue("\(bucket.purchases) purchases")
                }.chartYAxisLabel("Purchases")
                    .chartXScale(domain: calendar.date(report.filter.range.start)...calendar.date(report.filter.range.end))
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                    .frame(height: 180)
                    .environment(\.timeZone, calendar.calendar.timeZone).environment(\.calendar, calendar.calendar)
            }
        }
    }
    private func show(_ bucket: SpendingBucket) {
        guard let range = try? ReportRange(start: bucket.start, end: bucket.end) else { return }
        var filter = report.filter; filter.range = range; filter.baseline = nil; filter.purchasesOnly = true
        open(filter, "Purchases from " + bucket.start)
    }
}
