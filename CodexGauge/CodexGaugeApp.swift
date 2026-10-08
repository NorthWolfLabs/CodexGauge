import AppKit
import Network

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
    private let networkMonitor = NWPathMonitor()
    private var lastNetworkAvailable: Bool?
    private lazy var wakeRelay = MainActorNotificationRelay { [weak self] in
        self?.state.refreshAfterWake()
    }

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
        NSWorkspace.shared.notificationCenter.addObserver(
            wakeRelay, selector: #selector(MainActorNotificationRelay.receive(_:)),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG && STORE_PREVIEW_VERIFICATION
        SandboxRuntimeVerification.start(state)
        #endif
        #if DEBUG
        SandboxMigrationVerification.start(state)
        if arguments.contains("-showNotificationsSettings") {
            statusItemController?.showNotificationPreferencesForDevelopment()
        }
        if arguments.contains("-showDashboard") {
            statusItemController?.showDashboardForDevelopment()
        }
        #endif
        if arguments.contains("-uiTestDemo"),
           let index = arguments.firstIndex(of: "-AppleInterfaceStyle"), arguments.indices.contains(index + 1) {
            NSApp.appearance = NSAppearance(named: arguments[index + 1] == "Dark" ? .darkAqua : .aqua)
        }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let recovered = self.lastNetworkAvailable == false && available
                self.lastNetworkAvailable = available
                if recovered { self.state.refreshAfterWake() }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "com.northwolflabs.CodexGauge.network"))
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
