import Charts
import SwiftUI

struct SpendingChart: View {
    var compact = false
    @State private var selectedDate: Date?
    @State private var showTable = false

    private var selectedPoint: SampleData.SpendingPoint? {
        guard let selectedDate else { return nil }
        return SampleData.dailySpending.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !compact {
                HStack {
                    SectionHeading(title: "Daily spending", detail: "CAD")
                    Toggle("Table", isOn: $showTable).toggleStyle(.button)
                        .help("Show the exact chart values in a table")
                }
            }
            if showTable {
                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 10) {
                    GridRow {
                        Text("Date").fontWeight(.medium)
                        Text("Net spending · CAD").fontWeight(.medium)
                    }
                    Divider()
                    ForEach(SampleData.dailySpending) { point in
                        GridRow {
                            Text(point.date, format: .dateTime.month(.abbreviated).day())
                            Text(point.amount, format: .currency(code: "CAD")).monospacedDigit()
                        }
                    }
                }.font(.callout).textSelection(.enabled)
            } else {
                Chart {
                    ForEach(SampleData.dailySpending) { point in
                        BarMark(x: .value("Date", point.date, unit: .day), y: .value("Net spending (CAD)", point.amount))
                            .foregroundStyle(AppStyle.accent.opacity(selectedPoint == nil || selectedPoint?.id == point.id ? 0.85 : 0.3))
                            .cornerRadius(4)
                            .accessibilityLabel(point.date.formatted(.dateTime.month().day()))
                            .accessibilityValue(point.amount.formatted(.currency(code: "CAD")))
                    }
                    if let selectedPoint {
                        RuleMark(x: .value("Selected date", selectedPoint.date, unit: .day))
                            .foregroundStyle(.secondary.opacity(0.4))
                    }
                }
                .chartYScale(domain: 0...160)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100, 150]) { value in
                        AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                        AxisValueLabel {
                            if let number = value.as(Int.self) { Text("$\(number)") }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let plot = geometry[plotFrame]
                                    selectedDate = plot.contains(location) ? proxy.value(atX: location.x - plot.minX) : nil
                                case .ended: selectedDate = nil
                                }
                            }
                    }
                }
                .frame(height: compact ? 155 : 230)
                if !compact {
                    Group {
                        if let selectedPoint {
                            Text("\(selectedPoint.date.formatted(.dateTime.month(.abbreviated).day())) · \(selectedPoint.amount.formatted(.currency(code: "CAD")))")
                        } else {
                            Text("Hover over a bar for the exact amount, or switch to Table.")
                        }
                    }.font(.caption).foregroundStyle(AppStyle.muted).monospacedDigit()
                }
            }
        }
    }
}
