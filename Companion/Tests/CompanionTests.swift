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
    #expect(credit.displayBalance == "123.4568")
    #expect(try CompanionCoding.decoder.decode(CompanionCredit.self,
        from: CompanionCoding.encoder.encode(credit)).balance == "123.456789")
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

@Test(arguments: [
    ("62500.0000000000", "62500"), ("0.0000000000", "0"),
    ("123.456789", "123.4568"), ("1.2300000000", "1.23"),
    ("1.23445", "1.2345"), ("9.99999", "10"),
    ("0.00001", "0"), ("0.00005", "0.0001"),
    ("-0.00001", "0"), ("-1.23445", "-1.2345"),
    ("9007199254740993.12345", "9007199254740993.1235"),
    ("2.5e2", "250"), (" 12.34000 ", "12.34"),
    ("Unavailable", "Unavailable"), ("12 credits", "12 credits")
])
func creditDisplayRoundsAndTrims(_ input: String, _ expected: String) {
    #expect(CompanionCreditFormatting.balance(input) == expected)
    #expect(CompanionCredit(id: "codex", name: "Codex", hasCredits: true,
        unlimited: false, balance: input).displayBalance == expected)
}

@Test func longActivityRangesUseLines() {
    for range in [CompanionActivityRange.quarter, .year, .all] { #expect(range.usesLineChart) }
    for range in [CompanionActivityRange.today, .week, .month] { #expect(!range.usesLineChart) }
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
    #expect(!state.hasSameTaskSummary(as: changed))
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

@Test func liveActivityDisplayKeepsSingleStatusAndShowsOnlyUsefulRates() {
    var state = CompanionLiveState(taskID: "task", title: "Long task title", state: "running",
        running: 1, attention: 0, tokensPerMinute: 1200, updatedAt: 2000, hasRate: true)
    #expect(state.taskCountSummary == nil)
    #expect(state.displayedRate(stale: false) == 1200)
    #expect(state.displayedRate(stale: true) == nil)
    for rate in [0.0, -1, Double.infinity, Double.nan] {
        state.tokensPerMinute = rate
        #expect(state.displayedRate(stale: false) == nil)
    }
    state.tokensPerMinute = 1200; state.hasRate = nil
    #expect(state.displayedRate(stale: false) == nil)
    state.hasRate = false
    #expect(state.displayedRate(stale: false) == nil)
    state.hasRate = true; state.state = "needsInput"; state.running = 0; state.attention = 1
    #expect(state.displayedRate(stale: false) == nil)
    #expect(state.taskCountSummary == nil)
    state.running = 12; state.attention = 3
    #expect(state.taskCountSummary == "12 other running tasks · 2 other tasks waiting")
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

@Test func activityScopesKeepDeviceAndAccountProvenanceWithoutDoubleCounting() {
    var snapshots = CompanionFixtures.snapshots()
    let choices = CompanionActivityScope.choices(snapshots)
    #expect(choices.count == 2)
    #expect(Set(choices.map(\.id)).count == 2)
    #expect(choices[0].account(in: snapshots)?.lifetimeTokens == 18_240_000)
    let formerSecondDevice = choices.first { $0.deviceID == snapshots[1].id }!
    let all = CompanionActivityScope(accountID: CompanionMerge.allAccountsID, deviceID: nil)
    #expect(all.account(in: snapshots)?.lifetimeTokens == 18_240_000)
    snapshots[1].account?.id = "second-account"
    let sharedEmail = snapshots[0].account?.email
    snapshots[1].account?.email = sharedEmail
    snapshots[1].account?.lifetimeTokens = 1_000
    #expect(CompanionActivityScope.choices(snapshots).count == 2)
    #expect(all.account(in: snapshots)?.lifetimeTokens == 18_241_000)
    #expect(formerSecondDevice.account(in: snapshots) == nil, "Changing account cannot silently reuse an old device selection")
}

@Test func activitySelectionSurvivesRenameAndDisconnectAndRecoversAfterRemoval() {
    var snapshots = CompanionFixtures.snapshots()
    let choices = CompanionActivityScope.choices(snapshots)
    let selected = choices.first { $0.deviceID == snapshots[1].id }!
    snapshots[1].name = "Renamed device"
    snapshots[1].account?.email = "renamed@example.com"
    snapshots[1].observedAt = .distantPast
    #expect(CompanionActivityScope.resolve(selected, in: CompanionActivityScope.choices(snapshots)) == selected)
    #expect(selected.account(in: snapshots)?.id == "demo-account")
    snapshots.removeLast()
    let remaining = CompanionActivityScope.resolve(selected, in: CompanionActivityScope.choices(snapshots))
    #expect(remaining?.deviceID == snapshots[0].id)
    #expect(remaining?.accountID == selected.accountID)
    #expect(CompanionActivityScope.resolve(selected, in: []) == nil)
}

@Test func activityScopeHandlesOneDeviceMissingHistoryAndRevokedIdentity() {
    var snapshots = Array(CompanionFixtures.snapshots().prefix(1))
    snapshots[0].account?.dailyTokens = []
    let choices = CompanionActivityScope.choices(snapshots)
    #expect(choices.count == 1)
    let scope = CompanionActivityScope.resolve(nil, in: choices)!
    #expect(scope.account(in: snapshots)?.dailyTokens.isEmpty == true)
    snapshots[0].account = nil
    #expect(CompanionActivityScope.choices(snapshots).isEmpty)
    #expect(scope.account(in: snapshots) == nil)
}

@Test func activityChoicesDisambiguateAccountsSharingAnEmailAndDeviceName() {
    var snapshots = CompanionFixtures.snapshots()
    snapshots[1].account?.id = "second-account"
    let repeatedName = snapshots[0].name
    snapshots[1].name = repeatedName
    let choices = CompanionActivityScope.choices(snapshots)
    #expect(choices[0].label(in: snapshots) != choices[1].label(in: snapshots))
    #expect(choices.allSatisfy { $0.label(in: snapshots).contains("account ") && $0.label(in: snapshots).contains("device ") })
}

@Test func missingPhaseKeepsRunningTaskWorking() {
    var task = CompanionFixtures.snapshots()[0].tasks[0]
    task.state = .running; task.activity = "Activity unavailable"
    #expect(task.displayActivity == "Working")
    task.activity = "Thinking"; #expect(task.displayActivity == "Thinking")
    task.state = .completed; task.activity = "Activity unavailable"
    #expect(task.displayActivity == "Activity unavailable")
}

@Test func legacyLinksDecodeWithoutDeviceRegistration() throws {
    let data = Data(#"{"id":"11111111-2222-4333-8444-555555555555","server":"https://example.invalid","token":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"Mac"}"#.utf8)
    let link = try CompanionCoding.decoder.decode(CompanionLink.self, from: data)
    #expect(link.deviceID == nil)
    var paired = link; paired.deviceID = "22222222-2222-4333-8444-555555555555"
    #expect(try CompanionCoding.decoder.decode(CompanionLink.self, from: CompanionCoding.encoder.encode(paired)) == paired)
}

@Test func liveFreshnessUsesMacHeartbeatAndMetricsFollowSelectedTask() {
    let now = Date(timeIntervalSince1970: 2000)
    var snapshot = CompanionFixtures.snapshots(at: now)[0]
    var primary = snapshot.tasks[0]; primary.state = .running; primary.tokensPerMinute = 1250
    primary.observedAt = now.addingTimeInterval(-600); primary.project = "Project"
    var other = primary; other.id = "other"; other.tokensPerMinute = 9000
    snapshot.tasks = [primary, other]
    let state = CompanionLiveState.from(snapshot, previousTaskID: primary.id)
    #expect(state.tokensPerMinute == 1250)
    #expect(state.project == "Project")
    #expect(state.account == snapshot.account?.email)
    #expect(state.staleAt == now.addingTimeInterval(180))
    #expect(state.taskCountSummary == "1 other running task")
    #expect(state.activityTitle == primary.activity)
}

@Test @MainActor func liveRegistrationRetriesTransientFailuresWithoutReopening() async throws {
    var attempts = 0
    var sleeps: [Duration] = []
    try await CompanionRegistrationSync.retryLiveRegistration(sleep: { sleeps.append($0) }) {
        attempts += 1
        if attempts < 3 { throw URLError(.notConnectedToInternet) }
    }
    #expect(attempts == 3)
    #expect(sleeps == [.seconds(2), .seconds(4)])
    attempts = 0
    do {
        try await CompanionRegistrationSync.retryLiveRegistration(sleep: { _ in Issue.record("Do not retry revoked access") }) {
            attempts += 1; throw CompanionError.rejected
        }
        Issue.record("Expected rejection")
    } catch CompanionError.rejected { }
    #expect(attempts == 1)
    attempts = 0
    do {
        try await CompanionRegistrationSync.retryLiveRegistration(sleep: { _ in }) {
            attempts += 1; throw CancellationError()
        }
        Issue.record("Expected cancellation")
    } catch is CancellationError { }
    #expect(attempts == 1)
}

@Test func liveTaskPositionIsSeparateAndOnlyVisibleForMultipleTasks() {
    var state = CompanionLiveState(title: "Task", state: "running", running: 1, attention: 0, tokensPerMinute: 0, updatedAt: 2000)
    #expect(state.taskPosition == nil)
    state.running = 2
    #expect(state.taskPosition == "1/2")
    #expect(state.taskPositionDescription == "Showing 1 of 2 active tasks. 1 other running task")
    state.attention = 1
    #expect(state.taskPosition == "1/3")
    state.state = "needsApproval"
    #expect(state.taskPositionDescription == "Showing 1 of 3 active tasks. 2 other running tasks")
    state.taskIndex = 2
    #expect(state.taskPosition == "3/3")
    #expect(state.taskPositionDescription.hasPrefix("Showing 3 of 3"))
    state.taskIndex = 99
    #expect(state.taskPosition == "3/3")
}

@Test func liveActivityPinnedTaskUsesItsOwnMetricsAndSurvivesAttentionChanges() {
    var snapshot = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 2000))[0]
    let working = snapshot.tasks.first(where: { $0.state == .running })!
    let selected = CompanionLiveState.from(snapshot, selectedTaskID: working.id)
    #expect(selected.taskID == working.id)
    #expect(selected.selectionIsPinned == true)
    #expect(selected.tokensPerMinute == working.tokensPerMinute)
    #expect(selected.taskIndex == 1)
    snapshot.tasks.removeAll(where: { $0.id == working.id })
    let fallback = CompanionLiveState.from(snapshot, selectedTaskID: working.id)
    #expect(fallback.state == "needsInput")
    #expect(fallback.selectionIsPinned == nil)
    #expect(fallback.taskIndex == 0)
}

@Test func streamDeliveryClockIsIndependentOfSourceClockAndOptionalForOldRelays() throws {
    let old = try JSONDecoder().decode(CompanionEnvelope.self, from: Data(#"{"type":"waiting"}"#.utf8))
    #expect(old.deliveryTimestamp == nil)
    let current = try JSONDecoder().decode(CompanionEnvelope.self, from: Data(#"{"type":"waiting","deliveryTimestamp":2000}"#.utf8))
    #expect(current.deliveryTimestamp == 2000)
}

@Test func nextLiveTaskPreviewKeepsObservationAgeAndUsesThatTasksMetrics() throws {
    let now = Date(timeIntervalSince1970: 2000)
    var snapshot = CompanionFixtures.snapshots(at: now)[0]
    snapshot.tasks[0].state = .running; snapshot.tasks[1].state = .running
    snapshot.tasks[0].tokensPerMinute = 987; snapshot.tasks[0].contextPercent = 47
    snapshot.tasks[1].tokensPerMinute = 0; snapshot.tasks[1].contextPercent = nil
    var state = CompanionLiveState.from(snapshot, selectedTaskID: snapshot.tasks[0].id)
    state.deliveryTimestamp = 2001
    let preview = try #require(state.previewOfNextTask(at: now))
    #expect(preview.taskID == snapshot.tasks[1].id)
    #expect(preview.tokensPerMinute == 0 && preview.contextPercent == nil)
    #expect(preview.updatedAt == state.updatedAt && preview.staleAt == state.staleAt)
    #expect(preview.selectionPending == true && preview.nextTask == nil)
    let laterPreview = try #require(state.previewOfNextTask(at: now.addingTimeInterval(5)))
    #expect(laterPreview.deliveryTimestamp == 2005)
    #expect(laterPreview.updatedAt == state.updatedAt && laterPreview.staleAt == state.staleAt)
    #expect(preview.previewOfNextTask(at: now) == nil)
    #expect(state.previewOfNextTask(at: now.addingTimeInterval(180)) == nil)
    state.deliveryTimestamp = nil
    #expect(state.previewOfNextTask(at: now) == nil)
}
@Test func sleepingBeforeUsageArrivesDoesNotBorrowAnotherTasksMetrics() {
    var snapshot = CompanionFixtures.snapshots(at: Date(timeIntervalSince1970: 2000))[0]
    snapshot.tasks[0].state = .running; snapshot.tasks[0].activity = "Using a tool"
    snapshot.tasks[0].contextPercent = nil; snapshot.tasks[0].tokensPerMinute = 0
    snapshot.tasks[0].hasTokenObservation = true
    let state = CompanionLiveState.from(snapshot, selectedTaskID: snapshot.tasks[0].id)
    #expect(state.activityTitle == "Using a tool")
    #expect(state.contextPercent == nil && state.displayedRate(stale: false) == nil)
    #expect(state.startedAt == snapshot.tasks[0].startedAt?.timeIntervalSince1970)
}
