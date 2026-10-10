import SwiftUI

struct SidebarView: View {
    @Binding var selection: AppTab?
    let reviewCount: Int

    var body: some View {
        List(selection: $selection) {
            Section("Workspace") {
                ForEach(AppTab.allCases.filter { $0 != .settings }) { tab in
                    Label(tab.title, systemImage: tab.symbol(isSelected: selection == tab))
                        .badge(tab == .home ? reviewCount : 0)
                        .tag(tab)
                        .help("\(tab.title) (⌘\(String(tab.shortcut)))")
                }
            }
            Section {
                Label("Settings", systemImage: "gearshape").tag(AppTab.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("GroundKeeper")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Sample workspace", systemImage: "rectangle.on.rectangle")
                    .font(.callout.weight(.medium))
                Text("Fictional data. Edits last until you quit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }
}
