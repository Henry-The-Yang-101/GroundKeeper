import SwiftUI
import GroundKeeperCore

/// One category treatment for the ledger, recent transactions and evidence lists.
struct CategoryLabel: View {
    let category: SpendingCategory
    let attribution: CategoryAttribution

    init(category: SpendingCategory, attribution: CategoryAttribution) {
        self.category = category; self.attribution = attribution
    }
    init(transaction: Transaction) {
        category = transaction.kind.usesCategory ? transaction.category : .none
        attribution = transaction.categoryAttribution
    }
    private var explanation: String {
        category == .none ? "No category chosen" : attribution.explanation
    }
    var body: some View {
        HStack(spacing: 5) {
            Text(category.rawValue)
                .foregroundStyle(category == .none ? AppStyle.muted : AppStyle.text)
                .lineLimit(1)
            if category != .none {
                if attribution.isAI {
                    Image(systemName: "sparkles")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AppStyle.ai)
                        .accessibilityHidden(true)
                } else if attribution.isHuman {
                    Image(systemName: "person.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppStyle.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.rect)
        .help(explanation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(category.rawValue). \(explanation)")
    }
}
