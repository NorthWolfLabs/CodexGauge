import AppKit

/// Follows the anchor's screen geometry only while its popover is presented.
/// Status-item windows can move without changing the button's local frame.
@MainActor
final class PopoverAnchorTracker: NSObject {
    private struct Geometry: Equatable {
        let windowNumber: Int
        let screenRect: NSRect
        let bounds: NSRect
        let scale: CGFloat
    }
    private weak var view: NSView?
    private var lastGeometry: Geometry?
    private var generation = 0
    private var scheduled = false
    private var previousFrameNotifications = false
    private var previousBoundsNotifications = false
    private let canUpdate: () -> Bool
    private let update: (NSView) -> Void

    init(canUpdate: @escaping () -> Bool, update: @escaping (NSView) -> Void) {
        self.canUpdate = canUpdate
        self.update = update
    }

    func start(view: NSView) {
        stop()
        self.view = view
        lastGeometry = geometry(of: view)
        previousFrameNotifications = view.postsFrameChangedNotifications
        previousBoundsNotifications = view.postsBoundsChangedNotifications
        view.postsFrameChangedNotifications = true
        view.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            center.addObserver(self, selector: #selector(changed), name: name, object: view)
        }
        if let window = view.window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
                center.addObserver(self, selector: #selector(changed), name: name, object: window)
            }
        }
        center.addObserver(self, selector: #selector(changed), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Also call after opening animation/menu tracking ends, to apply deferred movement.
    @objc func changed() {
        guard view != nil, !scheduled else { return }
        scheduled = true
        let scheduledGeneration = generation
        // Coalesce one layout burst; common modes keep this event-driven during
        // AppKit tracking. The owner defers actual movement while a menu is open.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == scheduledGeneration else { return }
                self.scheduled = false
                guard let view = self.view, self.canUpdate(), let next = self.geometry(of: view), next != self.lastGeometry else { return }
                self.lastGeometry = next
                self.update(view)
            }
        }
    }

    func stop() {
        generation += 1
        scheduled = false
        NotificationCenter.default.removeObserver(self)
        view?.postsFrameChangedNotifications = previousFrameNotifications
        view?.postsBoundsChangedNotifications = previousBoundsNotifications
        view = nil
        lastGeometry = nil
    }

    private func geometry(of view: NSView) -> Geometry? {
        guard let window = view.window else { return nil }
        return Geometry(windowNumber: window.windowNumber,
                        screenRect: window.convertToScreen(view.convert(view.bounds, to: nil)),
                        bounds: view.bounds, scale: window.backingScaleFactor)
    }
}
