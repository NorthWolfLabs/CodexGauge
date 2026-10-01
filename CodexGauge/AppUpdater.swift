import AppKit
import Observation
#if !STORE_BUILD
import Sparkle
#endif

/// Release configuration never accepts a development/beta identity or an unsigned feed setup.
struct UpdateConfiguration: Equatable {
    let feedURL: URL
    let publicKey: String

    init?(bundleIdentifier: String?, developmentBuild: Bool, info: [String: Any]) {
        guard !developmentBuild,
              bundleIdentifier == AppIdentity.stableBundleIdentifier,
              let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        feedURL = url
        publicKey = key
    }
}

#if !STORE_BUILD
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()
    private(set) var isAvailable = false
    private(set) var canCheckForUpdates = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    var automaticallyChecksForUpdates = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    func start() {
        guard controller == nil else { return }
        #if DEBUG
        let developmentBuild = true
        #else
        let developmentBuild = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains("-uiTestDemo")
            || ProcessInfo.processInfo.arguments.contains("-performanceDemo")
        #endif
        guard UpdateConfiguration(bundleIdentifier: Bundle.main.bundleIdentifier,
                                  developmentBuild: developmentBuild,
                                  info: Bundle.main.infoDictionary ?? [:]) != nil else { return }
        let updater = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: nil, userDriverDelegate: nil)
        controller = updater
        isAvailable = true
        do {
            try updater.updater.start()
            automaticallyChecksForUpdates = updater.updater.automaticallyChecksForUpdates
            observation = updater.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let canCheck = change.newValue ?? false
                Task { @MainActor [weak self] in self?.canCheckForUpdates = canCheck }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}
#else
/// Store builds contain no third-party updater; updates belong to the App Store.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()
    let isAvailable = false
    let canCheckForUpdates = false
    let errorMessage: String? = nil
    var automaticallyChecksForUpdates = false
    func start() {}
    func checkForUpdates() {}
}
#endif
