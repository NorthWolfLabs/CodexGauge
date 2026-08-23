import AppKit
import Carbon.HIToolbox

@MainActor
final class HelpShortcutMonitor: NSObject {
    private static let signature: OSType = 0x43475848 // "CGXH"

    private let onShowHelp: () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    init(onShowHelp: @escaping () -> Void) {
        self.onShowHelp = onShowHelp
        super.init()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<HelpShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
                monitor.performSelector(onMainThread: #selector(HelpShortcutMonitor.openHelp), with: nil, waitUntilDone: false)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    func enable() {
        guard hotKey == nil else { return }
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Slash),
            UInt32(cmdKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    func disable() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }

    @objc private func openHelp() {
        onShowHelp()
    }

}
