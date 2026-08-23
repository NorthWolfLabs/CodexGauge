import CoreServices
import Darwin
import Foundation

actor LocalSessionMonitor: SessionTelemetryProviding {
    private struct TokenPulse: Sendable {
        let timestamp: Date
        let usage: TokenBreakdown
        let modelCallCount: Int
    }

    private struct Session: Sendable {
        let path: String
        var offset: UInt64 = 0
        var remainder = Data()
        var id = ""
        var parentID: String?
        var workspace = ""
        var model: String?
        var sessionStartedAt: Date?
        var turnStartedAt: Date?
        var lastTurnDurationSeconds: TimeInterval?
        var lastActivity = Date.distantPast
        var totalTokens: Int64 = 0
        var latestRawTotal: Int64?
        var latestPulseTotal: TokenBreakdown?
        var latestCallUsage: TokenBreakdown?
        var counterBaseline: Int64?
        var firstCallTokens: Int64 = 0
        var completedCounterSegments: Int64 = 0
        var contextWindow: Int64?
        var latestOutput: Int64?
        var latestLatency: Int64?
        var explicitState: ConversationState = .recent
        var attentionEventAt: Date?
        var activity: ConversationActivity = .waiting
        var pulses: [TokenPulse] = []
    }

    private let codexHomeURL: URL
    private let sessionsURL: URL
    private let locksURL: URL
    private let clock: any ClockProviding
    private var sessions: [String: Session] = [:]
    private var titles: [String: String] = [:]
    private var titleIndexModificationDate: Date?
    private var lockedIDs = Set<String>()
    private var watcher: RecursiveFSEventsWatcher?
    private var continuation: AsyncStream<[ConversationTelemetry]>.Continuation?
    private var maintenanceTask: Task<Void, Never>?
    private var started = false

    init(codexHomeURL: URL, clock: any ClockProviding = SystemClock()) {
        self.codexHomeURL = codexHomeURL
        self.clock = clock
        sessionsURL = codexHomeURL.appending(path: "sessions", directoryHint: .isDirectory)
        locksURL = codexHomeURL.appending(path: "thread-writer-locks", directoryHint: .isDirectory)
    }

    func snapshots() async -> AsyncStream<[ConversationTelemetry]> {
        AsyncStream { streamContinuation in
            continuation = streamContinuation
            streamContinuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
            Task { await self.startIfNeeded() }
        }
    }

    func stop() async {
        maintenanceTask?.cancel()
        maintenanceTask = nil
        watcher?.stop()
        watcher = nil
        continuation?.finish()
        continuation = nil
        sessions.removeAll()
        started = false
    }

    private func startIfNeeded() async {
        guard !started else { return }
        started = true
        loadTitles()
        probeLocks()
        discoverRecentSessions()
        processTrackedSessions()
        emitSnapshot()

        watcher = RecursiveFSEventsWatcher(paths: [sessionsURL.path, locksURL.path]) { [weak self] paths in
            Task { await self?.filesystemChanged(paths) }
        }
        watcher?.start()

        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await self?.performMaintenance()
            }
        }
    }

    private func performMaintenance() {
        loadTitles()
        probeLocks()
        processTrackedSessions()
        pruneOldSessions()
        emitSnapshot()
    }

    private func filesystemChanged(_ paths: [String]) {
        var shouldDiscover = false
        for path in paths {
            if path.hasSuffix(".jsonl") {
                track(path: path)
            } else if path.hasPrefix(sessionsURL.path) {
                shouldDiscover = true
            }
        }
        if shouldDiscover { discoverRecentSessions() }
        probeLocks()
        processTrackedSessions()
        emitSnapshot()
    }

    private func discoverRecentSessions() {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        let cutoff = clock.now.addingTimeInterval(-86_400)
        var candidates: [(url: URL, modified: Date, locked: Bool)] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let fileID = Self.threadID(from: fileURL.lastPathComponent)
            let modified = values?.contentModificationDate ?? .distantPast
            let locked = lockedIDs.contains(fileID)
            if modified >= cutoff || locked {
                candidates.append((fileURL, modified, locked))
            }
        }
        candidates.sort {
            if $0.locked != $1.locked { return $0.locked }
            return $0.modified > $1.modified
        }
        for candidate in candidates.prefix(500) {
            track(path: candidate.url.path)
        }
    }

    private func track(path: String) {
        guard path.hasSuffix(".jsonl"), sessions[path] == nil else { return }
        if sessions.count >= 500,
           let oldest = sessions
            .filter({ !lockedIDs.contains($0.value.id) })
            .min(by: { $0.value.lastActivity < $1.value.lastActivity })?.key {
            sessions.removeValue(forKey: oldest)
        }
        guard sessions.count < 500 else { return }
        sessions[path] = Session(path: path)
    }

    private func processTrackedSessions() {
        for path in Array(sessions.keys) {
            process(path: path)
        }
    }

    private func process(path: String) {
        guard var session = sessions[path],
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return }
        let fileSize = size.uint64Value

        if fileSize < session.offset {
            session.offset = 0
            session.remainder.removeAll(keepingCapacity: true)
            session.pulses.removeAll()
            session.totalTokens = 0
            session.latestRawTotal = nil
            session.latestPulseTotal = nil
            session.latestCallUsage = nil
            session.counterBaseline = nil
            session.firstCallTokens = 0
            session.completedCounterSegments = 0
            session.turnStartedAt = nil
            session.lastTurnDurationSeconds = nil
            session.attentionEventAt = nil
        }
        guard fileSize > session.offset else {
            sessions[path] = session
            return
        }

        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let maximumRead = UInt64(8 * 1_024 * 1_024)
            let headerRead = UInt64(256 * 1_024)

            if session.offset == 0, fileSize > maximumRead + headerRead {
                // The first rollout record carries the stable session metadata, while the
                // newest records carry live state and token pulses. Reading both ends avoids
                // replaying a very large conversation for minutes at launch.
                try handle.seek(toOffset: 0)
                if let header = try handle.read(upToCount: Int(headerRead)), !header.isEmpty {
                    session.offset = UInt64(header.count)
                    session.remainder.append(header)
                    parseLines(into: &session)
                }

                let tailOffset = fileSize - maximumRead
                try handle.seek(toOffset: tailOffset)
                if var tail = try handle.read(upToCount: Int(maximumRead)), !tail.isEmpty {
                    session.remainder.removeAll(keepingCapacity: true)
                    session.pulses.removeAll(keepingCapacity: true)
                    session.latestPulseTotal = nil
                    if tailOffset > 0, let firstNewline = tail.firstIndex(of: 0x0A) {
                        tail.removeSubrange(...firstNewline)
                    }
                    session.remainder.append(tail)
                    session.offset = fileSize
                    parseLines(into: &session)
                }
                sessions[path] = session
                return
            }

            try handle.seek(toOffset: session.offset)
            let count = Int(min(fileSize - session.offset, maximumRead))
            guard let newData = try handle.read(upToCount: count), !newData.isEmpty else { return }
            session.offset += UInt64(newData.count)
            session.remainder.append(newData)
            parseLines(into: &session)
            sessions[path] = session
        } catch {
            return
        }
    }

    private func parseLines(into session: inout Session) {
        while let newline = session.remainder.firstIndex(of: 0x0A) {
            let line = Data(session.remainder[..<newline])
            session.remainder.removeSubrange(...newline)
            guard line.count <= 2 * 1_024 * 1_024,
                  let event = try? Self.decoder.decode(RolloutEnvelope.self, from: line) else { continue }
            apply(event, to: &session)
        }
        if session.remainder.count > 4 * 1_024 * 1_024 {
            session.remainder = Data()
        } else if !session.remainder.isEmpty {
            // Data.removeSubrange retains the capacity of the multi-megabyte tail read.
            // Copy the usually tiny partial line so idle sessions release that storage.
            session.remainder = Data(session.remainder)
        } else {
            session.remainder = Data()
        }
    }

    private func apply(_ envelope: RolloutEnvelope, to session: inout Session) {
        let payload = envelope.payload
        let timestamp = envelope.timestamp ?? payload.timestamp ?? clock.now

        switch envelope.type {
        case "session_meta":
            session.id = payload.id ?? payload.sessionID ?? session.id
            session.parentID = payload.parentThreadID ?? payload.source?.parentThreadID ?? session.parentID
            session.workspace = payload.cwd ?? session.workspace
            session.model = payload.model ?? session.model
            session.sessionStartedAt = payload.timestamp ?? envelope.timestamp ?? session.sessionStartedAt
            session.lastActivity = max(session.lastActivity, timestamp)
        case "turn_context":
            session.model = payload.model ?? session.model
            session.lastActivity = max(session.lastActivity, timestamp)
        default:
            switch payload.type {
            case "task_started", "turn_started":
                session.explicitState = .running
                session.attentionEventAt = nil
                session.activity = .starting
                session.turnStartedAt = payload.startedAt ?? timestamp
                session.lastTurnDurationSeconds = nil
                session.contextWindow = payload.modelContextWindow ?? session.contextWindow
            case "task_complete", "task_completed", "turn_complete", "turn_completed":
                if let duration = payload.durationMilliseconds {
                    session.lastTurnDurationSeconds = max(0, Double(duration) / 1_000)
                } else if let startedAt = session.turnStartedAt {
                    session.lastTurnDurationSeconds = max(0, timestamp.timeIntervalSince(startedAt))
                }
                session.turnStartedAt = nil
                session.explicitState = .idle
                session.attentionEventAt = nil
                session.activity = .waiting
            case let type? where type.contains("approval") && (type.contains("request") || type.contains("needed")):
                session.explicitState = .needsApproval
                session.attentionEventAt = timestamp
                session.activity = .waiting
            case "request_user_input", "input_required", "waiting_for_input":
                session.explicitState = .needsInput
                session.attentionEventAt = timestamp
                session.activity = .waiting
            case "agent_reasoning", "reasoning":
                session.activity = .thinking
            case "agent_message", "message":
                session.activity = .generating
            case "command_execution", "shell_command", "exec_command":
                session.activity = .runningCommand
            case "custom_tool_call", "function_call", "tool_call", "web_search_call":
                session.activity = .usingTool
            case "custom_tool_call_output", "function_call_output", "tool_call_output":
                session.activity = .thinking
            case "token_count":
                let lastUsage = payload.info?.lastTokenUsage
                session.latestCallUsage = lastUsage?.breakdown ?? session.latestCallUsage
                session.latestOutput = lastUsage.map { max(0, $0.outputTokens) } ?? session.latestOutput
                if let total = payload.info?.totalTokenUsage {
                    let cumulative = total.breakdown
                    let pulse: TokenBreakdown?
                    if let previous = session.latestPulseTotal, cumulative.total >= previous.total {
                        let delta = cumulative.delta(since: previous)
                        pulse = delta.total > 0 ? delta : nil
                    } else {
                        pulse = lastUsage?.breakdown
                    }
                    if let pulse, pulse.total > 0 {
                        if let last = session.pulses.last,
                           Int(last.timestamp.timeIntervalSince1970) == Int(timestamp.timeIntervalSince1970) {
                            session.pulses[session.pulses.count - 1] = TokenPulse(
                                timestamp: timestamp,
                                usage: last.usage + pulse,
                                modelCallCount: last.modelCallCount + (lastUsage == nil ? 0 : 1)
                            )
                        } else {
                            session.pulses.append(TokenPulse(
                                timestamp: timestamp,
                                usage: pulse,
                                modelCallCount: lastUsage == nil ? 0 : 1
                            ))
                        }
                        if session.pulses.count > 360 {
                            session.pulses.removeFirst(session.pulses.count - 360)
                        }
                    }
                    session.latestPulseTotal = cumulative

                    let totalTokens = max(0, total.totalTokens)
                    let callTokens = max(0, payload.info?.lastTokenUsage?.totalTokens ?? 0)
                    if let previous = session.latestRawTotal, totalTokens < previous {
                        session.completedCounterSegments = session.totalTokens
                        session.counterBaseline = nil
                        session.firstCallTokens = 0
                    }
                    if session.counterBaseline == nil {
                        session.counterBaseline = totalTokens
                        session.firstCallTokens = callTokens
                    }
                    session.latestRawTotal = totalTokens
                    let baseline = session.counterBaseline ?? totalTokens
                    let currentSegment = max(
                        session.firstCallTokens,
                        totalTokens.subtractingWithoutOverflow(baseline).addingWithoutOverflow(session.firstCallTokens)
                    )
                    session.totalTokens = session.completedCounterSegments.addingWithoutOverflow(currentSegment)
                }
                session.contextWindow = payload.info?.modelContextWindow ?? session.contextWindow
            default:
                break
            }
            session.model = payload.model ?? session.model
            session.latestLatency = payload.timeToFirstTokenMilliseconds ?? session.latestLatency
            session.lastActivity = max(session.lastActivity, timestamp)
        }

        let cutoff = clock.now.addingTimeInterval(-300)
        session.pulses.removeAll { $0.timestamp < cutoff }
    }

    private func emitSnapshot() {
        let now = clock.now
        let values = sessions.values.filter { session in
            lockedIDs.contains(session.id) || session.lastActivity > now.addingTimeInterval(-86_400)
        }

        var byID: [String: Session] = [:]
        for session in values where !session.id.isEmpty {
            if let existing = byID[session.id], existing.lastActivity >= session.lastActivity { continue }
            byID[session.id] = session
        }
        var childIDs: [String: [String]] = [:]
        for session in values {
            if let parent = session.parentID, byID[parent] != nil {
                childIDs[parent, default: []].append(session.id)
            }
        }

        let roots = values.filter { session in
            guard let parent = session.parentID else { return true }
            return byID[parent] == nil
        }
        let telemetry = roots.map { root -> ConversationTelemetry in
            let descendants = descendantIDs(of: root.id, children: childIDs)
            let folded = [root] + descendants.compactMap { byID[$0] }
            let allPulses = folded.flatMap(\.pulses)
            let minute = allPulses.filter { $0.timestamp >= now.addingTimeInterval(-60) }
            let fiveMinutes = allPulses.filter { $0.timestamp >= now.addingTimeInterval(-300) }
            let mix = fiveMinutes.reduce(.zero) { $0 + $1.usage }
            let latest = folded.max { $0.lastActivity < $1.lastActivity } ?? root
            let state = folded.map { effectiveState(for: $0, now: now) }.max {
                $0.notificationPriority < $1.notificationPriority
            } ?? .recent
            let turnStartedAt = folded.compactMap { candidate -> Date? in
                let candidateState = effectiveState(for: candidate, now: now)
                return candidateState == .running || candidateState == .needsInput || candidateState == .needsApproval
                    ? candidate.turnStartedAt
                    : nil
            }.min()
            let workspace = root.workspace.isEmpty ? "Unattributed Codex Work" : URL(fileURLWithPath: root.workspace).lastPathComponent
            let title = titles[root.id] ?? workspace
            let contextPercent = latest.contextWindow.flatMap { window -> Double? in
                guard window > 0 else { return nil }
                let recentInput = latest.latestCallUsage?.input ?? 0
                return min(100, max(0, Double(recentInput) / Double(window) * 100))
            }
            let provenCalls = minute.reduce(0) { $0 + $1.modelCallCount }
            return ConversationTelemetry(
                id: root.id.isEmpty ? root.path : root.id,
                title: title,
                workspace: workspace,
                model: latest.model ?? root.model,
                state: state,
                activity: latest.activity,
                tokensPerMinute: Double(minute.reduce(Int64(0)) { $0.addingWithoutOverflow($1.usage.total) }),
                tokensPerFiveMinutes: Double(fiveMinutes.reduce(Int64(0)) { $0.addingWithoutOverflow($1.usage.total) }) / 5,
                callsPerMinute: provenCalls > 0 ? Double(provenCalls) : nil,
                totalTokens: folded.reduce(Int64(0)) { $0.addingWithoutOverflow($1.totalTokens) },
                recentTokenMix: mix,
                latestContextPercent: contextPercent,
                turnStartedAt: turnStartedAt,
                lastTurnDurationSeconds: latest.lastTurnDurationSeconds ?? root.lastTurnDurationSeconds,
                latestOutputTokens: latest.latestOutput,
                timeToFirstTokenMilliseconds: latest.latestLatency,
                attentionEventAt: folded.compactMap(\.attentionEventAt).max(),
                agentCount: descendants.count,
                lastActivity: folded.map(\.lastActivity).max() ?? root.lastActivity
            )
        }.sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            if $0.isLive {
                let left = $0.turnStartedAt ?? $0.lastActivity
                let right = $1.turnStartedAt ?? $1.lastActivity
                if left != right { return left > right }
            } else if $0.lastActivity != $1.lastActivity {
                return $0.lastActivity > $1.lastActivity
            }
            return $0.id < $1.id
        }
        let live = telemetry.filter { $0.isLive }
        let recent = telemetry.filter { !$0.isLive }
        continuation?.yield(live + Array(recent.prefix(200)))
    }

    private func effectiveState(for session: Session, now: Date) -> ConversationState {
        let isLocked = lockedIDs.contains(session.id)
        let isRecent = session.lastActivity > now.addingTimeInterval(-300)
        if isLocked, isRecent,
           (session.explicitState == .needsApproval || session.explicitState == .needsInput) {
            return session.explicitState
        }
        if isLocked, isRecent, session.explicitState == .running { return .running }
        return session.lastActivity > now.addingTimeInterval(-900) ? .recent : .idle
    }

    private func descendantIDs(of id: String, children: [String: [String]]) -> [String] {
        guard !id.isEmpty else { return [] }
        var result: [String] = []
        var pending = children[id] ?? []
        while let next = pending.popLast() {
            guard !result.contains(next) else { continue }
            result.append(next)
            pending.append(contentsOf: children[next] ?? [])
        }
        return result
    }

    private func probeLocks() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: locksURL, includingPropertiesForKeys: nil) else {
            lockedIDs = []
            return
        }
        lockedIDs = Set(files.compactMap { url in
            guard url.pathExtension == "lock", Self.isActivelyLocked(url.path) else { return nil }
            return url.deletingPathExtension().lastPathComponent
        })
    }

    private func loadTitles() {
        let indexURL = codexHomeURL.appending(path: "session_index.jsonl")
        let modified = try? indexURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard modified != titleIndexModificationDate else { return }
        guard let data = try? Data(contentsOf: indexURL), data.count <= 16 * 1_024 * 1_024 else { return }
        for line in data.split(separator: 0x0A) {
            guard let title = try? Self.decoder.decode(ThreadTitleRecord.self, from: line) else { continue }
            titles[title.id] = title.threadName
        }
        titleIndexModificationDate = modified
    }

    private func pruneOldSessions() {
        let cutoff = clock.now.addingTimeInterval(-86_400)
        sessions = sessions.filter { _, session in
            lockedIDs.contains(session.id) || session.lastActivity >= cutoff
        }
        let retainedIDs = Set(sessions.values.map(\.id))
        titles = titles.filter { retainedIDs.contains($0.key) }
    }

    private static func threadID(from filename: String) -> String {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let pieces = base.split(separator: "-")
        guard pieces.count >= 10 else { return base }
        return pieces.suffix(5).joined(separator: "-")
    }

    private static func isActivelyLocked(_ path: String) -> Bool {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported rollout timestamp")
        }
        return decoder
    }()
}

private struct RolloutEnvelope: Decodable {
    let timestamp: Date?
    let type: String
    let payload: RolloutPayload
}

private struct RolloutPayload: Decodable {
    struct Source: Decodable {
        struct Subagent: Decodable {
            struct ThreadSpawn: Decodable {
                let parentThreadID: String?

                enum CodingKeys: String, CodingKey {
                    case parentThreadID = "parent_thread_id"
                }
            }
            let threadSpawn: ThreadSpawn?

            enum CodingKeys: String, CodingKey {
                case threadSpawn = "thread_spawn"
            }
        }
        let subagent: Subagent?
        var parentThreadID: String? { subagent?.threadSpawn?.parentThreadID }

        enum CodingKeys: String, CodingKey {
            case subagent
        }

        init(from decoder: Decoder) throws {
            // Root rollout metadata commonly represents `source` as a simple string,
            // while linked agents use an object. A scalar source is valid and just has
            // no parent relationship to decode.
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                subagent = nil
                return
            }
            subagent = try? container.decodeIfPresent(Subagent.self, forKey: .subagent)
        }
    }

    struct UsageInfo: Decodable {
        let totalTokenUsage: TokenUsage?
        let lastTokenUsage: TokenUsage?
        let modelContextWindow: Int64?

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
            case lastTokenUsage = "last_token_usage"
            case modelContextWindow = "model_context_window"
        }
    }

    let type: String?
    let id: String?
    let sessionID: String?
    let parentThreadID: String?
    let cwd: String?
    let model: String?
    let timestamp: Date?
    let startedAt: Date?
    let durationMilliseconds: Int64?
    let timeToFirstTokenMilliseconds: Int64?
    let modelContextWindow: Int64?
    let source: Source?
    let info: UsageInfo?

    enum CodingKeys: String, CodingKey {
        case type, id, cwd, model, timestamp, source, info
        case sessionID = "session_id"
        case parentThreadID = "parent_thread_id"
        case startedAt = "started_at"
        case durationMilliseconds = "duration_ms"
        case timeToFirstTokenMilliseconds = "time_to_first_token_ms"
        case modelContextWindow = "model_context_window"
    }
}

private struct TokenUsage: Decodable, Sendable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

    var breakdown: TokenBreakdown {
        TokenBreakdown(
            input: max(0, inputTokens),
            cachedInput: max(0, cachedInputTokens),
            cacheWriteInput: max(0, cacheWriteInputTokens),
            output: max(0, outputTokens),
            reasoningOutput: max(0, reasoningOutputTokens),
            total: max(0, totalTokens)
        )
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteInputTokens = "cache_write_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct ThreadTitleRecord: Decodable {
    let id: String
    let threadName: String

    enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
    }
}

private final class RecursiveFSEventsWatcher: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let callback: @Sendable ([String]) -> Void
        init(callback: @escaping @Sendable ([String]) -> Void) { self.callback = callback }
    }

    private let paths: [String]
    private let box: CallbackBox
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.northwolflabs.CodexGauge.fsevents", qos: .utility)

    init(paths: [String], callback: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        box = CallbackBox(callback: callback)
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            if count > 0 { box.callback(paths) }
        }
        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
