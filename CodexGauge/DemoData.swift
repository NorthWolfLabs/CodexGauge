import Foundation

private struct DemoNotificationScheduler: NotificationScheduling {
    let status: NotificationAuthorizationState

    func requestAuthorization() async -> Bool { status == .authorized }
    func authorizationStatus() async -> NotificationAuthorizationState { status }
    func evaluate(snapshot: AccountSnapshot, thresholds: [Int]) async {}
    func evaluate(conversations: [ConversationTelemetry]) async {}
}

@MainActor
enum DemoData {
    static func state() -> AppState {
        let arguments = Set(ProcessInfo.processInfo.arguments)
        let notificationStatus: NotificationAuthorizationState = arguments.contains("-uiTestDeniedNotifications")
            ? .denied
            : .authorized
        let state = AppState(
            notifications: DemoNotificationScheduler(status: notificationStatus),
            startImmediately: false
        )
        let now = Date.now
        state.freshness = .fresh
        state.executableURL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        state.accountSnapshot = AccountSnapshot(
            accountType: "chatgpt",
            plan: "pro",
            buckets: [
                QuotaBucket(
                    id: "codex",
                    name: "Codex",
                    plan: "pro",
                    windows: [
                        QuotaWindow(id: "codex-primary", kind: "Primary", usedPercent: arguments.contains("-uiTestLowAllowances") ? 97 : 38, durationMinutes: 300, resetsAt: now.addingTimeInterval(8_400)),
                        QuotaWindow(id: "codex-secondary", kind: "Secondary", usedPercent: 72, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(240_000))
                    ],
                    credits: CreditSnapshot(hasCredits: true, unlimited: false, balance: "12.50"),
                    spendControl: nil,
                    spendControlReached: false,
                    reachedReason: nil
                ),
                QuotaBucket(
                    id: "codex-spark",
                    name: "Codex Spark",
                    plan: "pro",
                    windows: [
                        QuotaWindow(id: "spark-primary", kind: "Primary", usedPercent: 14, durationMinutes: 1_440, resetsAt: now.addingTimeInterval(52_000))
                    ],
                    credits: nil,
                    spendControl: nil,
                    spendControlReached: false,
                    reachedReason: nil
                )
            ],
            earnedResetCount: 2,
            activity: AccountActivity(
                lifetimeTokens: 42_800_000,
                peakDailyTokens: 2_100_000,
                longestRunningTurnSeconds: 1_804,
                currentStreakDays: 9,
                longestStreakDays: 21,
                dailyUsage: (0..<7).map { offset in
                    DailyUsage(date: Calendar.current.date(byAdding: .day, value: offset - 6, to: now)!, tokens: Int64((offset + 2) * 210_000))
                }
            ),
            fetchedAt: now
        )
        state.conversations = [
            ConversationTelemetry(
                id: "demo",
                title: "Build menu-bar telemetry",
                workspace: "CodexGauge",
                model: "gpt-5.6",
                state: .running,
                activity: .thinking,
                tokensPerMinute: 12_480,
                tokensPerFiveMinutes: 8_260,
                callsPerMinute: 1.7,
                totalTokens: 894_200,
                recentTokenMix: TokenBreakdown(input: 20_000, cachedInput: 12_000, output: 1_200, reasoningOutput: 340, total: 21_540),
                latestContextPercent: 43,
                turnStartedAt: now.addingTimeInterval(-1_240),
                lastTurnDurationSeconds: nil,
                latestOutputTokens: 840,
                timeToFirstTokenMilliseconds: 1_150,
                attentionEventAt: nil,
                agentCount: 2,
                lastActivity: now
            ),
            ConversationTelemetry(
                id: "demo-review",
                title: "Review release checks",
                workspace: "CodexGauge",
                model: "gpt-5.6",
                state: .needsApproval,
                activity: .waiting,
                tokensPerMinute: 4_920,
                tokensPerFiveMinutes: 3_870,
                callsPerMinute: 1,
                totalTokens: 220_400,
                recentTokenMix: TokenBreakdown(input: 7_000, cachedInput: 4_000, output: 980, reasoningOutput: 210, total: 8_190),
                latestContextPercent: 31,
                turnStartedAt: now.addingTimeInterval(-340),
                lastTurnDurationSeconds: nil,
                latestOutputTokens: 520,
                timeToFirstTokenMilliseconds: 880,
                attentionEventAt: now.addingTimeInterval(-12),
                agentCount: 0,
                lastActivity: now.addingTimeInterval(-12)
            )
        ]
        state.conversations += (0..<14).map { recentConversation(offset: $0, now: now) }
        state.hasLoadedConversations = true
        if arguments.contains("-uiTestLoading") {
            state.accountSnapshot = nil
            state.conversations = []
            state.hasLoadedConversations = false
            state.freshness = .loading
        } else if arguments.contains("-uiTestEmpty") {
            state.conversations = []
            state.hasLoadedConversations = true
        } else if arguments.contains("-uiTestStale") {
            state.freshness = .stale
        } else if arguments.contains("-uiTestOffline") {
            state.freshness = .stale
            state.errorMessage = "Codex could not be reached. Showing the last update."
        } else if arguments.contains("-uiTestMissingHelper") {
            state.executableURL = nil
            state.accountSnapshot = nil
            state.freshness = .unavailable
            state.errorMessage = "Codex could not be found."
        } else if arguments.contains("-uiTestSignedOut") {
            state.accountSnapshot = nil
            state.freshness = .unavailable
            state.errorMessage = "Open ChatGPT and sign in to view Codex allowances."
        }
        state.notificationAuthorization = notificationStatus
        if arguments.contains("-uiTestOversizedValues"), let original = state.conversations.first {
            state.conversations[0] = ConversationTelemetry(
                id: original.id,
                title: original.title,
                workspace: original.workspace,
                model: original.model,
                state: original.state,
                activity: original.activity,
                tokensPerMinute: .greatestFiniteMagnitude,
                tokensPerFiveMinutes: .greatestFiniteMagnitude,
                callsPerMinute: original.callsPerMinute,
                totalTokens: .max,
                recentTokenMix: TokenBreakdown(input: .max, cachedInput: .max, output: .max, reasoningOutput: .max, total: .max),
                latestContextPercent: .greatestFiniteMagnitude,
                turnStartedAt: original.turnStartedAt,
                lastTurnDurationSeconds: original.lastTurnDurationSeconds,
                latestOutputTokens: original.latestOutputTokens,
                timeToFirstTokenMilliseconds: original.timeToFirstTokenMilliseconds,
                attentionEventAt: original.attentionEventAt,
                agentCount: original.agentCount,
                lastActivity: original.lastActivity
            )
        }
        return state
    }

    private static func recentConversation(offset: Int, now: Date) -> ConversationTelemetry {
        let index = offset + 1
        return ConversationTelemetry(
            id: "recent-\(offset)",
            title: "Recent task \(index)",
            workspace: offset.isMultiple(of: 2) ? "CodexGauge" : "SampleProject",
            model: "gpt-5.6",
            state: .recent,
            activity: .waiting,
            tokensPerMinute: 0,
            tokensPerFiveMinutes: 0,
            callsPerMinute: nil,
            totalTokens: Int64(index * 42_000),
            recentTokenMix: .zero,
            latestContextPercent: nil,
            turnStartedAt: nil,
            lastTurnDurationSeconds: Double(index * 70),
            latestOutputTokens: Int64(index * 90),
            timeToFirstTokenMilliseconds: nil,
            attentionEventAt: nil,
            agentCount: 0,
            lastActivity: now.addingTimeInterval(Double(-index * 1_200))
        )
    }
}
