import SwiftUI

struct SidebarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredTab: AppTab?
    @FocusState private var focusedTab: AppTab?
    @Binding var selection: AppTab?
    let reviewCount: Int
    let queueCount: Int
    let isProcessingQueue: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(AppTab.allCases.filter { $0 != .settings }) { tab in
                    sidebarRow(for: tab)
                }
                sidebarRow(for: .settings)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sidebar")
        }
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

    private func sidebarRow(for tab: AppTab) -> some View {
        Button {
            selection = tab
        } label: {
            HStack {
                Label {
                    Text(tab.title)
                        .fontWeight(selection == tab ? .semibold : .regular)
                        .foregroundStyle(AppStyle.text)
                } icon: {
                    Image(systemName: tab.symbol(isSelected: selection == tab))
                        .font(.system(size: 17))
                        .frame(width: 20)
                        .foregroundStyle(selection == tab ? AppStyle.accent : AppStyle.muted)
                        .symbolEffect(.rotate.clockwise.wholeSymbol,
                                      isActive: tab == .sync && isProcessingQueue && !reduceMotion)
                }
                Spacer(minLength: 8)
                if badgeCount(for: tab) > 0 {
                    Text(badgeCount(for: tab).formatted())
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppStyle.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selection == tab ? AppStyle.selection : AppStyle.accent.opacity(hoveredTab == tab ? 0.14 : 0))
                    .animation(reduceMotion ? nil : VaultMotion.feedback, value: hoveredTab == tab)
            }
        }
        .buttonStyle(.plain)
        .focused($focusedTab, equals: tab)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
        .help("\(tab.title) (⌘\(String(tab.shortcut)))")
        .onHover { hovering in
            if hovering { hoveredTab = tab }
            else if hoveredTab == tab { hoveredTab = nil }
        }
        .onDisappear {
            if hoveredTab == tab { hoveredTab = nil }
        }
        .onMoveCommand { direction in
            guard let index = AppTab.allCases.firstIndex(of: tab) else { return }
            let offset = direction == .up ? -1 : direction == .down ? 1 : 0
            let nextIndex = index + offset
            guard offset != 0, AppTab.allCases.indices.contains(nextIndex) else { return }
            let nextTab = AppTab.allCases[nextIndex]
            focusedTab = nextTab
            selection = nextTab
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
