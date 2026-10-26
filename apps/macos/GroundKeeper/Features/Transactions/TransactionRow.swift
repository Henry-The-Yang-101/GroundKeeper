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
            if transaction.requiresReview { ReviewBadge() }
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

struct TransactionDataIndicators: View {
    let transaction: Transaction
    var body: some View {
        HStack(spacing: 10) {
            if transaction.location != nil { Image(systemName: "mappin.and.ellipse").help("Location recorded") }
            if transaction.hasNote { Image(systemName: "note.text").help("Has notes") }
            if transaction.hasReceiptImage { Image(systemName: "receipt").help("Receipt image attached") }
            if transaction.location == nil && !transaction.hasNote && !transaction.hasReceiptImage {
                Text("–").foregroundStyle(AppStyle.muted)
            }
        }
        .foregroundStyle(AppStyle.accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
    }
    private var description: String {
        let values = [transaction.location != nil ? "Location recorded" : nil,
                      transaction.hasNote ? "Has notes" : nil,
                      transaction.hasReceiptImage ? "Receipt image attached" : nil].compactMap { $0 }
        return values.isEmpty ? "No additional data" : values.joined(separator: ", ")
    }
}
