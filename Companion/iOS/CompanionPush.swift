import UIKit
import ActivityKit
import UserNotifications
import Observation
import OSLog

@MainActor @Observable final class CompanionPush: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let shared = CompanionPush()
    var status = "Not enabled"
    var pendingRoute: CompanionNotificationRoute?
    var kinds: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "phoneAlertKinds") ?? [])
    private var token: String?
    private var links: [CompanionLink] = []
    private var syncing = false
    private var syncAgain = false
    private var liveRegistrations = 0
    private var removing: Set<String> = []
    private let session = CompanionNoRedirect.session()
    static let choices: [(String, String)] = [("low", "Allowance low"), ("allowance", "Allowance reset"),
        ("banked", "Limit reset added"), ("attention", "Task needs input or approval"),
        ("completed", "Task completed"), ("working", "Task working")]

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-companionDemo") && arguments.contains("-companionAlertsOffReview") { Self.shared.kinds = []; Self.shared.status = "Off" }
        if arguments.contains("-companionLiveActivityReview") || arguments.contains("-companionDemo") || arguments.contains("-companionRelayDemo")
            || arguments.contains("-companionResetUITestLinks") { return true }
        #endif
        if let data = CompanionCredentialStore.read("viewing-links"), let links = try? CompanionCoding.decoder.decode([CompanionLink].self, from: data) {
            Self.shared.setLinks(links)
        }
        CompanionLiveActivities.shared.start()
        #if DEBUG
        if arguments.contains("-companionInspectLiveActivities") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                let activities = Activity<CompanionActivityAttributes>.activities
                print("Live registry: count=\(activities.count), active=\(activities.filter { $0.activityState == .active || $0.activityState == .stale }.count), enabled=\(ActivityAuthorizationInfo().areActivitiesEnabled), followEnabled=\(CompanionLiveActivities.shared.enabled), links=\(Self.shared.links.count), startTokenLength=\(CompanionLiveActivities.shared.startToken?.count ?? 0)")
            }
        }
        #endif
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // UIKit creates the delegate instance. Share registration with the observable coordinator.
        Self.shared.token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await Self.shared.sync(); await CompanionLiveActivities.shared.syncTokens() }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.shared.status = "Apple push registration failed. Check the connection and app signing, then try again."
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in completionHandler([.banner, .sound]) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let route = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? CompanionNotificationRoute(userInfo: response.notification.request.content.userInfo) : nil
        // UIKit's completion callback performs UI state restoration. Returning
        // from a nonisolated async delegate can invoke its synthesized callback
        // off-main; deliver the explicit completion on MainActor instead.
        Task { @MainActor in
            if let route { Self.shared.pendingRoute = route }
            completionHandler()
        }
    }
    func setLinks(_ links: [CompanionLink]) {
        self.links = links
        CompanionLiveActivities.shared.configure(links)
        if !links.isEmpty { UIApplication.shared.registerForRemoteNotifications() }
        Task { await sync() }
    }
    func refreshRegistration() { Task { await sync() } }

    func registerLiveActivity(_ link: CompanionLink, id: String, token activityToken: String?, dismissed: Bool = false, ended: Bool = false) async throws {
        guard let token else { throw URLError(.notConnectedToInternet) }
        guard links.contains(link), !removing.contains(link.id) else { throw CancellationError() }
        liveRegistrations += 1
        defer { liveRegistrations -= 1 }
        // Register normal device identity first, including on an ActivityKit wake.
        try await register(link, token: token)
        guard links.contains(link), !removing.contains(link.id) else {
            refreshRegistration()
            throw CancellationError()
        }
        var request = URLRequest(url: link.server.appending(path: "v1/macs/\(link.id)/live-activity"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["token": token, "environment": Self.environment, "activityID": id, "dismissed": dismissed, "ended": ended]
        if let activityToken { payload["activityToken"] = activityToken }
        if let selected = CompanionLiveSelectionPreference.task(macID: link.id) { payload["selectedTaskID"] = selected }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (stream, response) = try await session.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        #if DEBUG
        Logger(subsystem: "com.northwolflabs.CodexGauge", category: "Push").notice("Live registration HTTP \(statusCode ?? 0), device token length \(token.count), activity token length \(activityToken?.count ?? 0)")
        #endif
        if statusCode == 401 || statusCode == 403 { throw CompanionError.rejected }
        guard statusCode == 200 else { throw URLError(.badServerResponse) }
        var count = 0
        for try await _ in stream { count += 1; guard count <= 4096 else { throw CompanionError.invalidData } }
    }
    func set(_ kind: String, enabled: Bool) async {
        if enabled {
            guard await authorize() else { return }
            kinds.insert(kind)
            UIApplication.shared.registerForRemoteNotifications()
        } else { kinds.remove(kind) }
        UserDefaults.standard.set(Array(kinds), forKey: "phoneAlertKinds")
        await sync()
    }
    private func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    status = "Notifications are off in iPhone Settings."; return false
                }
            } catch { status = "Notification permission couldn’t be requested."; return false }
        } else if settings.authorizationStatus == .denied {
            status = "Notifications are off in iPhone Settings."; return false
        }
        return true
    }
    private static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
    func unlink(_ link: CompanionLink) async throws {
        // Suppress re-registration while removing, but keep the saved link on
        // failure so a later reconnect still retries its alert subscription.
        guard removing.insert(link.id).inserted else { throw CompanionError.rejected }
        defer { removing.remove(link.id) }
        while syncing || liveRegistrations > 0 { try await Task.sleep(for: .milliseconds(50)) }
        if token == nil {
            UIApplication.shared.registerForRemoteNotifications()
            for _ in 0..<80 {
                if token != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        // Do not silently abandon a live subscription if Apple registration has
        // not completed yet (for example, removing a link just after launch).
        guard let token else { throw CompanionError.rejected }
        try await register(link, token: token, deleting: true)
        links.removeAll { $0 == link }
    }
    private func sync() async {
        if syncing { syncAgain = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            syncAgain = false
            guard let token else { return }
            guard !links.isEmpty else { status = "Link a Mac to receive alerts."; return }
            status = "Updating alert choices…"
            let eligible = links.filter { !removing.contains($0.id) }
            let failures = await CompanionRegistrationSync.failures(links: eligible) { link in
                try await self.register(link, token: token)
            }
            if failures > 0 {
                status = "Alert setup is pending for \(failures) of \(eligible.count) linked Macs. It will retry when the app reconnects."
            } else if status == "Updating alert choices…" { status = kinds.isEmpty ? "Off" : "Enabled" }
        } while syncAgain
    }
    func reserveForegroundStart(macID: String) async throws -> (allowed: Bool, retry: Bool, retrySoon: Bool) {
        for _ in 0..<80 {
            if token != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let token, let link = links.first(where: { $0.id == macID }), !removing.contains(macID) else { throw URLError(.notConnectedToInternet) }
        while syncing { try await Task.sleep(for: .milliseconds(50)) }
        let result = try await register(link, token: token, foregroundStart: true)
        return (result["foregroundStartAllowed"] == true, result["foregroundStartRetry"] == true, result["foregroundStartRetrySoon"] == true)
    }
    @discardableResult private func register(_ link: CompanionLink, token: String, deleting: Bool = false, foregroundStart: Bool = false) async throws -> [String: Bool] {
        var request = URLRequest(url: link.server.appending(path: "v1/macs/\(link.id)/notifications"))
        request.httpMethod = deleting ? "DELETE" : "POST"
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var live: [String: Any] = ["enabled": CompanionLiveActivities.shared.canStartRemotely, "frequentUpdates": ActivityAuthorizationInfo().frequentPushesEnabled]
        if let startToken = CompanionLiveActivities.shared.startToken { live["pushToStartToken"] = startToken }
        if let ids = CompanionLiveActivities.shared.activeIDsForReconciliation(macID: link.id) { live["activeActivityIDs"] = ids }
        if foregroundStart { live["requestForegroundStart"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "environment": Self.environment, "kinds": Array(kinds), "liveActivities": live])
        let (stream, response) = try await session.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        #if DEBUG
        Logger(subsystem: "com.northwolflabs.CodexGauge", category: "Push").notice("Notification registration for \(link.id, privacy: .public) at \(link.server.host ?? "unknown", privacy: .public) HTTP \(statusCode ?? 0), device token length \(token.count), start token length \(CompanionLiveActivities.shared.startToken?.count ?? 0), foreground requested \(foregroundStart)")
        #endif
        // Revoking viewing links also revokes their push subscriptions server-side.
        // Such a link can be removed locally without trapping the user forever.
        if deleting && (statusCode == 401 || statusCode == 403) { return [:] }
        if statusCode == 401 || statusCode == 403 { throw CompanionError.rejected }
        guard statusCode == 200 else { throw URLError(.badServerResponse) }
        var bytes = Data()
        for try await byte in stream { guard bytes.count < 4096 else { throw CompanionError.invalidData }; bytes.append(byte) }
        let value = (try JSONSerialization.jsonObject(with: bytes) as? [String: Bool]) ?? [:]
        if !deleting, value["configured"] == false {
            status = "The relay still needs its Apple push key."
        }
        #if DEBUG
        if foregroundStart {
            Logger(subsystem: "com.northwolflabs.CodexGauge", category: "LiveActivity").notice("Foreground start allowed \(value["foregroundStartAllowed"] == true), retry \(value["foregroundStartRetry"] == true), dismissed \(value["foregroundStartDismissed"] == true)")
        }
        #endif
        return value
    }
}
