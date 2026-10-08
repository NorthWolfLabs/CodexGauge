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
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + " hierarchy"; tree.lifetime = .keepAlways; add(tree)
    }
    @MainActor private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.exists)
    }
    @MainActor private func account(_ title: String, _ app: XCUIApplication) {
        let activity = app.buttons["companion.activityScopeSelector"]
        let isActivity = activity.exists
        let picker = isActivity ? activity : app.buttons["companion.accountSelector"]
        for _ in 0..<6 where !picker.isHittable { app.swipeDown() }
        let value = picker.staticTexts.allElementsBoundByIndex.last ?? picker
        fitInViewport(value, app)
        let frame = value.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
        let choice = isActivity && title != "All accounts"
            ? app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + " · ")).firstMatch
            : app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        choice.tap()
    }
    @MainActor private func fitInViewport(_ element: XCUIElement, _ app: XCUIApplication) {
        let top = app.navigationBars.firstMatch.frame.maxY + 8
        let bottom = app.tabBars.firstMatch.frame.minY - 8
        for _ in 0..<12 {
            let frame = element.frame
            let delta: CGFloat
            if frame.minY < top { delta = min(180, max(32, top - frame.minY + 8)) }
            else if frame.maxY > bottom { delta = max(-180, min(-32, bottom - frame.maxY - 8)) }
            else { break }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = app.frame.width / 2
            let y = (top + bottom) / 2 - app.frame.minY
            origin.withOffset(CGVector(dx: x, dy: y)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: y + delta)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertGreaterThanOrEqual(element.frame.minY, top)
        XCTAssertLessThanOrEqual(element.frame.maxY, bottom)
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
        fitInViewport(target, app)
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
        account("sam@example.com", app)
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
        reveal(app.staticTexts["No token history"].firstMatch, app)
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
        XCTAssertFalse(app.buttons["companion.activityScopeSelector"].exists)
        XCTAssertEqual(app.staticTexts["companion.chart.value"].label, "200")
        shot("Second account revoked — remaining identity retained", app)
    }

    @MainActor func testAccountAttachedToAllowanceAndDeviceScopedActivity() {
        let app = launch()
        let identity = app.staticTexts["companion.accountIdentity"]
        let weekly = app.staticTexts["Weekly"].firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        XCTAssertTrue(weekly.exists)
        XCTAssertLessThan(weekly.frame.maxY, identity.frame.minY)
        XCTAssertFalse(app.staticTexts["Device · MacBook Pro"].exists)
        XCTAssertFalse(app.staticTexts["Account balances"].exists)
        XCTAssertTrue(app.staticTexts["Limit resets"].exists)
        XCTAssertLessThan(app.staticTexts["Limit resets"].frame.maxY, identity.frame.minY)
        shot("Overview — allowances and balances followed by account identity", app)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["MacBook Pro"].exists)
        XCTAssertFalse(app.staticTexts["Device · MacBook Pro"].exists)
        shot("Tasks — computer names retained", app)
        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.buttons["companion.activityScopeSelector"].exists)
        account("alex@example.com", app)
        range("90 days", app)
        XCTAssertTrue(app.otherElements["companion.accountChart"].exists)
        shot("Activity — same account multiple devices 90-day line", app)
        app.buttons["companion.activityScopeSelector"].tap()
        XCTAssertTrue(app.buttons["alex@example.com · MacBook Pro"].exists)
        XCTAssertTrue(app.buttons["alex@example.com · Mac mini"].exists)
        app.buttons["alex@example.com · Mac mini"].tap()
        shot("Activity — selected Mac mini provenance", app)
    }
    @MainActor func testSingleDeviceHidesActivitySelectorAndEmptyHistoryStaysHonest() {
        let app = launch(["-companionSingleDeviceDemo", "-companionEmptyHistoryDemo"])
        XCTAssertTrue(app.staticTexts["companion.accountIdentity"].waitForExistence(timeout: 5))
        shot("Single device — compact Overview allowance", app)
        app.tabBars.buttons["Activity"].tap()
        XCTAssertFalse(app.buttons["companion.activityScopeSelector"].exists)
        XCTAssertTrue(app.staticTexts["No token history"].exists)
        XCTAssertFalse(app.staticTexts["companion.chart.value"].exists)
        shot("Single device — no selector and honest empty activity", app)
    }

    @MainActor func testEmptyHistoryHeadingWrapsAtAX3AndAX5() {
        for (size, argument) in [("AX3", "-companionLargeType"), ("AX5", "-companionMaximumType")] {
            let app = launch(["-companionSingleDeviceDemo", "-companionEmptyHistoryDemo", argument])
            app.tabBars.buttons["Activity"].tap()
            let title = app.staticTexts["No token history"].firstMatch
            reveal(title, app)
            fitInViewport(title, app)
            XCTAssertFalse(app.staticTexts["companion.chart.value"].exists)
            shot("Empty history — \(size) title wraps", app)
            let description = app.staticTexts["Daily activity will appear when Codex provides it."].firstMatch
            reveal(description, app)
            fitInViewport(description, app)
            XCTAssertTrue(description.isHittable)
            shot("Empty history — \(size) description reachable", app)
            range("7 days", app)
            reveal(title, app)
            fitInViewport(title, app)
            XCTAssertTrue(title.exists)
            XCTAssertFalse(app.staticTexts["companion.chart.value"].exists)
            shot("Empty history — \(size) range remains usable", app)
            app.terminate()
        }
    }

    @MainActor func testCreditFormattingAndLongRangeLines() {
        let app = launch(["-companionSingleDeviceDemo"])
        let credits = app.staticTexts["Credits available, 250"]
        reveal(credits, app)
        XCTAssertFalse(app.staticTexts["Credits available, 250.0000000000"].exists)
        shot("Whole credit balance — trailing zeros removed", app)
        app.tabBars.buttons["Activity"].tap()
        for period in ["90 days", "1 year", "All"] {
            range(period, app)
            let chart = app.otherElements["companion.accountChart"]
            reveal(chart, app)
            fitInViewport(chart, app)
            XCTAssertTrue(app.staticTexts["companion.chart.value"].exists)
            shot("Activity — \(period) line chart", app)
        }
    }

    @MainActor func testSingleObservationLineInDarkMode() {
        let previousAppearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = previousAppearance }
        let app = launch(["-companionSingleDeviceDemo", "-companionSinglePointDemo"])
        XCUIDevice.shared.appearance = .dark
        Thread.sleep(forTimeInterval: 1)
        app.tabBars.buttons["Activity"].tap()
        range("90 days", app)
        XCTAssertTrue(app.staticTexts["companion.chart.value"].exists)
        XCTAssertFalse(app.staticTexts["No token history"].exists)
        app.swipeUp()
        shot("Dark Activity — one observed day remains visible", app)
    }

    @MainActor func testAccountCardLightDarkAndAccessibilitySizes() {
        let previousAppearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = previousAppearance }
        let requestedAppearance = ProcessInfo.processInfo.environment["COMPANION_REVIEW_APPEARANCE"]
        for (mode, appearance) in [("Light", XCUIDevice.Appearance.light), ("Dark", XCUIDevice.Appearance.dark)] where requestedAppearance == nil || requestedAppearance == mode {
            for (size, arguments) in [("Standard", [String]()), ("AX3", ["-companionLargeType"]), ("AX5", ["-companionMaximumType"])] {
                let app = launch(arguments)
                XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 10))
                XCUIDevice.shared.appearance = appearance
                Thread.sleep(forTimeInterval: 1)
                shot("Account card \(mode) \(size) — allowance windows", app)
                let identity = app.staticTexts["companion.accountIdentity"].firstMatch
                for _ in 0..<6 where !identity.exists { app.swipeUp() }
                XCTAssertTrue(identity.exists); fitInViewport(identity, app)
                shot("Account card \(mode) \(size) — secondary identity", app)
                let resets = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Limit resets,")).firstMatch
                for _ in 0..<6 where !resets.exists { app.swipeUp() }
                XCTAssertTrue(resets.exists); fitInViewport(resets, app)
                let credits = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Credits available,")).firstMatch
                for _ in 0..<6 where !credits.exists { app.swipeUp() }
                XCTAssertTrue(credits.exists); fitInViewport(credits, app)
                XCTAssertFalse(app.staticTexts["Account balances"].exists)
                shot("Account card \(mode) \(size) — resets and credits", app)
                if size == "Standard" {
                    for _ in 0..<3 { app.swipeDown() }
                    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "percent remaining")).firstMatch.tap()
                    XCTAssertTrue(app.navigationBars["Limits"].waitForExistence(timeout: 5))
                    shot("Account card \(mode) — Limits detail", app)
                }
                app.terminate()
            }
        }
    }

}
