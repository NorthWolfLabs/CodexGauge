import Foundation
import Testing
@testable import CompanionCore

private struct PushBatch: Decodable { let observations: [CompanionSnapshot] }

@Test func metricsDoNotJournalButImportantTransitionsSurviveRestart() throws {
    var source = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 1000))[0]
    var journal = CompanionPushJournal()
    let journaledInitialObservation = try journal.observe(source)
    #expect(journaledInitialObservation)
    source.observedAt += 1
    source.tasks[0].tokensPerMinute += 100
    source.tasks[0].contextPercent = 25
    source.tasks[0].activity = "Reading a file"
    let journaledMetrics = try journal.observe(source)
    #expect(!journaledMetrics)
    #expect(journal.pending.count == 1)
    source.observedAt += 1
    source.tasks[0].state = .completed
    source.tasks[0].eventAt = source.observedAt
    let journaledCompletion = try journal.observe(source)
    #expect(journaledCompletion)
    let disk = try CompanionCoding.encoder.encode(journal)
    var restored = try CompanionCoding.decoder.decode(CompanionPushJournal.self, from: disk)
    let batch = try CompanionCoding.decoder.decode(PushBatch.self, from: restored.batch(latest: source))
    #expect(batch.observations.count == 2)
    #expect(batch.observations[1].tasks[0].state == .completed)
    let acknowledgedInitialObservation = restored.acknowledge(through: batch.observations[0].observedAt)
    #expect(acknowledgedInitialObservation)
    #expect(restored.pending.count == 1)
    let journaledReplay = try restored.observe(source)
    #expect(!journaledReplay)
    let acknowledgedCompletion = restored.acknowledge(through: source.observedAt)
    #expect(acknowledgedCompletion)
    #expect(restored.pending.isEmpty)
}

@Test func pushBacklogCannotSkipImportantTransitionsToSendLatestMetrics() throws {
    var source = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 1000))[0]
    var journal = CompanionPushJournal()
    for i in 0..<20 {
        source.observedAt = Date(timeIntervalSince1970: 1000 + Double(i))
        source.tasks[0].state = i.isMultiple(of: 2) ? .running : .needsInput
        source.tasks[0].eventAt = source.observedAt
        let journaledTransition = try journal.observe(source)
        #expect(journaledTransition)
    }
    source.observedAt += 1
    let first = try CompanionCoding.decoder.decode(PushBatch.self, from: journal.batch(latest: source))
    #expect(first.observations.count == 15)
    #expect(first.observations.last?.observedAt == Date(timeIntervalSince1970: 1014))
    let acknowledgedBatch = journal.acknowledge(through: first.observations.last!.observedAt)
    #expect(acknowledgedBatch)
    let next = try CompanionCoding.decoder.decode(PushBatch.self, from: journal.batch(latest: source))
    #expect(next.observations.count == 6)
    #expect(next.observations.first?.observedAt == Date(timeIntervalSince1970: 1015))
    #expect(next.observations.last?.observedAt == source.observedAt)
    #expect(next.observations.allSatisfy { $0.account?.dailyTokens.isEmpty != false })
}

@Test func expiredJournalNeverSendsOutOfWindowHistory() throws {
    var source = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 1000))[0]
    var journal = CompanionPushJournal()
    let journaledInitialObservation = try journal.observe(source)
    #expect(journaledInitialObservation)
    source.observedAt += 3600
    let batch = try CompanionCoding.decoder.decode(PushBatch.self, from: journal.batch(latest: source))
    #expect(batch.observations.count == 1)
    #expect(batch.observations[0].observedAt == source.observedAt)
}
