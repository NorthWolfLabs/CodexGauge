import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class SettingsStore {
    static let supportedRefreshIntervals: [TimeInterval] = [1, 5, 15, 30, 60, 120]
    static let defaultNotificationThresholds = [20, 10, 5]
    private static let preferencesSchemaVersion = 1

    private enum Key {
        static let preferencesSchemaVersion = "preferencesSchemaVersion"
        static let refreshInterval = "refreshInterval"
        static let executableOverride = "executableOverride"
        static let codexHomeOverride = "codexHomeOverride"
        static let quotaNotifications = "quotaNotifications"
        static let attentionNotifications = "attentionNotifications"
        static let notificationThresholds = "notificationThresholds"
    }

    private let defaults: UserDefaults

    var refreshInterval: TimeInterval {
        didSet {
            let normalized = Self.supportedRefreshIntervals.contains(refreshInterval) ? refreshInterval : 60
            if refreshInterval != normalized {
                refreshInterval = normalized
                return
            }
            defaults.set(refreshInterval, forKey: Key.refreshInterval)
        }
    }
    var executableOverride: String {
        didSet { defaults.set(executableOverride, forKey: Key.executableOverride) }
    }
    var codexHomeOverride: String {
        didSet { defaults.set(codexHomeOverride, forKey: Key.codexHomeOverride) }
    }
    var quotaNotificationsEnabled: Bool {
        didSet { defaults.set(quotaNotificationsEnabled, forKey: Key.quotaNotifications) }
    }
    var attentionNotificationsEnabled: Bool {
        didSet { defaults.set(attentionNotificationsEnabled, forKey: Key.attentionNotifications) }
    }
    var notificationThresholds: [Int] {
        didSet {
            let normalized = Array(Set(notificationThresholds.map { max(1, min(99, $0)) })).sorted(by: >)
            if notificationThresholds != normalized {
                notificationThresholds = normalized
                return
            }
            defaults.set(notificationThresholds, forKey: Key.notificationThresholds)
        }
    }
    var launchAtLogin: Bool
    var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let interval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = Self.supportedRefreshIntervals.contains(interval) ? interval : 60
        executableOverride = defaults.string(forKey: Key.executableOverride) ?? ""
        codexHomeOverride = defaults.string(forKey: Key.codexHomeOverride) ?? ""
        let storedThresholds = defaults.array(forKey: Key.notificationThresholds) as? [Int]
        let configuredThresholds = storedThresholds.flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.defaultNotificationThresholds
        let normalizedThresholds = Array(Set(
            configuredThresholds.map { max(1, min(99, $0)) }
        )).sorted(by: >)
        // Early prerelease UI fixtures could leave the sentinel [99, 1] pair in
        // the production preference domain. Repair only that known state; keep
        // every genuine user configuration unchanged.
        let repairsPrereleaseFixture = defaults.integer(forKey: Key.preferencesSchemaVersion) < Self.preferencesSchemaVersion
            && normalizedThresholds == [99, 1]

        quotaNotificationsEnabled = repairsPrereleaseFixture ? false : defaults.bool(forKey: Key.quotaNotifications)
        attentionNotificationsEnabled = defaults.bool(forKey: Key.attentionNotifications)
        notificationThresholds = repairsPrereleaseFixture ? Self.defaultNotificationThresholds : normalizedThresholds
        launchAtLogin = SMAppService.mainApp.status == .enabled

        if repairsPrereleaseFixture {
            defaults.set(false, forKey: Key.quotaNotifications)
            defaults.set(Self.defaultNotificationThresholds, forKey: Key.notificationThresholds)
        }
        defaults.set(Self.preferencesSchemaVersion, forKey: Key.preferencesSchemaVersion)
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
        }
    }

    var codexHomeURL: URL {
        if !codexHomeOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: NSString(string: codexHomeOverride).expandingTildeInPath, isDirectory: true)
        }
        if let inherited = ProcessInfo.processInfo.environment["CODEX_HOME"], !inherited.isEmpty {
            return URL(fileURLWithPath: NSString(string: inherited).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex", directoryHint: .isDirectory)
    }
}
