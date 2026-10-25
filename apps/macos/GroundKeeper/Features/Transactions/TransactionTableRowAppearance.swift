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
                    let observer: HoverObserver
                    if let existing = table.subviews.first(where: { $0 is HoverObserver }) as? HoverObserver {
                        observer = existing
                    } else {
                        observer = HoverObserver()
                        observer.table = table
                        table.addSubview(observer)
                    }
                    // A reused/newly visible row must not inherit an old hover.
                    observer.applyHover(to: decoration, in: target)
                    break
                }
                parent = view.superview
            }
            updateColor()
        }

        func detach() {
            decoration.setHovered(false)
            decoration.removeFromSuperview()
            row = nil
        }

        private func updateColor() {
            decoration.updateColor()
        }
    }

    /// Observe the table's pointer events once, including gutters between cells.
    /// Own hover state centrally: row tracking-area transitions can arrive out of
    /// order during reuse. Observe clip bounds after scrolling, too, since the
    /// scroll-wheel event arrives before the rows move under a stationary pointer.
    /// This observer never consumes or changes an input event.
    final class HoverObserver: NSView {
        weak var table: NSTableView?
        private var monitor: Any?
        private var tracking: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let tracking { table?.removeTrackingArea(tracking); self.tracking = nil }
            NotificationCenter.default.removeObserver(self)
            guard window != nil else { updateHover(); return }
            setAccessibilityElement(false)
            window?.acceptsMouseMovedEvents = true
            if let table {
                // Keep receiving exits when the pointer leaves the window and
                // there are no further local mouse-moved events.
                let area = NSTrackingArea(rect: .zero,
                    options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
                    owner: self, userInfo: nil)
                table.addTrackingArea(area)
                tracking = area
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .otherMouseDown, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.updateHover() }
                return event
            }
            if let clip = table?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                clip.postsFrameChangedNotifications = true
                for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(updateHover), name: name, object: clip)
                }
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(updateHover), name: name, object: window)
            }
            updateHover()
        }

        override func mouseEntered(with event: NSEvent) { updateHover() }
        override func mouseExited(with event: NSEvent) { updateHover() }

        private var hoveredRowIndex: Int {
            guard let table, let window, window.isKeyWindow, window.attachedSheet == nil else { return -1 }
            let point = table.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            return table.visibleRect.contains(point) ? table.row(at: point) : -1
        }

        func applyHover(to background: RowBackground, in row: NSTableRowView) {
            guard let table else { return }
            let index = hoveredRowIndex
            background.setHovered(index >= 0 && table.row(for: row) == index)
        }

        @objc private func updateHover() {
            guard let table else { return }
            let index = hoveredRowIndex
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
                options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
                owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }
        func setHovered(_ value: Bool) {
            guard hovered != value else { return }
            hovered = value
            updateColor()
        }
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
