import Foundation
import Testing
@testable import GroundKeeperCore

@Test func csvSelectionTotalsExcludeSkippedAndInvalidRows() throws {
    let document = try CSVDocument(data: Data("Date,Description,Amount\n2026-10-01,Purchase,-12.50\n2026-10-02,Refund,2.75\n2026-10-03,Skipped,-90.00\n2026-10-04,Broken,unreadable\n".utf8), filename: "fictional.csv")
    let rows = document.preview(CSVMapping())
    let summary = CSVImportSelectionSummary(rows: rows, skipped: [4])
    #expect(summary.selectedCount == 3)
    #expect(summary.validCount == 2)
    #expect(summary.invalidCount == 1)
    #expect(summary.skippedCount == 1)
    #expect(summary.moneyOut == Decimal(string: "12.50"))
    #expect(summary.moneyIn == Decimal(string: "2.75"))
    #expect(summary.net == Decimal(string: "-9.75"))
    #expect(summary.firstDay == "2026-10-01")
    #expect(summary.lastDay == "2026-10-02")
    let empty = CSVImportSelectionSummary(rows: rows, skipped: Set(rows.map(\.id)))
    #expect(empty.validCount == 0 && empty.selectedCount == 0 && empty.invalidCount == 0)
    #expect(empty.moneyOut == 0 && empty.moneyIn == 0 && empty.net == 0)
    #expect(empty.firstDay == nil && empty.lastDay == nil)
}

@Test func csvSelectionTotalsCoverRowsBeyondDisplayedPreviewAndDoNotOverflow() throws {
    let data = "Date,Description,Amount\n" + (1...201).map { "2026-10-01,Fictional \($0),-92233720368547758.07\n" }.joined()
    let rows = try CSVDocument(data: Data(data.utf8), filename: "large-fictional.csv").preview(CSVMapping())
    let summary = CSVImportSelectionSummary(rows: rows, skipped: [202])
    #expect(summary.validCount == 200)
    #expect(summary.moneyOut == Decimal(string: "18446744073709551614.00"))
    #expect(summary.net == -summary.moneyOut)
}
