import SwiftUI

struct SidebarView: View {
    @Binding var selection: AppTab?
    let reviewCount: Int

    var body: some View {
        List(selection: $selection) {
            Section("Workspace") {
                ForEach(AppTab.allCases.filter { $0 != .settings }) { tab in
                    Label {
                        Text(tab.title).foregroundStyle(AppStyle.text)
                    } icon: {
                        Image(systemName: tab.symbol(isSelected: selection == tab))
                            .foregroundStyle(selection == tab ? AppStyle.accent : AppStyle.muted)
                    }
                        .badge(tab == .home ? reviewCount : 0)
                        .tag(tab)
                        .help("\(tab.title) (⌘\(String(tab.shortcut)))")
                }
            }
            Section {
                Label {
                    Text("Settings").foregroundStyle(AppStyle.text)
                } icon: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(selection == .settings ? AppStyle.accent : AppStyle.muted)
                }.tag(AppTab.settings)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(AppStyle.sidebar)
        .navigationTitle("GroundKeeper")
        .safeAreaInset(edge: .top, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "square.grid.3x3.square")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(AppStyle.accent)
                    .accessibilityHidden(true)
                Text("GroundKeeper").font(VaultTypography.wordmark)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(AppStyle.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 10)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(AppStyle.separator).frame(height: 1).padding(.bottom, 10)
                Label("On this Mac", systemImage: "internaldrive")
                    .font(.callout.weight(.medium))
                Text("Saved on this Mac. Capture via iCloud Drive.")
                    .font(.caption).foregroundStyle(AppStyle.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(AppStyle.sidebar)
        }
    }
}
