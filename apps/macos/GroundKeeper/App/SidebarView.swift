import SwiftUI

struct SidebarView: View {
    @Binding var selection: AppTab
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredTab: AppTab?

    var body: some View {
        VStack(spacing: 12) {
            ForEach(AppTab.allCases.filter { $0 != .settings }) { tab in
                tabButton(tab)
            }

            Spacer(minLength: 16)

            tabButton(.settings)
        }
        .padding(.top, 56)
        .padding(.bottom, 20)
        .padding(.horizontal, 22)
        .frame(width: AppLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.92))
    }

    private func tabButton(_ tab: AppTab) -> some View {
        let isSelected = selection == tab
        let isHovered = hoveredTab == tab

        return Button {
            selection = tab
        } label: {
            Image(systemName: tab.symbol(isSelected: isSelected))
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(isSelected || isHovered ? .primary : .secondary)
                .scaleEffect(isHovered && !reduceMotion ? 1.08 : 1)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.primary.opacity(isSelected ? (isHovered ? 0.12 : 0.08) : (isHovered ? 0.06 : 0)))
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                hoveredTab = tab
            } else if hoveredTab == tab {
                hoveredTab = nil
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        .help("\(tab.title) (⌘\(String(tab.shortcut)))")
        .keyboardShortcut(KeyEquivalent(tab.shortcut), modifiers: .command)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
