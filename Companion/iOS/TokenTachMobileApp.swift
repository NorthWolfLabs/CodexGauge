import SwiftUI
import ActivityKit

@main struct TokenTachMobileApp: App {
    @UIApplicationDelegateAdaptor(CompanionPush.self) private var pushDelegate
    @State private var store = CompanionStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-companionLiveActivityReview") {
                CompanionActivityLayoutReview()
            } else { home }
            #else
            home
            #endif
        }
    }
    private var home: some View {
        CompanionHome(store: store)
            .modifier(CompanionTestTypeSize())
            .onChange(of: scenePhase, initial: true) { _, phase in store.setForeground(phase == .active) }
    }
}

#if DEBUG
/// Local ActivityKit fixture. No viewing links, push tokens or preferences are
/// read/written, and cleanup is limited to this fixture's attribute prefix.
private struct CompanionActivityLayoutReview: View {
    @State private var activityID: String?
    @State private var message = "Ready"
    nonisolated private static let prefix = "codexgauge-layout-review-"
    var body: some View {
        NavigationStack {
            List {
                Text(message).accessibilityIdentifier("live-review.status")
                ForEach(["Working", "Updated work", "Needs input", "Needs approval", "Multiple tasks", "Short task", "Sleep tool", "Stale", "Zero rate"], id: \.self) { name in
                    Button(name) { Task { await show(name) } }
                }
                Button("End review activity") { Task { await Self.finish(); activityID = nil; message = "Ended" } }
            }.navigationTitle("Live Activity review")
        }
    }
    @MainActor private func show(_ name: String) async {
        let now = Date.now.timeIntervalSince1970
        let attention = name == "Needs input" || name == "Needs approval"
        var state = CompanionLiveState(taskID: "layout-review-task",
            title: name == "Multiple tasks" ? "Create cross-platform UI polish for the account cards" : "Create cross-platform UI polish", project: "ViewTranslate",
            state: name == "Needs input" ? "needsInput" : name == "Needs approval" ? "needsApproval" : "running",
            running: attention ? 0 : name == "Multiple tasks" ? 12 : 1,
            attention: attention ? 1 : name == "Multiple tasks" ? 3 : 0,
            tokensPerMinute: name == "Zero rate" ? 0 : name == "Updated work" ? 1600 : 12800, updatedAt: now,
            taskObservedAt: now, startedAt: now - 318, activity: name == "Updated work" ? "Thinking" : "Using a tool", contextPercent: name == "Updated work" ? 72 : 64, hasRate: true, account: "alex@example.com")
        if name == "Short task" || name == "Sleep tool" {
            state.title = name == "Short task" ? "UI" : "Test sleep tool call"
            state.project = name == "Short task" ? "Allweave" : "Computer"
            state.running = 2; state.attention = 0
            if name == "Sleep tool" { state.contextPercent = nil; state.tokensPerMinute = 0 }
        }
        state.deliveryTimestamp = now
        if name == "Multiple tasks" {
            state.nextTask = .init(taskID: "layout-review-task-1", title: "Review selected task 2", project: "TokenTach", state: "running",
                tokensPerMinute: 12800, taskObservedAt: now, startedAt: now - 318, activity: "Using a tool", contextPercent: 64, hasRate: true, taskIndex: 1)
        }
        do {
            if let activityID {
                await Self.update(activityID, state: state, stale: name == "Stale")
            } else {
                await Self.finish()
                let activity = try Activity.request(attributes: CompanionActivityAttributes(
                    macID: Self.prefix + UUID().uuidString, macName: "George’s M4 Mac Mini"),
                    content: ActivityContent(state: state, staleDate: name == "Stale" ? .now.addingTimeInterval(-1) : .now.addingTimeInterval(600)),
                    pushType: nil)
                activityID = activity.id
                // Give the preview and ActivityKit the same delivery timestamp.
                await Self.update(activity.id, state: state, stale: name == "Stale")
            }
            message = "Showing " + name
        } catch { message = "Failed: " + error.localizedDescription }
    }
    @concurrent private static func update(_ id: String, state: CompanionLiveState, stale: Bool) async {
        if let activity = Activity<CompanionActivityAttributes>.activities.first(where: { $0.id == id }) {
            let timestamp = Date.now
            var delivered = state
            delivered.deliveryTimestamp = timestamp.timeIntervalSince1970
            let content = ActivityContent(state: delivered, staleDate: stale ? .now.addingTimeInterval(-1) : .now.addingTimeInterval(600))
            if #available(iOS 17.2, *) { await activity.update(content, timestamp: timestamp) }
            else { await activity.update(content) }
        }
    }
    @concurrent private static func finish() async {
        for activity in Activity<CompanionActivityAttributes>.activities where activity.attributes.macID.hasPrefix(prefix) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif

private struct CompanionTestTypeSize: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-companionMaximumType") {
            content.dynamicTypeSize(.accessibility5)
        } else if ProcessInfo.processInfo.arguments.contains("-companionLargeType") {
            content.dynamicTypeSize(.accessibility3)
        } else { content }
        #else
        content
        #endif
    }
}
