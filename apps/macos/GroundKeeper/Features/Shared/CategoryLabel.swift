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

/// Use a passive, nonanimated popover: SwiftUI's presentation dismisses on a
/// click and can take focus from the table. This card never consumes row clicks.
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
        // The background must occupy the complete pill, not NSView's empty ideal size.
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.setPresented(false)
    }

    final class AnchorView: NSView {
        var text = ""
        private var card: NSPopover?
        private var presentationRequested = false

        private var anchorRect: NSRect {
            NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
        }

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
            guard presentationRequested else { dismiss(); return }
            guard window != nil, !visibleRect.isEmpty else { return }
            if let card {
                card.positioningRect = anchorRect
                return
            }
            let popover = NSPopover()
            popover.animates = false
            popover.behavior = .semitransient
            popover.contentViewController = NSHostingController(rootView: CardContent(text: text))
            card = popover
            // A narrow center anchor prevents AppKit from choosing another point
            // along a wide pill. The pointer position never affects placement.
            popover.show(relativeTo: anchorRect, of: self, preferredEdge: .maxY)
        }

        func dismiss() {
            guard let card else { return }
            card.close()
            self.card = nil
        }
    }

    private struct CardContent: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(AppStyle.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
                .background(AppStyle.pageBackground)
        }
    }
}
