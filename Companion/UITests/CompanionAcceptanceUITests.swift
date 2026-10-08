import XCTest

/// Local synthetic relay only. These tests never read the owner's Mac or phone.
final class CompanionAcceptanceUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-companionUITest", "-companionResetUITestLinks"]
        app.launch()
        return app
    }
    @MainActor private func link(_ feed: AcceptanceFeed, to app: XCUIApplication, usageOnly: Bool = false) {
        if !app.buttons["Link a Mac"].firstMatch.exists { app.buttons["Settings"].tap() }
        app.buttons["Link a Mac"].firstMatch.tap()
        let input = app.textFields["companion.viewingLink"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText(feed.viewingLink(usageOnly: usageOnly))
        app.buttons["Link Mac"].tap()
        XCTAssertFalse(app.navigationBars["Link a Mac"].exists)
        if app.navigationBars["Settings"].waitForExistence(timeout: 1) { app.buttons["Done"].tap() }
    }
    @MainActor private func shot(_ name: String, app: XCUIApplication) {
        let item = XCTAttachment(screenshot: app.screenshot())
        item.name = name; item.lifetime = .keepAlways; add(item)
    }

    @MainActor private func chooseRange(_ title: String, app: XCUIApplication) {
        app.buttons["companion.chart.range"].tap()
        app.buttons[title].firstMatch.tap()
    }

    @MainActor func testLongMacAndTaskNamesStayWithinDetail() async throws {
        continueAfterFailure = false
        let name = "Acceptance MacBook Pro — development workspace with a long identifying name"
        let feed = try await AcceptanceFeed.create(name: name)
        addTeardownBlock { try await feed.delete() }
        try await feed.publish(state: "needsApproval")
        let app = launch(); link(feed, to: app)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts[feed.title].waitForExistence(timeout: 10))
        app.staticTexts[feed.title].tap()
        let value = app.staticTexts["Mac, \(name)"].firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(value.frame.minX, 16)
        XCTAssertLessThanOrEqual(value.frame.maxX, app.frame.maxX - 16)
        XCTAssertTrue(value.isHittable)
        XCTAssertTrue(app.staticTexts["Needs approval"].exists)
        XCTAssertFalse(app.buttons["Approve"].exists)
        shot("Long Mac and task names — read-only detail", app: app)
    }

    @MainActor func testChartRangesSelectionAndInvalidLinkCorrection() async throws {
        continueAfterFailure = false
        let feed = try await AcceptanceFeed.create()
        addTeardownBlock { try await feed.delete() }
        try await feed.publish()
        let app = launch()
        app.open(URL(string: "codexgauge://view?invalid=1")!)
        XCTAssertTrue(app.navigationBars["Link a Mac"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This viewing link isn’t valid. Copy a new link from the Mac."].exists)
        shot("Invalid viewing link — actionable correction", app: app)
        let input = app.textFields["companion.viewingLink"]
        input.tap()
        input.press(forDuration: 1)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        // Replace through the native editing path, including its existing error.
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        input.typeText(feed.viewingLink())
        app.buttons["Link Mac"].tap()
        XCTAssertTrue(app.staticTexts["83%"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Activity"].tap()
        let totals = ["7 days": "350", "30 days": "650", "90 days": "1,250"]
        for range in ["7 days", "30 days", "90 days"] {
            chooseRange(range, app: app)
            XCTAssertEqual(app.staticTexts["companion.chart.value"].label, totals[range])
            XCTAssertEqual(app.staticTexts["companion.chart.period"].label, "Observed tokens · last \(range)")
            XCTAssertEqual(app.staticTexts["companion.chart.average"].label, ["7 days": "116", "30 days": "162", "90 days": "250"][range])
        }
        chooseRange("7 days", app: app)
        let chart = app.descendants(matching: .any)["companion.accountChart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        shot("Seven-day chart before selection", app: app)
        let chartTree = XCTAttachment(string: chart.debugDescription)
        chartTree.name = "Chart accessibility frame"; chartTree.lifetime = .keepAlways; add(chartTree)
        // Charts includes axes/annotations in its accessibility frame, which
        // can extend outside the visible plot. Target the dated bar itself.
        let today = Calendar.current.startOfDay(for: Date.now)
        let todayBar = chart.descendants(matching: .any).matching(NSPredicate(format: "label == %@", today.formatted(date: .abbreviated, time: .omitted))).firstMatch
        todayBar.tap()
        let selected = app.staticTexts["companion.chart.period"]
        XCTAssertEqual(selected.label, Calendar.current.startOfDay(for: .now).formatted(date: .abbreviated, time: .omitted))
        XCTAssertEqual(app.staticTexts["companion.chart.value"].label, "200")
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        chart.descendants(matching: .any).matching(NSPredicate(format: "label == %@", yesterday.formatted(date: .abbreviated, time: .omitted))).firstMatch.tap()
        XCTAssertEqual(selected.label, yesterday.formatted(date: .abbreviated, time: .omitted))
        XCTAssertEqual(app.staticTexts["companion.chart.value"].label, "100")
        shot("Selected day — exact date and 100 tokens", app: app)
        chooseRange("30 days", app: app)
        XCTAssertEqual(selected.label, "Observed tokens · last 30 days")
        XCTAssertEqual(app.staticTexts["companion.chart.value"].label, "650")
    }

    @MainActor func testEmptyOverviewAndWaitingForFirstFeed() async throws {
        continueAfterFailure = false
        let feed = try await AcceptanceFeed.create(name: "Waiting Acceptance Mac")
        addTeardownBlock { try await feed.delete() }
        let app = launch()
        XCTAssertTrue(app.staticTexts["Link your Mac"].waitForExistence(timeout: 5))
        shot("Empty overview — pairing entry", app: app)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["No active tasks"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["companion.accountSelector"].exists)
        shot("Empty tasks — no invented running sessions", app: app)
        app.tabBars.buttons["Overview"].tap()
        link(feed, to: app)
        XCTAssertTrue(app.staticTexts["Waiting for usage"].waitForExistence(timeout: 10))
        shot("Linked Mac — waiting for first observation", app: app)
        try await feed.publish()
        XCTAssertTrue(app.staticTexts["83%"].waitForExistence(timeout: 10))
        shot("First observation — usage arrives without refresh", app: app)
    }

    @MainActor func testTaskEmptyHistoryStaleRecoveryAndUsageOnlyReplacement() async throws {
        continueAfterFailure = false
        let feed = try await AcceptanceFeed.create()
        addTeardownBlock { try await feed.delete() }
        try await feed.publish(state: "needsInput")
        let app = launch(); link(feed, to: app)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts[feed.title].waitForExistence(timeout: 10))
        app.staticTexts[feed.title].tap()
        XCTAssertTrue(app.staticTexts["No recent live samples"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Approve"].exists)
        shot("Waiting task — empty throughput history", app: app)
        // A new feed accepts its first stale checkpoint only; this one already
        // has a fresh snapshot, so use another Mac to exercise stale UI honestly.
        let stale = try await AcceptanceFeed.create(name: "Offline Acceptance Mac")
        addTeardownBlock { try await stale.delete() }
        try await stale.publish(state: "running", observedAt: Date.now.timeIntervalSince1970 - 100)
        app.buttons["Settings"].tap(); link(stale, to: app)
        app.tabBars.buttons["Tasks"].tap()
        if app.navigationBars["Task"].exists { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertTrue(app.staticTexts[stale.title].waitForExistence(timeout: 10))
        app.staticTexts[stale.title].tap()
        XCTAssertTrue(app.staticTexts["Mac offline or no recent update · showing last known task"].waitForExistence(timeout: 5))
        shot("Stale Mac — last known task", app: app)
        let resumed = Date.now.timeIntervalSince1970 - 30
        try await stale.publish(state: "running", activity: "Fresh observation restored", observedAt: resumed)
        XCTAssertTrue(app.staticTexts["Fresh observation restored"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Mac offline or no recent update · showing last known task"].exists)
        try await stale.publish(state: "running", observedAt: resumed + 2)
        XCTAssertTrue(app.descendants(matching: .any)["companion.rateChart"].waitForExistence(timeout: 10))
        try await stale.publish(state: "running", observedAt: resumed + 20)
        try await stale.publish(state: "running", observedAt: resumed + 22)
        shot("Task throughput — gap across missed observations", app: app)
        try await stale.publish(state: "completed")
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Collecting live activity…"].exists)
        shot("Completed task remains readable in open detail", app: app)
        app.buttons["Settings"].tap(); link(feed, to: app, usageOnly: true)
        app.tabBars.buttons["Tasks"].tap()
        if app.navigationBars["Task"].exists { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertFalse(app.staticTexts[feed.title].exists)
        app.tabBars.buttons["Overview"].tap()
        XCTAssertTrue(app.staticTexts["83%"].waitForExistence(timeout: 10))
        shot("Usage-only replacement — task data removed", app: app)
    }

    @MainActor func testColdWarmRepeatedTaskLinksAndAccessRevocation() async throws {
        continueAfterFailure = false
        let first = try await AcceptanceFeed.create(name: "Acceptance Mac A")
        let second = try await AcceptanceFeed.create(name: "Acceptance Mac B")
        addTeardownBlock { try await first.delete(); try await second.delete() }
        try await first.publish(state: "running")
        try await second.publish(state: "needsApproval")
        let app = launch(); link(first, to: app)
        app.launchArguments = ["-companionUITest"]
        app.buttons["Settings"].tap(); link(second, to: app)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts[first.title].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[second.title].exists)
        shot("Two Macs — same task ID, distinct ownership", app: app)
        for feed in [first, second, second, first] {
            app.open(feed.taskLink)
            XCTAssertTrue(app.navigationBars["Task"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[feed.title].exists)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", feed.name)).firstMatch.exists)
        }
        app.terminate(); app.launchArguments = ["-companionUITest"]
        app.open(second.taskLink)
        XCTAssertTrue(app.navigationBars["Task"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[second.title].waitForExistence(timeout: 10))
        shot("Cold task link — correct Mac and approval", app: app)
        try await second.rotate()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Access revoked — add a new link"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertFalse(app.staticTexts[second.title].exists)
        if app.navigationBars["Task"].exists { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertTrue(app.staticTexts[first.title].waitForExistence(timeout: 10))
        shot("Revoked Mac cleared — other Mac stays active", app: app)
    }
}

struct AcceptanceFeed: Sendable {
    let id: String
    let publisher: String
    let reader: String
    let usage: String
    let name: String
    let socket: URLSessionWebSocketTask
    var title: String { "Task on \(name)" }
    static let base = URL(string: "http://127.0.0.1:8798")!
    var taskLink: URL { URL(string: "codexgauge://tasks/\(id)?task=shared-task")! }
    static func create(name: String = "Acceptance Mac") async throws -> Self {
        func key() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased() }
        let id = UUID().uuidString.lowercased(), publisher = key(), reader = key(), usage = key()
        var request = URLRequest(url: base.appending(path: "v1/macs/\(id)/initialize"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["reader": reader, "usageReader": usage])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var stream = URLRequest(url: URL(string: "ws://127.0.0.1:8798/v1/macs/\(id)/stream")!)
        stream.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: stream); socket.resume()
        return Self(id: id, publisher: publisher, reader: reader, usage: usage, name: name, socket: socket)
    }
    func viewingLink(usageOnly: Bool = false) -> String {
        "codexgauge://view?server=http%3A%2F%2F127.0.0.1%3A8798&id=\(id)#\(usageOnly ? usage : reader)"
    }
    func publish(state: String = "running", activity: String? = nil, observedAt: Double = Date.now.timeIntervalSince1970,
                 remainingPercent: Int = 64, creditBalance: String = "250", bankedResets: Int = 2,
                 accountID: String = "shared-acceptance-account", email: String? = nil) async throws {
        let calendar = Calendar.current
        func day(_ offset: Int, _ count: Int) -> [String: Any] {
            let date = calendar.date(byAdding: .day, value: offset, to: .now)!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return ["id": String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!), "tokens": count]
        }
        var account: [String: Any] = ["id": accountID, "plan": "Pro", "observedAt": observedAt,
            "windows": [["id": "session", "name": "Session", "remainingPercent": 83, "resetsAt": observedAt + 8000],
                        ["id": "weekly", "name": "Weekly", "remainingPercent": remainingPercent, "resetsAt": observedAt + 280000]],
            "bankedResets": bankedResets, "lifetimeTokens": 2000, "dailyTokens": [day(0, 200), day(-1, 100), day(-2, 50), day(-10, 300), day(-40, 600)],
            "credits": [["id": "codex", "name": "Codex", "hasCredits": true, "unlimited": false, "balance": creditBalance]]]
        if let email { account["email"] = email; account["accountType"] = "chatgpt" }
        let payload: [String: Any] = ["schemaVersion": 1, "id": id, "name": name, "observedAt": observedAt, "account": account,
            "tasks": [["id": "shared-task", "title": title, "project": "CodexGauge tests", "state": state,
                       "activity": activity ?? state, "tokensPerMinute": state == "running" ? 1200 : 0,
                       "totalTokens": 100, "agentCount": 0, "eventAt": observedAt]]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await publishRelayFixture(data, on: socket, base: Self.base, id: id, publisher: publisher)
    }
    func rotate() async throws {
        var request = URLRequest(url: Self.base.appending(path: "v1/macs/\(id)/rotate"))
        request.httpMethod = "POST"; request.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["reader": String(repeating: "d", count: 64), "usageReader": String(repeating: "e", count: 64)])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    func delete() async throws {
        socket.cancel(with: .normalClosure, reason: nil)
        var request = URLRequest(url: Self.base.appending(path: "v1/macs/\(id)/feed"))
        request.httpMethod = "DELETE"; request.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}


/// Synthetic publisher shared by the integration UI checks. Refresh requests are
/// display-only controls; only an accepted frame acknowledges a publication.
func publishRelayFixture(_ data: Data, on socket: URLSessionWebSocketTask, base: URL, id: String, publisher: String) async throws {
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    while true {
        let message = try await socket.receive()
        let reply: Data
        switch message { case .string(let text): reply = Data(text.utf8); case .data(let bytes): reply = bytes; @unknown default: throw URLError(.badServerResponse) }
        let value = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        if value?["type"] as? String == "accepted" { break }
        guard value?["type"] as? String == "refresh" else { throw URLError(.badServerResponse) }
    }
    var request = URLRequest(url: base.appending(path: "v1/macs/\(id)/push"))
    request.httpMethod = "POST"; request.timeoutInterval = 25
    request.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["observations": [JSONSerialization.jsonObject(with: data)]])
    let (_, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
}
