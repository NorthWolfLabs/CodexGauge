import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    private let helpShortcut: HelpShortcutMonitor
    private let state: AppState
    private let onShowHelp: () -> Void
    private var surfaceClock: VisibleSurfaceClock?

    init(state: AppState, onShowHelp: @escaping () -> Void) {
        self.state = state
        self.onShowHelp = onShowHelp
        helpShortcut = HelpShortcutMonitor(onShowHelp: onShowHelp)
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        let presentationStartedAt = ProcessInfo.processInfo.systemUptime
        if window == nil { makeWindow() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        surfaceClock?.start()
        helpShortcut.enable()
        PerformanceSignposts.recordPresentation("dashboard", startedAt: presentationStartedAt)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        helpShortcut.enable()
    }

    func windowDidResignKey(_ notification: Notification) {
        helpShortcut.disable()
    }

    func windowWillClose(_ notification: Notification) {
        helpShortcut.disable()
        surfaceClock?.stop()
        surfaceClock = nil
        window?.contentViewController = nil
        window?.delegate = nil
        window = nil
        RuntimeMemory.scheduleUnusedPageRelease()
    }

    private func makeWindow() {
        let signpost = PerformanceSignposts.begin("Dashboard construction")
        defer { PerformanceSignposts.end("Dashboard construction", signpost) }
        let clock = VisibleSurfaceClock()
        let controller = NSHostingController(rootView: DashboardView(state: state, clock: clock))
        let window = CodexGaugeWindow(contentViewController: controller)
        window.showHelp = onShowHelp
        window.title = "CodexGauge"
        window.identifier = NSUserInterfaceItemIdentifier("codexgauge.dashboardWindow")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = true
        window.setContentSize(NSSize(width: 920, height: 650))
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.delegate = self
        surfaceClock = clock
        self.window = window
    }
}
