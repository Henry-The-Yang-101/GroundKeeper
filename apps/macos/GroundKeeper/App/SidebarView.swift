import SwiftUI

struct SidebarView: View {
    @Binding var selection: AppTab
    @Environment(\.colorScheme) private var colorScheme

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
        .frame(width: 88)
        .frame(maxHeight: .infinity)
        .background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.92))
    }

    private func tabButton(_ tab: AppTab) -> some View {
        Button {
            selection = tab
        } label: {
            Image(systemName: tab.symbol(isSelected: selection == tab))
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(selection == tab ? .primary : .secondary)
                .frame(width: 44, height: 44)
                .background {
                    if selection == tab {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.primary.opacity(0.08))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("\(tab.title) (⌘\(String(tab.shortcut)))")
        .keyboardShortcut(KeyEquivalent(tab.shortcut), modifiers: .command)
        .accessibilityLabel(tab.title)
        .accessibilityValue(selection == tab ? "Selected" : "")
    }
}
