import ActivityKit
import Foundation
import Observation
import UIKit
import OSLog

@MainActor @Observable final class CompanionLiveActivities {
    static let shared = CompanionLiveActivities()
    var enabled = UserDefaults.standard.object(forKey: "liveActivitiesEnabled") as? Bool ?? true
    var status = "Waiting for a linked Mac."
    private(set) var startToken: String?
    private var links: [CompanionLink] = []
    private var observers: [String: Task<Void, Never>] = [:]
    private var stateObservers: [String: Task<Void, Never>] = [:]
    private var tokens: [String: String] = [:]
    private var lastUpdate: [String: Date] = [:]
    private var updates: [String: Task<Void, Never>] = [:]
    private var pendingSnapshots: [String: (snapshot: CompanionSnapshot, timestamp: Double?)] = [:]
    private var pendingFlushes: [String: Task<Void, Never>] = [:]
    private var started = false
    private var foreground = false
    private var registrationTask: Task<Void, Never>?
    private var registrationAgain = false
    private var recoverySnapshots: [String: CompanionSnapshot] = [:]
    private var recoveries: [String: Task<Void, Never>] = [:]
    private var recoveryTickets: [String: UUID] = [:]
    private var recoveryAttempted: Set<String> = []
    // Scope destructive fixture cleanup to the fixture's feed. A native test
    // must not end the owner's saved connection as a side effect of isolation.
    private func manages(macID: String) -> Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-companionUITest"), let id = ProcessInfo.processInfo.environment["COMPANION_ACTIVITY_TEST_MAC_ID"] { return macID == id }
        #endif
        return true
    }

    func start() {
        guard !started else { return }; started = true
        for activity in Activity<CompanionActivityAttributes>.activities { observe(activity) }
        Task {
            for await activity in Activity<CompanionActivityAttributes>.activityUpdates { self.observe(activity) }
        }
        Task {
            for await _ in ActivityAuthorizationInfo().frequentPushEnablementUpdates {
                CompanionPush.shared.refreshRegistration()
            }
        }
        if #available(iOS 17.2, *) {
            if let token = Activity<CompanionActivityAttributes>.pushToStartToken { startToken = hex(token) }
            Task {
                for await token in Activity<CompanionActivityAttributes>.pushToStartTokenUpdates {
                    self.startToken = self.hex(token)
                    CompanionPush.shared.refreshRegistration()
                }
            }
        }
    }
    func configure(_ links: [CompanionLink]) {
        let replaced = Set(self.links.filter { !links.contains($0) }.map(\.id))
        for id in replaced {
            recoveries.removeValue(forKey: id)?.cancel(); recoveryTickets.removeValue(forKey: id); recoverySnapshots.removeValue(forKey: id); recoveryAttempted.remove(id)
        }
        self.links = links; start()
        status = links.isEmpty ? "Link a Mac to follow its tasks." : !enabled ? "Off" : ActivityAuthorizationInfo().areActivitiesEnabled
            ? "If asked, allow Live Activities on your Lock Screen to receive updates." : "Live Activities are off in iPhone Settings."
        Task {
            for activity in Activity<CompanionActivityAttributes>.activities where self.manages(macID: activity.attributes.macID) && (replaced.contains(activity.attributes.macID) || !links.contains(where: { $0.id == activity.attributes.macID }) || !enabled) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            await self.syncTokens()
        }
    }
    func setEnabled(_ value: Bool) {
        if enabled != value {
            recoveries.values.forEach { $0.cancel() }; recoveries.removeAll(); recoveryTickets.removeAll(); recoveryAttempted.removeAll()
        }
        enabled = value; UserDefaults.standard.set(value, forKey: "liveActivitiesEnabled")
        configure(links); CompanionPush.shared.refreshRegistration()
    }
    func setForeground(_ value: Bool) {
        if foreground != value {
            recoveries.values.forEach { $0.cancel() }; recoveries.removeAll(); recoveryTickets.removeAll(); recoveryAttempted.removeAll()
        }
        foreground = value
        if value { configure(links) }
    }
    func activeIDsForReconciliation(macID: String) -> [String]? {
        guard foreground else { return nil }
        return currentActivities.filter { $0.attributes.macID == macID }.map(\.id)
    }
    var canStartRemotely: Bool { enabled && ActivityAuthorizationInfo().areActivitiesEnabled }
    func end(macID: String) {
        let ids = Set(currentActivities.filter { $0.attributes.macID == macID }.map(\.id))
        Task { await Self.endActivities(ids) }
    }

    func update(_ snapshot: CompanionSnapshot, deliveryTimestamp: Double? = nil) {
        guard enabled else { return }
        let activities = currentActivities.filter { $0.attributes.macID == snapshot.id }
        let state = CompanionLiveState.from(snapshot, previousTaskID: activities.first?.content.state.taskID, selectedTaskID: CompanionLiveSelectionPreference.task(macID: snapshot.id))
        if !state.hasActiveTasks { recoverySnapshots.removeValue(forKey: snapshot.id); recoveryAttempted.remove(snapshot.id) }
        if let activity = activities.first {
            // The foreground stream is faster than APNs. Background updates use
            // the separately registered ActivityKit token; no background socket.
            guard (lastUpdate[activity.id].map({ Date.now.timeIntervalSince($0) >= 1 }) ?? true)
                    || activity.content.state.taskID != state.taskID || activity.content.state.state != state.state || !state.hasActiveTasks else {
                pendingSnapshots[activity.id] = (snapshot, deliveryTimestamp)
                if pendingFlushes[activity.id] == nil {
                    let id = activity.id
                    pendingFlushes[id] = Task {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        self.pendingFlushes.removeValue(forKey: id)
                        if let latest = self.pendingSnapshots.removeValue(forKey: id) { self.update(latest.snapshot, deliveryTimestamp: latest.timestamp) }
                    }
                }
                return
            }
            pendingSnapshots.removeValue(forKey: activity.id)
            pendingFlushes.removeValue(forKey: activity.id)?.cancel()
            lastUpdate[activity.id] = .now
            let activityID = activity.id
            let duplicateIDs = Set(activities.dropFirst().map(\.id))
            let previous = updates[activityID]
            updates[activityID] = Task {
                // Serialize local applications before assigning delivery times.
                // A later queued snapshot must not be overtaken by an older one.
                if let previous { await previous.value }
                guard !Task.isCancelled, self.enabled,
                      self.links.contains(where: { $0.id == snapshot.id }) else { return }
                await Self.apply(state, activityID: activityID, duplicateIDs: duplicateIDs, deliveryTimestamp: deliveryTimestamp)
            }
        } else if foreground && state.hasActiveTasks && !snapshot.isStale(at: .now) {
            recoverySnapshots[snapshot.id] = snapshot
            guard recoveryAttempted.insert(snapshot.id).inserted else { return }
            let ticket = UUID(); recoveryTickets[snapshot.id] = ticket
            recoveries[snapshot.id] = Task {
                defer {
                    if self.recoveryTickets[snapshot.id] == ticket {
                        self.recoveries.removeValue(forKey: snapshot.id); self.recoveryTickets.removeValue(forKey: snapshot.id)
                    }
                }
                do {
                    // The relay owns dismissal state and reserves a short local
                    // start window. Remote starts still work while backgrounded.
                    var permission = try await CompanionPush.shared.reserveForegroundStart(macID: snapshot.id)
                    for _ in 0..<2 {
                        guard !permission.allowed && permission.retry else { break }
                        try await Task.sleep(for: permission.retrySoon ? .milliseconds(1250) : .seconds(31))
                        guard self.foreground, self.enabled, self.currentActivities.allSatisfy({ $0.attributes.macID != snapshot.id }) else { return }
                        permission = try await CompanionPush.shared.reserveForegroundStart(macID: snapshot.id)
                    }
                    guard permission.allowed, !Task.isCancelled, self.foreground, self.canStartRemotely,
                          self.links.contains(where: { $0.id == snapshot.id }),
                          self.currentActivities.allSatisfy({ $0.attributes.macID != snapshot.id }),
                          let latest = self.recoverySnapshots[snapshot.id], !latest.isStale(at: .now) else { return }
                    let latestState = CompanionLiveState.from(latest, selectedTaskID: CompanionLiveSelectionPreference.task(macID: snapshot.id))
                    guard latestState.hasActiveTasks else { return }
                    let activity = try Activity.request(attributes: CompanionActivityAttributes(macID: latest.id, macName: latest.name),
                        content: ActivityContent(state: latestState, staleDate: Date(timeIntervalSince1970: latestState.updatedAt + CompanionLiveState.freshnessInterval)), pushType: .token)
                    self.observe(activity)
                } catch is CancellationError {} catch {
                    self.status = "A Live Activity couldn’t be started. Open the app to reconnect."
                }
            }
        }
    }
    // ActivityKit's Activity reference isn't Sendable in this SDK. Resolve it on
    // the executor performing the async operation; only value data crosses over.
    @concurrent private static func apply(_ state: CompanionLiveState, activityID: String, duplicateIDs: Set<String>, deliveryTimestamp: Double?) async {
        guard let activity = Activity<CompanionActivityAttributes>.activities.first(where: { $0.id == activityID }) else { return }
        guard activity.activityState != .ended && activity.activityState != .dismissed,
              activity.content.state.updatedAt <= state.updatedAt else { return }
        var delivered = state
        let timestamp = deliveryTimestamp.map { Date(timeIntervalSince1970: $0) } ?? Date.now
        delivered.deliveryTimestamp = timestamp.timeIntervalSince1970
        let content = ActivityContent(state: delivered, staleDate: Date(timeIntervalSince1970: state.updatedAt + CompanionLiveState.freshnessInterval), relevanceScore: state.attention > 0 ? 100 : 50)
        if #available(iOS 17.2, *) {
            // Use the relay's delivery clock for both the stream and APNs.
            // Keep the Mac observation time in content and staleDate instead.
            if state.hasActiveTasks { await activity.update(content, timestamp: timestamp) }
            else { await activity.end(nil, dismissalPolicy: .immediate, timestamp: timestamp) }
        } else {
            if state.hasActiveTasks { await activity.update(content) }
            else { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        for duplicate in Activity<CompanionActivityAttributes>.activities where duplicateIDs.contains(duplicate.id) {
            await duplicate.end(nil, dismissalPolicy: .immediate)
        }
    }
    @concurrent private static func endActivities(_ ids: Set<String>) async {
        for activity in Activity<CompanionActivityAttributes>.activities where ids.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    func syncTokens() async {
        if let registrationTask { registrationAgain = true; await registrationTask.value; return }
        let task = Task {
            let ticket = UIApplication.shared.beginBackgroundTask(withName: "Register Live Activity") {
                self.registrationTask?.cancel()
            }
            defer { if ticket != .invalid { UIApplication.shared.endBackgroundTask(ticket) } }
            repeat {
                self.registrationAgain = false
                await self.registerTokens()
            } while self.registrationAgain && !Task.isCancelled
        }
        registrationTask = task
        await task.value
        registrationTask = nil
    }
    private func registerTokens() async {
        guard enabled else { return }
        var registeredMacs = Set<String>()
        for activity in currentActivities {
            guard let token = tokens[activity.id] ?? activity.pushToken.map(hex),
                  let link = links.first(where: { $0.id == activity.attributes.macID }),
                  registeredMacs.insert(link.id).inserted else { continue }
            do {
                try await CompanionRegistrationSync.retryLiveRegistration {
                    guard self.enabled, self.links.contains(link), !Task.isCancelled else { throw CancellationError() }
                    let latestToken = self.tokens[activity.id] ?? token
                    try await CompanionPush.shared.registerLiveActivity(link, id: activity.id, token: latestToken)
                }
                status = "Live Activity updates connected."
            }
            catch CompanionError.rejected {
                let id = activity.id
                await Self.endActivities([id])
            }
            catch is CancellationError { return }
            catch { status = "Live Activity updates are waiting for a connection. Open the app to reconnect." }
        }
    }
    private func observe(_ activity: Activity<CompanionActivityAttributes>) {
        guard manages(macID: activity.attributes.macID) else { return }
        #if DEBUG
        Logger(subsystem: "com.northwolflabs.CodexGauge", category: "LiveActivity").notice("Observed activity, enabled \(self.enabled), linked \(self.links.contains(where: { $0.id == activity.attributes.macID }))")
        #endif
        // Push-to-start can arrive after a link was removed or the feature was
        // switched off. It must not leave a task card on the Lock Screen.
        guard enabled, links.contains(where: { $0.id == activity.attributes.macID }) else {
            let id = activity.id
            Task { await Self.endActivities([id]) }; return
        }
        let duplicates = currentActivities.filter { $0.attributes.macID == activity.attributes.macID }.dropFirst()
        let duplicateIDs = Set(duplicates.map(\.id))
        if !duplicateIDs.isEmpty { Task { await Self.endActivities(duplicateIDs) } }
        guard !duplicates.contains(where: { $0.id == activity.id }) else { return }
        guard observers[activity.id] == nil else { return }
        observers[activity.id] = Task {
            for await token in activity.pushTokenUpdates {
                #if DEBUG
                Logger(subsystem: "com.northwolflabs.CodexGauge", category: "LiveActivity").notice("Received update token, bytes \(token.count)")
                #endif
                self.tokens[activity.id] = self.hex(token)
                await self.syncTokens()
            }
        }
        stateObservers[activity.id] = Task {
            for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                if let link = self.links.first(where: { $0.id == activity.attributes.macID }) {
                    try? await CompanionPush.shared.registerLiveActivity(link, id: activity.id, token: nil,
                        dismissed: state == .dismissed, ended: state == .ended)
                }
                self.tokens.removeValue(forKey: activity.id)
                self.lastUpdate.removeValue(forKey: activity.id)
                self.pendingSnapshots.removeValue(forKey: activity.id)
                self.pendingFlushes.removeValue(forKey: activity.id)?.cancel()
                self.updates.removeValue(forKey: activity.id)?.cancel()
                self.observers.removeValue(forKey: activity.id)?.cancel()
                self.stateObservers.removeValue(forKey: activity.id)
                break
            }
        }
        if let token = activity.pushToken { tokens[activity.id] = hex(token); Task { await syncTokens() } }
    }
    private var currentActivities: [Activity<CompanionActivityAttributes>] {
        Activity<CompanionActivityAttributes>.activities
            .filter { manages(macID: $0.attributes.macID) && $0.activityState != .ended && $0.activityState != .dismissed }
            .sorted {
                if $0.content.state.updatedAt != $1.content.state.updatedAt { return $0.content.state.updatedAt > $1.content.state.updatedAt }
                return $0.id < $1.id
            }
    }
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
