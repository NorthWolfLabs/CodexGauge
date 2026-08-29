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
        var fileModificationDate = Date.distantPast
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
        var workObservedAfterLifecycle = false
        var pulses: [TokenPulse] = []
    }

    private let codexHomeURL: URL
    private let sessionsURL: URL
    private let locksURL: URL
    private let clock: any ClockProviding
    private let maintenanceInterval: Duration
    private let watchesFilesystemEvents: Bool
    private var sessions: [String: Session] = [:]
    private var titles: [String: String] = [:]
    private var titleIndexModificationDate: Date?
    private var lockedIDs = Set<String>()
    private var watcher: RecursiveFSEventsWatcher?
    private var continuation: AsyncStream<[ConversationTelemetry]>.Continuation?
    private var maintenanceTask: Task<Void, Never>?
    private var filesystemRefreshTask: Task<Void, Never>?
    private var pendingFilesystemPaths = Set<String>()
    private var pendingParsingPaths = Set<String>()
    private var processingCursor = 0
    private var liveProcessingCursor = 0
    private var maintenanceTick = 0
    private var snapshotPolicy = SemanticSnapshotPolicy<[ConversationTelemetry]>()
    private var requiresRescan = false
    private var started = false
    private var sessionsRootDescriptor: Int32 = -1
    private var sessionsRootPath: String?
    private var lockDirectoryStream: AnchoredFileAccess.DirectoryStream?
    private var lockCycleActiveIDs = Set<String>()
    private var lockDirectoryRestartPending = false

    private static let maximumRecentSessions = 200
    private static let maximumLiveSessions = 512
    // Reserve recent and live capacity independently. This remains bounded for
    // hostile or corrupted directories without letting live work displace history.
    private static let maximumTrackedSessions = maximumRecentSessions + maximumLiveSessions
    private static let maximumFilesPerPass = maximumTrackedSessions
    private static let maximumBytesPerPass = 16 * 1_024 * 1_024
    private static let maximumBytesPerFile = 4 * 1_024 * 1_024
    private static let maximumDiscoveryEntries = 5_000
    private static let maximumDiscoveryDepth = 6
    private static let maximumRecordsPerParse = 10_000
    private static let maximumTitleRecords = 20_000
    private static let maximumLockEntriesPerPass = maximumLiveSessions
    private static let maximumLockProbesPerPass = maximumLiveSessions

    init(
        codexHomeURL: URL,
        clock: any ClockProviding = SystemClock(),
        maintenanceInterval: Duration = .seconds(1),
        watchesFilesystemEvents: Bool = true
    ) {
        self.codexHomeURL = codexHomeURL
        self.clock = clock
        self.maintenanceInterval = maintenanceInterval
        self.watchesFilesystemEvents = watchesFilesystemEvents
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
        filesystemRefreshTask?.cancel()
        filesystemRefreshTask = nil
        pendingFilesystemPaths.removeAll()
        pendingParsingPaths.removeAll()
        watcher?.stop()
        watcher = nil
        if sessionsRootDescriptor >= 0 {
            close(sessionsRootDescriptor)
            sessionsRootDescriptor = -1
        }
        sessionsRootPath = nil
        lockDirectoryStream = nil
        lockCycleActiveIDs.removeAll()
        lockDirectoryRestartPending = false
        continuation?.finish()
        continuation = nil
        sessions.removeAll()
        snapshotPolicy.reset()
        processingCursor = 0
        liveProcessingCursor = 0
        maintenanceTick = 0
        requiresRescan = false
        started = false
    }

    private func startIfNeeded() async {
        guard !started else { return }
        started = true
        loadTitles()
        let discoverySignpost = PerformanceSignposts.begin("Session discovery")
        if prepareSessionsRoot() {
            probeLocks()
            discoverRecentSessions()
            processTrackedSessions()
        }
        PerformanceSignposts.end("Session discovery", discoverySignpost)
        emitSnapshot()

        if watchesFilesystemEvents {
            watcher = RecursiveFSEventsWatcher(paths: [sessionsURL.path, locksURL.path]) { [weak self] paths, rescan in
                Task { await self?.queueFilesystemChanges(paths, requiresRescan: rescan) }
            }
            watcher?.start()
        }

        let maintenanceInterval = self.maintenanceInterval
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: maintenanceInterval)
                guard !Task.isCancelled else { break }
                await self?.performMaintenance()
            }
        }
    }

    private func performMaintenance() {
        maintenanceTick += 1
        // Token reports are discrete, but the rates are time-weighted. Keep
        // publishing while a report can still contribute so visible rates decay
        // smoothly during tool calls and other periods with no new token events.
        var shouldEmitSnapshot = hasRateHistory(at: clock.now)
        if maintenanceTick.isMultiple(of: 3) {
            loadTitles()
            probeLocks()
            shouldEmitSnapshot = true
        }
        if sessionsRootDescriptor < 0, prepareSessionsRoot() {
            discoverRecentSessions()
            processTrackedSessions()
            shouldEmitSnapshot = true
        }
        shouldEmitSnapshot = processPendingSessions() || shouldEmitSnapshot
        shouldEmitSnapshot = processLiveSessions() || shouldEmitSnapshot
        if maintenanceTick.isMultiple(of: 60) {
            processTrackedSessions(maximumFiles: 20)
            shouldEmitSnapshot = true
        }
        if maintenanceTick.isMultiple(of: 3) { pruneOldSessions() }
        if shouldEmitSnapshot { emitSnapshot() }
    }

    private func hasRateHistory(at now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-300)
        return sessions.values.contains { session in
            switch effectiveState(for: session, now: now) {
            case .running, .needsInput, .needsApproval:
                break
            case .idle, .recent:
                return false
            }
            return session.pulses.contains { $0.timestamp >= cutoff && $0.timestamp <= now }
        }
    }

    private func queueFilesystemChanges(_ paths: [String], requiresRescan: Bool) {
        pendingFilesystemPaths.formUnion(paths.prefix(512))
        self.requiresRescan = self.requiresRescan || requiresRescan
        guard filesystemRefreshTask == nil else { return }
        filesystemRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await self?.flushFilesystemChanges()
        }
    }

    private func flushFilesystemChanges() {
        filesystemRefreshTask = nil
        let paths = Array(pendingFilesystemPaths)
        pendingFilesystemPaths.removeAll(keepingCapacity: true)
        let shouldDiscover = requiresRescan
        requiresRescan = false
        if shouldDiscover || paths.contains(where: { $0.hasPrefix(locksURL.path) }) {
            lockDirectoryRestartPending = true
        }
        for path in paths {
            if path.hasSuffix(".jsonl") {
                if let trackedPath = track(path: path) {
                    pendingParsingPaths.insert(trackedPath)
                }
            }
        }
        if shouldDiscover {
            sessions.removeAll()
            pendingParsingPaths.removeAll()
            if prepareSessionsRoot(replacingExisting: true) { discoverRecentSessions() }
        }
        probeLocks()
        processPendingSessions()
        processLiveSessions()
        emitSnapshot()
    }

    private func discoverRecentSessions() {
        guard let sessionsRootPath else { return }
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: sessionsRootPath, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        let cutoff = clock.now.addingTimeInterval(-86_400)
        var candidates: [(url: URL, modified: Date, locked: Bool)] = []
        var visitedEntries = 0
        for case let fileURL as URL in enumerator {
            visitedEntries += 1
            guard visitedEntries <= Self.maximumDiscoveryEntries else { break }
            if enumerator.level > Self.maximumDiscoveryDepth {
                enumerator.skipDescendants()
                continue
            }
            guard fileURL.pathExtension == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ])
            guard values?.isRegularFile == true else { continue }
            guard values?.isSymbolicLink != true else { continue }
            let fileID = Self.threadID(from: fileURL.lastPathComponent)
            let modified = values?.contentModificationDate ?? .distantPast
            let locked = lockedIDs.contains(fileID)
            if modified >= cutoff || locked {
                let candidate = (fileURL, modified, locked)
                if candidates.count < Self.maximumTrackedSessions {
                    candidates.append(candidate)
                } else if let leastUseful = candidates.indices.min(by: {
                    Self.isBetterDiscoveryCandidate(candidates[$1], than: candidates[$0])
                }), Self.isBetterDiscoveryCandidate(candidate, than: candidates[leastUseful]) {
                    candidates[leastUseful] = candidate
                }
            }
        }
        candidates.sort { Self.isBetterDiscoveryCandidate($0, than: $1) }
        for candidate in candidates {
            track(path: candidate.url.path)
        }
    }

    private static func isBetterDiscoveryCandidate(
        _ lhs: (url: URL, modified: Date, locked: Bool),
        than rhs: (url: URL, modified: Date, locked: Bool)
    ) -> Bool {
        if lhs.locked != rhs.locked { return lhs.locked }
        return lhs.modified > rhs.modified
    }

    @discardableResult
    private func track(path: String) -> String? {
        guard sessionsRootDescriptor >= 0, let sessionsRootPath else { return nil }
        let original = URL(fileURLWithPath: path).standardizedFileURL
        let originalValues = try? original.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ])
        guard original.pathExtension == "jsonl",
              originalValues?.isRegularFile == true,
              originalValues?.isSymbolicLink != true else { return nil }
        guard let candidatePath = AnchoredFileAccess.canonicalPath(for: original) else { return nil }
        let candidate = URL(fileURLWithPath: candidatePath)
        let root = sessionsRootPath + "/"
        guard candidate.path.hasPrefix(root) else { return nil }
        if var existing = sessions[candidate.path] {
            existing.fileModificationDate = max(
                existing.fileModificationDate,
                originalValues?.contentModificationDate ?? .distantPast
            )
            sessions[candidate.path] = existing
            return candidate.path
        }
        if sessions.count >= Self.maximumTrackedSessions,
           let oldest = sessions
            .filter({ !lockedIDs.contains($0.value.id) })
            .min(by: { $0.value.lastActivity < $1.value.lastActivity })?.key {
            sessions.removeValue(forKey: oldest)
            pendingParsingPaths.remove(oldest)
        }
        guard sessions.count < Self.maximumTrackedSessions else { return nil }
        sessions[candidate.path] = Session(
            path: candidate.path,
            fileModificationDate: originalValues?.contentModificationDate ?? .distantPast,
            id: Self.threadID(from: candidate.lastPathComponent)
        )
        return candidate.path
    }

    private func processTrackedSessions() {
        processTrackedSessions(maximumFiles: Self.maximumFilesPerPass)
    }

    private func processTrackedSessions(maximumFiles: Int) {
        let paths = sessions.values.sorted { lhs, rhs in
            let lhsLocked = lockedIDs.contains(lhs.id)
            let rhsLocked = lockedIDs.contains(rhs.id)
            if lhsLocked != rhsLocked { return lhsLocked }
            if lhs.fileModificationDate != rhs.fileModificationDate {
                return lhs.fileModificationDate > rhs.fileModificationDate
            }
            return lhs.path < rhs.path
        }.map(\.path)
        guard !paths.isEmpty else {
            processingCursor = 0
            return
        }
        processingCursor %= paths.count
        var processedFiles = 0
        var processedBytes = 0
        while processedFiles < min(maximumFiles, paths.count),
              processedBytes < Self.maximumBytesPerPass {
            let path = paths[processingCursor]
            let remaining = Self.maximumBytesPerPass - processedBytes
            let budget = min(Self.maximumBytesPerFile, remaining)
            processedBytes += process(path: path, byteBudget: budget)
            processedFiles += 1
            processingCursor = (processingCursor + 1) % paths.count
        }
    }

    /// FSEvents remains the primary update path. This bounded pass prevents a
    /// missed or coalesced event from making a known live task appear frozen.
    @discardableResult
    private func processLiveSessions() -> Bool {
        let now = clock.now
        let paths = sessions.values
            .filter {
                if lockedIDs.contains($0.id) { return true }
                switch effectiveState(for: $0, now: now) {
                case .running, .needsInput, .needsApproval: return true
                case .idle, .recent: return false
                }
            }
            .map(\.path)
            .sorted()
        guard !paths.isEmpty else {
            liveProcessingCursor = 0
            return false
        }

        liveProcessingCursor %= paths.count
        let signpost = PerformanceSignposts.begin("Session parsing")
        defer { PerformanceSignposts.end("Session parsing", signpost) }
        var processedFiles = 0
        var processedBytes = 0
        while processedFiles < paths.count,
              processedBytes < Self.maximumBytesPerPass {
            let path = paths[liveProcessingCursor]
            let remaining = Self.maximumBytesPerPass - processedBytes
            processedBytes += process(
                path: path,
                byteBudget: min(Self.maximumBytesPerFile, remaining),
                prefersLatestData: true
            )
            processedFiles += 1
            liveProcessingCursor = (liveProcessingCursor + 1) % paths.count
        }
        return processedBytes > 0
    }

    @discardableResult
    private func processPendingSessions() -> Bool {
        guard !pendingParsingPaths.isEmpty else { return false }
        let signpost = PerformanceSignposts.begin("Session parsing")
        defer { PerformanceSignposts.end("Session parsing", signpost) }
        var remaining = Self.maximumBytesPerPass
        for path in pendingParsingPaths.sorted() where remaining > 0 {
            let bytes = process(path: path, byteBudget: min(Self.maximumBytesPerFile, remaining))
            remaining -= bytes
            if !hasUnreadData(at: path) {
                pendingParsingPaths.remove(path)
            }
        }
        return true
    }

    private func hasUnreadData(at path: String) -> Bool {
        guard let session = sessions[path],
              let relativePath = relativeSessionPath(for: path),
              let descriptor = AnchoredFileAccess.openRegularFile(
                  relativePath: relativePath,
                  directoryDescriptor: sessionsRootDescriptor
              ) else { return false }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size >= 0 else { return false }
        return UInt64(status.st_size) > session.offset
    }

    private func process(paths: [String]) {
        guard !paths.isEmpty else { return }
        let signpost = PerformanceSignposts.begin("Session parsing")
        defer { PerformanceSignposts.end("Session parsing", signpost) }
        var remaining = Self.maximumBytesPerPass
        for path in paths.prefix(Self.maximumFilesPerPass) where remaining > 0 {
            let bytes = process(path: path, byteBudget: min(Self.maximumBytesPerFile, remaining))
            remaining -= bytes
        }
    }

    @discardableResult
    private func process(
        path: String,
        byteBudget: Int,
        prefersLatestData: Bool = false
    ) -> Int {
        guard var session = sessions[path], byteBudget > 0,
              let relativePath = relativeSessionPath(for: path),
              let descriptor = AnchoredFileAccess.openRegularFile(
                relativePath: relativePath,
                directoryDescriptor: sessionsRootDescriptor
              ) else {
            sessions.removeValue(forKey: path)
            return 0
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size >= 0 else {
            sessions.removeValue(forKey: path)
            return 0
        }
        let fileSize = UInt64(status.st_size)
        session.fileModificationDate = Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )

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
            session.workObservedAfterLifecycle = false
        }
        guard fileSize > session.offset else {
            sessions[path] = session
            return 0
        }

        do {
            let maximumRead = UInt64(byteBudget)
            let headerRead = min(UInt64(256 * 1_024), maximumRead / 4)
            var bytesRead = 0

            if session.offset == 0, fileSize > maximumRead + headerRead {
                // The first rollout record carries the stable session metadata, while the
                // newest records carry live state and token pulses. Reading both ends avoids
                // replaying a very large conversation for minutes at launch.
                try handle.seek(toOffset: 0)
                if let header = try handle.read(upToCount: Int(headerRead)), !header.isEmpty {
                    bytesRead += header.count
                    session.offset = UInt64(header.count)
                    session.remainder.append(header)
                    parseLines(into: &session)
                }

                let tailRead = maximumRead - UInt64(bytesRead)
                let tailOffset = fileSize - tailRead
                try handle.seek(toOffset: tailOffset)
                if var tail = try handle.read(upToCount: Int(tailRead)), !tail.isEmpty {
                    bytesRead += tail.count
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
                return bytesRead
            }

            if prefersLatestData, fileSize - session.offset > maximumRead {
                // A live rollout can grow by hundreds of megabytes while a tool is
                // running. Replaying that stale backlog in bounded chunks makes the
                // visible task state lag by tens of seconds. Keep the metadata and
                // cumulative counters already decoded, but catch up from a bounded,
                // record-aligned tail so the newest lifecycle and activity records
                // reach the UI on the next maintenance pass.
                let tailOffset = fileSize - maximumRead
                var startsAtRecordBoundary = tailOffset == 0
                if tailOffset > 0 {
                    try handle.seek(toOffset: tailOffset - 1)
                    startsAtRecordBoundary = try handle.read(upToCount: 1)?.first == 0x0A
                }
                try handle.seek(toOffset: tailOffset)
                guard var tail = try handle.read(upToCount: Int(maximumRead)), !tail.isEmpty else {
                    return 0
                }
                let bytesRead = tail.count
                if !startsAtRecordBoundary {
                    guard let firstNewline = tail.firstIndex(of: 0x0A) else {
                        // The bounded tail is entirely inside one oversized record.
                        // Advance past it; the next append will be decoded normally.
                        session.offset = fileSize
                        session.remainder.removeAll(keepingCapacity: false)
                        sessions[path] = session
                        return bytesRead
                    }
                    tail.removeSubrange(...firstNewline)
                }
                session.offset = fileSize
                session.remainder.removeAll(keepingCapacity: true)
                session.remainder.append(tail)
                parseLines(into: &session)
                sessions[path] = session
                return bytesRead
            }

            try handle.seek(toOffset: session.offset)
            let count = Int(min(fileSize - session.offset, maximumRead))
            guard let newData = try handle.read(upToCount: count), !newData.isEmpty else { return 0 }
            session.offset += UInt64(newData.count)
            session.remainder.append(newData)
            parseLines(into: &session)
            sessions[path] = session
            return newData.count
        } catch {
            return 0
        }
    }

    private func parseLines(into session: inout Session) {
        var processedRecords = 0
        while processedRecords < Self.maximumRecordsPerParse,
              let newline = session.remainder.firstIndex(of: 0x0A) {
            let line = Data(session.remainder[..<newline])
            session.remainder.removeSubrange(...newline)
            processedRecords += 1
            guard line.count <= 2 * 1_024 * 1_024,
                  let event = try? Self.decoder.decode(RolloutEnvelope.self, from: line) else { continue }
            apply(event, to: &session)
        }
        if processedRecords == Self.maximumRecordsPerParse,
           session.remainder.firstIndex(of: 0x0A) != nil {
            session.remainder.removeAll(keepingCapacity: true)
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
                session.workObservedAfterLifecycle = true
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
                session.workObservedAfterLifecycle = false
            case let type? where type.contains("approval") && (type.contains("request") || type.contains("needed")):
                session.explicitState = .needsApproval
                session.attentionEventAt = timestamp
                session.activity = .waiting
                session.workObservedAfterLifecycle = false
            case "request_user_input", "input_required", "waiting_for_input":
                session.explicitState = .needsInput
                session.attentionEventAt = timestamp
                session.activity = .waiting
                session.workObservedAfterLifecycle = false
            case "agent_reasoning", "reasoning":
                session.activity = .thinking
                session.workObservedAfterLifecycle = true
            case "agent_message", "message":
                session.activity = .generating
                session.workObservedAfterLifecycle = true
            case "command_execution", "shell_command", "exec_command":
                session.activity = .runningCommand
                session.workObservedAfterLifecycle = true
            case "custom_tool_call", "function_call", "tool_call", "web_search_call":
                session.activity = .usingTool
                session.workObservedAfterLifecycle = true
            case "custom_tool_call_output", "function_call_output", "tool_call_output":
                session.activity = .thinking
                session.workObservedAfterLifecycle = true
            case "token_count":
                session.workObservedAfterLifecycle = true
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
                tokensPerMinute: Self.timeWeightedRate(
                    samples: minute.map { ($0.timestamp, $0.usage.total) },
                    now: now,
                    window: 60
                ),
                tokensPerFiveMinutes: Self.timeWeightedRate(
                    samples: fiveMinutes.map { ($0.timestamp, $0.usage.total) },
                    now: now,
                    window: 300
                ),
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
        let snapshot = live + Array(recent.prefix(Self.maximumRecentSessions))
        guard snapshotPolicy.shouldPublish(snapshot) else { return }
        PerformanceSignposts.event("Session snapshot published")
        continuation?.yield(snapshot)
    }

    /// Codex writes token usage in batches rather than as individual tokens. A
    /// strict rectangular window makes a batch appear frozen and then disappear
    /// all at once. Preserve the exact rolling-window total while reports arrive,
    /// then taper that total during an idle interval so the displayed rate reflects
    /// each elapsed second without inventing additional token usage.
    nonisolated static func timeWeightedRate(
        samples: [(timestamp: Date, tokens: Int64)],
        now: Date,
        window: TimeInterval
    ) -> Double {
        guard window.isFinite, window > 0 else { return 0 }
        let recent = samples.filter {
            let age = now.timeIntervalSince($0.timestamp)
            return age >= 0 && age <= window && $0.tokens > 0
        }
        guard let newest = recent.map(\.timestamp).max() else { return 0 }
        let total = recent.reduce(Int64(0)) { $0.addingWithoutOverflow($1.tokens) }
        let idleDuration = max(0, now.timeIntervalSince(newest))
        let idleWeight = max(0, min(1, 1 - idleDuration / window))
        return Double(total) * (60 / window) * idleWeight
    }

    private func effectiveState(for session: Session, now: Date) -> ConversationState {
        let isLocked = lockedIDs.contains(session.id)
        let isRecent = session.lastActivity > now.addingTimeInterval(-300)
        if isRecent,
           (session.explicitState == .needsApproval || session.explicitState == .needsInput) {
            return session.explicitState
        }
        // A lifecycle start is direct evidence of a live turn even when a Codex
        // build does not expose writer locks. For very large resumed rollouts the
        // bounded tail can begin after task_started; recent work activity plus a
        // held writer lock is the corresponding high-confidence fallback.
        if isRecent, session.explicitState == .running { return .running }
        if isLocked, isRecent,
           session.workObservedAfterLifecycle {
            return .running
        }
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
        guard let directory = AnchoredFileAccess.openDirectory(locksURL) else {
            lockedIDs = []
            lockDirectoryStream = nil
            lockCycleActiveIDs.removeAll()
            lockDirectoryRestartPending = false
            return
        }
        defer { close(directory.descriptor) }
        if lockDirectoryStream == nil {
            lockDirectoryStream = AnchoredFileAccess.DirectoryStream(directoryDescriptor: directory.descriptor)
        }
        guard let lockDirectoryStream else {
            lockedIDs = []
            lockCycleActiveIDs.removeAll()
            return
        }

        var discovered = Set<String>()
        let trackedIDs = Set(sessions.values.lazy.map(\.id).filter { UUID(uuidString: $0) != nil })
        var directlyActive = Set<String>()
        for id in trackedIDs where Self.isActivelyLocked("\(id).lock", directoryDescriptor: directory.descriptor) {
            directlyActive.insert(id)
        }
        lockedIDs.subtract(trackedIDs)
        lockedIDs.formUnion(directlyActive)

        var probes = 0
        let batch = lockDirectoryStream.nextBatch(maximumEntries: Self.maximumLockEntriesPerPass)
        for name in batch.names where probes < Self.maximumLockProbesPerPass {
            guard name.hasSuffix(".lock") else { continue }
            let id = String(name.dropLast(5))
            guard UUID(uuidString: id) != nil else { continue }
            probes += 1
            if Self.isActivelyLocked(name, directoryDescriptor: directory.descriptor) {
                discovered.insert(id)
            }
        }
        lockCycleActiveIDs.formUnion(discovered)
        if batch.reachedEnd {
            lockCycleActiveIDs.subtract(trackedIDs)
            lockCycleActiveIDs.formUnion(directlyActive)
            lockedIDs = lockCycleActiveIDs
            lockCycleActiveIDs.removeAll(keepingCapacity: true)
            if lockDirectoryRestartPending {
                self.lockDirectoryStream = nil
                lockDirectoryRestartPending = false
            }
        } else {
            lockedIDs.formUnion(discovered)
        }
        reconcileLockedSessions()
    }

    /// A resumed task can be much older than the recent-session scan. Codex task
    /// IDs are UUIDv7 values, so their creation day identifies the rollout folder
    /// without a full-directory rescan. This reconnects every newly observed live
    /// lock while keeping idle maintenance bounded.
    private func reconcileLockedSessions() {
        guard sessionsRootDescriptor >= 0 else { return }
        let trackedIDs = Set(sessions.values.lazy.map(\.id).filter { !$0.isEmpty })
        var pathsToProcess: [String] = []
        for id in lockedIDs.subtracting(trackedIDs) {
            guard let path = rolloutPath(for: id) else { continue }
            if let trackedPath = track(path: path) {
                pathsToProcess.append(trackedPath)
            }
        }
        process(paths: pathsToProcess)
    }

    private func rolloutPath(for id: String) -> String? {
        guard let date = Self.creationDate(fromTaskID: id) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return nil }
        let directory = sessionsURL
            .appending(path: String(format: "%04d", year), directoryHint: .isDirectory)
            .appending(path: String(format: "%02d", month), directoryHint: .isDirectory)
            .appending(path: String(format: "%02d", day), directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              let name = names.first(where: {
                  $0.hasPrefix("rollout-") && $0.hasSuffix("-\(id).jsonl")
              }) else { return nil }
        return directory.appending(path: name).path
    }

    static func creationDate(fromTaskID id: String) -> Date? {
        let compact = id.replacingOccurrences(of: "-", with: "")
        guard compact.count == 32,
              compact[compact.index(compact.startIndex, offsetBy: 12)] == "7",
              let milliseconds = UInt64(compact.prefix(12), radix: 16) else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private func loadTitles() {
        let indexURL = codexHomeURL.appending(path: "session_index.jsonl")
        let values = try? indexURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        let modified = values?.contentModificationDate
        guard modified != titleIndexModificationDate else { return }
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              let size = values?.fileSize,
              size <= 16 * 1_024 * 1_024,
              let data = BoundedFileReader.read(indexURL, maximumBytes: 16 * 1_024 * 1_024) else { return }
        for line in data.split(
            separator: 0x0A,
            maxSplits: Self.maximumTitleRecords,
            omittingEmptySubsequences: true
        ).prefix(Self.maximumTitleRecords) {
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

    private static func isActivelyLocked(_ name: String, directoryDescriptor: Int32) -> Bool {
        guard let descriptor = AnchoredFileAccess.openRegularFile(
            relativePath: name,
            directoryDescriptor: directoryDescriptor
        ) else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    private func prepareSessionsRoot(replacingExisting: Bool = false) -> Bool {
        if sessionsRootDescriptor >= 0, !replacingExisting { return true }
        guard let directory = AnchoredFileAccess.openDirectory(sessionsURL) else { return false }
        if sessionsRootDescriptor >= 0 { close(sessionsRootDescriptor) }
        sessionsRootDescriptor = directory.descriptor
        sessionsRootPath = directory.resolvedPath
        return true
    }

    private func relativeSessionPath(for path: String) -> String? {
        guard let sessionsRootPath else { return nil }
        let prefix = sessionsRootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
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
        let callback: @Sendable ([String], Bool) -> Void
        init(callback: @escaping @Sendable ([String], Bool) -> Void) { self.callback = callback }
    }

    private let paths: [String]
    private let box: CallbackBox
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.northwolflabs.CodexGauge.fsevents", qos: .utility)

    init(paths: [String], callback: @escaping @Sendable ([String], Bool) -> Void) {
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
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = (0..<count).map { eventFlags[$0] }
            let requiresRescan = FSEventRescanPolicy.requiresRescan(flags)
            if count > 0 { box.callback(paths, requiresRescan) }
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
