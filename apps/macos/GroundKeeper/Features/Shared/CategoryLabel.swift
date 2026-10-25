import AppKit
import SwiftUI
import GroundKeeperCore

/// One category treatment for the ledger, recent transactions and evidence lists.
struct CategoryLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

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
    private var tint: Color {
        guard category != .none else { return AppStyle.unassigned }
        return attribution.isAI ? AppStyle.ai : attribution.isHuman ? AppStyle.accent : AppStyle.muted
    }
    var body: some View {
        HStack(spacing: 5) {
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
            Text(category.rawValue)
                .foregroundStyle(category == .none ? AppStyle.unassigned : AppStyle.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            Capsule()
                .fill(tint.opacity(isHovered ? 0.18 : 0.08))
                .overlay {
                    Capsule().strokeBorder(tint.opacity(isHovered ? 0.28 : 0.14), lineWidth: 1)
                }
                .animation(reduceMotion ? nil : VaultMotion.feedback, value: isHovered)
        }
        .contentShape(.capsule)
        .background {
            GeometryReader { geometry in
                CategoryHoverCard(text: explanation, isPresented: isHovered)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .onHover { isHovered = $0 }
        .onDisappear { isHovered = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(category.rawValue). \(explanation)")
    }
}

/// A nonactivating child panel keeps placement in explicit screen coordinates.
/// NSPopover's automatic positioning drifts inside SwiftUI's flipped table cells.
private struct CategoryHoverCard: NSViewRepresentable {
    let text: String
    let isPresented: Bool

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        if view.text != text { view.dismiss() }
        view.text = text
        view.setPresented(isPresented)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnchorView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.setPresented(false)
    }

    final class AnchorView: NSView {
        var text = ""
        private var card: HoverPanel?
        private var presentationRequested = false
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            dismiss()
            super.viewWillMove(toWindow: newWindow)
        }

        override func layout() {
            super.layout()
            updatePresentation()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updatePresentation()
        }

        func setPresented(_ presented: Bool) {
            presentationRequested = presented
            updatePresentation()
        }

        private func updatePresentation() {
            guard presentationRequested, let window, !isHiddenOrHasHiddenAncestor,
                  !visibleRect.isEmpty else { dismiss(); return }
            // NSView -> window -> screen handles flipped views and window origins.
            // Screen coordinates increase upwards, so maxY is always the pill's top.
            let pill = window.convertToScreen(convert(bounds, to: nil))
            if card == nil {
                let panel = HoverPanel(contentRect: .zero,
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.hidesOnDeactivate = true
                panel.ignoresMouseEvents = true
                panel.isReleasedWhenClosed = false
                let content = NSHostingView(rootView: CardContent(text: text))
                panel.contentView = content
                panel.setContentSize(content.fittingSize)
                card = panel
                window.addChildWindow(panel, ordered: .above)
                observe(NSWindow.didResizeNotification, object: window)
                if let clipView = enclosingScrollView?.contentView {
                    observe(NSView.boundsDidChangeNotification, object: clipView)
                }
            }
            guard let card else { return }
            card.setFrameOrigin(NSPoint(x: pill.midX - card.frame.width / 2, y: pill.maxY + 4))
            card.orderFront(nil)
        }

        private func observe(_ name: Notification.Name, object: AnyObject) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePresentation() }
            })
        }

        func dismiss() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            guard let card else { return }
            card.parent?.removeChildWindow(card)
            card.close()
            self.card = nil
        }
    }

    private final class HoverPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private struct CardContent: View {
        let text: String

        var body: some View {
            VStack(spacing: 0) {
                Text(text)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AppStyle.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(width: 320)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(AppStyle.pageBackground, in: .rect(cornerRadius: 16))
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: 9, y: 8))
                    path.addLine(to: CGPoint(x: 18, y: 0))
                    path.closeSubpath()
                }
                .fill(AppStyle.pageBackground)
                .frame(width: 18, height: 8)
            }
            .fixedSize()
        }
    }
}
