import Foundation

private final class BoundedPipeBuffer: @unchecked Sendable {
    enum AppendResult {
        case buffered
        case scheduleDrain
        case overflow
        case closed
    }

    private let lock = NSLock()
    private let maximumBytes: Int
    private var chunks: [Data] = []
    private var byteCount = 0
    private var drainScheduled = false
    private var isClosed = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ data: Data) -> AppendResult {
        lock.withLock {
            guard !isClosed else { return .closed }
            guard byteCount <= maximumBytes - data.count else {
                isClosed = true
                chunks.removeAll(keepingCapacity: false)
                byteCount = 0
                return .overflow
            }
            chunks.append(data)
            byteCount += data.count
            if drainScheduled { return .buffered }
            drainScheduled = true
            return .scheduleDrain
        }
    }

    func take() -> Data? {
        lock.withLock {
            guard !chunks.isEmpty else {
                drainScheduled = false
                return nil
            }
            let data = chunks.removeFirst()
            byteCount -= data.count
            return data
        }
    }

    func reset() {
        lock.withLock {
            chunks.removeAll(keepingCapacity: false)
            byteCount = 0
            drainScheduled = false
            isClosed = false
        }
    }

    func close() {
        lock.withLock {
            isClosed = true
            chunks.removeAll(keepingCapacity: false)
            byteCount = 0
            drainScheduled = false
        }
    }
}

enum CodexAppServerError: LocalizedError, Sendable {
    case executableUnavailable
    case launchFailed(String)
    case connectionClosed
    case timedOut(String)
    case protocolError(String)
    case signedOut

    var errorDescription: String? {
        switch self {
        case .executableUnavailable: "Codex could not be found."
        case .launchFailed: "Codex could not be started. Check the selected executable in Settings and try again."
        case .connectionClosed: "Codex stopped responding unexpectedly."
        case .timedOut: "Codex did not respond in time."
        case .protocolError: "Codex returned an unexpected response."
        case .signedOut: "Open ChatGPT and sign in to view Codex allowances."
        }
    }
}

actor CodexAppServerClient: AccountTelemetryProviding {
    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let executableURL: URL
    private let codexHomeURL: URL
    private let clock: any ClockProviding
    private let skipTrustValidation: Bool
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private let queuedOutput = BoundedPipeBuffer(maximumBytes: 1_024 * 1_024)
    private var pending: [Int: PendingRequest] = [:]
    private var nextRequestID = 1
    private var initialized = false
    private var generation = 0
    private var eventContinuations: [UUID: AsyncStream<AppServerEvent>.Continuation] = [:]

    init(
        executableURL: URL,
        codexHomeURL: URL,
        clock: any ClockProviding = SystemClock(),
        skipTrustValidation: Bool = false
    ) {
        self.executableURL = executableURL
        self.codexHomeURL = codexHomeURL
        self.clock = clock
        self.skipTrustValidation = skipTrustValidation
    }

    func events() async -> AsyncStream<AppServerEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    func fetchAccountIdentity() async throws -> AccountIdentity {
        try await ensureInitialized()
        let data = try await request(method: "account/read", params: ["refreshToken": false])
        let account = try decode(AccountResponse.self, from: data)
        guard let accountValue = account.account else { throw CodexAppServerError.signedOut }
        return AccountIdentity(accountType: accountValue.type, plan: accountValue.planType)
    }

    func validateConnection() async throws {
        try await ensureInitialized()
    }

    func fetchRateLimits() async throws -> RateLimitSnapshot {
        try await ensureInitialized()
        let data = try await request(method: "account/rateLimits/read")
        let limits = try decode(RateLimitsResponse.self, from: data)
        return RateLimitSnapshot(
            plan: limits.rateLimits.planType,
            buckets: limits.buckets,
            earnedResetCount: limits.rateLimitResetCredits?.availableCount,
            fetchedAt: clock.now
        )
    }

    func fetchAccountActivity() async throws -> AccountActivity {
        try await ensureInitialized()
        let data = try await request(method: "account/usage/read")
        return try decode(AccountUsageResponse.self, from: data).activity
    }

    func stop() async {
        generation += 1
        initialized = false
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        inputHandle?.closeFile()
        outputHandle?.closeFile()
        errorHandle?.closeFile()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputBuffer.removeAll(keepingCapacity: false)
        queuedOutput.close()
        failPending(with: CodexAppServerError.connectionClosed)
        eventContinuations.values.forEach { $0.finish() }
        eventContinuations.removeAll()
    }

    private func ensureInitialized() async throws {
        if initialized, process?.isRunning == true { return }
        try startProcess()
        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "CodexGauge",
                    "title": "CodexGauge",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                ],
                "capabilities": [:]
            ]
        )
        try sendNotification(method: "initialized")
        initialized = true
    }

    private func startProcess() throws {
        let launchURL = skipTrustValidation
            ? executableURL.standardizedFileURL.resolvingSymlinksInPath()
            : try CodexExecutableTrust.validate(executableURL)
        guard FileManager.default.isExecutableFile(atPath: launchURL.path) else {
            throw CodexAppServerError.executableUnavailable
        }

        generation += 1
        let currentGeneration = generation
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let child = Process()
        child.executableURL = launchURL
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        child.standardError = errorPipe

        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"] {
            environment[key] = inherited[key]
        }
        environment["CODEX_HOME"] = codexHomeURL.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        child.environment = environment
        child.terminationHandler = { [weak self] _ in
            Task { await self?.processTerminated(generation: currentGeneration) }
        }

        do {
            try child.run()
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        process = child
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        errorHandle = errorPipe.fileHandleForReading
        initialized = false
        outputBuffer.removeAll(keepingCapacity: true)
        queuedOutput.reset()

        outputHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self else { return }
            switch self.queuedOutput.append(data) {
            case .scheduleDrain:
                Task { await self.drainOutput(generation: currentGeneration) }
            case .overflow:
                Task { await self.rejectExcessiveOutput(generation: currentGeneration) }
            case .buffered, .closed:
                break
            }
        }
        // Codex can be verbose on stderr. Always drain it so the helper cannot deadlock.
        errorHandle?.readabilityHandler = { handle in
            _ = handle.availableData
        }
    }

    private func request(
        method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval = 15
    ) async throws -> Data {
        guard process?.isRunning == true, let inputHandle else {
            throw CodexAppServerError.connectionClosed
        }

        let id = nextRequestID
        nextRequestID += 1
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        let payload = try JSONSerialization.data(withJSONObject: message) + Data([0x0A])

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    await self?.requestTimedOut(id: id, method: method)
                }
                pending[id] = PendingRequest(
                    method: method,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                do {
                    try inputHandle.write(contentsOf: payload)
                } catch {
                    resolve(id: id, result: .failure(CodexAppServerError.connectionClosed))
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    private func sendNotification(method: String, params: [String: Any]? = nil) throws {
        guard let inputHandle else { throw CodexAppServerError.connectionClosed }
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        let payload = try JSONSerialization.data(withJSONObject: message) + Data([0x0A])
        try inputHandle.write(contentsOf: payload)
    }

    private func drainOutput(generation receivedGeneration: Int) {
        while let data = queuedOutput.take() {
            guard receive(data, generation: receivedGeneration) else { return }
        }
    }

    private func receive(_ data: Data, generation receivedGeneration: Int) -> Bool {
        guard receivedGeneration == generation else { return false }
        guard outputBuffer.count <= 1_024 * 1_024 - data.count else {
            rejectExcessiveOutput(generation: receivedGeneration)
            return false
        }
        outputBuffer.append(data)
        var processedFrames = 0
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            guard newline <= 1_024 * 1_024, processedFrames < 512 else {
                rejectExcessiveOutput(generation: receivedGeneration)
                return false
            }
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            handleLine(Data(line))
            processedFrames += 1
        }
        return true
    }

    private func rejectExcessiveOutput(generation receivedGeneration: Int) {
        guard receivedGeneration == generation else { return }
        generation += 1
        initialized = false
        queuedOutput.close()
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        inputHandle?.closeFile()
        outputHandle?.closeFile()
        errorHandle?.closeFile()
        if let process, process.isRunning { process.terminate() }
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputBuffer.removeAll(keepingCapacity: false)
        failPending(with: CodexAppServerError.protocolError("Codex sent too much data."))
    }

    private func handleLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = Self.integerID(object["id"]), pending[id] != nil {
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Codex returned an unknown error."
                resolve(id: id, result: .failure(CodexAppServerError.protocolError(message)))
            } else if let result = object["result"] {
                do {
                    resolve(id: id, result: .success(try JSONSerialization.data(withJSONObject: result)))
                } catch {
                    resolve(id: id, result: .failure(error))
                }
            } else {
                resolve(id: id, result: .failure(CodexAppServerError.protocolError("Codex returned an incomplete response.")))
            }
            return
        }

        guard let method = object["method"] as? String else { return }
        let event: AppServerEvent?
        switch method {
        case "account/rateLimits/updated": event = AppServerEvent(kind: .rateLimitsChanged)
        case "account/updated": event = AppServerEvent(kind: .accountChanged)
        default: event = nil
        }
        if let event {
            eventContinuations.values.forEach { $0.yield(event) }
        }
    }

    private func processTerminated(generation terminatedGeneration: Int) {
        guard terminatedGeneration == generation else { return }
        initialized = false
        process = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        queuedOutput.close()
        failPending(with: CodexAppServerError.connectionClosed)
    }

    private func requestTimedOut(id: Int, method: String) {
        resolve(id: id, result: .failure(CodexAppServerError.timedOut(method)))
    }

    private func cancelRequest(id: Int) {
        resolve(id: id, result: .failure(CancellationError()))
    }

    private func resolve(id: Int, result: Result<Data, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(with: result)
    }

    private func failPending(with error: Error) {
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CodexAppServerError.protocolError("Codex returned activity data in an unsupported format.")
        }
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

struct AccountResponse: Decodable {
    struct Account: Decodable {
        let type: String
        let planType: String?
    }
    let account: Account?
}

struct RateLimitsResponse: Decodable {
    struct ResetCredits: Decodable { let availableCount: Int }
    struct Credits: Decodable {
        let hasCredits: Bool
        let unlimited: Bool
        let balance: String?
    }
    struct SpendControl: Decodable {
        let limit: String
        let used: String
        let remainingPercent: Int
        let resetsAt: Int64
    }
    struct Window: Decodable {
        let usedPercent: Int
        let windowDurationMins: Int?
        let resetsAt: Int64?
    }
    struct Snapshot: Decodable {
        let limitId: String?
        let limitName: String?
        let planType: String?
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
        let individualLimit: SpendControl?
        let spendControlReached: Bool?
        let rateLimitReachedType: String?
    }

    let rateLimits: Snapshot
    let rateLimitsByLimitId: [String: Snapshot]?
    let rateLimitResetCredits: ResetCredits?

    var buckets: [QuotaBucket] {
        let values: [(String, Snapshot)]
        if let mapped = rateLimitsByLimitId, !mapped.isEmpty {
            values = mapped.map { ($0.key, $0.value) }
        } else {
            values = [(rateLimits.limitId ?? "codex", rateLimits)]
        }

        return values.map { key, snapshot in
            let windows: [QuotaWindow] = [
                snapshot.primary.map {
                    QuotaWindow(
                        id: "\(key)-primary",
                        kind: "Primary",
                        usedPercent: min(100, max(0, $0.usedPercent)),
                        durationMinutes: $0.windowDurationMins,
                        resetsAt: $0.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    )
                },
                snapshot.secondary.map {
                    QuotaWindow(
                        id: "\(key)-secondary",
                        kind: "Secondary",
                        usedPercent: min(100, max(0, $0.usedPercent)),
                        durationMinutes: $0.windowDurationMins,
                        resetsAt: $0.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    )
                }
            ].compactMap { $0 }

            return QuotaBucket(
                id: snapshot.limitId ?? key,
                name: snapshot.limitName ?? (key == "codex" ? "Codex" : key),
                plan: snapshot.planType,
                windows: windows,
                credits: snapshot.credits.map {
                    CreditSnapshot(hasCredits: $0.hasCredits, unlimited: $0.unlimited, balance: $0.balance)
                },
                spendControl: snapshot.individualLimit.map {
                    SpendControlSnapshot(
                        limit: $0.limit,
                        used: $0.used,
                        remainingPercent: min(100, max(0, $0.remainingPercent)),
                        resetsAt: Date(timeIntervalSince1970: TimeInterval($0.resetsAt))
                    )
                },
                spendControlReached: snapshot.spendControlReached,
                reachedReason: snapshot.rateLimitReachedType
            )
        }.sorted { lhs, rhs in
            if lhs.id == "codex" { return true }
            if rhs.id == "codex" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

struct AccountUsageResponse: Decodable {
    struct Summary: Decodable {
        let lifetimeTokens: Int64?
        let peakDailyTokens: Int64?
        let longestRunningTurnSec: Int64?
        let currentStreakDays: Int64?
        let longestStreakDays: Int64?
    }
    struct Bucket: Decodable {
        let startDate: String
        let tokens: Int64
    }

    let summary: Summary
    let dailyUsageBuckets: [Bucket]?

    var activity: AccountActivity {
        return AccountActivity(
            lifetimeTokens: summary.lifetimeTokens,
            peakDailyTokens: summary.peakDailyTokens,
            longestRunningTurnSeconds: summary.longestRunningTurnSec,
            currentStreakDays: summary.currentStreakDays,
            longestStreakDays: summary.longestStreakDays,
            dailyUsage: (dailyUsageBuckets ?? []).compactMap { bucket in
                ActivityDay(iso8601Date: bucket.startDate).map { DailyUsage(day: $0, tokens: bucket.tokens) }
            }.sorted { $0.day < $1.day }
        )
    }
}
