import Foundation
import Testing
@testable import CompanionCore

@Test func adaptivePublishingSendsTransitionsButLimitsMetricsToAMinute() throws {
    let start = Date(timeIntervalSince1970: 1000)
    var snapshot = CompanionFixtures.snapshots(at: start)[0]
    var policy = CompanionPublishPolicy(demand: .init(viewers: 0, push: true, paired: true))
    policy.pushed(snapshot, at: start)
    snapshot.tasks[0].tokensPerMinute += 100
    snapshot.tasks[0].contextPercent = 33
    #expect(try !policy.shouldPush(snapshot, pending: false, force: false, now: start + 59))
    #expect(try policy.shouldPush(snapshot, pending: false, force: false, now: start + 60))
    snapshot.tasks[0].activity = "Using a tool"
    #expect(try !policy.shouldPush(snapshot, pending: false, force: false, now: start + 4))
    #expect(try policy.shouldPush(snapshot, pending: false, force: false, now: start + 5))
    snapshot.tasks[0].state = .completed
    #expect(try policy.shouldPush(snapshot, pending: false, force: false, now: start + 1))
    #expect(try policy.shouldPush(snapshot, pending: true, force: false, now: start + 1))
}

@Test func noConsumersSuppressAllRoutinePublishingAndRefreshBypassesIt() throws {
    let start = Date(timeIntervalSince1970: 1000)
    let snapshot = CompanionFixtures.snapshots(at: start)[0]
    var policy = CompanionPublishPolicy(demand: .init(viewers: 0, push: false, paired: false))
    for seconds in [0.0, 60, 300, 86400] {
        #expect(try !policy.shouldPush(snapshot, pending: true, force: true, now: start + seconds))
        #expect(try !policy.shouldStream(snapshot, refresh: false, now: start + seconds))
    }
    #expect(try policy.shouldStream(snapshot, refresh: true, now: start))
    policy.demand = .init(viewers: 1, push: false, paired: true)
    #expect(try policy.shouldStream(snapshot, refresh: false, now: start))
    policy.streamed(snapshot, at: start)
    policy.demand?.viewers = 0
    #expect(try !policy.shouldStream(snapshot, refresh: false, now: start + 299))
    #expect(try policy.shouldStream(snapshot, refresh: false, now: start + 300))
    policy.demand?.push = true
    #expect(try policy.shouldPush(snapshot, pending: false, force: true, now: start))
}

@Test func quietActiveCardGetsFreshnessButIdleDoesNotPoll() throws {
    let start = Date(timeIntervalSince1970: 1000)
    var snapshot = CompanionFixtures.snapshots(at: start)[0]
    var policy = CompanionPublishPolicy(demand: .init(viewers: 0, push: true, paired: true))
    policy.pushed(snapshot, at: start)
    snapshot.observedAt = start + 119; snapshot.account?.observedAt = start + 119
    for index in snapshot.tasks.indices { snapshot.tasks[index].observedAt = start + 119 }
    #expect(try !policy.shouldPush(snapshot, pending: false, force: false, now: start + 119))
    #expect(try policy.shouldPush(snapshot, pending: false, force: false, now: start + 120))
    snapshot.tasks = []
    policy.pushed(snapshot, at: start)
    #expect(try !policy.shouldPush(snapshot, pending: false, force: false, now: start + 86400))
}

@Test func receiverDeadlineRefreshesDeferredPhasesAndMetricsWithoutPolling() throws {
    let start = Date(timeIntervalSince1970: 1000)
    let snapshot = CompanionFixtures.snapshots(at: start)[0]
    var policy = CompanionPublishPolicy(demand: .init(viewers: 0, push: true, paired: true))
    policy.pushed(snapshot, at: start, refreshAfter: 20)
    #expect(try !policy.shouldPush(snapshot, pending: false, force: false, now: start + 19))
    #expect(try policy.shouldPush(snapshot, pending: false, force: false, now: start + 20))
    policy.pushed(snapshot, at: start + 20, refreshAfter: 120)
    #expect(try !policy.shouldPush(snapshot, pending: false, force: false, now: start + 139))
    #expect(try policy.shouldPush(snapshot, pending: false, force: false, now: start + 140))
}

@Test func eightHoursOfChangingMetricsNeedsOnlyMinuteBatchesAndSparseCheckpoints() throws {
    let start = Date(timeIntervalSince1970: 1000)
    var snapshot = CompanionFixtures.snapshots(at: start)[0]
    var policy = CompanionPublishPolicy(demand: .init(viewers: 0, push: true, paired: true))
    policy.pushed(snapshot, at: start); policy.streamed(snapshot, at: start)
    var pushes = 0, streams = 0
    for second in 1...28_800 {
        let now = start + Double(second)
        snapshot.observedAt = now; snapshot.tasks[0].tokensPerMinute = Double(second)
        if try policy.shouldPush(snapshot, pending: false, force: false, now: now) {
            pushes += 1; policy.pushed(snapshot, at: now)
        }
        if try policy.shouldStream(snapshot, refresh: false, now: now) {
            streams += 1; policy.streamed(snapshot, at: now)
        }
    }
    #expect(pushes == 480)
    #expect(streams == 96)
}
