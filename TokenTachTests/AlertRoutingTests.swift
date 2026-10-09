import Foundation
import Testing
@testable import TokenTach

@MainActor private final class RoutingLocal: NotificationScheduling {
    var delivered: [ResetAlert] = []
    var fails = false
    func deliver(_ alert: ResetAlert) async -> Bool {
        if fails { return false }
        delivered.append(alert); return true
    }
    func authorizationStatus() async -> NotificationAuthorizationState { .authorized }
    func requestAuthorization() async -> Bool { true }
    func evaluate(snapshot: AccountSnapshot, thresholds: [Int]) async {}
    func evaluate(conversations: [ConversationTelemetry]) async {}
}
@MainActor struct AlertRoutingTests {
    private let epoch = Date(timeIntervalSince1970: 2_000_000_000)
    private func snapshot(_ seconds: Double, count: Int = 1, used: Int = 50, reset: Double = 100) -> RateLimitSnapshot {
        RateLimitSnapshot(plan: "pro", buckets: [QuotaBucket(id: "codex", name: "Codex", plan: "pro",
            windows: [QuotaWindow(id: "primary", kind: "Primary", usedPercent: used, durationMinutes: 300,
                                 resetsAt: epoch.addingTimeInterval(reset))],
            credits: nil, spendControl: nil, spendControlReached: nil, reachedReason: nil)],
            earnedResetCount: count, fetchedAt: epoch.addingTimeInterval(seconds))
    }
    private func task(_ state: ConversationState, at: Double, completed: Bool = false) -> ConversationTelemetry {
        ConversationTelemetry(id: "private-thread", title: "PRIVATE TASK TITLE", workspace: "PRIVATE PATH", model: nil,
            state: state, activity: .waiting, tokensPerMinute: 0, tokensPerFiveMinutes: 0, callsPerMinute: nil,
            totalTokens: 0, recentTokenMix: .zero, latestContextPercent: nil, turnStartedAt: nil,
            lastTurnDurationSeconds: nil, latestOutputTokens: nil, timeToFirstTokenMilliseconds: nil,
            attentionEventAt: state == .needsInput ? epoch.addingTimeInterval(at) : nil, agentCount: 0,
            lastActivity: epoch.addingTimeInterval(at), completionEventAt: completed ? epoch.addingTimeInterval(at) : nil,
            projectName: "Example Project")
    }
    private func settle(_ monitor: AlertMonitor) async {
        for _ in 0..<100 {
            if monitor.pendingCount == 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func everyEventSupportsLocalOnAndOffWithTaskMetadata() async throws {
        for kind in ResetAlertKind.allCases {
            for route in AlertDestination.allCases {
                let suite = "RoutingTests.\(UUID())"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let settings = SettingsStore(defaults: defaults)
                for other in ResetAlertKind.allCases { settings.setDestination(.off, for: other) }
                settings.setDestination(route, for: kind)
                let local = RoutingLocal()
                let monitor = AlertMonitor(settings: settings, local: local, store: MemoryAlertMonitorStore())
                defer { monitor.suspend() }
                monitor.observe(snapshot(0), scope: "A")
                monitor.observeTasks([task(.running, at: 0)], at: epoch)
                switch kind {
                case .working:
                    monitor.observeTasks([task(.idle, at: 0)], at: epoch)
                    monitor.observeTasks([task(.running, at: 1)], at: epoch.addingTimeInterval(1))
                case .banked: monitor.observe(snapshot(1, count: 2), scope: "A")
                case .allowance: monitor.observe(snapshot(101, reset: 200), scope: "A")
                case .low: monitor.observe(snapshot(1, used: 95), scope: "A")
                case .attention: monitor.observeTasks([task(.needsInput, at: 1)], at: epoch.addingTimeInterval(1))
                case .completed: monitor.observeTasks([task(.idle, at: 1, completed: true)], at: epoch.addingTimeInterval(1))
                }
                await settle(monitor)
                #expect(local.delivered.map(\.kind) == (route.apple ? [kind] : []))
                let isTask = kind == .attention || kind == .completed || kind == .working
                if route.apple && isTask {
                    #expect(local.delivered.first?.name == "PRIVATE TASK TITLE")
                    #expect(local.delivered.first?.projectName == "Example Project")
                }
                let persisted = String(decoding: try JSONEncoder().encode(local.delivered), as: UTF8.self)
                #expect(!persisted.contains("PRIVATE PATH"))
                #expect(!persisted.contains("private-thread"))

            }
        }
    }

    @Test func completedRequiresAnExplicitNewEventAndNeverReplaysHistory() async {
        let suite = "RoutingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.setDestination(.apple, for: .completed)
        let local = RoutingLocal()
        let store = MemoryAlertMonitorStore()
        let monitor = AlertMonitor(settings: settings, local: local, store: store)
        monitor.observe(snapshot(0), scope: "A")
        monitor.observeTasks([task(.idle, at: -10, completed: true)], at: epoch)
        monitor.observeTasks([task(.running, at: 1)], at: epoch.addingTimeInterval(1))
        monitor.observeTasks([task(.recent, at: 2)], at: epoch.addingTimeInterval(2))
        #expect(local.delivered.isEmpty)
        monitor.observeTasks([task(.idle, at: 3, completed: true)], at: epoch.addingTimeInterval(3))
        await settle(monitor)
        monitor.observeTasks([task(.idle, at: 3, completed: true)], at: epoch.addingTimeInterval(4))
        #expect(local.delivered.count == 1)
        monitor.suspend()
        let restarted = AlertMonitor(settings: settings, local: local, store: store)
        restarted.observe(snapshot(5), scope: "A")
        restarted.observeTasks([task(.idle, at: 3, completed: true)], at: epoch.addingTimeInterval(5))
        #expect(local.delivered.count == 1)
        restarted.suspend()
    }

    @Test func restartRecoversTaskTransitionWithAnObservationWindow() async {
        let suite = "RoutingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.setDestination(.apple, for: .completed)
        let local = RoutingLocal()
        let store = MemoryAlertMonitorStore()
        let before = AlertMonitor(settings: settings, local: local, store: store)
        before.observe(snapshot(0), scope: "A")
        before.observeTasks([task(.running, at: 0)], at: epoch)
        before.suspend()
        let after = AlertMonitor(settings: settings, local: local, store: store)
        after.observe(snapshot(10), scope: "A")
        after.observeTasks([task(.idle, at: 5, completed: true)], at: epoch.addingTimeInterval(10))
        await settle(after)
        #expect(local.delivered.count == 1)
        #expect(local.delivered.first?.isCatchUp == true)
        #expect(local.delivered.first?.since == epoch)
        #expect(local.delivered.first?.observedAt == epoch.addingTimeInterval(10))
        after.suspend()
    }

    @Test func legacyChoicesMigrateAndNewChoicesPersist() throws {
        let suite = "RoutingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "quotaNotifications")
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.destination(for: .low) == .apple)
        #expect(settings.destination(for: .banked) == .off)
        #expect(settings.destination(for: .allowance) == .off)
        #expect(settings.destination(for: .completed) == .off)
        settings.setDestination(.apple, for: .completed)
        #expect(SettingsStore(defaults: defaults).destination(for: .completed) == .apple)
    }

    @Test func retiredDestinationsPreserveOnlyPreviouslyEnabledAppleDelivery() throws {
        let suite = "RoutingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"low":"apple","attention":"both","completed":"slack","banked":"off","working":"ntfy","allowance":"appleAndNtfy"}"#.utf8), forKey: "alertDestinations")
        for key in ["ntfyUsage", "ntfyConfigured", "ntfyConfiguration"] { defaults.set("retired", forKey: key) }
        let settings = SettingsStore(defaults: defaults)
        for key in ["ntfyUsage", "ntfyConfigured", "ntfyConfiguration"] { #expect(defaults.object(forKey: key) == nil) }
        #expect(settings.destination(for: .low) == .apple)
        #expect(settings.destination(for: .attention) == .apple)
        #expect(settings.destination(for: .completed) == .off)
        #expect(settings.destination(for: .banked) == .off)
        #expect(settings.destination(for: .working) == .off)
        #expect(settings.destination(for: .allowance) == .apple)
        let stored = try #require(defaults.data(forKey: "alertDestinations"))
        let canonical = try JSONDecoder().decode([String: String].self, from: stored)
        #expect(Set(canonical.values) == ["apple", "off"])
        #expect(SettingsStore(defaults: defaults).destination(for: .attention) == .apple)
    }

    @Test func retiredQueueEntriesDoNotReplayOrDiscardPendingAppleEvents() async throws {
        let suite = "RoutingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.setDestination(.apple, for: .banked)
        let local = RoutingLocal()
        let store = MemoryAlertMonitorStore()
        let event = ResetAlert(kind: .banked, key: "banked", name: "Codex", added: 1,
                               available: 2, since: epoch, observedAt: epoch)
        let state = AlertMonitorState(scope: "A", routes: ["banked": .apple],
            pending: [RoutedAlert(event: event, apple: true), RoutedAlert(event: event, apple: false)])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var pending = try #require(json["pending"] as? [[String: Any]])
        for index in pending.indices { pending[index]["slackConnection"] = UUID().uuidString; pending[index]["ntfyConfigurationID"] = UUID().uuidString }
        json["pending"] = pending
        json["routes"] = ["banked": "appleAndNtfy"]
        store.value = try JSONDecoder().decode(AlertMonitorState.self, from: JSONSerialization.data(withJSONObject: json))
        let monitor = AlertMonitor(settings: settings, local: local, store: store)
        defer { monitor.suspend() }
        #expect(monitor.pendingCount == 1)
        #expect(local.delivered.isEmpty)
        monitor.observe(snapshot(1, count: 2), scope: "A")
        await settle(monitor)
        #expect(local.delivered.count == 1)
        #expect(local.delivered.first?.isCatchUp == true)
        #expect(store.value?.pending.isEmpty == true)
    }

    @Test(arguments: ["A", "B"])
    func persistedAppleDeliveryRequiresTheSameAccount(account: String) async {
        let suite = "RoutingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.setDestination(.apple, for: .banked)
        let local = RoutingLocal()
        let store = MemoryAlertMonitorStore()
        let monitor = AlertMonitor(settings: settings, local: local, store: store)
        local.fails = true
        monitor.observe(snapshot(0), scope: "A")
        monitor.observe(snapshot(1, count: 2), scope: "A")
        #expect(store.value?.pending.count == 1)
        monitor.suspend()
        local.fails = false
        let restarted = AlertMonitor(settings: settings, local: local, store: store)
        #expect(local.delivered.isEmpty)
        restarted.observe(snapshot(2, count: 2), scope: account)
        await settle(restarted)
        #expect(local.delivered.count == (account == "A" ? 1 : 0))
        if account == "A" { #expect(local.delivered.first?.isCatchUp == true) }
        restarted.suspend()
    }

    @Test func reenabledResetRouteEstablishesNewBaseline() async {
        let suite = "RoutingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.setDestination(.apple, for: .banked)
        let local = RoutingLocal()
        let monitor = AlertMonitor(settings: settings, local: local, store: MemoryAlertMonitorStore())
        monitor.observe(snapshot(0), scope: "A")
        settings.setDestination(.off, for: .banked); monitor.routesChanged()
        monitor.observe(snapshot(1, count: 3), scope: "A")
        settings.setDestination(.apple, for: .banked); monitor.routesChanged()
        monitor.observe(snapshot(2, count: 4), scope: "A")
        #expect(local.delivered.isEmpty)
        monitor.observe(snapshot(3, count: 5), scope: "A")
        await settle(monitor)
        #expect(local.delivered.count == 1)
        #expect(local.delivered.first?.added == 1)
        monitor.suspend()
    }
}
