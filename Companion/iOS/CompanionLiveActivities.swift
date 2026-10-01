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
    private var started = false
    private var foreground = false

    func start() {
        guard !started else { return }; started = true
        for activity in Activity<CompanionActivityAttributes>.activities { observe(activity) }
        Task {
            for await activity in Activity<CompanionActivityAttributes>.activityUpdates { self.observe(activity) }
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
        self.links = links; start()
        status = links.isEmpty ? "Link a Mac to follow its tasks." : !enabled ? "Off" : ActivityAuthorizationInfo().areActivitiesEnabled
            ? "If asked, allow Live Activities on your Lock Screen to receive updates." : "Live Activities are off in iPhone Settings."
        Task {
            for activity in Activity<CompanionActivityAttributes>.activities where replaced.contains(activity.attributes.macID) || !links.contains(where: { $0.id == activity.attributes.macID }) || !enabled {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            await self.syncTokens()
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value, forKey: "liveActivitiesEnabled")
        configure(links); CompanionPush.shared.refreshRegistration()
    }
    func setForeground(_ value: Bool) { foreground = value; if value { configure(links) } }
    var canStartRemotely: Bool { enabled && ActivityAuthorizationInfo().areActivitiesEnabled }
    func end(macID: String) {
        let ids = Set(currentActivities.filter { $0.attributes.macID == macID }.map(\.id))
        Task { await Self.endActivities(ids) }
    }

    func update(_ snapshot: CompanionSnapshot) {
        guard enabled else { return }
        let activities = currentActivities.filter { $0.attributes.macID == snapshot.id }
        let state = CompanionLiveState.from(snapshot, previousTaskID: activities.first?.content.state.taskID)
        if let activity = activities.first {
            // The foreground stream is faster than APNs. Background updates use
            // the separately registered ActivityKit token; no background socket.
            guard (lastUpdate[activity.id].map({ Date.now.timeIntervalSince($0) >= 5 }) ?? true)
                    || !activity.content.state.hasSameTaskSummary(as: state) || !state.hasActiveTasks else { return }
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
                await Self.apply(state, activityID: activityID, duplicateIDs: duplicateIDs)
            }
        } else if foreground && state.hasActiveTasks && !snapshot.isStale(at: .now) {
            // iOS 17.2+ starts via APNs so new tasks also appear when backgrounded.
            // iOS 17.0/17.1 can start locally and still receive remote updates.
            if #available(iOS 17.2, *) { return }
            do {
                let activity = try Activity.request(attributes: CompanionActivityAttributes(macID: snapshot.id, macName: snapshot.name),
                    content: ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: min(state.updatedAt, state.taskObservedAt ?? state.updatedAt) + 90)), pushType: .token)
                observe(activity)
            } catch { status = "A Live Activity couldn’t be started. Check Live Activities in iPhone Settings." }
        }
    }
    // ActivityKit's Activity reference isn't Sendable in this SDK. Resolve it on
    // the executor performing the async operation; only value data crosses over.
    @concurrent private static func apply(_ state: CompanionLiveState, activityID: String, duplicateIDs: Set<String>) async {
        guard let activity = Activity<CompanionActivityAttributes>.activities.first(where: { $0.id == activityID }) else { return }
        guard activity.activityState != .ended && activity.activityState != .dismissed,
              activity.content.state.updatedAt <= state.updatedAt else { return }
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: min(state.updatedAt, state.taskObservedAt ?? state.updatedAt) + 90), relevanceScore: state.attention > 0 ? 100 : 50)
        if #available(iOS 17.2, *) {
            // Order this application of state using the phone's current time.
            // Keep the Mac observation time in content and staleDate instead.
            let timestamp = Date.now
            if state.hasActiveTasks { await activity.update(content, timestamp: timestamp) }
            else { await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(60)), timestamp: timestamp) }
        } else {
            if state.hasActiveTasks { await activity.update(content) }
            else { await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(60))) }
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
        guard enabled else { return }
        var registeredMacs = Set<String>()
        for activity in currentActivities {
            guard let token = tokens[activity.id] ?? activity.pushToken.map(hex),
                  let link = links.first(where: { $0.id == activity.attributes.macID }),
                  registeredMacs.insert(link.id).inserted else { continue }
            do { try await CompanionPush.shared.registerLiveActivity(link, id: activity.id, token: token) }
            catch CompanionError.rejected {
                let id = activity.id
                await Self.endActivities([id])
            }
            catch { status = "Live Activity updates are waiting for a connection. Reopen the app to retry." }
        }
    }
    private func observe(_ activity: Activity<CompanionActivityAttributes>) {
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
            .filter { $0.activityState != .ended && $0.activityState != .dismissed }
            .sorted {
                if $0.content.state.updatedAt != $1.content.state.updatedAt { return $0.content.state.updatedAt > $1.content.state.updatedAt }
                return $0.id < $1.id
            }
    }
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
