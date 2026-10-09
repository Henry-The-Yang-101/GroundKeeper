enum AppTab: String, CaseIterable, Identifiable {
    case home
    case fullInsights
    case sync
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "Home"
        case .fullInsights: "Full insights"
        case .sync: "Sync"
        case .settings: "Settings"
        }
    }

    func symbol(isSelected: Bool) -> String {
        switch self {
        case .home: isSelected ? "house.fill" : "house"
        case .fullInsights: "chart.bar.xaxis"
        case .sync: "arrow.triangle.2.circlepath"
        case .settings: "gearshape"
        }
    }

    var shortcut: Character {
        switch self {
        case .home: "1"
        case .fullInsights: "2"
        case .sync: "3"
        case .settings: "4"
        }
    }
}
