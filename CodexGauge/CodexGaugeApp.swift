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
    private var performanceWorkload: PerformanceWorkloadController?

    override init() {
        let processInfo = ProcessInfo.processInfo
        if processInfo.arguments.contains("-uiTestDemo")
            || processInfo.arguments.contains("-performanceDemo") {
            state = DemoData.state()
        } else if processInfo.environment["XCTestConfigurationFilePath"] != nil {
            // A hosted unit-test bundle should not discover or launch the user's
            // installed Codex helper, inspect local sessions, or query notification
            // authorization. Individual tests inject the providers they exercise.
            state = AppState(startImmediately: false)
        } else {
            state = AppState()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        notificationDelegate.configure()
        statusItemController = StatusItemController(state: state)
        let arguments = ProcessInfo.processInfo.arguments
        if let marker = arguments.firstIndex(of: "-performanceScenario"), arguments.indices.contains(marker + 1) {
            let scenario = arguments[marker + 1]
            if arguments.contains("-performanceStress") {
                let workload = PerformanceWorkloadController()
                performanceWorkload = workload
                workload.start()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                await self?.statusItemController?.runPerformanceScenario(scenario)
            }
        }
    }
}
