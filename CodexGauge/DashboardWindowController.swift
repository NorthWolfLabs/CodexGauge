import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    private let helpShortcut: HelpShortcutMonitor

    init(state: AppState, onShowHelp: @escaping () -> Void) {
        helpShortcut = HelpShortcutMonitor(onShowHelp: onShowHelp)
        let window = CodexGaugeWindow(contentViewController: NSHostingController(rootView: DashboardView(state: state)))
        window.showHelp = onShowHelp
        window.title = "CodexGauge"
        window.identifier = NSUserInterfaceItemIdentifier("codexgauge.dashboardWindow")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 920, height: 650))
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        helpShortcut.enable()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        helpShortcut.enable()
    }

    func windowDidResignKey(_ notification: Notification) {
        helpShortcut.disable()
    }

    func windowWillClose(_ notification: Notification) {
        helpShortcut.disable()
    }
}
