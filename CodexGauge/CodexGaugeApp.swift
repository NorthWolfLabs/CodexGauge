import AppKit

@main
enum CodexGaugeApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = CodexGaugeAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class CodexGaugeAppDelegate: NSObject, NSApplicationDelegate {
    let state: AppState
    private let notificationDelegate = NotificationDelegate()
    private var statusItemController: StatusItemController?

    override init() {
        if ProcessInfo.processInfo.arguments.contains("-uiTestDemo") {
            state = DemoData.state()
        } else {
            state = AppState()
        }
        super.init()

        if ProcessInfo.processInfo.arguments.contains("-uiTestDelayedConversations") {
            let delayedConversations = state.conversations
            state.conversations = []
            state.hasLoadedConversations = false
            Task { @MainActor [weak state] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                state?.conversations = delayedConversations
                state?.hasLoadedConversations = true
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        notificationDelegate.configure()
        statusItemController = StatusItemController(state: state)
    }
}
