import XCTest
import UIKit

/// Local rendering checks. No relay, APNs, viewing link or personal task data.
final class CompanionLiveLayoutUITests: XCTestCase {
    @MainActor private func launchReview() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-companionLiveActivityReview"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Live Activity review"].waitForExistence(timeout: 10))
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.press(.home)
            app.activate()
            Thread.sleep(forTimeInterval: 1)
            if app.buttons["End review activity"].exists {
                app.buttons["End review activity"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(app.staticTexts["Ended"].waitForExistence(timeout: 5))
            }
            app.terminate(); app.launchArguments = []; app.launch()
        }
        return app
    }
    @MainActor private func capture(_ title: String, _ board: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = title; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: board.debugDescription)
        tree.name = title + " hierarchy"; tree.lifetime = .keepAlways; add(tree)
    }
    /// Accessibility alone cannot establish visual contrast. Check the first
    /// word's actual pixels against the activity's black background as well.
    @MainActor private func assertIslandTitleIsVisible(_ frame: CGRect, screenWidth: CGFloat, threshold: UInt8 = 200) {
        let screenshot = XCUIScreen.main.screenshot().image
        guard let fullImage = screenshot.cgImage, screenWidth > 0 else {
            XCTFail("Capture the native screen pixels"); return
        }
        let scale = CGFloat(fullImage.width) / screenWidth
        let firstWord = CGRect(x: frame.minX * scale, y: frame.minY * scale,
            width: min(70, frame.width) * scale, height: min(23, frame.height) * scale)
        guard let crop = fullImage.cropping(to: firstWord) else {
            XCTFail("Capture the native title pixels"); return
        }
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let visible = stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] > threshold && bytes[$0 + 1] > threshold && bytes[$0 + 2] > threshold && bytes[$0 + 3] > 200
        }.count
        XCTAssertGreaterThan(Double(visible) / Double(width * height), 0.03,
            "The first title word must render; an accessibility label alone isn't visual verification")
    }
    @MainActor private func show(_ name: String, app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        app.activate()
        Thread.sleep(forTimeInterval: 1)
        app.buttons[name].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let result = app.staticTexts["Showing " + name]
        if !result.waitForExistence(timeout: 3) {
            app.buttons[name].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
    }
    @MainActor func testExpandedIslandKeepsStatusOnOneLine() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dynamic Island layout uses an isolated simulator, not the owner's iPhone 17.")
        #else
        let app = launchReview()
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for name in ["Working", "Updated work", "Needs input", "Needs approval", "Multiple tasks", "Stale", "Zero rate"] {
            show(name, app: app)
            let island = board.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "jindo-container-view:")).firstMatch
            XCTAssertTrue(island.waitForExistence(timeout: 5))
            island.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).press(forDuration: 1.2)
            // Widget rendering/expansion completes independently of app idleness.
            Thread.sleep(forTimeInterval: 2)
            let expectedTitle = (name == "Multiple tasks" ? "Create cross-platform UI polish for the account cards" : "Create cross-platform UI polish")
            let title = board.staticTexts[expectedTitle].firstMatch
            let exists = title.waitForExistence(timeout: 5)
            capture("Native expanded island — " + name, board)
            XCTAssertTrue(exists)
            let label = name == "Stale" ? "Last known state" : name == "Needs input" || name == "Needs approval" ? name : name == "Updated work" ? "Thinking" : "Using a tool"
            let status = board.staticTexts[label].firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            XCTAssertLessThan(status.frame.height, 30, "Status must stay horizontal")
            XCTAssertLessThan(title.frame.height, 30, "The compact Island keeps its thread on one line")
            XCTAssertGreaterThan(title.frame.width, 200)
            assertIslandTitleIsVisible(title.frame, screenWidth: board.frame.width)
            if name == "Working" || name == "Updated work" || name == "Multiple tasks" {
                let metrics = board.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "tok/min")).firstMatch
                let context = board.staticTexts[name == "Updated work" ? "72% context" : "64% context"].firstMatch
                for element in [metrics, context] {
                    XCTAssertTrue(element.exists)
                    // This host clips bottom-region content about 14 points
                    // before the outer accessibility frame. Reserve 2 more.
                    XCTAssertLessThanOrEqual(element.frame.maxY, island.frame.maxY - 16,
                        "Metrics must fit inside the visible Island, not merely exist in accessibility")
                    assertIslandTitleIsVisible(element.frame, screenWidth: board.frame.width, threshold: 150)
                }
                if name == "Multiple tasks" {
                    let others = board.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Showing 1 of 15")).firstMatch
                    XCTAssertTrue(others.exists)
                    XCTAssertLessThan(others.frame.midY, status.frame.minY, "Task position belongs in the header, away from task metrics")
                    assertIslandTitleIsVisible(others.frame, screenWidth: board.frame.width, threshold: 150)
                }
            }
            if name == "Zero rate" || name == "Stale" {
                XCTAssertEqual(board.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "tok/min")).count, 0)
            }
        }
        #endif
    }
    @MainActor func testNativeLockScreenCard() throws {
        #if !targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["COMPANION_LIVE_LAYOUT_IPHONE12"] == "1" else {
            throw XCTSkip("iPhone 12 device review requires its dedicated run plan.")
        }
        #endif
        let app = launchReview()
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for name in ["Working", "Updated work", "Needs approval", "Multiple tasks", "Short task", "Sleep tool", "Stale"] {
            show(name, app: app)
            let card = board.otherElements.matching(identifier: "activity-content-view")
                .containing(NSPredicate(format: "label == %@", "George’s M4 Mac Mini")).firstMatch
            for _ in 0..<3 {
                board.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01)).press(forDuration: 0.1,
                    thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)))
                if card.waitForExistence(timeout: 3) { break }
                board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 0.1,
                    thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
                if card.waitForExistence(timeout: 3) { break }
            }
            let exists = card.exists
            let allow = board.buttons.matching(identifier: "swipe-action-button-identifier")
                .matching(NSPredicate(format: "label IN %@", ["Allow", "Always Allow"])).firstMatch
            if exists, allow.exists { allow.tap() }
            Thread.sleep(forTimeInterval: 2)
            #if targetEnvironment(simulator)
            capture("Simulator native Lock Screen — " + name, board)
            #else
            capture("iPhone 12 native Lock Screen — " + name, board)
            #endif
            XCTAssertTrue(exists)
            let expectedTitle = (name == "Multiple tasks" ? "Create cross-platform UI polish for the account cards" : "Create cross-platform UI polish")
            let actualTitle = name == "Short task" ? "UI" : name == "Sleep tool" ? "Test sleep tool call" : expectedTitle
            let title = card.staticTexts[actualTitle].firstMatch
            XCTAssertTrue(title.exists)
            assertIslandTitleIsVisible(title.frame, screenWidth: board.frame.width)
            let label = name == "Stale" ? "Last known state" : name == "Needs approval" ? name : name == "Updated work" ? "Thinking" : "Using a tool"
            let status = card.staticTexts[label].firstMatch
            XCTAssertTrue(status.exists)
            XCTAssertLessThan(status.frame.height, 30)
            if name == "Short task" || name == "Sleep tool" {
                let device = card.staticTexts["George’s M4 Mac Mini"].firstMatch
                XCTAssertLessThanOrEqual(device.frame.minY - card.staticTexts[name == "Short task" ? "Allweave" : "Computer"].firstMatch.frame.maxY, 12, "The touch target must not create a blank title row")
                let picker = card.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Showing 1 of 2")).firstMatch
                XCTAssertGreaterThanOrEqual(picker.frame.height, 44)
                XCTAssertGreaterThanOrEqual(picker.frame.width, 44)
                if name == "Sleep tool" {
                    XCTAssertEqual(card.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "tok/min")).count, 0)
                    XCTAssertEqual(card.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "% context")).count, 0)
                }
            }
        }
    }
    @MainActor func testExpandedIslandTaskButtonCyclesWithoutOpeningApp() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Uses an isolated simulator Live Activity fixture.")
        #else
        let app = launchReview()
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        show("Multiple tasks", app: app)
        let island = board.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "jindo-container-view:")).firstMatch
        XCTAssertTrue(island.waitForExistence(timeout: 5))
        island.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 2)
        for position in 1...3 {
            let button = board.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Showing \(position) of 15")).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            capture("Interactive task picker — position \(position)", board)
            if position < 3 {
                button.tap()
                XCTAssertTrue(board.staticTexts["Review selected task \(position + 1)"].waitForExistence(timeout: 5))
                let nextButton = board.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Showing \(position + 1) of 15")).firstMatch
                XCTAssertEqual(nextButton.value as? String, "Confirming selection", "Show the received next task while its six-second confirmation is still pending")
                capture("Pending task picker — position \(position + 1)", board)
                Thread.sleep(forTimeInterval: 6.2)
                XCTAssertNotEqual(app.state, .runningForeground, "Cycling must not open the app")
            }
        }
        #endif
    }
}

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
        let startedAt = Date.now.timeIntervalSince1970 - 120
        var includesSecondTask = false
        var refreshAfter: TimeInterval = 120
        func publish(_ state: String?, activity: String? = nil, rate: Int = 1200, context: Int = 32) async throws {
            let now = Date.now.timeIntervalSince1970
            var payload: [String: Any] = ["schemaVersion": 1, "id": id, "name": "Activity Test Mac", "observedAt": now, "tasks": []]
            if let state {
                payload["tasks"] = [["id": "activity-probe", "title": "Live Activity probe", "project": "TokenTach tests",
                    "state": state, "activity": activity ?? state, "tokensPerMinute": state == "running" ? rate : 0,
                    "contextPercent": context, "hasTokenObservation": true, "startedAt": startedAt,
                    "observedAt": now, "totalTokens": 100, "agentCount": 0, "eventAt": now]]
                if includesSecondTask {
                    var tasks = payload["tasks"] as! [[String: Any]]
                    tasks.append(["id": "activity-probe-second", "title": "Second activity probe", "project": "Selection tests",
                        "state": "running", "activity": "Using a tool", "tokensPerMinute": 4800,
                        "contextPercent": 64, "hasTokenObservation": true, "startedAt": startedAt + 60,
                        "observedAt": now, "totalTokens": 200, "agentCount": 0, "eventAt": now])
                    payload["tasks"] = tasks
                }
            }
            let data = try JSONSerialization.data(withJSONObject: payload)
            refreshAfter = try await publishRelayFixture(data, on: socket, base: base, id: id, publisher: publisher) ?? 120
        }
        try await publish(nil)
        let app = XCUIApplication()
        #if !targetEnvironment(simulator)
        addTeardownBlock { @MainActor in
            app.terminate(); app.launchArguments = []; app.launch()
        }
        #endif
        app.launchArguments = ["-companionUITest", "-companionResetUITestLinks"]
        let localStart = ProcessInfo.processInfo.environment["COMPANION_LOCAL_LIVE_START_TEST"] == "1"
        app.launchEnvironment["COMPANION_ACTIVITY_TEST_MAC_ID"] = id
        app.launchEnvironment["COMPANION_TEST_CLIPBOARD"] = "codexgauge://view?server=https%3A%2F%2Fcodexgauge-relay-dev.north-wolf-labs.workers.dev&id=\(id)#\(reader)"
        app.launch()
        app.buttons["Link a Mac"].firstMatch.tap()
        let paste = app.buttons["companion.pasteLink"]
        if !paste.waitForExistence(timeout: 5) {
            // An unrelated phone banner can cover the first tap.
            app.buttons["Link a Mac"].firstMatch.tap()
        }
        XCTAssertTrue(paste.waitForExistence(timeout: 5)); paste.tap()
        XCTAssertTrue(paste.waitForNonExistence(timeout: 10), app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        app.buttons["Settings"].tap()
        // Current Settings exposes alert preferences, not the former diagnostic
        // button. Obtain permission through the real preference flow.
        let completed = app.switches["Task completed"].switches.firstMatch
        if !completed.isHittable { app.swipeUp() }
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        let completedWasEnabled = completed.value as? String == "1"
        if completed.value as? String != "1" { completed.tap() }
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var surface: XCUIElement {
            let cover = board.windows["SBCoverSheetWindow"].firstMatch
            return cover.exists ? cover : board.otherElements["Home screen icons"].firstMatch
        }
        if board.alerts.buttons["Allow"].waitForExistence(timeout: 3) { board.alerts.buttons["Allow"].tap() }
        let follow = app.switches["Follow active tasks"].switches.firstMatch
        if !follow.isHittable { app.swipeUp() }
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        let followWasEnabled = follow.value as? String == "1"
        if follow.value as? String != "1" { follow.tap() }
        app.buttons["Done"].tap()
        addTeardownBlock { @MainActor in
            // The lifecycle check can finish with a task sheet or the system
            // cover sheet open. Relaunch the isolated test session at its root
            // before restoring preferences; preserve its link until feed cleanup.
            app.terminate(); app.launchArguments = ["-companionUITest"]; app.launch()
            app.buttons["Settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            let restoredCompleted = app.switches["Task completed"].switches.firstMatch
            if !restoredCompleted.isHittable { app.swipeUp() }
            if (restoredCompleted.value as? String == "1") != completedWasEnabled { restoredCompleted.tap() }
            let restoredFollow = app.switches["Follow active tasks"].switches.firstMatch
            if !restoredFollow.isHittable { app.swipeUp() }
            if (restoredFollow.value as? String == "1") != followWasEnabled { restoredFollow.tap() }
            app.buttons["Done"].tap()
        }
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
        XCTAssertTrue(registered, "The phone must register its own APNs identity before the background lifecycle check.")
        if localStart { try await publish("running"); try await Task.sleep(for: .seconds(3)) }
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        if !localStart { try await publish("running") }
        try await Task.sleep(for: .seconds(10))
        // Dynamic Island chooses which concurrent activity to expand. Assert
        // against the specific Lock Screen card instead of its screen position.
        // The physical phone can have other Macs' activities in Dynamic Island.
        // Target this fixture's native Lock Screen card, never an ordinary alert.
        let card = board.otherElements.matching(identifier: "activity-content-view")
            .containing(NSPredicate(format: "label == %@", "Activity Test Mac")).firstMatch
        XCUIDevice.shared.press(.home)
        for _ in 0..<3 {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01)).press(forDuration: 0.1,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)))
            if card.waitForExistence(timeout: 3) { break }
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 0.1,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
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
        XCTAssertTrue(card.staticTexts["32% context"].exists)
        XCTAssertTrue(card.staticTexts["1.2K tok/min"].exists)
        // Verify a metrics-only update and a phase update while the app remains
        // suspended. A ticking system timer does not prove remote delivery.
        try await publish("running", activity: "Thinking", rate: 2400, context: 48)
        if !card.staticTexts["48% context"].waitForExistence(timeout: 3) {
            // APNs may defer priority 5. Follow the relay's one-shot deadline,
            // just like the adaptive Mac, rather than polling every five seconds.
            try await Task.sleep(for: .seconds(refreshAfter + 1))
            try await publish("running", activity: "Thinking", rate: 2400, context: 48)
        }
        XCTAssertTrue(card.staticTexts["48% context"].waitForExistence(timeout: 25), "Background delivery must refresh context.")
        XCTAssertTrue(card.staticTexts["2.4K tok/min"].exists, "Background delivery must refresh token rate.")
        XCTAssertTrue(card.staticTexts["Thinking"].exists, "Background delivery must refresh task phase.")
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningBackgroundSuspended)
        let metrics = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        metrics.name = "Remote Live Activity background metrics and phase"; metrics.lifetime = .keepAlways; add(metrics)
        // A routine metrics-only publication uses the replaceable, lower-cost
        // delivery path. Wait beyond its ordinary rate limit before publishing.
        try await Task.sleep(for: .seconds(61))
        try await publish("running", activity: "Thinking", rate: 3600, context: 55)
        if !card.staticTexts["55% context"].waitForExistence(timeout: 3) {
            try await Task.sleep(for: .seconds(refreshAfter + 1))
            try await publish("running", activity: "Thinking", rate: 3600, context: 55)
        }
        XCTAssertTrue(card.staticTexts["55% context"].waitForExistence(timeout: 25))
        XCTAssertTrue(card.staticTexts["3.6K tok/min"].exists)
        includesSecondTask = true
        try await publish("running", activity: "Thinking", rate: 3600, context: 55)
        let picker = card.buttons["live.taskPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 25))
        picker.tap()
        XCTAssertTrue(card.staticTexts["Second activity probe"].waitForExistence(timeout: 10))
        XCTAssertTrue(card.staticTexts["64% context"].exists)
        XCTAssertTrue(card.staticTexts["4.8K tok/min"].exists)
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningBackgroundSuspended)
        let confirmed = NSPredicate(format: "value == %@", "Selection confirmed")
        for _ in 0..<75 {
            if confirmed.evaluate(with: picker) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(confirmed.evaluate(with: picker))
        let selection = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        selection.name = "Remote Live Activity selected second task"; selection.lifetime = .keepAlways; add(selection)
        picker.tap()
        XCTAssertTrue(card.staticTexts["Live Activity probe"].waitForExistence(timeout: 10))
        for _ in 0..<75 {
            if confirmed.evaluate(with: picker) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(confirmed.evaluate(with: picker))
        includesSecondTask = false
        try await publish("needsApproval")
        let waiting = card.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Needs approval")).firstMatch
        let updated = waiting.waitForExistence(timeout: 20)
        if !updated {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01)).press(forDuration: 0.1,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)))
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
        // Unlike the real Mac's reader task, this synthetic publisher advances
        // only when publish() is called. Answer the newly opened viewer's refresh
        // even if the feed hibernated while the system launched the app.
        try await publish("needsApproval")
        XCTAssertTrue(app.staticTexts["Needs approval"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Approve"].exists)
        XCTAssertFalse(app.staticTexts["Collecting live activity…"].exists)
        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "Live Activity opens read-only task"; detail.lifetime = .keepAlways; add(detail)
        XCUIDevice.shared.press(.home)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01)).press(forDuration: 0.1,
            thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)))
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        try await publish("completed")
        for _ in 0..<15 {
            if !card.exists { break }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertTrue(!card.exists, "Completion must remove the card on delivery, without the former one-minute retention.")
        let completedShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        completedShot.name = "Completed task — activity removed"; completedShot.lifetime = .keepAlways; add(completedShot)
        if localStart { app.activate() }
        try await publish("running")
        if localStart {
            try await Task.sleep(for: .seconds(3))
            XCUIDevice.shared.press(.home)
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01)).press(forDuration: 0.1,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)))
        }
        XCTAssertTrue(card.waitForExistence(timeout: 15), "A later active task can start a new activity.")
        app.activate()
        try await publish(nil)
        XCUIDevice.shared.press(.home)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01)).press(forDuration: 0.1,
            thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)))
        for _ in 0..<15 {
            if !card.exists { break }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertFalse(card.exists, "An empty task snapshot must remove the entire activity.")
        let emptyShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        emptyShot.name = "No active tasks — no activity card"; emptyShot.lifetime = .keepAlways; add(emptyShot)
    }
}

/// Explicitly authorized review of the owner's existing Mac on the iPhone 12.
/// Uses normal storage and leaves the reviewed connection ready for the owner.
final class CompanionPhoneReviewUITests: XCTestCase {
    @MainActor func testExistingConnectionLiveActivity() throws {
        guard ProcessInfo.processInfo.environment["COMPANION_AUTHORIZED_PHONE_REVIEW"] == "1" else {
            throw XCTSkip("Requires authorization to review the saved real connection.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-companionInspectLiveActivities"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["Refine account card"].waitForExistence(timeout: 25))
        let tasks = XCTAttachment(screenshot: app.screenshot())
        tasks.name = "Normal connection — actual active tasks"; tasks.lifetime = .keepAlways; add(tasks)
        app.buttons["Settings"].tap()
        let follow = app.switches["Follow active tasks"].switches.firstMatch
        if !follow.isHittable { app.swipeUp() }
        XCTAssertEqual(follow.value as? String, "1")
        app.buttons["Done"].tap()
        XCUIDevice.shared.press(.home)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let home = board.otherElements["Home screen icons"].firstMatch
        home.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01)).press(forDuration: 0.1,
            thenDragTo: home.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.8)))
        let card = board.otherElements.matching(identifier: "activity-content-view")
            .containing(NSPredicate(format: "label CONTAINS %@", "M4 Mac Mini")).firstMatch
        let appeared = card.waitForExistence(timeout: 20)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "Normal connection — actual Lock Screen"; image.lifetime = .keepAlways; add(image)
        XCTAssertTrue(appeared, "The saved real connection must show its active task card without a fixture or forced-start flag.")
        let nativeTree = XCTAttachment(string: card.debugDescription)
        nativeTree.name = "Normal connection — native card accessibility"; nativeTree.lifetime = .keepAlways; add(nativeTree)
        // Stay backgrounded through several publisher batches and capture the
        // real card again. The separate fixture test asserts exact metric changes.
        Thread.sleep(forTimeInterval: 35)
        XCTAssertTrue(card.exists, "The normal card must survive background update delivery.")
        let updated = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        updated.name = "Normal connection — after background updates"; updated.lifetime = .keepAlways; add(updated)
        app.activate()
    }

    @MainActor func testAuthorizedPhoneConnection() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The authorized connection review belongs on the iPhone 12.")
        #else
        guard ProcessInfo.processInfo.environment["COMPANION_AUTHORIZED_PHONE_REVIEW"] == "1",
              let text = ProcessInfo.processInfo.environment["COMPANION_REVIEW_LINK"],
              let link = URL(string: text), link.scheme == "codexgauge", link.host == "view" else {
            throw XCTSkip("Requires the owner's authorized local pairing link.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []; app.launch()
        app.open(link)
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 15))
        let device = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "M4 Mac Mini")).firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 25), "The sandboxed Mac must supply its fresh feed.")
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        capture("Authorized Mac connection — Overview")
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(device.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Current turn elapsed")).firstMatch.exists)
        capture("Authorized Mac connection — current task timers")
        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["companion.activityDevice"].firstMatch.waitForExistence(timeout: 10))
        capture("Authorized Mac connection — Activity")
        app.tabBars.buttons["Overview"].tap()
        if ProcessInfo.processInfo.environment["COMPANION_RESTORE_COMPLETED_ALERTS_OFF"] == "1" {
            // This review's first run recorded the owner's completed-alert
            // preference as off. Restore that exact baseline after delivery tests.
            app.buttons["Settings"].tap()
            let completed = app.switches["Task completed"].switches.firstMatch
            if !completed.isHittable { app.swipeUp() }
            if completed.value as? String == "1" { completed.tap() }
            XCTAssertEqual(completed.value as? String, "0")
            XCTAssertFalse(app.staticTexts["Off"].exists)
            XCTAssertFalse(app.buttons["Notification diagnostics"].exists)
            app.buttons["Done"].tap()
        }
        #endif
    }
}
