import AppKit
import SwiftUI

@MainActor
final class HelpWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: HelpView().codexGaugeWritingToolsDisabled()
            )
        )
        window.title = "CodexGauge Help"
        window.identifier = NSUserInterfaceItemIdentifier("codexgauge.helpWindow")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 800, height: 560))
        window.minSize = NSSize(width: 720, height: 480)
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
    }
}
