import Foundation

struct CompanionNotificationRoute: Equatable, Sendable {
    let macID: String
    let taskID: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard let rawID = userInfo["macID"] as? String, let id = UUID(uuidString: rawID) else { return nil }
        macID = id.uuidString.lowercased()
        if let value = userInfo["taskID"] {
            guard let task = value as? String, !task.isEmpty, task.utf16.count <= 200 else { return nil }
            taskID = task
        } else { taskID = nil }
    }

    func isLinked(in links: [CompanionLink]) -> Bool {
        links.contains { $0.id.lowercased() == macID }
    }
}

enum CompanionText {
    /// The JSON schema counts UTF-16 code units (JavaScript string length), not
    /// Swift Characters. Keep whole graphemes while respecting that wire limit.
    static func prefix(_ value: String, utf16Limit: Int = 200) -> String {
        var result = "", count = 0
        for character in value {
            let length = String(character).utf16.count
            guard count + length <= utf16Limit else { break }
            result.append(character); count += length
        }
        return result
    }
}

// Deliberately contains only presentation telemetry. No paths, credentials,
// prompts, transcripts, tool output, or executable commands cross this boundary.
struct CompanionWindow: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var remainingPercent: Int
    var resetsAt: Date?
}

struct CompanionAccount: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var plan: String?
    var observedAt: Date
    var windows: [CompanionWindow]
    var bankedResets: Int?
    var lifetimeTokens: Int64?
    var dailyTokens: [CompanionDay]
    var credits: [CompanionCredit]? = nil
    var metrics: CompanionAccountMetrics? = nil
    var email: String? = nil
    var accountType: String? = nil
    var historyTruncated: Bool? = nil
    var historyObservedAt: Date? = nil

    var displayName: String { email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Account identity unavailable" }
    var detail: String { [accountType.map { $0.lowercased() == "chatgpt" ? "ChatGPT" : $0.lowercased() == "apikey" ? "API key" : $0 }, plan?.capitalized].compactMap { $0?.nilIfEmpty }.joined(separator: " · ") }
    var hasHistoryEvidence: Bool {
        !dailyTokens.isEmpty || lifetimeTokens != nil || metrics.map { $0.peakDailyTokens != nil || $0.longestTurnSeconds != nil || $0.currentStreakDays != nil || $0.longestStreakDays != nil } == true
    }
    var hasVerifiedIdentity: Bool { !id.hasPrefix("unverified:") }
    func isStale(at now: Date) -> Bool { now.timeIntervalSince(observedAt) >= 180 }
}

struct CompanionCredit: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?
    var displayBalance: String {
        if unlimited { return "Unlimited" }
        if let balance, !balance.isEmpty { return CompanionCreditFormatting.balance(balance) }
        return hasCredits ? "Available" : "0"
    }
}

/// Round only the displayed balance; keep the original decimal string on the wire.
enum CompanionCreditFormatting {
    static func balance(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z"#,
                         options: .regularExpression) != nil,
              var decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !decimal.isNaN else { return value }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 4, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}

enum CompanionWidgetTimeline {
    static func dates(now: Date, observedAt: Date?, resetsAt: Date?) -> [Date] {
        var dates: Set<Date> = [now]
        if let staleAt = observedAt?.addingTimeInterval(180), staleAt > now { dates.insert(staleAt) }
        if let resetsAt, resetsAt > now { dates.insert(resetsAt) }
        return dates.sorted()
    }
}

struct CompanionDay: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var tokens: Int64
}

struct CompanionAccountMetrics: Codable, Hashable, Sendable {
    var peakDailyTokens: Int64?
    var longestTurnSeconds: Int64?
    var currentStreakDays: Int64?
    var longestStreakDays: Int64?
}

struct CompanionTaskMetrics: Codable, Hashable, Sendable {
    var model: String?
    var fiveMinuteRate: Double?
    var callsPerMinute: Double?
    var input: Int64?
    var cachedInput: Int64?
    var cacheWriteInput: Int64?
    var output: Int64?
    var reasoning: Int64?
    var latestOutput: Int64?
    var firstTokenMilliseconds: Int64?
    var lastTurnSeconds: Double?
    var contextIncludesAgent: Bool?
    var tokenTotalsComplete: Bool? = nil
}

enum CompanionTaskState: String, Codable, Sendable {
    case running, needsInput, needsApproval, completed
    var title: String {
        switch self {
        case .running: "Working"
        case .needsInput: "Needs input"
        case .needsApproval: "Needs approval"
        case .completed: "Completed"
        }
    }
    var symbol: String {
        switch self {
        case .running: "circle.dotted"
        case .needsInput: "text.bubble"
        case .needsApproval: "checkmark.shield"
        case .completed: "checkmark.circle"
        }
    }
}

struct CompanionTask: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var project: String?
    var state: CompanionTaskState
    var activity: String
    var tokensPerMinute: Double
    var totalTokens: Int64
    var contextPercent: Double?
    var startedAt: Date?
    var eventAt: Date?
    var agentCount: Int
    var observedAt: Date? = nil
    var hasTokenObservation: Bool? = nil
    var metrics: CompanionTaskMetrics? = nil
    func isStale(at now: Date) -> Bool { observedAt.map { now.timeIntervalSince($0) > 90 } ?? false }
    var hasRate: Bool { hasTokenObservation ?? (tokensPerMinute > 0) }
    // Accept old Mac snapshots without presenting a missing phase as a failure.
    var displayActivity: String { state == .running && activity == "Activity unavailable" ? "Working" : activity }

}

struct CompanionSnapshot: Codable, Hashable, Identifiable, Sendable {
    var schemaVersion = 1
    var id: String // Stable installation identifier, not the Mac's hardware identity.
    var name: String
    var observedAt: Date
    var account: CompanionAccount?
    var tasks: [CompanionTask]
    var activeTasks: [CompanionTask] {
        tasks.filter { $0.state != .completed }.sorted {
            let left = $0.state == .running ? 1 : 0
            let right = $1.state == .running ? 1 : 0
            if left != right { return left < right }
            // Token updates must not continually rearrange the list under a finger.
            let leftDate = $0.startedAt ?? .distantPast, rightDate = $1.startedAt ?? .distantPast
            return leftDate == rightDate ? $0.id < $1.id : leftDate > rightDate
        }
    }
    func isStale(at now: Date) -> Bool { now.timeIntervalSince(observedAt) > 90 }

    /// Long Unicode titles can exceed the wire limit even within the task-count
    /// limit. Keep allowances and active tasks ahead of completed task history.
    func encodedForTransport(maxBytes: Int = 128 * 1024 - 1) throws -> Data {
        let full = try CompanionCoding.encoder.encode(self)
        if full.count <= maxBytes { return full }
        var bounded = self
        let ordered = tasks.filter { $0.state != .completed } + tasks.filter { $0.state == .completed }
        bounded.tasks = []
        var result = try CompanionCoding.encoder.encode(bounded)
        guard result.count <= maxBytes else { throw CompanionError.invalidData }
        var low = 0, high = ordered.count
        while low < high {
            let count = (low + high + 1) / 2
            bounded.tasks = Array(ordered.prefix(count))
            let data = try CompanionCoding.encoder.encode(bounded)
            if data.count <= maxBytes { low = count; result = data }
            else { high = count - 1 }
        }
        return result
    }
}

/// A read capability is independent of the Mac's publish credential. It cannot
/// connect as a publisher, configure a Mac, or issue commands.
struct CompanionLink: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var server: URL
    var token: String
    var name: String
    var deviceID: String? = nil

    var shareURL: URL {
        var components = URLComponents()
        components.scheme = "tokentach"
        components.host = "view"
        components.queryItems = [URLQueryItem(name: "server", value: server.absoluteString),
                                URLQueryItem(name: "id", value: id)]
        // Keep the capability out of HTTP query strings / access logs.
        components.fragment = token
        return components.url!
    }

    init(id: String, server: URL, token: String, name: String) {
        self.id = id.lowercased(); self.server = server; self.token = token; self.name = name
    }

    init(url: URL) throws {
        guard ["tokentach", "codexgauge"].contains(url.scheme ?? ""), url.host == "view",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let serverText = parts.queryItems?.first(where: { $0.name == "server" })?.value,
              let server = URL(string: serverText), Self.validServer(server),
              let id = parts.queryItems?.first(where: { $0.name == "id" })?.value,
              UUID(uuidString: id) != nil, let token = parts.fragment,
              token.count == 64, token.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw CompanionError.invalidLink
        }
        self.init(id: id, server: server, token: token, name: "Mac")
    }

    static func validServer(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.host != nil else { return false }
        if url.scheme == "https" { return true }
        #if DEBUG
        return url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host)
        #else
        return false
        #endif
    }
}

enum CompanionError: LocalizedError {
    case invalidLink, rejected, invalidData
    var errorDescription: String? {
        switch self {
        case .invalidLink: "This viewing link isn’t valid. Copy a new link from the Mac."
        case .rejected: "Access was rejected. The link may have been revoked."
        case .invalidData: "The relay returned an unsupported response."
        }
    }
}

enum CompanionCoding {
    static var encoder: JSONEncoder {
        let value = JSONEncoder(); value.dateEncodingStrategy = .secondsSince1970; return value
    }
    static var decoder: JSONDecoder {
        let value = JSONDecoder(); value.dateDecodingStrategy = .secondsSince1970; return value
    }
}

enum CompanionMerge {
    static let allAccountsID = "codexgauge:all-accounts"
    /// Input has already been deduplicated by verified account identity.
    static func combinedActivity(_ accounts: [CompanionAccount]) -> CompanionAccount? {
        guard !accounts.isEmpty else { return nil }
        let verified = accounts.filter(\.hasVerifiedIdentity)
        var values: [String: Int64] = [:]
        func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let value = lhs.addingReportingOverflow(rhs)
            return value.overflow ? Int64.max : value.partialValue
        }
        for account in verified {
            let days = Dictionary(account.dailyTokens.map { ($0.id, max(0, $0.tokens)) }, uniquingKeysWith: max)
            for (day, tokens) in days { values[day] = add(values[day] ?? 0, tokens) }
        }
        return CompanionAccount(id: allAccountsID, plan: nil, observedAt: (verified.isEmpty ? accounts : verified).map(\.observedAt).min()!,
            windows: [], bankedResets: nil, lifetimeTokens: !verified.isEmpty && verified.allSatisfy { $0.lifetimeTokens != nil } ? verified.reduce(0) { add($0, $1.lifetimeTokens!) } : nil,
            dailyTokens: values.keys.sorted().map { .init(id: $0, tokens: values[$0]!) },
            historyTruncated: verified.contains { $0.historyTruncated == true },
            historyObservedAt: verified.allSatisfy { $0.historyObservedAt != nil } ? verified.compactMap(\.historyObservedAt).min() : nil)
    }

    /// Percentages and account-wide activity are observations, never additive.
    /// Missing identities use installation-specific keys at the publishing boundary.
    static func accounts(_ snapshots: [CompanionSnapshot]) -> [CompanionAccount] {
        let groups = Dictionary(grouping: snapshots.filter { $0.account != nil }) { $0.account!.id }
        return groups.values.compactMap { group -> CompanionAccount? in
            let metadata = group.sorted {
                let lhs = $0.account!.observedAt, rhs = $1.account!.observedAt
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            }.last?.account
            guard var result = metadata else { return nil }
            var days: [String: Int64] = [:]
            let observations = group.filter { $0.account!.hasHistoryEvidence }.sorted {
                let lhs = $0.account!.historyObservedAt ?? $0.account!.observedAt
                let rhs = $1.account!.historyObservedAt ?? $1.account!.observedAt
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            }
            for snapshot in observations {
                let values = Dictionary(snapshot.account!.dailyTokens.map { ($0.id, $0.tokens) }, uniquingKeysWith: max)
                for (day, tokens) in values { days[day] = tokens }
            }
            result.dailyTokens = days.keys.sorted().map { CompanionDay(id: $0, tokens: days[$0]!) }
            result.historyObservedAt = observations.last?.account?.historyObservedAt
            result.lifetimeTokens = observations.last?.account?.lifetimeTokens
            result.metrics = observations.last?.account?.metrics
            result.historyTruncated = observations.contains { $0.account?.historyTruncated == true }
            return result
        }.sorted { $0.id < $1.id }
    }
}

/// A fetch is bound to the exact viewing capability that initiated it. An old
/// full-access response must not survive a replacement with a usage-only link.
enum CompanionFetchResult: Sendable {
    case snapshot(CompanionSnapshot), unavailable, cleared
}

struct CompanionFetchUpdate: Sendable {
    var link: CompanionLink
    var result: CompanionFetchResult
}

extension CompanionMerge {
    static func refreshedSnapshots(_ cached: [CompanionSnapshot], updates: [CompanionFetchUpdate],
                                   currentLinks: [CompanionLink]) -> [CompanionSnapshot] {
        var values: [String: CompanionSnapshot] = [:]
        for snapshot in cached where currentLinks.contains(where: { $0.id == snapshot.id }) {
            values[snapshot.id] = snapshot
        }
        for update in updates where currentLinks.contains(update.link) {
            switch update.result {
            case .snapshot(let snapshot):
                guard snapshot.id == update.link.id else { continue }
                if let existing = values[snapshot.id], existing.observedAt > snapshot.observedAt { continue }
                values[snapshot.id] = snapshot
            case .cleared: values.removeValue(forKey: update.link.id)
            case .unavailable: break // Keep explicitly dated last-known usage when offline.
            }
        }
        return values.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Rolling calendar days in the viewer's time zone, including today. A year
/// respects leap years; All means available observations, never a lifetime sum.
enum CompanionActivityRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, quarter, year, all
    var id: Self { self }
    var usesLineChart: Bool {
        switch self {
        case .quarter, .year, .all: true
        case .today, .week, .month: false
        }
    }
    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .year: "1 year"
        case .all: "All"
        }
    }
    var periodName: String {
        switch self {
        case .today: "Today"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .quarter: "Last 90 days"
        case .year: "Last year"
        case .all: "All available days"
        }
    }
    func dayCount(at now: Date, calendar: Calendar = .current) -> Int? {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return nil
        case .year:
            let today = calendar.startOfDay(for: now)
            guard let prior = calendar.date(byAdding: .year, value: -1, to: today) else { return 365 }
            return calendar.dateComponents([.day], from: prior, to: today).day ?? 365
        }
    }
}

/// An observation before the turn began cannot measure that turn's elapsed time.
enum CompanionTaskTiming {
    static func observedElapsed(start: Date, task: Date?, snapshot: Date?) -> TimeInterval? {
        guard let observation = [task, snapshot].compactMap({ $0 }).min(), observation >= start else { return nil }
        return observation.timeIntervalSince(start)
    }
}

/// Latest-value telemetry may be replaced; notification transitions are retained
/// locally until the relay has accepted them into its durable inbox. This file
/// contains display data only, never publisher credentials or APNs tokens.
struct CompanionPushJournal: Codable, Sendable {
    private(set) var pending: [CompanionSnapshot] = []
    private var signature: String?

    mutating func observe(_ snapshot: CompanionSnapshot) throws -> Bool {
        let next = try snapshot.notificationSignature()
        guard signature != next else { return false }
        signature = next
        pending.removeAll { $0.id != snapshot.id || snapshot.observedAt.timeIntervalSince($0.observedAt) > 3500 }
        pending.append(snapshot.pushObservation)
        // The server's notification expiry is one hour. Bound local disk use as
        // well, retaining the baseline and most recent transitions under overload.
        if pending.count > 128 { pending = [pending[0]] + Array(pending.suffix(127)) }
        return true
    }
    mutating func acknowledge(through date: Date) -> Bool {
        let before = pending.count
        pending.removeAll { $0.isAcknowledged(through: date) }
        return pending.count != before
    }
    func batch(latest: CompanionSnapshot) throws -> Data {
        struct Batch: Encodable { let observations: [CompanionSnapshot] }
        let retained = pending.filter { $0.id == latest.id && latest.observedAt.timeIntervalSince($0.observedAt) < 3500 }
        var observations = Array(retained.prefix(15))
        // Never skip ahead of unsent important transitions. Otherwise the
        // receiver's ordering guard would discard those transitions on replay.
        if retained.count <= 15 && (observations.last?.observedAt ?? .distantPast) < latest.observedAt {
            observations.append(latest.pushObservation)
        }
        if observations.isEmpty { observations = [latest.pushObservation] }
        var data = try CompanionCoding.encoder.encode(Batch(observations: observations))
        while data.count > 1024 * 1024 && observations.count > 1 {
            observations.removeLast()
            data = try CompanionCoding.encoder.encode(Batch(observations: observations))
        }
        guard data.count <= 1024 * 1024 else { throw CompanionError.invalidData }
        return data
    }
}

extension CompanionSnapshot {
    /// Compare in the wire timestamp's precision. Date stores seconds from 2001;
    /// converting to/from Unix seconds can lose a fraction of a microsecond.
    func isAcknowledged(through date: Date) -> Bool {
        date.timeIntervalSince1970 >= observedAt.timeIntervalSince1970
    }
    var pushObservation: CompanionSnapshot {
        var result = self
        result.account?.dailyTokens = []
        result.account?.metrics = nil
        result.account?.credits = nil
        result.account?.lifetimeTokens = nil
        result.tasks = tasks.map { task in
            var result = task
            result.metrics = task.metrics?.contextIncludesAgent.map { includes in
                CompanionTaskMetrics(contextIncludesAgent: includes)
            }
            return result
        }
        return result
    }
    func notificationSignature() throws -> String {
        struct Window: Encodable { let id: String; let low: Bool; let resetsAt: Date? }
        struct Task: Encodable { let id: String; let state: CompanionTaskState; let eventAt: Date?; let startedAt: Date? }
        struct Signature: Encodable { let accountID: String?; let banked: Int?; let windows: [Window]; let tasks: [Task] }
        let value = Signature(accountID: account?.id, banked: account?.bankedResets,
            windows: (account?.windows ?? []).map { Window(id: $0.id, low: $0.remainingPercent <= 10, resetsAt: $0.resetsAt) },
            tasks: tasks.map { Task(id: $0.id, state: $0.state, eventAt: $0.eventAt, startedAt: $0.startedAt) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}


/// The relay derives this from authorized subscriptions and hibernating sockets.
/// It is a hint about telemetry consumers, never permission to execute a command.
struct CompanionPublishDemand: Codable, Equatable, Sendable {
    var viewers: Int
    var push: Bool
    var paired: Bool
    static let legacy = Self(viewers: 1, push: true, paired: true)
}

/// Latest-value delivery clocks are independent of the durable event journal.
/// A failed upload must not mark its observations sent or postpone a transition.
struct CompanionPublishPolicy: Sendable {
    var demand: CompanionPublishDemand?
    private(set) var lastPush: CompanionSnapshot?
    private(set) var lastStream: CompanionSnapshot?
    private var pushAt = Date.distantPast
    private var streamAt = Date.distantPast
    private var refreshAt = Date.distantPast

    mutating func pushed(_ snapshot: CompanionSnapshot, at now: Date, refreshAfter: TimeInterval = 120) {
        lastPush = snapshot; pushAt = now
        refreshAt = now + min(120, max(5, refreshAfter))
    }
    mutating func streamed(_ snapshot: CompanionSnapshot, at now: Date) { lastStream = snapshot; streamAt = now }

    func shouldPush(_ snapshot: CompanionSnapshot, pending: Bool, force: Bool, now: Date) throws -> Bool {
        guard (demand ?? .legacy).push else { return false }
        guard let lastPush else { return true }
        if try pending || force || snapshot.notificationSignature() != lastPush.notificationSignature() { return true }
        let elapsed = now.timeIntervalSince(pushAt)
        if try elapsed >= 5 && snapshot.phaseSignature() != lastPush.phaseSignature() { return true }
        if try elapsed >= 60 && snapshot.pushMetricSignature() != lastPush.pushMetricSignature() { return true }
        // Only a live card needs freshness/lifetime maintenance. No idle polling
        // for alerts: semantic changes above wake the push path immediately.
        return !snapshot.activeTasks.isEmpty && now >= refreshAt
    }

    func shouldStream(_ snapshot: CompanionSnapshot, refresh: Bool, now: Date) throws -> Bool {
        if refresh { return true }
        let demand = demand ?? .legacy, elapsed = now.timeIntervalSince(streamAt)
        if demand.viewers == 0 { return demand.paired && elapsed >= 300 }
        guard let lastStream else { return true }
        if try snapshot.notificationSignature() != lastStream.notificationSignature()
            || snapshot.phaseSignature() != lastStream.phaseSignature() { return true }
        var current = snapshot, previous = lastStream
        current.observedAt = .distantPast; previous.observedAt = .distantPast
        return elapsed >= 30 || elapsed >= 5 && current != previous
    }
}

extension CompanionSnapshot {
    func phaseSignature() throws -> String {
        struct Phase: Encodable { let id: String; let activity: String? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(tasks.sorted { $0.id < $1.id }.map {
            Phase(id: $0.id, activity: $0.activity)
        }), as: UTF8.self)
    }
    func pushMetricSignature() throws -> String {
        var value = pushObservation
        value.observedAt = .distantPast; value.account?.observedAt = .distantPast
        for index in value.tasks.indices { value.tasks[index].observedAt = nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
