import Foundation

struct CompanionLiveState: Codable, Hashable, Sendable {
    var taskID: String?
    var title: String
    var project: String?
    var state: String
    var running: Int
    var attention: Int
    var tokensPerMinute: Double
    var updatedAt: Double
    var taskObservedAt: Double? = nil
    var startedAt: Double? = nil
    var activity: String? = nil
    var contextPercent: Double? = nil
    var hasRate: Bool? = nil
    var hasActiveTasks: Bool { running + attention > 0 }
    func hasSameTaskSummary(as other: Self) -> Bool {
        taskID == other.taskID && title == other.title && project == other.project && state == other.state
            && running == other.running && attention == other.attention
            && startedAt == other.startedAt && activity == other.activity && contextPercent == other.contextPercent && hasRate == other.hasRate
    }
    var statusTitle: String {
        switch state {
        case "needsInput": "Needs input"
        case "needsApproval": "Needs approval"
        case "running": "Working"
        default: "No active tasks"
        }
    }
    static func from(_ snapshot: CompanionSnapshot, previousTaskID: String? = nil) -> Self {
        let tasks = snapshot.activeTasks
        let attention = tasks.filter { $0.state == .needsInput || $0.state == .needsApproval }
        let candidates = attention.isEmpty ? tasks : attention
        let primary = candidates.first(where: { $0.id == previousTaskID }) ?? candidates.sorted {
            let a = $0.startedAt ?? .distantFuture, b = $1.startedAt ?? .distantFuture
            return a == b ? $0.id < $1.id : a < b
        }.first
        return .init(taskID: primary?.id, title: CompanionText.prefix(primary?.title ?? "No active tasks", utf16Limit: 100),
            project: primary?.project.map { CompanionText.prefix($0, utf16Limit: 80) }, state: primary?.state.rawValue ?? "idle",
            running: tasks.filter { $0.state == .running }.count, attention: attention.count,
            tokensPerMinute: tasks.filter { $0.state == .running }.reduce(0) { $0 + $1.tokensPerMinute },
            updatedAt: snapshot.observedAt.timeIntervalSince1970, taskObservedAt: primary?.observedAt?.timeIntervalSince1970,
            startedAt: primary?.startedAt?.timeIntervalSince1970, activity: primary?.activity, contextPercent: primary?.metrics?.contextIncludesAgent == true ? nil : primary?.contextPercent,
            hasRate: tasks.filter { $0.state == .running }.allSatisfy(\.hasRate))
    }
    func url(macID: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "codexgauge"; parts.host = "tasks"; parts.path = "/" + macID
        if let taskID { parts.queryItems = [URLQueryItem(name: "task", value: taskID)] }
        return parts.url
    }
}

#if os(iOS)
import ActivityKit

struct CompanionActivityAttributes: ActivityAttributes {
    typealias ContentState = CompanionLiveState
    var macID: String
    var macName: String
}
#endif
