import Foundation
import Testing
@testable import TokenTach

@MainActor struct CompanionPublishingTests {
    private func fixture(state: ConversationState) -> ConversationTelemetry {
        ConversationTelemetry(id: "raw-private-thread-id", title: String(repeating: "T", count: 250),
            workspace: "/private/workspace/path", model: nil, state: state, activity: .waiting,
            tokensPerMinute: 0, tokensPerFiveMinutes: 0, callsPerMinute: nil, totalTokens: 100,
            recentTokenMix: .zero, latestContextPercent: nil, turnStartedAt: nil,
            lastTurnDurationSeconds: nil, latestOutputTokens: nil, timeToFirstTokenMilliseconds: nil,
            attentionEventAt: nil, agentCount: 0, lastActivity: .now,
            projectName: String(repeating: "P", count: 250))
    }
    @Test func publishingContainsOnlyBoundedDisplayMetadataAndScopesUnknownAccountsToTheMac() throws {
        let state = DemoData.state()
        let task = fixture(state: .needsApproval)
        state.conversations = [task]
        let snapshot = state.companionSnapshot(installationID: "fixture-mac")
        #expect(snapshot.tasks.count == 1)
        #expect(snapshot.tasks[0].title.count == 200)
        #expect(snapshot.tasks[0].project?.count == 200)
        #expect(snapshot.tasks[0].state == .needsApproval)
        #expect(snapshot.account?.id == "unverified:fixture-mac")
        let encoded = String(decoding: try CompanionCoding.encoder.encode(snapshot), as: UTF8.self)
        #expect(!encoded.contains(task.id))
        #expect(!encoded.contains(task.workspace))
        #expect(state.companionSnapshot(installationID: "other-mac").tasks[0].id != snapshot.tasks[0].id)
    }

    @Test func publisherExcludesUnconfirmedIdleTasksAndRetainsExplicitCompletionForAlerts() throws {
        let state = DemoData.state()
        var task = fixture(state: .recent)
        state.conversations = [task]
        #expect(state.companionSnapshot(installationID: "fixture-mac").tasks.isEmpty)
        task.completionEventAt = .now
        state.conversations = [task]
        let snapshot = state.companionSnapshot(installationID: "fixture-mac")
        #expect(snapshot.tasks.first?.state == .completed)
        #expect(snapshot.activeTasks.isEmpty)
        #expect(snapshot.tasks.first?.eventAt == task.completionEventAt)
    }
}
