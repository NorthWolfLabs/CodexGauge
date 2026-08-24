import Foundation

extension Int64 {
    func addingWithoutOverflow(_ other: Int64) -> Int64 {
        let (result, overflow) = addingReportingOverflow(other)
        guard overflow else { return result }
        return other >= 0 ? .max : .min
    }

    func subtractingWithoutOverflow(_ other: Int64) -> Int64 {
        let (result, overflow) = subtractingReportingOverflow(other)
        guard overflow else { return result }
        return other >= 0 ? .min : .max
    }
}

enum DataFreshness: String, Codable, Sendable {
    case loading
    case fresh
    case stale
    case unavailable
}

enum ConversationState: String, Codable, Sendable, CaseIterable {
    case running
    case needsInput
    case needsApproval
    case idle
    case recent

    var title: String {
        switch self {
        case .running: "Running"
        case .needsInput: "Input Needed"
        case .needsApproval: "Approval Needed"
        case .idle: "Waiting"
        case .recent: "Recently Active"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "waveform"
        case .needsInput: "text.bubble"
        case .needsApproval: "checkmark.shield"
        case .idle: "pause.circle"
        case .recent: "clock"
        }
    }

    var notificationPriority: Int {
        switch self {
        case .needsApproval: 3
        case .needsInput: 2
        case .running: 1
        case .idle, .recent: 0
        }
    }
}

enum ConversationActivity: String, Codable, Sendable {
    case starting
    case thinking
    case generating
    case usingTool
    case runningCommand
    case waiting

    var title: String {
        switch self {
        case .starting: "Starting"
        case .thinking: "Thinking"
        case .generating: "Writing a response"
        case .usingTool: "Using a tool"
        case .runningCommand: "Running a command"
        case .waiting: "Waiting"
        }
    }

    var systemImage: String {
        switch self {
        case .starting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .thinking: "brain"
        case .generating: "text.line.last.and.arrowtriangle.forward"
        case .usingTool: "wrench.and.screwdriver"
        case .runningCommand: "terminal"
        case .waiting: "pause"
        }
    }
}

struct TokenBreakdown: Codable, Hashable, Sendable {
    var input: Int64 = 0
    var cachedInput: Int64 = 0
    var cacheWriteInput: Int64 = 0
    var output: Int64 = 0
    var reasoningOutput: Int64 = 0
    var total: Int64 = 0

    static let zero = TokenBreakdown()

    static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: lhs.input.addingWithoutOverflow(rhs.input),
            cachedInput: lhs.cachedInput.addingWithoutOverflow(rhs.cachedInput),
            cacheWriteInput: lhs.cacheWriteInput.addingWithoutOverflow(rhs.cacheWriteInput),
            output: lhs.output.addingWithoutOverflow(rhs.output),
            reasoningOutput: lhs.reasoningOutput.addingWithoutOverflow(rhs.reasoningOutput),
            total: lhs.total.addingWithoutOverflow(rhs.total)
        )
    }

    func delta(since previous: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: max(0, input.subtractingWithoutOverflow(previous.input)),
            cachedInput: max(0, cachedInput.subtractingWithoutOverflow(previous.cachedInput)),
            cacheWriteInput: max(0, cacheWriteInput.subtractingWithoutOverflow(previous.cacheWriteInput)),
            output: max(0, output.subtractingWithoutOverflow(previous.output)),
            reasoningOutput: max(0, reasoningOutput.subtractingWithoutOverflow(previous.reasoningOutput)),
            total: max(0, total.subtractingWithoutOverflow(previous.total))
        )
    }
}

struct PacingEstimate: Codable, Hashable, Sendable {
    let elapsedPercent: Double
    let projectedUsedAtReset: Double
    let projectedExhaustion: Date?

    var isAheadOfPace: Bool { projectedUsedAtReset >= 100 }
}

struct QuotaWindow: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let kind: String
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var clampedUsedPercent: Int { max(0, min(100, usedPercent)) }
    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }

    var durationName: String {
        guard let durationMinutes else { return kind }
        if durationMinutes % 10_080 == 0 {
            let weeks = durationMinutes / 10_080
            return weeks == 1 ? "Weekly" : "\(weeks)-Week"
        }
        if durationMinutes % 1_440 == 0 {
            let days = durationMinutes / 1_440
            return days == 1 ? "Daily" : "\(days)-Day"
        }
        if durationMinutes % 60 == 0 {
            return "\(durationMinutes / 60)-Hour"
        }
        return "\(durationMinutes)-Minute"
    }

    func pacing(now: Date = .now, isFresh: Bool = true) -> PacingEstimate? {
        guard isFresh,
              usedPercent > 0,
              let durationMinutes,
              durationMinutes > 0,
              let resetsAt,
              resetsAt > now else { return nil }

        let duration = TimeInterval(durationMinutes * 60)
        let start = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 60, elapsed < duration else { return nil }

        let elapsedPercent = elapsed / duration * 100
        let rate = Double(usedPercent) / elapsed
        guard rate.isFinite, rate > 0 else { return nil }

        let projectedUsed = min(999, rate * duration)
        let exhaustion = start.addingTimeInterval(100 / rate)
        return PacingEstimate(
            elapsedPercent: elapsedPercent,
            projectedUsedAtReset: projectedUsed,
            projectedExhaustion: exhaustion < resetsAt ? exhaustion : nil
        )
    }
}

struct CreditSnapshot: Codable, Hashable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct SpendControlSnapshot: Codable, Hashable, Sendable {
    let limit: String
    let used: String
    let remainingPercent: Int
    let resetsAt: Date
}

struct QuotaBucket: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let plan: String?
    let windows: [QuotaWindow]
    let credits: CreditSnapshot?
    let spendControl: SpendControlSnapshot?
    let spendControlReached: Bool?
    let reachedReason: String?

    var limitingWindow: QuotaWindow? {
        windows.min { lhs, rhs in lhs.remainingPercent < rhs.remainingPercent }
    }
}

struct ActivityDay: Codable, Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
    }

    init?(iso8601Date value: String) {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        year = parts[0]
        month = parts[1]
        day = parts[2]
    }

    func date(in calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func < (lhs: ActivityDay, rhs: ActivityDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

struct DailyUsage: Identifiable, Codable, Hashable, Sendable {
    var id: ActivityDay { day }
    let day: ActivityDay
    let tokens: Int64

    var date: Date { day.date() ?? .distantPast }

    init(date: Date, tokens: Int64, calendar: Calendar = .current) {
        day = ActivityDay(date: date, calendar: calendar)
        self.tokens = max(0, tokens)
    }

    init(day: ActivityDay, tokens: Int64) {
        self.day = day
        self.tokens = max(0, tokens)
    }

    private enum CodingKeys: String, CodingKey { case day, date, tokens }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = max(0, try container.decode(Int64.self, forKey: .tokens))
        if let decodedDay = try container.decodeIfPresent(ActivityDay.self, forKey: .day) {
            day = decodedDay
        } else {
            day = ActivityDay(date: try container.decode(Date.self, forKey: .date))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(day, forKey: .day)
        try container.encode(tokens, forKey: .tokens)
    }
}

struct AccountActivity: Codable, Hashable, Sendable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSeconds: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
    let dailyUsage: [DailyUsage]

    static let empty = AccountActivity(
        lifetimeTokens: nil,
        peakDailyTokens: nil,
        longestRunningTurnSeconds: nil,
        currentStreakDays: nil,
        longestStreakDays: nil,
        dailyUsage: []
    )
}

struct AccountSnapshot: Codable, Hashable, Sendable {
    let accountType: String
    let plan: String?
    let buckets: [QuotaBucket]
    let earnedResetCount: Int?
    var activity: AccountActivity
    let fetchedAt: Date

    var canonicalBucket: QuotaBucket? {
        buckets.first(where: { $0.id == "codex" }) ?? buckets.first
    }

    var limitingWindow: QuotaWindow? {
        if let canonical = buckets.first(where: { $0.id == "codex" }) {
            return canonical.limitingWindow
        }
        return buckets.compactMap(\.limitingWindow).min {
            $0.remainingPercent < $1.remainingPercent
        }
    }
}

struct AccountIdentity: Codable, Hashable, Sendable {
    let accountType: String
    let plan: String?
}

struct RateLimitSnapshot: Codable, Hashable, Sendable {
    let plan: String?
    let buckets: [QuotaBucket]
    let earnedResetCount: Int?
    let fetchedAt: Date
}

struct ConversationTelemetry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let workspace: String
    let model: String?
    let state: ConversationState
    let activity: ConversationActivity
    let tokensPerMinute: Double
    let tokensPerFiveMinutes: Double
    /// A model-call rate is available only when the rollout format proves that a
    /// token record represents a distinct call. Nil is preferable to a guess.
    let callsPerMinute: Double?
    let totalTokens: Int64
    let recentTokenMix: TokenBreakdown
    let latestContextPercent: Double?
    /// The start of the current live turn. Nil once that turn has ended.
    let turnStartedAt: Date?
    /// The duration of the most recently completed turn.
    let lastTurnDurationSeconds: TimeInterval?
    let latestOutputTokens: Int64?
    let timeToFirstTokenMilliseconds: Int64?
    /// Timestamp of the exact local input/approval request that produced the
    /// current attention state. Used only to deduplicate local notifications.
    let attentionEventAt: Date?
    let agentCount: Int
    let lastActivity: Date

    var isLive: Bool {
        state == .running || state == .needsInput || state == .needsApproval
    }
}

struct ThreadTitle: Codable, Sendable {
    let id: String
    let name: String
}

struct AppServerEvent: Sendable {
    enum Kind: Sendable {
        case rateLimitsChanged
        case accountChanged
    }
    let kind: Kind
}

protocol AccountTelemetryProviding: Sendable {
    func fetchAccountIdentity() async throws -> AccountIdentity
    func fetchRateLimits() async throws -> RateLimitSnapshot
    func fetchAccountActivity() async throws -> AccountActivity
    func events() async -> AsyncStream<AppServerEvent>
    func stop() async
}

protocol SessionTelemetryProviding: Sendable {
    func snapshots() async -> AsyncStream<[ConversationTelemetry]>
    func stop() async
}

protocol CodexExecutableLocating: Sendable {
    func locate(override: String?) async -> URL?
}

protocol CodexExecutableValidating: Sendable {
    func validate(_ candidate: URL) async throws -> URL
}

@MainActor
protocol NotificationScheduling: Sendable {
    func requestAuthorization() async -> Bool
    func authorizationStatus() async -> NotificationAuthorizationState
    func evaluate(snapshot: AccountSnapshot, thresholds: [Int]) async
    func evaluate(conversations: [ConversationTelemetry]) async
}

enum NotificationAuthorizationState: String, Codable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case unavailable
}

protocol ClockProviding: Sendable {
    var now: Date { get }
}

struct SystemClock: ClockProviding {
    var now: Date { .now }
}
