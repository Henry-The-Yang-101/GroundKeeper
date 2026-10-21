import SwiftUI
import GroundKeeperCore
import Charts

struct HomeSpendingOverview: View {
    @Environment(AppWorkspace.self) private var workspace
    @AppStorage("reportCurrency", store: AppPreferences.defaults) private var currency = "CAD"
    @AppStorage("reportTimezone", store: AppPreferences.defaults) private var timezone = TimeZone.current.identifier
    @AppStorage("reportWeekStart", store: AppPreferences.defaults) private var weekStart = 2
    @AppStorage("reportPending", store: AppPreferences.defaults) private var pending = true
    @AppStorage("insightSensitivity", store: AppPreferences.defaults) private var sensitivity = InsightSensitivity.balanced
    @State private var report: SpendingReport?
    @State private var error: String?
    @State private var refresh = 0
    var body: some View {
        Surface {
            SectionHeading(title: "This month", detail: currency)
            if let report {
                ReportSummary(report: report)
                Chart(report.buckets) { bucket in
                    BarMark(x: .value("Day", calendar.date(bucket.start), unit: .day), y: .value("Net spending", Double(bucket.net) / 100))
                        .foregroundStyle(AppStyle.accent.opacity(0.85))
                        .accessibilityLabel(bucket.start).accessibilityValue(ReportFormat.money(bucket.net, currency))
                }
                .environment(\.calendar, calendar.calendar).environment(\.timeZone, calendar.calendar.timeZone)
                .chartXAxis(.hidden).chartYScale(domain: .automatic(includesZero: true)).frame(height: 110)
                if let leading = report.categories.first {
                    Text("Leading category: \(ReportFormat.category(leading.category)) · \(ReportFormat.money(leading.net, currency))")
                        .font(.callout).foregroundStyle(AppStyle.muted)
                }
                if let finding = report.findings.first(where: { $0.kind != "purchase_pattern" }) {
                    Text((finding.category.map(ReportFormat.category) ?? "Recorded spending") + ": " + ReportFormat.change(finding.current, finding.previous, currency: currency))
                        .font(.callout)
                }
                Button("Explore spending") { workspace.selectedTab = .spending }.buttonStyle(.borderless)
            } else if let error {
                Text(error).foregroundStyle(AppStyle.muted)
                Button("Try again") { refresh += 1 }
            } else { ProgressView("Loading spending…") }
        }
        .task(id: "\(workspace.reportingRevision)|\(workspace.ready)|\(currency)|\(timezone)|\(weekStart)|\(pending)|\(sensitivity)|\(refresh)") {
            report = nil; error = nil
            do {
                let calendar = try ReportCalendar(timezone: timezone, weekStart: weekStart)
                let ranges = try calendar.ranges(.month)
                var filter = SpendingFilter(range: ranges.0, baseline: ranges.1, currency: currency, includePending: pending, timezone: timezone, weekStart: weekStart)
                filter.sensitivity = sensitivity
                let result = try await workspace.spendingReport(filter)
                try Task.checkCancellation(); report = result
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh += 1 }
        .onChange(of: workspace.ready) { if !workspace.ready { report = nil } }
    }
    private var calendar: ReportCalendar { (try? ReportCalendar(timezone: timezone)) ?? (try! ReportCalendar(timezone: "UTC")) }
}
