import SwiftUI
import AppKit

/// SwiftUI Table does not expose full-row backgrounds or the native selection
/// highlight. Attach once in the first column and keep native selection, sorting,
/// keyboard navigation and context menus intact.
struct TransactionTableRowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> RowAnchor { RowAnchor() }
    func updateNSView(_ view: RowAnchor, context: Context) {
        view.attach()
    }
    static func dismantleNSView(_ view: RowAnchor, coordinator: ()) { view.detach() }

    final class RowAnchor: NSView {
        private weak var row: NSTableRowView?
        private let decoration = RowBackground()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() }
            else { attach() }
        }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        override func layout() { super.layout(); attach() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }

        func attach() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is NSTableRowView) { ancestor = view.superview }
            guard let target = ancestor as? NSTableRowView else { return }
            if row !== target {
                detach()
                row = target
                decoration.frame = target.bounds
                decoration.autoresizingMask = [.width, .height]
                target.addSubview(decoration, positioned: .below, relativeTo: nil)
            }
            // Suppress only the native fill, not the selection itself.
            target.selectionHighlightStyle = .none
            var parent = target.superview
            while let view = parent {
                if let table = view as? NSTableView {
                    table.selectionHighlightStyle = .none
                    if !table.subviews.contains(where: { $0 is HoverObserver }) {
                        let observer = HoverObserver()
                        observer.table = table
                        table.addSubview(observer)
                    }
                    break
                }
                parent = view.superview
            }
            updateColor()
        }

        func detach() {
            decoration.removeFromSuperview()
            row = nil
        }

        private func updateColor() {
            decoration.updateColor()
        }
    }

    /// Observe the table's pointer events once, including gutters between cells.
    /// Native table cell hosts can consume tracking-area transitions as they reuse
    /// rows. This observer never consumes or changes an input event.
    final class HoverObserver: NSView {
        weak var table: NSTableView?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            setAccessibilityElement(false)
            window?.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .otherMouseDown, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.updateHover(event) }
                return event
            }
        }
        private func updateHover(_ event: NSEvent) {
            guard let table else { return }
            let point = table.convert(event.locationInWindow, from: nil)
            let index = event.window === window && window?.attachedSheet == nil && table.visibleRect.contains(point)
                ? table.row(at: point) : -1
            table.enumerateAvailableRowViews { row, rowIndex in
                for case let background as RowBackground in row.subviews { background.setHovered(rowIndex == index) }
            }
            if index >= 0 { NSCursor.pointingHand.set() }
        }
    }

    final class RowBackground: NSView {
        private var hovered = false
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
                owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }
        func setHovered(_ value: Bool) {
            guard hovered != value else { return }
            hovered = value
            updateColor()
        }
        override func mouseEntered(with event: NSEvent) { setHovered(true) }
        override func mouseExited(with event: NSEvent) { setHovered(false) }
        override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }

        func updateColor() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let surface = NSColor(named: "VaultSurface") ?? .controlBackgroundColor
                let selection = NSColor(named: "VaultSelection") ?? .unemphasizedSelectedContentBackgroundColor
                layer?.backgroundColor = surface.blended(withFraction: hovered ? 0.42 : 0, of: selection)?.cgColor
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(false)
            wantsLayer = true
            layer?.cornerRadius = 6
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
