import AppKit
import SwiftUI

/// Positions the existing macOS controls without replacing their native behavior.
struct WindowControls: NSViewRepresentable {
    let sidebarWidth: CGFloat

    func makeNSView(context: Context) -> WindowControlsView {
        let view = WindowControlsView()
        view.sidebarWidth = sidebarWidth
        return view
    }

    func updateNSView(_ view: WindowControlsView, context: Context) {
        view.sidebarWidth = sidebarWidth
        view.scheduleLayout()
    }

    static func dismantleNSView(_ view: WindowControlsView, coordinator: ()) {
        view.stopObserving()
    }
}

final class WindowControlsView: NSView {
    var sidebarWidth: CGFloat = AppLayout.sidebarWidth
    private var observers: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()

        guard let window else { return }
        let notifications: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        observers = notifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleLayout()
                }
            }
        }
        scheduleLayout()
    }

    func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func scheduleLayout() {
        // AppKit lays out the title bar first, then we adjust only horizontal position.
        DispatchQueue.main.async { [weak self] in
            self?.centerControls()
        }
    }

    private func centerControls() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let contentView = window.contentView else { return }

        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap(window.standardWindowButton)
        guard buttons.count == types.count, let parent = buttons.first?.superview,
              parent.window == window,
              buttons.allSatisfy({ $0.superview === parent }) else { return }

        let bounds = buttons.dropFirst().reduce(buttons[0].frame) { $0.union($1.frame) }
        let sidebarCenter = parent.convert(NSPoint(x: sidebarWidth / 2, y: 0), from: contentView).x
        let offset = sidebarCenter - bounds.midX
        guard abs(offset) > 0.1 else { return }

        for button in buttons {
            button.setFrameOrigin(NSPoint(x: button.frame.minX + offset, y: button.frame.minY))
        }
    }
}
