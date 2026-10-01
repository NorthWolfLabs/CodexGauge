import XCTest

/// Opt-in APNs lifecycle acceptance on a dedicated simulator only.
final class CompanionActivityAccessUITests: XCTestCase {
    @MainActor func testActivityDismissalToggleReplacementUnlinkAndRevocation() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This acceptance check is simulator-only.")
        #else
        guard ProcessInfo.processInfo.environment["COMPANION_ACTIVITY_ACCESS_TEST"] == "1" else {
            throw XCTSkip("Real APNs access-lifecycle verification is opt-in.")
        }
        continueAfterFailure = false
        let feed = try await ActivityAccessFeed.create()
        addTeardownBlock { try await feed.delete() }
        try await feed.publish(nil)
        let app = XCUIApplication()
        app.launchArguments = ["-companionUITest", "-companionResetUITestLinks"]
        app.launch()
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func link(usage: Bool = false) {
            app.buttons["Settings"].tap()
            app.buttons["Link a Mac"].firstMatch.tap()
            let field = app.textFields["companion.viewingLink"]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(feed.link(usage: usage))
            app.buttons["Link Mac"].tap()
            XCTAssertFalse(app.navigationBars["Link a Mac"].exists)
        }
        // Initial unlinked Overview has no Settings tab contents to scroll.
        app.buttons["Link a Mac"].firstMatch.tap()
        let field = app.textFields["companion.viewingLink"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(feed.link())
        app.buttons["Link Mac"].tap()
        app.buttons["Settings"].tap()
        let send = app.buttons["Send test notification"]
        if !send.isHittable { app.swipeUp() }; send.tap()
        if board.alerts.buttons["Allow"].waitForExistence(timeout: 3) { board.alerts.buttons["Allow"].tap() }
        let result = app.staticTexts["companion.pushTestResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        XCTAssertEqual(result.label, "Apple accepted the test. Check for its notification.")
        func enabled(_ value: Bool) {
            app.buttons["Settings"].tap()
            let control = app.switches["Follow active tasks"].switches.firstMatch
            if !control.isHittable { app.swipeUp() }
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            if (control.value as? String == "1") != value { control.tap() }
            XCTAssertEqual(control.value as? String, value ? "1" : "0")
        }
        enabled(true)
        let card = board.otherElements.matching(identifier: "activity-content-view")
            .containing(NSPredicate(format: "label == %@", "Activity Access Mac")).firstMatch
        func showCards() {
            XCUIDevice.shared.press(.home)
            board.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01)).press(forDuration: 0.1,
                thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)))
        }
        func absent(_ name: String) throws {
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card)
            let passed = XCTWaiter.wait(for: [gone], timeout: 15) == .completed
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = name; image.lifetime = .keepAlways; add(image)
            XCTAssertTrue(passed)
            if !passed { throw ProbeFailure.missingTransition }
        }
        func active(_ name: String) async throws {
            try await feed.publish("running")
            try await Task.sleep(for: .seconds(8))
            showCards()
            let appeared = card.waitForExistence(timeout: 15)
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = name; image.lifetime = .keepAlways; add(image)
            XCTAssertTrue(appeared)
            if !appeared { throw ProbeFailure.missingTransition }
            let allow = board.buttons.matching(identifier: "swipe-action-button-identifier")
                .matching(NSPredicate(format: "label IN %@", ["Allow", "Always Allow"])).firstMatch
            if allow.waitForExistence(timeout: 2) { allow.tap() }
        }
        XCUIDevice.shared.press(.home)
        try await active("Activity access — initial native card")
        app.activate(); enabled(false); showCards()
        try absent("Live Activities off — card removed")
        app.activate(); enabled(true); XCUIDevice.shared.press(.home)
        try await active("Live Activities on — fresh native card")
        app.activate(); link(usage: true); showCards()
        try absent("Usage-only replacement — card removed")
        app.activate(); link(); XCUIDevice.shared.press(.home)
        try await active("Full viewing access restored — native card")
        card.swipeLeft()
        let clear = board.buttons["Clear"].firstMatch
        if clear.waitForExistence(timeout: 2) { clear.tap() }
        try absent("User dismissed native activity")
        // Let the app forward ActivityKit's dismissal and refresh registration;
        // fresh task states must not undo a user's dismissal.
        app.activate(); XCUIDevice.shared.press(.home)
        try await feed.publish("needsApproval")
        try await Task.sleep(for: .seconds(8)); showCards()
        try absent("Dismissed activity stays dismissed after reconnect")
        app.activate(); enabled(false); enabled(true); XCUIDevice.shared.press(.home)
        try await active("Off-on after dismissal — new native activity")
        app.activate(); app.buttons["Settings"].tap(); app.swipeDown()
        let row = app.staticTexts["Activity Access Mac"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.swipeLeft()
        app.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Link your Mac"].waitForExistence(timeout: 15) || !row.exists)
        showCards(); try absent("Unlinked Mac — native activity removed")
        app.activate(); link(); XCUIDevice.shared.press(.home)
        try await active("Relinked Mac — native activity restored")
        try await feed.rotate()
        try await Task.sleep(for: .seconds(8)); showCards()
        try absent("Access revoked — native activity removed")
        try await feed.publish("needsApproval")
        try await Task.sleep(for: .seconds(5)); showCards()
        try absent("Revocation survives a later publisher state")
        app.activate(); app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Access revoked — add a new link"].waitForExistence(timeout: 15))
        #endif
    }
}
private enum ProbeFailure: Error { case missingTransition }
private struct ActivityAccessFeed: Sendable {
    static let base = URL(string: "https://codexgauge-relay-dev.north-wolf-labs.workers.dev")!
    let id: String, publisher: String, reader: String, usage: String
    let socket: URLSessionWebSocketTask
    static func create() async throws -> Self {
        func key() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased() }
        let id = UUID().uuidString.lowercased(), publisher = key(), reader = key(), usage = key()
        var request = URLRequest(url: base.appending(path: "v1/macs/\(id)/initialize"))
        request.httpMethod = "POST"; request.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["reader": reader, "usageReader": usage])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var stream = URLRequest(url: URL(string: "wss://codexgauge-relay-dev.north-wolf-labs.workers.dev/v1/macs/\(id)/stream")!)
        stream.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: stream); socket.resume()
        return Self(id: id, publisher: publisher, reader: reader, usage: usage, socket: socket)
    }
    func link(usage: Bool = false) -> String {
        "codexgauge://view?server=https%3A%2F%2Fcodexgauge-relay-dev.north-wolf-labs.workers.dev&id=\(id)#\(usage ? self.usage : reader)"
    }
    func publish(_ state: String?) async throws {
        let now = Date.now.timeIntervalSince1970
        let tasks: [[String: Any]] = state.map { [["id": "access-probe", "title": "Access lifecycle probe", "project": "CodexGauge tests", "state": $0,
            "activity": $0, "tokensPerMinute": 1200, "totalTokens": 100, "agentCount": 0, "eventAt": now]] } ?? []
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": id, "name": "Activity Access Mac", "observedAt": now, "tasks": tasks])
        try await socket.send(.string(String(decoding: data, as: UTF8.self))); _ = try await socket.receive()
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
