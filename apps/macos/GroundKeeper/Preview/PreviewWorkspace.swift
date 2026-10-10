import Observation
import SwiftUI

/// A disposable UI workspace. All transaction changes disappear when the app quits.
/// Future services should supply presentation models without moving business logic into views.
@MainActor @Observable
final class PreviewWorkspace {
    var selectedTab: AppTab? = .home
    var insightsSection: InsightsSection = .spending
    var transactions = SampleData.transactions
    var reviewOnly = false
    var editor: Transaction?
    var showingImportPreview = false

    var reviewCount: Int { transactions.filter(\.needsReview).count }

    func showTransactions(needingReview: Bool = false) {
        reviewOnly = needingReview
        insightsSection = .transactions
        selectedTab = .fullInsights
    }

    func save(_ transaction: Transaction) {
        if let index = transactions.firstIndex(where: { $0.id == transaction.id }) {
            transactions[index] = transaction
        } else {
            transactions.insert(transaction, at: 0)
        }
        editor = nil
    }

    func reset() {
        transactions = SampleData.transactions
        reviewOnly = false
    }
}

enum InsightsSection: String, CaseIterable, Identifiable {
    case spending = "Spending"
    case transactions = "Transactions"
    case planning = "Planning"
    var id: Self { self }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: Self { self }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
