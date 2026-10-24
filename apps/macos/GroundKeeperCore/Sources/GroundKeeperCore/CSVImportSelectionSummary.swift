import Foundation

/// Exact totals of valid, selected preview rows. Invalid and skipped rows never
/// contribute money or dates, and Decimal avoids overflowing a multi-row total.
public struct CSVImportSelectionSummary: Sendable {
    public let selectedCount: Int
    public let validCount: Int
    public let invalidCount: Int
    public let skippedCount: Int
    public let firstDay: String?
    public let lastDay: String?
    public let moneyOut: Decimal
    public let moneyIn: Decimal
    public var net: Decimal { moneyIn - moneyOut }

    public init(rows: [CSVPreviewRow], skipped: Set<Int>) {
        let selected = rows.filter { !skipped.contains($0.id) }
        let valid = selected.filter { $0.error == nil && $0.amountMinor != nil }
        selectedCount = selected.count
        validCount = valid.count
        invalidCount = selected.count - valid.count
        skippedCount = rows.count - selected.count
        firstDay = valid.map(\.day).min()
        lastDay = valid.map(\.day).max()
        moneyOut = valid.reduce(Decimal.zero) { total, row in
            guard let amount = row.amountMinor, amount < 0 else { return total }
            return total + Decimal(amount.magnitude) / 100
        }
        moneyIn = valid.reduce(Decimal.zero) { total, row in
            guard let amount = row.amountMinor, amount > 0 else { return total }
            return total + Decimal(amount) / 100
        }
    }
}
