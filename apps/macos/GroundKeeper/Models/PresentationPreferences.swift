import AppKit

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
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
