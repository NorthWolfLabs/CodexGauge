import AppKit

@MainActor
final class CodexGaugeWindow: NSWindow {
    var showHelp: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isHelpShortcut = event.keyCode == 44 && modifiers.contains([.command, .shift])
            if isHelpShortcut {
                showHelp?()
                return
            }
        }
        super.sendEvent(event)
    }
}
