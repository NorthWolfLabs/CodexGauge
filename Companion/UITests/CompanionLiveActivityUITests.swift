import XCTest

/// Uses real APNs and disposable task data in a separate UI-test Keychain service.
/// Physical-device testing is separately opt-in and restores the normal app after it.
final class CompanionLiveActivityUITests: XCTestCase {
    @MainActor func testBackgroundActivityLifecycle() async throws {
        #if !targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["COMPANION_LIVE_ACTIVITY_PHYSICAL_TEST"] == "1" else {
            throw XCTSkip("Physical ActivityKit testing requires its separate opt-in.")
        }
        #endif
        guard ProcessInfo.processInfo.environment["COMPANION_LIVE_ACTIVITY_TEST"] == "1" else {
            throw XCTSkip("Real ActivityKit delivery is an opt-in integration check.")
        }
        continueAfterFailure = false
        let base = URL(string: "https://codexgauge-relay-dev.north-wolf-labs.workers.dev")!
        let id = UUID().uuidString.lowercased()
        func credential() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased() }
        let publisher = credential(), reader = credential(), usage = credential()
        var request = URLRequest(url: base.appending(path: "v1/macs/\(id)/initialize"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["reader": reader, "usageReader": usage])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        addTeardownBlock {
            var remove = URLRequest(url: base.appending(path: "v1/macs/\(id)/feed"))
            remove.httpMethod = "DELETE"; remove.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: remove)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
        var socketRequest = URLRequest(url: URL(string: "wss://codexgauge-relay-dev.north-wolf-labs.workers.dev/v1/macs/\(id)/stream")!)
        socketRequest.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: socketRequest)
        socket.resume(); defer { socket.cancel(with: .normalClosure, reason: nil) }
        func publish(_ state: String?) async throws {
            let now = Date.now.timeIntervalSince1970
            var payload: [String: Any] = ["schemaVersion": 1, "id": id, "name": "Activity Test Mac", "observedAt": now, "tasks": []]
            if let state {
                payload["tasks"] = [["id": "activity-probe", "title": "Live Activity probe", "project": "CodexGauge tests",
                    "state": state, "activity": state, "tokensPerMinute": state == "running" ? 1200 : 0,
                    "totalTokens": 100, "agentCount": 0, "eventAt": now]]
            }
            let data = try JSONSerialization.data(withJSONObject: payload)
            try await socket.send(.string(String(decoding: data, as: UTF8.self))); _ = try await socket.receive()
        }
        try await publish(nil)
        let app = XCUIApplication()
        #if !targetEnvironment(simulator)
        addTeardownBlock { @MainActor in
            app.terminate(); app.launchArguments = []; app.launch()
        }
        #endif
        app.launchArguments = ["-companionUITest", "-companionResetUITestLinks"]
        app.launch()
        app.buttons["Link a Mac"].firstMatch.tap()
        let field = app.textFields["companion.viewingLink"]
        if !field.waitForExistence(timeout: 5) {
            // An unrelated phone banner can cover the first tap.
            app.buttons["Link a Mac"].firstMatch.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeText("codexgauge://view?server=https%3A%2F%2Fcodexgauge-relay-dev.north-wolf-labs.workers.dev&id=\(id)#\(reader)")
        app.buttons["Link Mac"].tap()
        app.buttons["Settings"].tap()
        let send = app.buttons["Send test notification"]
        if !send.isHittable { app.swipeUp() }; XCTAssertTrue(send.waitForExistence(timeout: 5)); send.tap()
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if board.alerts.buttons["Allow"].waitForExistence(timeout: 3) { board.alerts.buttons["Allow"].tap() }
        let result = app.staticTexts["companion.pushTestResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        XCTAssertEqual(result.label, "Apple accepted the test. Check for its notification.")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        try await publish("running")
        try await Task.sleep(for: .seconds(10))
        // Dynamic Island chooses which concurrent activity to expand. Assert
        // against the specific Lock Screen card instead of its screen position.
        // The physical phone can have other Macs' activities in Dynamic Island.
        // Target this fixture's native Lock Screen card, never an ordinary alert.
        let card = board.otherElements.matching(identifier: "activity-content-view")
            .containing(NSPredicate(format: "label == %@", "Activity Test Mac")).firstMatch
        XCUIDevice.shared.press(.home)
        for _ in 0..<3 {
            board.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01)).press(forDuration: 0.1,
                thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)))
            if card.waitForExistence(timeout: 3) { break }
            board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 0.1,
                thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
            if card.waitForExistence(timeout: 3) { break }
        }
        if !card.exists {
            let diagnostic = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            diagnostic.name = "Missing native activity card"; diagnostic.lifetime = .keepAlways; add(diagnostic)
        }
        XCTAssertTrue(card.exists, "Find the fixture's native Lock Screen activity alongside other Macs.")
        // The permission controls are siblings of the content view, and the
        // system's outer container type differs between iOS versions.
        let allowActivity = board.buttons.matching(identifier: "swipe-action-button-identifier")
            .matching(NSPredicate(format: "label IN %@", ["Allow", "Always Allow"])).firstMatch
        if allowActivity.waitForExistence(timeout: 3) { allowActivity.tap() }
        let lockScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        lockScreen.name = "Remote Live Activity Lock Screen"; lockScreen.lifetime = .keepAlways; add(lockScreen)
        try await publish("needsApproval")
        let waiting = card.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Needs approval")).firstMatch
        let updated = waiting.waitForExistence(timeout: 20)
        if !updated {
            board.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01)).press(forDuration: 0.1,
                thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)))
            let diagnostic = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            diagnostic.name = "Live Activity update diagnostic"; diagnostic.lifetime = .keepAlways; add(diagnostic)
            let tree = XCTAttachment(string: board.debugDescription); tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertTrue(updated, "Background APNs must update the activity without reopening the app.")
        let update = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        update.name = "Remote Live Activity approval"; update.lifetime = .keepAlways; add(update)
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningBackgroundSuspended)
        card.staticTexts["Live Activity probe"].tap()
        XCTAssertTrue(app.navigationBars["Task"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Live Activity probe"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Activity Test Mac")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Needs approval"].exists)
        XCTAssertFalse(app.buttons["Approve"].exists)
        XCTAssertFalse(app.staticTexts["Collecting live activity…"].exists)
        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "Live Activity opens read-only task"; detail.lifetime = .keepAlways; add(detail)
        XCUIDevice.shared.press(.home)
        board.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01)).press(forDuration: 0.1,
            thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)))
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        try await publish("completed")
        for _ in 0..<75 {
            if !card.exists { break }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertTrue(!card.exists)
    }
}
