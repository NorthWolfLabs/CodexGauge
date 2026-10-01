import XCTest

/// Opt in with COMPANION_LIVE_PUSH_TEST=1 in the test runner environment.
/// Uses a disposable feed and this simulator/device's own APNs registration.
/// Banner assertions inspect only the iPhone. They cannot observe delivery to a
/// paired Apple Watch; a missing phone banner is not proof of failed delivery.
final class CompanionPushUITests: XCTestCase {
    @MainActor func testAppleAcceptsAndDisplaysPush() async throws {
        guard ProcessInfo.processInfo.environment["COMPANION_LIVE_PUSH_TEST"] == "1" else {
            throw XCTSkip("Live Apple push verification is explicitly enabled for a provisioned test device.")
        }
        continueAfterFailure = false
        let taskTitle = "Live delivery verification \(UUID().uuidString.prefix(6))"
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
            remove.httpMethod = "DELETE"
            remove.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
            let (_, deleted) = try await URLSession.shared.data(for: remove)
            XCTAssertEqual((deleted as? HTTPURLResponse)?.statusCode, 200)
        }
        do {
            let app = XCUIApplication()
            // A notification launches the app without XCTest launch arguments.
            // Use its normal credential service for a genuine cold launch.
            app.launchArguments = []
            app.launch()
            app.buttons["Settings"].tap()
            app.swipeDown()
            for name in ["Widget Acceptance Mac", "Push Test Mac"] {
                let old = app.staticTexts[name].firstMatch
                while old.exists {
                    old.swipeLeft(); app.buttons["Remove"].firstMatch.tap()
                    let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: old)
                    XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 15), .completed)
                }
            }
            app.buttons["Link a Mac"].firstMatch.tap()
            let field = app.textFields["companion.viewingLink"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText("codexgauge://view?server=https%3A%2F%2Fcodexgauge-relay-dev.north-wolf-labs.workers.dev&id=\(id)#\(reader)")
            app.buttons["Link Mac"].tap()
            app.buttons["Settings"].tap()
            let send = app.buttons["Send test notification"]
            if !send.isHittable { app.swipeUp() }
            XCTAssertTrue(send.waitForExistence(timeout: 5))
            send.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = springboard.alerts.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
            let result = app.staticTexts["companion.pushTestResult"]
            XCTAssertTrue(result.waitForExistence(timeout: 30))
            XCTAssertEqual(result.label, "Apple accepted the test. Check for its notification.")
            let banner = springboard.staticTexts["Your CodexGauge phone alerts are connected."]
            XCTAssertTrue(banner.waitForExistence(timeout: 15), "No iPhone test banner observed. This assertion cannot observe delivery to a paired Apple Watch.")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Live APNs test notification"; shot.lifetime = .keepAlways; add(shot)

            // Exercise the real publisher → Durable Object alarm → APNs path,
            // while the app is backgrounded and cannot receive WebSocket updates.
            // SwiftUI exposes a labeled row and a nested native switch. Tapping
            // the row's center doesn't necessarily activate the native control.
            let completed = app.switches["Task completed"].switches.firstMatch
            if !completed.isHittable { app.swipeDown() }
            let wasEnabled = completed.value as? String == "1"
            if !wasEnabled { completed.tap() }
            XCTAssertTrue(app.staticTexts["Enabled"].waitForExistence(timeout: 10))
            var socketRequest = URLRequest(url: URL(string: "wss://codexgauge-relay-dev.north-wolf-labs.workers.dev/v1/macs/\(id)/stream")!)
            socketRequest.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: socketRequest)
            socket.resume()
            defer { socket.cancel(with: .normalClosure, reason: nil) }
            func publish(_ state: String, activity: String? = nil) async throws {
                let now = Date().timeIntervalSince1970
                let payload: [String: Any] = ["schemaVersion": 1, "id": id, "name": "Push Test Mac", "observedAt": now,
                    "tasks": [["id": "push-verification", "title": taskTitle, "project": "CodexGauge tests",
                        "state": state, "activity": activity ?? state, "tokensPerMinute": 0, "totalTokens": 10, "agentCount": 0, "eventAt": now]]]
                let data = try JSONSerialization.data(withJSONObject: payload)
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                _ = try await socket.receive()
            }
            try await publish("running")
            app.tabBars.buttons["Tasks"].tap()
            XCTAssertTrue(app.staticTexts[taskTitle].waitForExistence(timeout: 15))
            try await publish("running", activity: "Live update verified")
            XCTAssertTrue(app.staticTexts["Live update verified"].waitForExistence(timeout: 10), "A second cloud snapshot must appear without manual refresh.")
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended,
                          "Push verification requires the viewer to be backgrounded.")
            try await publish("completed")
            let completion = springboard.buttons.matching(identifier: "ShortLook.Platter.Content.Seamless")
                .matching(NSPredicate(format: "label CONTAINS %@", taskTitle)).firstMatch
            XCTAssertTrue(completion.waitForExistence(timeout: 25), "No iPhone completion banner observed while backgrounded. Check paired Watch receipt separately.")
            for _ in 0..<30 {
                guard completion.exists else { break }
                if completion.isHittable { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(completion.exists && completion.isHittable, "The completion banner must be visibly presented, not only present in the accessibility tree.")
            let backgroundShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            backgroundShot.name = "Background task completion via APNs"; backgroundShot.lifetime = .keepAlways; add(backgroundShot)
            let routingTree = XCTAttachment(string: springboard.debugDescription)
            routingTree.name = "Delivered notification routing target"; routingTree.lifetime = .keepAlways; add(routingTree)
            completion.tap()
            XCTAssertTrue(app.navigationBars["Task"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts[taskTitle].exists)
            XCTAssertTrue(app.staticTexts["Completed"].exists)
            for cold in [true, false] {
                if cold { app.terminate() }
                else { XCUIDevice.shared.press(.home) }
                try await publish("running")
                try await Task.sleep(for: .seconds(2))
                try await publish("completed")
                XCTAssertTrue(completion.waitForExistence(timeout: 25))
                completion.tap()
                XCTAssertTrue(app.navigationBars["Task"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.staticTexts[taskTitle].waitForExistence(timeout: 10))
                XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 10))
                let routed = XCTAttachment(screenshot: app.screenshot())
                routed.name = cold ? "Cold APNs notification tap — correct task" : "Repeated APNs notification tap — correct task"
                routed.lifetime = .keepAlways; add(routed)
            }
            app.buttons["Settings"].tap()
            if !wasEnabled { completed.tap() }
            app.swipeDown()
            let linked = app.staticTexts["Push Test Mac"].firstMatch
            linked.swipeLeft(); app.buttons["Remove"].firstMatch.tap()
        }
    }
}
