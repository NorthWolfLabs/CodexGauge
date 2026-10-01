import Foundation

enum CompanionFixtures {
    static func snapshots(at now: Date = .now) -> [CompanionSnapshot] {
        let account = CompanionAccount(id: "demo-account", plan: "Pro", observedAt: now,
            windows: [.init(id: "session", name: "Session", remainingPercent: 83, resetsAt: now.addingTimeInterval(9600)),
                      .init(id: "weekly", name: "Weekly", remainingPercent: 64, resetsAt: now.addingTimeInterval(280000))],
            bankedResets: 2, lifetimeTokens: 18_240_000,
            dailyTokens: (0..<90).map { index in
                let date = Calendar.current.date(byAdding: .day, value: index - 89, to: now)!
                let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
                return .init(id: String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!), tokens: Int64(85000 + (index * 37123) % 160000))
            }, credits: [.init(id: "codex", name: "Codex", hasCredits: true, unlimited: false, balance: "250")], metrics: .init(peakDailyTokens: 245000, longestTurnSeconds: 1400, currentStreakDays: 5, longestStreakDays: 12), email: "alex@example.com", accountType: "ChatGPT", historyObservedAt: now)
        return [CompanionSnapshot(id: "11111111-1111-4111-8111-111111111111", name: "MacBook Pro", observedAt: now, account: account,
            tasks: [.init(id: "task1", title: "Build the iPhone companion", project: "CodexGauge", state: .running,
                activity: "Writing a response", tokensPerMinute: 2340, totalTokens: 38200, contextPercent: 32,
                startedAt: now.addingTimeInterval(-318), agentCount: 1, observedAt: now, hasTokenObservation: true, metrics: .init(model: "gpt-6.1-sol", fiveMinuteRate: 2400, callsPerMinute: 2, input: 32000, cachedInput: 22000, output: 4400, reasoning: 1800, latestOutput: 307, firstTokenMilliseconds: 3700)),
                .init(id: "task2", title: "Review library navigation", project: "Allweave", state: .needsInput,
                activity: "Waiting for your response", tokensPerMinute: 0, totalTokens: 12100, contextPercent: 14, agentCount: 0)]),
            CompanionSnapshot(id: "22222222-2222-4222-8222-222222222222", name: "Mac mini", observedAt: now, account: account,
                tasks: [.init(id: "task3", title: "Run the integration checks", project: "CodexGauge", state: .needsApproval,
                    activity: "Approval requested", tokensPerMinute: 0, totalTokens: 18700, agentCount: 0),
                    .init(id: "task4", title: "Optimize image exports", project: "CodexGauge", state: .completed,
                    activity: "Completed", tokensPerMinute: 0, totalTokens: 6200, agentCount: 0)])]
    }
}
