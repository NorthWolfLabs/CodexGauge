import Foundation

enum AlertDestination: String, Codable, CaseIterable, Sendable {
    case off, apple
    var title: String {
        switch self {
        case .off: "Off"
        case .apple: "Apple notifications"
        }
    }
    var apple: Bool { self == .apple }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "apple", "both", "appleAndNtfy": self = .apple
        case "off", "slack", "ntfy": self = .off
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown alert destination")
        }
    }
}

struct RoutedAlert: Codable {
    var event: ResetAlert
    var apple: Bool
}

struct AlertMonitorState: Codable {
    var version = 1
    var scope: String?
    var detector = ResetDetector()
    var seen: [String] = []
    var routes: [String: AlertDestination] = [:]
    var pending: [RoutedAlert] = []
    var taskTokens: [String: String]?
    var taskCheckedAt: Date?
}

@MainActor protocol AlertMonitorStoring {
    func load() throws -> AlertMonitorState?
    func save(_ state: AlertMonitorState) throws
}

@MainActor final class MemoryAlertMonitorStore: AlertMonitorStoring {
    var value: AlertMonitorState?
    func load() throws -> AlertMonitorState? { value }
    func save(_ state: AlertMonitorState) throws { value = state }
}

@MainActor final class AlertMonitorStore: AlertMonitorStoring {
    private let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: AppIdentity.current.supportDirectoryName).appending(path: "notification-events.json")
    }
    func load() throws -> AlertMonitorState? {
        guard let data = BoundedFileReader.read(url, maximumBytes: 512 * 1024),
              let value = try? JSONDecoder().decode(AlertMonitorState.self, from: data), value.version == 1 else { return nil }
        return value
    }
    func save(_ state: AlertMonitorState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        guard data.count <= 512 * 1024 else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Persistent local notification pipeline. Task
/// bodies and raw thread identifiers never enter the outbox. Task titles identify alerts.
@MainActor final class AlertMonitor {
    private let settings: SettingsStore
    private let local: any NotificationScheduling
    private let store: any AlertMonitorStoring
    private var state: AlertMonitorState
    private var validated = false
    private var firstObservation = true
    private var taskBaseline: [String: String] = [:]
    private var tasksLoaded = false
    private var taskObservationStartedAt: Date?
    private var drainTask: Task<Void, Never>?
    private var generation = 0
    private var inFlightIDs: Set<UUID> = []
    var pendingCount: Int { state.pending.count }
    private(set) var storageError: String?
    private var lastPersistedAt: Date?

    init(settings: SettingsStore, local: any NotificationScheduling,
         store: any AlertMonitorStoring = AlertMonitorStore()) {
        self.settings = settings; self.local = local; self.store = store
        state = (try? store.load()) ?? AlertMonitorState()
        // Decoding ignores retired remote-delivery fields; retain only unsent Mac alerts.
        state.pending.removeAll { !$0.apple }
        for index in state.pending.indices { state.pending[index].event.isCatchUp = true }
    }

    func suspend() {
        generation += 1
        drainTask?.cancel(); drainTask = nil
        inFlightIDs = []
        validated = false
        firstObservation = true
        tasksLoaded = false
        taskObservationStartedAt = nil
        taskBaseline = [:]
    }

    func routesChanged() {
        let changed = ResetAlertKind.allCases.contains { state.routes[$0.rawValue] != settings.destination(for: $0) }
        guard changed else { return }
        generation += 1
        drainTask?.cancel(); drainTask = nil
        inFlightIDs = []
        for kind in ResetAlertKind.allCases {
            let next = settings.destination(for: kind)
            if let before = state.routes[kind.rawValue], before != next {
                state.detector.reset(kind)
                state.pending.removeAll { $0.event.kind == kind }
                state.seen.removeAll { $0.hasPrefix(kind.rawValue + "|") }
                if kind == .attention || kind == .completed || kind == .working { tasksLoaded = false; taskBaseline = [:]; taskObservationStartedAt = nil; state.taskTokens = nil; state.taskCheckedAt = nil }
            }
            state.routes[kind.rawValue] = next
        }
        if persist() { drain() }
    }

    func observe(_ limits: RateLimitSnapshot, scope: String?) {
        if state.scope != scope || (firstObservation && scope == nil) {
            suspend()
            state = AlertMonitorState(scope: scope)
        }
        state.scope = scope
        let catchUp = firstObservation
        firstObservation = false
        validated = true
        routesChanged()
        let previousDetector = state.detector
        var events = state.detector.evaluate(limits,
            banked: settings.destination(for: .banked) != .off,
            allowance: settings.destination(for: .allowance) != .off, catchUp: catchUp)
        if settings.destination(for: .low) != .off {
            for bucket in limits.buckets {
                for window in bucket.windows {
                    let crossed = NotificationDecision.crossedThresholds(remainingPercent: window.remainingPercent,
                                                                        thresholds: settings.notificationThresholds)
                    let keys = crossed.map { "low|" + NotificationDedupeKey.quota(bucket: bucket, window: window, threshold: $0, now: limits.fetchedAt) }
                    if keys.contains(where: { !state.seen.contains($0) }) {
                        events.append(ResetAlert(kind: .low, key: "low|\(bucket.id)|\(window.id)",
                            name: "\(bucket.name) \(window.durationName)", added: 0, available: window.remainingPercent,
                            since: limits.fetchedAt, observedAt: limits.fetchedAt, isCatchUp: catchUp, resetsAt: window.resetsAt))
                        state.seen += keys.filter { !state.seen.contains($0) }
                    }
                }
            }
        }
        enqueue(events, forcePersistence: !state.detector.hasSameEvidence(as: previousDetector) || !events.isEmpty)
    }

    func observeTasks(_ tasks: [ConversationTelemetry], at now: Date) {
        guard validated else { return }
        let catchUp = !tasksLoaded && state.taskTokens != nil
        if catchUp {
            taskBaseline = state.taskTokens ?? [:]
            taskObservationStartedAt = state.taskCheckedAt
        }
        var next: [String: String] = [:]
        var events: [ResetAlert] = []
        for task in tasks {
            let taskID = ResetAccountIdentity.digest(task.id, salt: settings.resetIdentitySalt)
            for kind in [ResetAlertKind.working, .attention, .completed] {
                let date: Date?
                if kind == .working {
                    date = task.state == .running ? (task.turnStartedAt ?? task.lastActivity) : nil
                } else if kind == .completed {
                    date = task.isLive ? nil : task.completionEventAt
                } else {
                    date = task.state == .needsInput || task.state == .needsApproval ? task.attentionEventAt : nil
                }
                let key = kind.rawValue + "|" + taskID
                let token: String
                if kind == .working {
                    // Some helpers omit turnStartedAt; don't re-alert on each activity update.
                    token = task.state == .running ? (task.turnStartedAt.map { String($0.timeIntervalSince1970) } ?? "running") : ""
                } else {
                    token = date.map { String($0.timeIntervalSince1970) } ?? ""
                }
                next[key] = token
                let eventKey = key + "|" + (kind == .working ? String((date ?? now).timeIntervalSince1970) : token)
                let newlyObserved = date.map { $0 >= (taskObservationStartedAt ?? now) } ?? false
                guard tasksLoaded || catchUp, taskBaseline[key] != nil || newlyObserved, taskBaseline[key] != token, !token.isEmpty,
                      settings.destination(for: kind) != .off, !state.seen.contains(eventKey) else { continue }
                state.seen.append(eventKey)
                events.append(ResetAlert(kind: kind, key: eventKey, name: String(task.title.prefix(200)), added: 1, available: 0,
                                         since: catchUp ? (state.taskCheckedAt ?? now) : (date ?? now), observedAt: now, projectName: task.projectName, isCatchUp: catchUp, taskID: taskID,
                                         taskStatus: task.state == .needsApproval ? "Needs approval" : nil))
            }
        }
        let changed = state.taskTokens != next
        state.taskTokens = next
        state.taskCheckedAt = now
        taskBaseline = next
        if taskObservationStartedAt == nil { taskObservationStartedAt = now }
        tasksLoaded = true
        enqueue(events, forcePersistence: changed || !events.isEmpty)
    }

    private func enqueue(_ events: [ResetAlert], forcePersistence: Bool = true) {
        for event in events {
            let route = settings.destination(for: event.kind)
            guard route.apple else { continue }
            // Coalesce recurring allowance/reset observations while delivery is down.
            if let i = state.pending.firstIndex(where: { !inFlightIDs.contains($0.event.id) && $0.event.key == event.key && $0.apple == route.apple }) {
                let prior = state.pending[i].event
                var merged = event
                merged.since = prior.since
                merged.isCatchUp = prior.isCatchUp != false || event.isCatchUp != false
                merged.added = prior.added.addingReportingOverflow(event.added).overflow ? Int.max : prior.added + event.added
                state.pending[i].event = merged
            } else {
                state.pending.append(RoutedAlert(event: event, apple: true))
            }
        }
        state.seen = Array(state.seen.suffix(2000))
        if persist(force: forcePersistence) { drain() }
    }

    private func persist(force: Bool = true) -> Bool {
        if !force, storageError == nil, let lastPersistedAt, Date.now.timeIntervalSince(lastPersistedAt) < 60 { return true }
        do { try store.save(state); storageError = nil; lastPersistedAt = .now; return true }
        catch { storageError = "Notification state couldn’t be saved. Check disk space and folder permissions."; return false }
    }

    private func drain() {
        guard validated, storageError == nil, drainTask == nil, !state.pending.isEmpty else { return }
        let currentGeneration = generation
        drainTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == currentGeneration { self.drainTask = nil } }
            while !Task.isCancelled, self.generation == currentGeneration, !self.state.pending.isEmpty {
                let batch = Array(self.state.pending.filter(\.apple).prefix(20))
                self.inFlightIDs = Set(batch.map { $0.event.id })
                defer { if self.generation == currentGeneration { self.inFlightIDs = [] } }
                var localAccepted = true
                for item in batch where item.apple {
                    let sent = await self.local.deliver(item.event)
                    guard !Task.isCancelled, self.generation == currentGeneration else { return }
                    if sent, let index = self.state.pending.firstIndex(where: { $0.event.id == item.event.id }) {
                        self.state.pending[index].apple = false
                        guard self.persist() else { return }
                    } else { localAccepted = false }
                }
                self.state.pending.removeAll { !$0.apple }
                guard self.persist() else { return }
                if !localAccepted {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
        }
    }
}
