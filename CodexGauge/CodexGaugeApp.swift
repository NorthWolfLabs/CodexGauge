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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        notificationDelegate.configure()
        statusItemController = StatusItemController(state: state)
    }
}
