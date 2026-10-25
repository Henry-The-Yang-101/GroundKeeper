import SwiftUI

struct SidebarView: View {
    @Binding var selection: AppTab?
    let reviewCount: Int
    let queueCount: Int
    let isProcessingQueue: Bool

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(AppTab.allCases.filter { $0 != .settings }) { tab in
                    SidebarTabRow(tab: tab, isSelected: selection == tab,
                                  isProcessingQueue: isProcessingQueue)
                        .badge(badgeCount(for: tab))
                        .tag(tab)
                        .help("\(tab.title) (⌘\(String(tab.shortcut)))")
                }
            }
            Section {
                SidebarTabRow(tab: .settings, isSelected: selection == .settings,
                              isProcessingQueue: false)
                    .tag(AppTab.settings)
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

    private func badgeCount(for tab: AppTab) -> Int {
        switch tab {
        case .home: reviewCount
        case .sync: queueCount
        default: 0
        }
    }
}

private struct SidebarTabRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let tab: AppTab
    let isSelected: Bool
    let isProcessingQueue: Bool

    var body: some View {
        Label {
            Text(tab.title).foregroundStyle(AppStyle.text)
        } icon: {
            Image(systemName: tab.symbol(isSelected: isSelected))
                .foregroundStyle(isSelected || isHovered ? AppStyle.accent : AppStyle.muted)
                .symbolEffect(.rotate.clockwise.wholeSymbol,
                              isActive: tab == .sync && isProcessingQueue && !reduceMotion)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppStyle.accent.opacity(isHovered ? 0.14 : 0))
                .animation(reduceMotion ? nil : VaultMotion.feedback, value: isHovered)
        )
        .animation(reduceMotion ? nil : VaultMotion.feedback, value: isHovered)
        .onHover { isHovered = $0 }
        .onDisappear { isHovered = false }
    }
}
