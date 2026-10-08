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
            app.open(URL(string: "codexgauge://view?server=https%3A%2F%2Fcodexgauge-relay-dev.north-wolf-labs.workers.dev&id=\(id)#\(reader)")!)
            XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 15))
            app.buttons["Settings"].tap()
            let completed = app.switches["Task completed"].switches.firstMatch
            if !completed.isHittable { app.swipeUp() }
            XCTAssertTrue(completed.waitForExistence(timeout: 5))
            let wasEnabled = completed.value as? String == "1"
            if !wasEnabled { completed.tap() }
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            if springboard.alerts.buttons["Allow"].waitForExistence(timeout: 3) {
                springboard.alerts.buttons["Allow"].tap()
            }
            app.buttons["Done"].tap()
            // Current product UI intentionally has no diagnostics button. Check
            // registration through the publisher API, then send real task events.
            var registered = false
            for _ in 0..<30 {
                var diagnostic = URLRequest(url: base.appending(path: "v1/macs/\(id)/diagnostics"))
                diagnostic.setValue("Bearer \(publisher)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: diagnostic)
                if (response as? HTTPURLResponse)?.statusCode == 200,
                   let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let receivers = value["receivers"] as? [[String: Any]], !receivers.isEmpty { registered = true; break }
                try await Task.sleep(for: .milliseconds(300))
            }
            XCTAssertTrue(registered)
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
                try await publishRelayFixture(data, on: socket, base: base, id: id, publisher: publisher)
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
