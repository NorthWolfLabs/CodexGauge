import Foundation
import Testing
@testable import CompanionCore

@Test func sharedAllowanceIsAnObservationNotASum() {
    var snapshots = CompanionFixtures.snapshots()
    snapshots[1].account?.observedAt = .now.addingTimeInterval(10)
    snapshots[1].account?.windows[0].remainingPercent = 72
    let accounts = CompanionMerge.accounts(snapshots)
    #expect(accounts.count == 1)
    #expect(accounts[0].windows[0].remainingPercent == 72)
}
@Test func differentAccountsRemainSeparate() {
    var snapshots = CompanionFixtures.snapshots()
    snapshots[1].account?.id = "another-account"
    #expect(CompanionMerge.accounts(snapshots).count == 2)
}
@Test func followUpReadyTasksAreNotActive() {
    let tasks = CompanionFixtures.snapshots().flatMap(\.activeTasks)
    #expect(tasks.count == 3)
    #expect(!tasks.contains { $0.state == .completed })
    #expect(tasks.contains { $0.state == .needsApproval })
    #expect(tasks.contains { $0.state == .needsInput })
}
@Test func linksRoundTripAndRejectUntrustedShapes() throws {
    let link = CompanionLink(id: UUID().uuidString, server: URL(string: "https://relay.example.com")!,
                             token: String(repeating: "a", count: 64), name: "Mac")
    #expect(try CompanionLink(url: link.shareURL).token == link.token)
    #expect(link.shareURL.query?.contains(link.token) == false)
    #expect(throws: (any Error).self) { try CompanionLink(url: URL(string: "codexgauge://publish")!) }
    #expect(!CompanionLink.validServer(URL(string: "https://secret@example.com")!))
}
@Test func wireDatesUseUnixSecondsAndSnapshotsExpire() throws {
    let snapshot = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 1000))[0]
    let data = try CompanionCoding.encoder.encode(snapshot)
    #expect(String(decoding: data, as: UTF8.self).contains("\"observedAt\":1000"))
    #expect(try CompanionCoding.decoder.decode(CompanionSnapshot.self, from: data) == snapshot)
    #expect(snapshot.isStale(at: Date(timeIntervalSince1970: 1100)))
}

@Test func attentionTasksSortAheadOfRunningWithoutTokenDrivenReordering() {
    var snapshot = CompanionFixtures.snapshots()[0]
    #expect(snapshot.activeTasks.map(\.id) == ["task2", "task1"])
    snapshot.tasks[0].tokensPerMinute = 9000
    snapshot.tasks.reverse()
    #expect(snapshot.activeTasks.map(\.id) == ["task2", "task1"])
}

private func viewingLink(_ snapshot: CompanionSnapshot, token: String = "a") -> CompanionLink {
    CompanionLink(id: snapshot.id, server: URL(string: "https://relay.example.com")!,
                  token: String(repeating: token, count: 64), name: snapshot.name)
}

@Test func widgetRefreshCannotRollBackFresherAppData() {
    let current = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 2000))[0]
    let older = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 1000))[0]
    let link = viewingLink(current)
    let result = CompanionMerge.refreshedSnapshots([current],
        updates: [.init(link: link, result: .snapshot(older))], currentLinks: [link])
    #expect(result == [current])
}

@Test func widgetRefreshDropsRemovedAndReplacedCapabilities() {
    let snapshot = CompanionFixtures.snapshots()[0]
    let oldLink = viewingLink(snapshot)
    let newLink = viewingLink(snapshot, token: "b")
    let update = CompanionFetchUpdate(link: oldLink, result: .snapshot(snapshot))
    #expect(CompanionMerge.refreshedSnapshots([], updates: [update], currentLinks: [newLink]).isEmpty)
    #expect(CompanionMerge.refreshedSnapshots([snapshot], updates: [update], currentLinks: []).isEmpty)
}

@Test func widgetRefreshClearsRevokedDataButKeepsDatedOfflineObservations() {
    let snapshots = CompanionFixtures.snapshots()
    let links = snapshots.map { viewingLink($0) }
    let updates = [CompanionFetchUpdate(link: links[0], result: .cleared),
                   CompanionFetchUpdate(link: links[1], result: .unavailable)]
    #expect(CompanionMerge.refreshedSnapshots(snapshots, updates: updates, currentLinks: links) == [snapshots[1]])
}

@Test func oneFailedMacDoesNotBlockRemainingPushRegistrations() async {
    let links = CompanionFixtures.snapshots().map { viewingLink($0) }
    var attempted: [String] = []
    let failures = await CompanionRegistrationSync.failures(links: links) { link in
        attempted.append(link.id)
        if link == links[0] { throw CompanionError.rejected }
    }
    #expect(failures == 1)
    #expect(attempted == links.map(\.id))
}

@Test func oversizedUnicodeSnapshotFitsWithoutLosingAllowancesOrActiveTasks() throws {
    var snapshot = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 2000))[0]
    var task = snapshot.tasks[0]
    task.title = String(repeating: "🧑🏽‍💻", count: 200)
    task.project = String(repeating: "🧑🏽‍💻", count: 200)
    snapshot.tasks = (0..<199).map { index in
        var completed = task
        completed.id = "completed-\(index)"; completed.state = .completed
        return completed
    } + [task]
    #expect(try CompanionCoding.encoder.encode(snapshot).count > 128 * 1024)
    let data = try snapshot.encodedForTransport()
    let decoded = try CompanionCoding.decoder.decode(CompanionSnapshot.self, from: data)
    #expect(data.count < 128 * 1024)
    #expect(decoded.account == snapshot.account)
    #expect(decoded.tasks.first?.id == task.id)
    #expect(decoded.tasks.count > 1)
    #expect(decoded.tasks.count < snapshot.tasks.count)
    #expect(throws: (any Error).self) { try snapshot.encodedForTransport(maxBytes: 1) }
}

@Test func ordinarySnapshotsKeepAllTaskEventsOnTheWire() throws {
    let snapshot = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 2000))[1]
    let decoded = try CompanionCoding.decoder.decode(CompanionSnapshot.self, from: snapshot.encodedForTransport())
    #expect(decoded == snapshot)
}

@Test func widgetTimelineMarksStalenessAndResetWithoutNetworkRefresh() {
    let now = Date(timeIntervalSince1970: 2000)
    let stale = now.addingTimeInterval(180), reset = now.addingTimeInterval(900)
    #expect(CompanionWidgetTimeline.dates(now: now, observedAt: now, resetsAt: reset) == [now, stale, reset])
    #expect(CompanionWidgetTimeline.dates(now: now, observedAt: now.addingTimeInterval(-200), resetsAt: now.addingTimeInterval(-1)) == [now])
    #expect(CompanionWidgetTimeline.dates(now: now, observedAt: now, resetsAt: stale) == [now, stale])
    let account = CompanionFixtures.snapshots(at: now)[0].account!
    #expect(!account.isStale(at: stale.addingTimeInterval(-1)))
    #expect(account.isStale(at: stale))
}

@Test func wireTextLimitsMatchJavaScriptWithoutSplittingEmoji() throws {
    let emoji = "🧑🏽‍💻"
    let text = CompanionText.prefix(String(repeating: emoji, count: 200))
    #expect(text.utf16.count <= 200)
    #expect(text.allSatisfy { String($0) == emoji })
    #expect(text == String(repeating: emoji, count: 200 / emoji.utf16.count))
    #expect(CompanionText.prefix("hello", utf16Limit: 3) == "hel")
    #expect(CompanionText.prefix(emoji, utf16Limit: 1).isEmpty)
    let combining = "a" + String(repeating: "\u{0301}", count: 250)
    #expect(CompanionText.prefix(combining).isEmpty)

    // The check script validates these actual Swift-encoded snapshots with Zod.
    if let path = ProcessInfo.processInfo.environment["COMPANION_WIRE_FIXTURE_PATH"] {
        var snapshots = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 2000))
        snapshots[0].name = CompanionText.prefix(String(repeating: emoji, count: 80), utf16Limit: 80)
        snapshots[0].tasks[0].title = text
        snapshots[0].tasks[0].project = CompanionText.prefix(String(repeating: "日本語", count: 200))
        snapshots[1].tasks[0].title = CompanionText.prefix(String(repeating: "\"\\\n", count: 200))
        try CompanionCoding.encoder.encode(snapshots).write(to: URL(fileURLWithPath: path))
    }
}

@Test func notificationRoutesOnlyOpenKnownMacsAndBoundedTaskIDs() throws {
    let id = UUID().uuidString
    let route = try #require(CompanionNotificationRoute(userInfo: ["macID": id, "taskID": "task-1"]))
    #expect(route.macID == id.lowercased())
    #expect(route.taskID == "task-1")
    let link = CompanionLink(id: id, server: URL(string: "https://relay.example.com")!, token: String(repeating: "a", count: 64), name: "Mac")
    #expect(route.isLinked(in: [link]))
    #expect(!route.isLinked(in: []))
    #expect(CompanionNotificationRoute(userInfo: ["macID": id])?.taskID == nil)
    #expect(CompanionNotificationRoute(userInfo: ["macID": "invalid"]) == nil)
    #expect(CompanionNotificationRoute(userInfo: ["macID": id, "taskID": ""]) == nil)
    #expect(CompanionNotificationRoute(userInfo: ["macID": id, "taskID": 7]) == nil)
    #expect(CompanionNotificationRoute(userInfo: ["macID": id, "taskID": String(repeating: "🙂", count: 101)]) == nil)
}

@Test func creditsRemainExactAndOptionalAcrossOldSnapshots() throws {
    let credit = CompanionCredit(id: "codex", name: "Codex", hasCredits: true, unlimited: false, balance: "123.456789")
    #expect(credit.displayBalance == "123.456789")
    var changed = credit; changed.unlimited = true
    #expect(changed.displayBalance == "Unlimited")
    changed.unlimited = false; changed.balance = nil; changed.hasCredits = false
    #expect(changed.displayBalance == "0")
    changed.hasCredits = true
    #expect(changed.displayBalance == "Available")
    var account = CompanionFixtures.snapshots()[0].account!
    account.credits = nil
    let data = try CompanionCoding.encoder.encode(account)
    #expect(!String(decoding: data, as: UTF8.self).contains("credits"))
    #expect(try CompanionCoding.decoder.decode(CompanionAccount.self, from: data).credits == nil)
}

@Test func activityChartsUseCalendarDaysAndDoNotDoubleCountMacObservations() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!
    let source: [CompanionDay] = [.init(id: "2026-09-30", tokens: 20), .init(id: "2026-09-28", tokens: 10),
        .init(id: "2026-09-30", tokens: 20), .init(id: "2026-02-31", tokens: 100), .init(id: "invalid", tokens: 50)]
    let days = CompanionChartData.days(source, count: 3, endingAt: now, calendar: calendar)
    #expect(days.map(\.tokens) == [10, 20])
    #expect(CompanionChartData.days(source + [.init(id: "2026-09-29", tokens: 0)], count: 3, endingAt: now, calendar: calendar).map(\.tokens) == [10, 0, 20])
    #expect(CompanionChartData.total(days) == 30)
    let afternoon = days[1].date.addingTimeInterval(13 * 3600)
    #expect(CompanionChartData.selectedDay(in: days, at: afternoon, calendar: calendar) == days[1])
    #expect(CompanionChartData.selectedDay(in: days, at: days[0].date.addingTimeInterval(-1), calendar: calendar) == nil)
    #expect(CompanionChartData.days([], count: 30, endingAt: now).isEmpty)
    #expect(CompanionChartData.days(source, count: 10000, endingAt: now).isEmpty)
}

@Test func liveTaskChartsRejectReplayAndBreakLinesAcrossDisconnects() {
    let now = Date(timeIntervalSince1970: 2000)
    var snapshot = CompanionFixtures.snapshots(at: now)[0]
    var history = CompanionTaskHistory()
    history.record(snapshot, now: now)
    snapshot.observedAt = now.addingTimeInterval(2)
    history.record(snapshot, now: snapshot.observedAt)
    snapshot.observedAt = now.addingTimeInterval(30)
    snapshot.tasks[0].state = .needsInput
    history.record(snapshot, now: snapshot.observedAt)
    let samples = history.samples(mac: snapshot.id, task: snapshot.tasks[0].id)
    #expect(samples.count == 3)
    #expect(samples[0].segment == samples[1].segment)
    #expect(samples[1].segment != samples[2].segment)
    #expect(samples[2].rate == 0)
    snapshot.observedAt = now
    history.record(snapshot, now: now.addingTimeInterval(300))
    #expect(history.samples(mac: snapshot.id, task: snapshot.tasks[0].id) == samples)
    history.remove(mac: snapshot.id)
    #expect(history.samples(mac: snapshot.id, task: snapshot.tasks[0].id).isEmpty)
}

@Test func liveActivitySummariesPrioritizeAttentionAndExcludeFollowUpReadyTasks() throws {
    var snapshots = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 2000))
    let state = CompanionLiveState.from(snapshots[0])
    #expect(state.running == 1 && state.attention == 1)
    #expect(state.state == "needsInput")
    #expect(state.taskID == "task2")
    var changed = state
    changed.tokensPerMinute += 100; changed.updatedAt += 1
    #expect(state.hasSameTaskSummary(as: changed))
    changed.running += 1
    #expect(!state.hasSameTaskSummary(as: changed))
    changed = state; changed.taskID = "another-waiting-task"
    #expect(!state.hasSameTaskSummary(as: changed))
    #expect(CompanionLiveState.from(snapshots[1]).running == 0)
    #expect(CompanionLiveState.from(snapshots[1]).attention == 1)
    snapshots[0].tasks = []
    let empty = CompanionLiveState.from(snapshots[0])
    #expect(!empty.hasActiveTasks)
    #expect(empty.state == "idle")
    #expect(empty.title == "No active tasks")
    let info = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
    #expect(info["updatedAt"] as? Double == 2000)
    if let path = ProcessInfo.processInfo.environment["COMPANION_WIRE_FIXTURE_PATH"] {
        let fixtures = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 2000))
        struct Fixture: Encodable { var snapshot: CompanionSnapshot; var state: CompanionLiveState }
        try CompanionCoding.encoder.encode(fixtures.map { Fixture(snapshot: $0, state: CompanionLiveState.from($0)) }).write(to: URL(fileURLWithPath: path + ".live"))
    }
}

@Test func liveActivitySelectionStaysStableAndFreshCountsDoNotRenewTaskEvidence() {
    let now = Date(timeIntervalSince1970: 2000)
    var snapshot = CompanionFixtures.snapshots(at: now)[0]
    var selected = snapshot.tasks[0]
    selected.startedAt = now.addingTimeInterval(-600)
    selected.observedAt = now.addingTimeInterval(-300)
    snapshot.tasks = [selected]
    #expect(CompanionLiveState.from(snapshot).taskID == selected.id)
    var newer = selected; newer.id = "newer"; newer.title = "New task"; newer.startedAt = now; newer.observedAt = now
    snapshot.tasks.append(newer)
    var state = CompanionLiveState.from(snapshot, previousTaskID: selected.id)
    #expect(state.taskID == selected.id)
    #expect(state.running == 2)
    #expect(state.updatedAt == 2000)
    #expect(state.taskObservedAt == 1700)
    snapshot.tasks[1].state = .needsApproval
    state = CompanionLiveState.from(snapshot, previousTaskID: selected.id)
    #expect(state.taskID == newer.id)
    #expect(state.attention == 1)
    snapshot.tasks[1].state = .completed
    #expect(CompanionLiveState.from(snapshot, previousTaskID: newer.id).taskID == selected.id)
}

@Test func missingTokenObservationAndOldTaskEvidenceDoNotBecomeChartZeros() {
    let now = Date(timeIntervalSince1970: 2000)
    var snapshot = CompanionFixtures.snapshots(at: now)[0]
    snapshot.tasks = [snapshot.tasks[0]]
    snapshot.tasks[0].hasTokenObservation = false
    var history = CompanionTaskHistory()
    history.record(snapshot, now: now)
    #expect(history.samples(mac: snapshot.id, task: snapshot.tasks[0].id).isEmpty)
    snapshot.tasks[0].hasTokenObservation = true
    snapshot.tasks[0].observedAt = now.addingTimeInterval(-100)
    history.record(snapshot, now: now)
    #expect(history.samples(mac: snapshot.id, task: snapshot.tasks[0].id).isEmpty)
    snapshot.tasks[0].observedAt = now
    snapshot.tasks[0].tokensPerMinute = 0
    history.record(snapshot, now: now)
    #expect(history.samples(mac: snapshot.id, task: snapshot.tasks[0].id).first?.rate == 0)
}

@Test func legacyRatesRequirePositiveEvidenceAndExplicitFlagsTakePrecedence() {
    var task = CompanionFixtures.snapshots()[0].tasks[0]
    task.hasTokenObservation = nil
    task.tokensPerMinute = 0
    #expect(!task.hasRate)
    task.tokensPerMinute = 10
    #expect(task.hasRate)
    task.hasTokenObservation = false
    #expect(!task.hasRate)
    task.hasTokenObservation = true
    task.tokensPerMinute = 0
    #expect(task.hasRate)
}

@Test func accountHistoryMergesActualObservationOrderBeforeIndependentAccountTotals() {
    let now = Date.now
    var latest = CompanionFixtures.snapshots(at: now)[0]
    latest.account?.dailyTokens = [.init(id: "2026-09-30", tokens: 5)]
    var old = latest; old.id = "old"; old.account?.observedAt = now.addingTimeInterval(-20); old.account?.historyObservedAt = now.addingTimeInterval(-20)
    old.account?.dailyTokens = [.init(id: "2026-09-28", tokens: 10)]
    var middle = latest; middle.id = "middle"; middle.account?.observedAt = now.addingTimeInterval(-10); middle.account?.historyObservedAt = now.addingTimeInterval(-10)
    middle.account?.dailyTokens = [.init(id: "2026-09-28", tokens: 15)]
    let merged = CompanionMerge.accounts([latest, old, middle])
    #expect(merged[0].dailyTokens.map(\.tokens) == [15, 5])
    #expect(CompanionMerge.accounts([middle, latest, old]) == merged)
    var other = latest; other.account?.id = "another-account"
    other.account?.email = "sam@example.com"; other.account?.dailyTokens = [.init(id: "2026-09-30", tokens: 8)]
    let accounts = CompanionMerge.accounts([old, middle, latest, other])
    #expect(accounts.count == 2)
    #expect(CompanionMerge.combinedActivity(accounts)?.dailyTokens.map(\.tokens) == [15, 13])
    #expect(CompanionMerge.combinedActivity(accounts)?.lifetimeTokens == 36_480_000)
    other.account?.lifetimeTokens = nil
    #expect(CompanionMerge.combinedActivity(CompanionMerge.accounts([latest, other]))?.lifetimeTokens == nil)
}

@Test func allHistoryAndCalendarYearRespectLeapYearsStaleTodayAndInvalidDates() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let now = calendar.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 12))!
    #expect(CompanionActivityRange.year.dayCount(at: now, calendar: calendar) == 366)
    #expect(CompanionActivityRange.all.dayCount(at: now, calendar: calendar) == nil)
    let source: [CompanionDay] = [.init(id: "2022-01-01", tokens: 10), .init(id: "2024-03-09", tokens: 0),
        .init(id: "2024-03-11", tokens: 30), .init(id: "2024-02-31", tokens: 999)]
    #expect(CompanionChartData.days(source, count: nil, endingAt: now, calendar: calendar).map(\.tokens) == [10, 0])
    #expect(CompanionChartData.days(source, count: 1, endingAt: now, calendar: calendar).isEmpty)
    #expect(CompanionActivityRange.allCases.map(\.title) == ["Today", "7 days", "30 days", "90 days", "1 year", "All"])
}

@Test func identityAndHistoryFieldsRemainOptionalForLegacyWireData() throws {
    var account = CompanionFixtures.snapshots()[0].account!
    account.email = nil; account.accountType = nil; account.historyObservedAt = nil; account.historyTruncated = nil
    let data = try CompanionCoding.encoder.encode(account)
    let decoded = try CompanionCoding.decoder.decode(CompanionAccount.self, from: data)
    #expect(decoded.email == nil)
    #expect(decoded.displayName == "Account identity unavailable")
}

@Test func staleTaskElapsedUsesActualSnapshotAndRejectsImpossibleObservation() {
    let start = Date(timeIntervalSince1970: 1000)
    #expect(CompanionTaskTiming.observedElapsed(start: start, task: nil, snapshot: start.addingTimeInterval(318)) == 318)
    #expect(CompanionTaskTiming.observedElapsed(start: start, task: start.addingTimeInterval(-1), snapshot: start.addingTimeInterval(10)) == nil)
    #expect(CompanionTaskTiming.observedElapsed(start: start, task: nil, snapshot: nil) == nil)
}

@Test func unknownAccountsNeverBecomeProvenCombinedTotals() {
    var first = CompanionFixtures.snapshots()[0]
    first.account?.id = "unverified:first-mac"; first.account?.lifetimeTokens = 100
    first.account?.dailyTokens = [.init(id: "2026-09-30", tokens: 100)]
    var second = first; second.id = "second-mac"; second.account?.id = "unverified:second-mac"
    let unknown = CompanionMerge.accounts([first, second])
    #expect(unknown.count == 2)
    #expect(CompanionMerge.combinedActivity(unknown)?.lifetimeTokens == nil)
    #expect(CompanionMerge.combinedActivity(unknown)?.dailyTokens.isEmpty == true)
    var verified = first; verified.id = "verified-mac"; verified.account?.id = "verified-account"
    let mixed = CompanionMerge.accounts([first, second, verified])
    #expect(CompanionMerge.combinedActivity(mixed)?.lifetimeTokens == 100)
    #expect(CompanionMerge.combinedActivity(mixed)?.dailyTokens.map(\.tokens) == [100])
}

@Test func freshLimitsWithoutHistoryNeverFreshenOlderHistoryFromAnotherMac() {
    let now = Date.now
    var old = CompanionFixtures.snapshots(at: now.addingTimeInterval(-4000))[0]
    old.account?.historyObservedAt = now.addingTimeInterval(-4000)
    old.account?.historyTruncated = true
    var fresh = old; fresh.id = "fresh-mac"; fresh.account?.observedAt = now
    fresh.account?.dailyTokens = []; fresh.account?.lifetimeTokens = nil
    fresh.account?.metrics = .init(peakDailyTokens: nil, longestTurnSeconds: nil, currentStreakDays: nil, longestStreakDays: nil)
    fresh.account?.historyObservedAt = nil; fresh.account?.historyTruncated = false
    let merged = CompanionMerge.accounts([old, fresh])[0]
    #expect(merged.observedAt == now)
    #expect(merged.historyObservedAt == old.account?.historyObservedAt)
    #expect(merged.lifetimeTokens == old.account?.lifetimeTokens)
    #expect(merged.metrics == old.account?.metrics)
    #expect(merged.dailyTokens == old.account?.dailyTokens)
    #expect(merged.historyTruncated == true)
}
