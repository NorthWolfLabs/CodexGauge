import Foundation

/// A bounded next-task observation travels with each card so selecting it can
/// begin locally. It never advances the observation's freshness deadline.
struct CompanionLiveTaskPreview: Codable, Hashable, Sendable {
    var taskID: String
    var title: String
    var project: String?
    var state: String
    var tokensPerMinute: Double
    var taskObservedAt: Double?
    var startedAt: Double?
    var activity: String?
    var contextPercent: Double?
    var hasRate: Bool
    var taskIndex: Int
}

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
    var account: String? = nil
    var taskIndex: Int? = nil
    var selectionIsPinned: Bool? = nil
    var nextTask: CompanionLiveTaskPreview? = nil
    var deliveryTimestamp: Double? = nil
    var selectionPending: Bool? = nil
    static let freshnessInterval: Double = 180
    var staleAt: Date { Date(timeIntervalSince1970: updatedAt + Self.freshnessInterval) }
    var hasActiveTasks: Bool { running + attention > 0 }
    var taskPosition: String? { running + attention > 1 ? "\(displayedTaskIndex + 1)/\(running + attention)" : nil }
    private var displayedTaskIndex: Int { min(max(0, taskIndex ?? 0), max(0, running + attention - 1)) }
    var taskPositionDescription: String {
        "Showing \(displayedTaskIndex + 1) of \(running + attention) active tasks" + (taskCountSummary.map { ". \($0)" } ?? "")
    }
    var taskCountSummary: String? {
        let otherRunning = max(0, running - (state == "running" ? 1 : 0))
        let otherWaiting = max(0, attention - (["needsInput", "needsApproval"].contains(state) ? 1 : 0))
        let parts = [otherRunning > 0 ? "\(otherRunning) other running task\(otherRunning == 1 ? "" : "s")" : nil,
                otherWaiting > 0 ? "\(otherWaiting) other task\(otherWaiting == 1 ? "" : "s") waiting" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return parts.isEmpty ? nil : parts
    }
    var activityTitle: String {
        if state == "running", let activity, !activity.isEmpty, activity != "Activity unavailable" { return activity }
        return statusTitle
    }
    func displayedRate(stale: Bool) -> Double? {
        guard !stale, running > 0, hasRate == true,
              tokensPerMinute.isFinite, tokensPerMinute > 0 else { return nil }
        return tokensPerMinute
    }
    func hasSameTaskSummary(as other: Self) -> Bool {
        taskID == other.taskID && title == other.title && project == other.project && state == other.state
            && running == other.running && attention == other.attention
            && startedAt == other.startedAt && activity == other.activity && contextPercent == other.contextPercent && hasRate == other.hasRate && account == other.account && tokensPerMinute == other.tokensPerMinute && taskIndex == other.taskIndex && selectionIsPinned == other.selectionIsPinned && nextTask == other.nextTask
    }
    var statusTitle: String {
        switch state {
        case "needsInput": "Needs input"
        case "needsApproval": "Needs approval"
        case "running": "Working"
        default: "No active tasks"
        }
    }
    static func from(_ snapshot: CompanionSnapshot, previousTaskID: String? = nil, selectedTaskID: String? = nil) -> Self {
        let tasks = snapshot.activeTasks.sorted {
            let a = $0.state == .running ? 1 : 0, b = $1.state == .running ? 1 : 0
            if a != b { return a < b }
            let startA = $0.startedAt ?? .distantFuture, startB = $1.startedAt ?? .distantFuture
            return startA == startB ? $0.id < $1.id : startA < startB
        }
        let attention = tasks.filter { $0.state == .needsInput || $0.state == .needsApproval }
        let candidates = attention.isEmpty ? tasks : attention
        let primary = tasks.first(where: { $0.id == selectedTaskID }) ?? candidates.first(where: { $0.id == previousTaskID }) ?? candidates.sorted {
            let a = $0.startedAt ?? .distantFuture, b = $1.startedAt ?? .distantFuture
            return a == b ? $0.id < $1.id : a < b
        }.first
        let nextIndex = primary.flatMap { primary in tasks.firstIndex(where: { $0.id == primary.id }) }.map { ($0 + 1) % max(1, tasks.count) }
        let next = tasks.count > 1 ? nextIndex.map { index -> CompanionLiveTaskPreview in
            let task = tasks[index]
            return .init(taskID: task.id, title: CompanionText.prefix(task.title, utf16Limit: 100),
                project: task.project.map { CompanionText.prefix($0, utf16Limit: 80) }, state: task.state.rawValue,
                tokensPerMinute: task.state == .running ? task.tokensPerMinute : 0,
                taskObservedAt: task.observedAt?.timeIntervalSince1970, startedAt: task.startedAt?.timeIntervalSince1970,
                activity: task.activity, contextPercent: task.metrics?.contextIncludesAgent == true ? nil : task.contextPercent,
                hasRate: task.hasRate, taskIndex: index)
        } : nil
        return .init(taskID: primary?.id, title: CompanionText.prefix(primary?.title ?? "No active tasks", utf16Limit: 100),
            project: primary?.project.map { CompanionText.prefix($0, utf16Limit: 80) }, state: primary?.state.rawValue ?? "idle",
            running: tasks.filter { $0.state == .running }.count, attention: attention.count,
            tokensPerMinute: primary?.state == .running ? primary?.tokensPerMinute ?? 0 : 0,
            updatedAt: snapshot.observedAt.timeIntervalSince1970, taskObservedAt: primary?.observedAt?.timeIntervalSince1970,
            startedAt: primary?.startedAt?.timeIntervalSince1970, activity: primary?.activity, contextPercent: primary?.metrics?.contextIncludesAgent == true ? nil : primary?.contextPercent,
            hasRate: primary?.hasRate ?? false, account: snapshot.account?.email.map { CompanionText.prefix($0, utf16Limit: 100) },
            taskIndex: primary.flatMap { primary in tasks.firstIndex(where: { $0.id == primary.id }) },
            selectionIsPinned: selectedTaskID != nil && primary?.id == selectedTaskID ? true : nil, nextTask: next)
    }
    func previewOfNextTask(at now: Date = .now) -> Self? {
        guard now < staleAt, selectionPending != true, let deliveryTimestamp,
              deliveryTimestamp.isFinite, let nextTask, nextTask.taskID != taskID,
              nextTask.taskIndex >= 0, nextTask.taskIndex < running + attention,
              ["running", "needsInput", "needsApproval"].contains(nextTask.state) else { return nil }
        var result = self
        result.taskID = nextTask.taskID; result.title = nextTask.title; result.project = nextTask.project
        result.state = nextTask.state; result.tokensPerMinute = nextTask.tokensPerMinute
        result.taskObservedAt = nextTask.taskObservedAt; result.startedAt = nextTask.startedAt
        result.activity = nextTask.activity; result.contextPercent = nextTask.contextPercent
        result.hasRate = nextTask.hasRate; result.taskIndex = nextTask.taskIndex
        result.nextTask = nil; result.selectionPending = true
        // Apply the preview at the current delivery time, rather than beside
        // the cached observation's old delivery time. Keep source age/staleAt
        // unchanged; choosing another task does not make its data fresher.
        result.deliveryTimestamp = max(deliveryTimestamp + 0.001, now.timeIntervalSince1970)
        return result
    }
    func url(macID: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "tokentach"; parts.host = "tasks"; parts.path = "/" + macID
        if let taskID { parts.queryItems = [URLQueryItem(name: "task", value: taskID)] }
        return parts.url
    }
}

#if os(iOS)
import ActivityKit
import AppIntents
import OSLog

struct CompanionActivityAttributes: ActivityAttributes {
    typealias ContentState = CompanionLiveState
    var macID: String
    var macName: String
}

enum CompanionLiveSelectionPreference {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: "group.com.northwolflabs.CodexGauge") }
    static func task(macID: String) -> String? { (defaults?.dictionary(forKey: "liveSelectedTasks") as? [String: String])?[macID] }
    static func set(_ taskID: String, macID: String) {
        var selected = defaults?.dictionary(forKey: "liveSelectedTasks") as? [String: String] ?? [:]
        selected[macID] = taskID; defaults?.set(selected, forKey: "liveSelectedTasks")
    }
}

struct CycleLiveTaskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Show Next Task"
    static let openAppWhenRun = false
    @Parameter(title: "Mac") var macID: String
    init() { macID = "" }
    init(macID: String) { self.macID = macID }
    func perform() async throws -> some IntentResult {
        // Preview the received observation without advancing its freshness.
        // Confirm the selection with the relay, or restore a still-pending preview.
        #if DEBUG
        Logger(subsystem: "com.northwolflabs.CodexGauge", category: "LiveSelection").notice("Intent started")
        #endif
        do { try await CompanionLiveTaskCycler.shared.cycle(macID: macID) }
        catch {
            #if DEBUG
            // Log only an error category, never a URL, token, account or task.
            print("Live task selection: failed category=\((error as NSError).domain), code=\((error as NSError).code)")
            #endif
            return .result()
        }
        return .result()
    }
}

private actor CompanionLiveTaskCycler {
    static let shared = CompanionLiveTaskCycler()
    private var cycling = Set<String>()
    func cycle(macID: String) async throws {
        guard cycling.insert(macID).inserted else { return }
        defer { cycling.remove(macID) }
        guard let activity = Activity<CompanionActivityAttributes>.activities.first(where: {
            $0.attributes.macID == macID && $0.activityState != .ended && $0.activityState != .dismissed
        }) else {
            #if DEBUG
            print("Live task selection: activity unavailable")
            #endif
            return
        }
        let activityID = activity.id
        let currentTask = activity.content.state.taskID
        #if DEBUG
        if macID.hasPrefix("codexgauge-layout-review-") {
            let original = activity.content.state
            Logger(subsystem: "com.northwolflabs.CodexGauge", category: "LiveSelection").notice("Fixture index=\(original.taskIndex ?? 0) pending=\(original.selectionPending == true) next=\(original.nextTask != nil)")
            guard var selected = original.previewOfNextTask() else { return }
            await Self.apply(selected, activityID: activityID, timestamp: Date(timeIntervalSince1970: selected.deliveryTimestamp!))
            Logger(subsystem: "com.northwolflabs.CodexGauge", category: "LiveSelection").notice("Fixture preview applied")
            // Deliberately slow confirmation: the native test must see the local
            // selection before this completes, rather than merely testing cache math.
            try await Task.sleep(for: .seconds(6))
            selected.selectionPending = nil; selected.selectionIsPinned = true
            selected.deliveryTimestamp = Date.now.timeIntervalSince1970
            let index = ((selected.taskIndex ?? 0) + 1) % max(1, selected.running + selected.attention)
            selected.nextTask = .init(taskID: "layout-review-task-\(index)", title: "Review selected task \(index + 1)", project: "TokenTach", state: "running",
                tokensPerMinute: 12800, taskObservedAt: selected.updatedAt, startedAt: selected.startedAt, activity: "Using a tool", contextPercent: 64, hasRate: true, taskIndex: index)
            await Self.apply(selected, activityID: activityID, timestamp: Date(timeIntervalSince1970: selected.deliveryTimestamp!))
            Logger(subsystem: "com.northwolflabs.CodexGauge", category: "LiveSelection").notice("Fixture confirmation applied")
            return
        }
        #endif
        guard let data = CompanionCredentialStore.read("viewing-links"),
              let links = try? CompanionCoding.decoder.decode([CompanionLink].self, from: data),
              let link = links.first(where: { $0.id == macID }), link.deviceID != nil else {
            #if DEBUG
            print("Live task selection: paired credential unavailable")
            #endif
            return
        }
        let original = activity.content.state
        let preview = original.previewOfNextTask()
        if let preview {
            await Self.apply(preview, activityID: activityID,
                             timestamp: Date(timeIntervalSince1970: preview.deliveryTimestamp!))
        }
        do {
        var request = URLRequest(url: link.server.appending(path: "v1/macs/\(link.id)/live-selection"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["activityID": activityID]
        if let currentTask { body["afterTaskID"] = currentTask }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (stream, response) = try await CompanionNoRedirect.session(timeout: 10).bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            #if DEBUG
            print("Live task selection: HTTP status=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
            #endif
            throw URLError(.badServerResponse)
        }
        var bytes = Data()
        for try await byte in stream { guard bytes.count < 8192 else { throw CompanionError.invalidData }; bytes.append(byte) }
        struct Selection: Decodable { var state: CompanionLiveState; var deliveryTimestamp: Double }
        let selected = try JSONDecoder().decode(Selection.self, from: bytes)
        guard let taskID = selected.state.taskID, selected.state.selectionIsPinned == true else { throw CompanionError.invalidData }
        CompanionLiveSelectionPreference.set(taskID, macID: macID)
        var confirmed = selected.state
        confirmed.deliveryTimestamp = selected.deliveryTimestamp
        await Self.apply(confirmed, activityID: activityID, timestamp: Date(timeIntervalSince1970: selected.deliveryTimestamp))
        } catch {
            // Restore only our still-pending preview; never overwrite a newer push
            // or report cached data as freshly observed after a failed request.
            if let preview, let current = Activity<CompanionActivityAttributes>.activities.first(where: { $0.id == activityID }),
               current.content.state.selectionPending == true, current.content.state.taskID == preview.taskID {
                var restored = original
                restored.deliveryTimestamp = max(preview.deliveryTimestamp! + 0.001, Date.now.timeIntervalSince1970)
                await Self.apply(restored, activityID: activityID, timestamp: Date(timeIntervalSince1970: restored.deliveryTimestamp!))
            }
            throw error
        }
    }
    @concurrent private static func apply(_ state: CompanionLiveState, activityID: String, timestamp: Date) async {
        guard let activity = Activity<CompanionActivityAttributes>.activities.first(where: { $0.id == activityID }),
              activity.activityState != .ended && activity.activityState != .dismissed else { return }
        let content = ActivityContent(state: state, staleDate: state.staleAt, relevanceScore: state.attention > 0 ? 100 : 50)
        if #available(iOS 17.2, *) { await activity.update(content, timestamp: timestamp) }
        else { await activity.update(content) }
    }
}
#endif
