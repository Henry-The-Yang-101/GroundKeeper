import SwiftUI

struct TransactionRow: View {
    let transaction: Transaction
    private var detail: String {
        switch transaction.kind {
        case .purchase: transaction.category.rawValue
        case .refund: "Refund · \(transaction.category.rawValue)"
        default: transaction.kind.rawValue
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: transaction.category)
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchant).fontWeight(.medium).lineLimit(1).help(transaction.merchant)
                Text(detail)
                    .font(.caption).foregroundStyle(AppStyle.muted)
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
