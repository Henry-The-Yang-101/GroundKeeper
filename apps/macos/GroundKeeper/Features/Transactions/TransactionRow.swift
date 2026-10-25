import SwiftUI

struct TransactionRow: View {
    let transaction: Transaction
    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: transaction.category)
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchant).fontWeight(.medium).lineLimit(1).help(transaction.merchant)
                HStack(spacing: 5) {
                    if transaction.kind != .purchase {
                        Text(transaction.kind.rawValue + " ·").foregroundStyle(AppStyle.muted)
                    }
                    CategoryLabel(transaction: transaction)
                }.font(.caption)
            }
            Spacer(minLength: 12)
            if transaction.needsReview { ReviewBadge() }
            VStack(alignment: .trailing, spacing: 4) {
                Text(transaction.formattedAmount).monospacedDigit()
                Text(transaction.date, format: .dateTime.month(.abbreviated).day())
                    .font(.caption).foregroundStyle(AppStyle.muted)
            }
        }
        .padding(.vertical, 15)
        .accessibilityElement(children: .combine)
    }
}
