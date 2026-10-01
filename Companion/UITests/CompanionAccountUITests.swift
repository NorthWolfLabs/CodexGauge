import XCTest

final class CompanionAccountUITests: XCTestCase {
    @MainActor private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-companionDemo", "-companionUITest", "-companionResetUITestLinks"] + arguments
        app.launch()
        return app
    }
    @MainActor private func shot(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.exists)
    }
    @MainActor private func account(_ title: String, _ app: XCUIApplication) {
        for _ in 0..<6 where !app.buttons["companion.accountSelector"].isHittable { app.swipeDown() }
        app.buttons["companion.accountSelector"].tap()
        app.buttons[title].firstMatch.tap()
    }
    @MainActor private func range(_ title: String, _ app: XCUIApplication) {
        let picker = app.buttons["companion.chart.range"]
        reveal(picker, app)
        // At accessibility text sizes the picker frame includes its stacked
        // label. Activate the visible selected value, not that combined center.
        let value = picker.staticTexts.firstMatch
        let target = value.exists ? value : picker
        let top = app.navigationBars.firstMatch.frame.maxY + 8
        let bottom = app.tabBars.firstMatch.frame.minY - 8
        for _ in 0..<6 {
            if target.frame.minY < top { app.swipeDown() }
            else if target.frame.maxY > bottom { app.swipeUp() }
            else { break }
        }
        let frame = target.frame
        XCTAssertGreaterThanOrEqual(frame.minY, top)
        XCTAssertLessThanOrEqual(frame.maxY, bottom)
        // The retained failing tap event used (45,57) despite the selected
        // value's actual frame around y692. Derive a bounded visible point.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
        let choice = app.buttons[title].firstMatch
        let opened = choice.waitForExistence(timeout: 3)
        if !opened {
            shot("Range menu did not open", app)
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "Range menu failure hierarchy"; tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertTrue(opened)
        choice.tap()
    }
    @MainActor func testTwoAccountsFilterOverviewAndActivityAndOfferCombinedTotals() {
        let app = launch(["-companionMultiAccountDemo"])
        XCTAssertTrue(app.staticTexts["alex@example.com"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["companion.accountSelector"].exists)
        reveal(app.staticTexts["Build the iPhone companion"], app)
        XCTAssertFalse(app.staticTexts["Run the integration checks"].exists)
        shot("Two accounts — first account overview", app)
        account("sam@example.com", app)
        reveal(app.staticTexts["Run the integration checks"], app)
        XCTAssertFalse(app.staticTexts["Build the iPhone companion"].exists)
        shot("Two accounts — second account overview", app)
        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.staticTexts["sam@example.com"].exists)
        range("Today", app)
        XCTAssertEqual(app.staticTexts["companion.chart.value"].label, "10")
        account("alex@example.com", app)
        let first = app.staticTexts["companion.chart.value"].label
        XCTAssertEqual(first, "188,947")
        shot("First account — today activity", app)
        account("All accounts", app)
        XCTAssertTrue(app.staticTexts["All accounts"].exists)
        XCTAssertEqual(app.staticTexts["companion.chart.value"].label, "188,957")
        shot("Combined account activity — no duplicate Mac sum", app)
        for period in ["7 days", "30 days", "90 days", "1 year", "All"] {
            range(period, app)
            XCTAssertTrue(app.staticTexts["companion.chart.value"].exists)
        }
        shot("All available activity", app)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["Build the iPhone companion"].exists)
        XCTAssertTrue(app.staticTexts["Run the integration checks"].exists)
        shot("Task card hierarchy — two Macs", app)
    }
    @MainActor func testSingleAccountKeepsIdentityAndHidesSelector() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["alex@example.com"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["companion.accountSelector"].exists)
        shot("Single account — visible identity", app)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["CodexGauge · gpt-6.1-sol"].exists)
        shot("Native running task cards", app)
        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.staticTexts["alex@example.com"].exists)
        XCTAssertFalse(app.buttons["companion.accountSelector"].exists)
        range("All", app)
        shot("Single account — all observed history", app)
    }
    @MainActor func testMissingIdentityStaleTodayAndLargeTextStayHonest() {
        let app = launch(["-companionUnknownAccountDemo", "-companionStaleAccountDemo", "-companionLargeType"])
        XCTAssertTrue(app.staticTexts["Account identity unavailable"].waitForExistence(timeout: 5))
        shot("Missing identity — large text", app)
        app.tabBars.buttons["Tasks"].tap()
        reveal(app.staticTexts["Last seen: working"].firstMatch, app)
        let elapsed = app.staticTexts["0:05:18"].firstMatch
        reveal(elapsed, app)
        XCTAssertTrue(elapsed.exists)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(elapsed.exists, "Elapsed stays at the actual last observation")
        shot("Stale task card — large text frozen elapsed", app)
        app.tabBars.buttons["Activity"].tap()
        app.swipeUp()
        range("Today", app)
        XCTAssertTrue(app.staticTexts["No token history"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["companion.chart.value"].exists)
        shot("Stale Today — no invented current day", app)
        range("7 days", app)
        XCTAssertTrue(app.staticTexts["companion.chart.value"].exists)
        app.swipeUp()
        shot("Large text — readable chart axes and wrapped summary", app)
    }
    @MainActor func testRevokingOneOfTwoAccountsRestoresTheRemainingIdentityAfterAllSelection() async throws {
        continueAfterFailure = false
        let first = try await AcceptanceFeed.create(name: "First Account Mac")
        let second = try await AcceptanceFeed.create(name: "Second Account Mac")
        addTeardownBlock { try await first.delete(); try await second.delete() }
        try await first.publish(accountID: "first-account", email: "first@example.com")
        try await second.publish(accountID: "second-account", email: "second@example.com")
        let app = XCUIApplication()
        app.launchArguments = ["-companionUITest", "-companionResetUITestLinks"]
        app.launch()
        app.launchArguments = ["-companionUITest"]
        app.open(URL(string: first.viewingLink())!)
        XCTAssertTrue(app.staticTexts["first@example.com"].waitForExistence(timeout: 10))
        app.open(URL(string: second.viewingLink())!)
        XCTAssertTrue(app.buttons["companion.accountSelector"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Activity"].tap()
        account("All accounts", app)
        range("Today", app)
        XCTAssertEqual(app.staticTexts["companion.chart.value"].label, "400")
        shot("Two real fixture feeds — all-account total", app)
        try await second.rotate()
        XCTAssertTrue(app.staticTexts["first@example.com"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["companion.accountSelector"].exists)
        XCTAssertEqual(app.staticTexts["companion.chart.value"].label, "200")
        shot("Second account revoked — remaining identity retained", app)
    }

}
