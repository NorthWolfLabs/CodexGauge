import XCTest

final class CompanionUITests: XCTestCase {
    @MainActor func testTaskMetadataDoesNotCrushElapsedTime() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-companionDemo", "-companionTaskLayoutDemo"]
        app.launch()
        app.tabBars.buttons["Tasks"].tap()
        let row = app.descendants(matching: .any)["companion.taskRow.task1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Task metadata at standard text size"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertLessThan(row.frame.height, 130, "A short stale task must not grow into a tall card from compressed metadata.")
        let elapsed = app.staticTexts["0:05:43"].firstMatch
        XCTAssertTrue(elapsed.exists)
        XCTAssertLessThan(elapsed.frame.height, 25, "The elapsed value must remain on one line.")
        XCTAssertGreaterThan(elapsed.frame.width, 45)
    }
    @MainActor func testPairingShowsDeviceNameAndAccessExplanation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-companionDemo"]
        app.launch()
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Link a Mac"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Link a Mac"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["companion.deviceName"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Its name appears in Devices on your Mac")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Device name and paired Mac access explanation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    @MainActor func testChartsAndCredits() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-companionDemo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 10))
        for _ in 0..<3 {
            if app.staticTexts["Credits available, 250"].exists && app.staticTexts["Limit resets"].exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Credits available, 250"].exists)
        XCTAssertTrue(app.staticTexts["Limit resets"].exists)
        let credits = XCTAttachment(screenshot: app.screenshot())
        credits.name = "Available credits and resets"; credits.lifetime = .keepAlways; add(credits)
        app.tabBars.buttons["Activity"].tap()
        for period in ["7 days", "30 days", "90 days"] {
            let option = app.segmentedControls.buttons[period]
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
            XCTAssertTrue(option.isSelected)
            XCTAssertTrue(app.staticTexts["Average per observed day"].exists)
        }
        app.swipeUp()
        let accountChart = XCTAttachment(screenshot: app.screenshot())
        accountChart.name = "Account token history"; accountChart.lifetime = .keepAlways; add(accountChart)
        app.tabBars.buttons["Tasks"].tap()
        app.staticTexts["Build the iPhone companion"].tap()
        XCTAssertTrue(app.navigationBars["Task"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Collecting live activity…"].exists)
        app.swipeUp()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Task throughput chart"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    /// Opt-in placement/screenshot check for the recorded iPhone 17 Pro / iOS 27
    /// wallpaper: Calendar first, then Weather and Fitness beneath the large clock.
    /// Temporarily replaces Calendar in the editor and cancels without saving.
    /// Screenshot attachments still require visual review of WidgetKit content.
    @MainActor func testLockScreenWidgetGallery() throws {
        guard ProcessInfo.processInfo.environment["COMPANION_LOCK_WIDGET_TEST"] == "1" else {
            throw XCTSkip("Requires an authorized device for Lock Screen widget verification.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.activate() }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        if !settings.searchFields.firstMatch.exists { settings.swipeDown() }
        let search = settings.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Wallpaper")
        let wallpaper = settings.staticTexts["Wallpaper"].firstMatch
        XCTAssertTrue(wallpaper.waitForExistence(timeout: 5)); wallpaper.tap()
        let customize = settings.buttons["Customize"].firstMatch
        XCTAssertTrue(customize.waitForExistence(timeout: 5)); customize.tap()
        XCTAssertTrue(settings.buttons["Done"].waitForExistence(timeout: 5))
        let style = ProcessInfo.processInfo.environment["COMPANION_LOCK_WIDGET_STYLE"] ?? "circular"
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if style == "inline" {
            settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09)).tap()
        } else {
            settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.785)).tap()
            XCTAssertTrue(settings.buttons["TokenTach, Codex allowance"].waitForExistence(timeout: 5))
            // The system animates the widget row upward after its gallery appears.
            Thread.sleep(forTimeInterval: 1)
            board.coordinate(withNormalizedOffset: CGVector(dx: 0.078, dy: 0.30)).tap()
        }
        if style == "rectangular" {
            for _ in 0..<5 {
                if settings.cells["TokenTach"].firstMatch.exists && settings.cells["TokenTach"].firstMatch.isHittable { break }
                board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).press(forDuration: 0.1,
                    thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52)))
            }
            let row = settings.cells["TokenTach"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            let rectangular = settings.buttons.matching(NSPredicate(format: "value == %@", "Widget, Rectangular")).firstMatch
            XCTAssertTrue(rectangular.waitForExistence(timeout: 5)); rectangular.tap()
        } else if style == "inline" {
            let inline = settings.cells["TokenTach, Codex allowance, Top Widget"]
            XCTAssertTrue(inline.waitForExistence(timeout: 5)); inline.tap()
        } else {
            settings.buttons["TokenTach, Codex allowance"].tap()
        }
        Thread.sleep(forTimeInterval: 10)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Lock Screen \(ProcessInfo.processInfo.environment["COMPANION_LOCK_WIDGET_STYLE"] ?? "circular") widget"; screenshot.lifetime = .keepAlways; add(screenshot)
        if settings.buttons["close"].exists { settings.buttons["close"].tap() }
        for _ in 0..<2 {
            if settings.buttons["Cancel"].waitForExistence(timeout: 2) && settings.buttons["Cancel"].isHittable { break }
            guard settings.buttons["Sheet Grabber"].firstMatch.exists else { break }
            settings.buttons["Sheet Grabber"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)))
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(settings.buttons["Cancel"].waitForExistence(timeout: 5))
        settings.buttons["Cancel"].tap()
    }
    /// Explicitly enabled only when the owner authorizes testing a linked phone.
    /// Preserves its links and reuses a widget, or adds one to an empty Home Screen.
    @MainActor func testLinkedPhoneAndHomeScreenWidget() throws {
        guard ProcessInfo.processInfo.environment["COMPANION_PAIRED_DEVICE_TEST"] == "1" else {
            throw XCTSkip("Requires an authorized phone with a saved Mac link.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let percentages = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{1,3}%"))
        XCTAssertTrue(percentages.firstMatch.waitForExistence(timeout: 15))
        let remaining = percentages.firstMatch.label
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 15))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts[remaining].waitForExistence(timeout: 15), "The saved link must reconnect after relaunch.")
        let overview = XCTAttachment(screenshot: app.screenshot())
        overview.name = "Paired phone overview"; overview.lifetime = .keepAlways; add(overview)
        XCUIDevice.shared.press(.home)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if !board.staticTexts[remaining].waitForExistence(timeout: 5) {
            // This authorized phone has an empty Focus Home Screen. Holding its
            // empty background enters edit mode without moving any existing app.
            board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 1.5)
            let edit = board.buttons["Edit"]
            XCTAssertTrue(edit.waitForExistence(timeout: 10), board.debugDescription)
            edit.tap()
            let addWidgets = board.buttons["Add Widget"]
            XCTAssertTrue(addWidgets.waitForExistence(timeout: 5)); addWidgets.tap()
            let search = board.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap(); search.typeText("TokenTach")
            let result = board.cells["TokenTach"].firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 5)); result.tap()
            let addWidget = board.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Add Widget")).firstMatch
            XCTAssertTrue(addWidget.waitForExistence(timeout: 5)); addWidget.tap()
            let done = board.buttons["Done"]
            if done.waitForExistence(timeout: 5) { done.tap() }
        }
        XCTAssertTrue(board.staticTexts[remaining].waitForExistence(timeout: 20), "The widget must read the linked Mac's usage.")
        XCTAssertTrue(board.staticTexts["Weekly"].exists, "The compact widget title must remain readable.")
        let widget = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        widget.name = "Physical Home Screen widget"; widget.lifetime = .keepAlways; add(widget)
        app.activate()
    }

    @MainActor func testWidgetGallery() async throws {
        guard ProcessInfo.processInfo.environment["COMPANION_WIDGET_TEST"] == "1" else {
            throw XCTSkip("Home Screen widget verification is opt-in on a dedicated simulator.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        let medium = ProcessInfo.processInfo.environment["COMPANION_WIDGET_STYLE"] == "medium"
        // The extension reads the normal shared Keychain service. A demo-only
        // placeholder cannot establish that a placed widget reads live data.
        let feed = medium ? try await AcceptanceFeed.create(name: "Widget Acceptance Mac") : nil
        if let feed { try await feed.publish(remainingPercent: 63, creditBalance: "137", bankedResets: 7) }
        app.launchArguments = medium ? ["-companionUITest"] : ["-companionDemo"]
        if let feed { app.launchEnvironment["COMPANION_TEST_CLIPBOARD"] = feed.viewingLink() }
        app.launch()
        if let feed {
            app.buttons["Settings"].tap(); app.swipeDown()
            let oldRows = app.staticTexts.matching(NSPredicate(format: "label == %@", "Widget Acceptance Mac"))
            while oldRows.count > 0 {
                let count = oldRows.count
                oldRows.firstMatch.swipeLeft(); app.buttons["Remove"].firstMatch.tap()
                let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in oldRows.count < count }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 15), .completed)
            }
            addTeardownBlock { try await feed.delete() }
            app.buttons["Link a Mac"].firstMatch.tap()
            app.buttons["companion.pasteLink"].tap()
        }
        app.tabBars.buttons["Overview"].tap()
        XCTAssertTrue(app.staticTexts["83%"].waitForExistence(timeout: 10))
        if medium { XCTAssertTrue(app.staticTexts["63%"].exists) }
        XCUIDevice.shared.press(.home)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = board.icons["TokenTach"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        icon.press(forDuration: 1.5)
        let editHome = board.buttons["Edit Home Screen"]
        XCTAssertTrue(editHome.waitForExistence(timeout: 5), board.debugDescription)
        editHome.tap()
        let edit = board.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), board.debugDescription)
        edit.tap()
        let addWidgets = board.buttons["Add Widget"]
        XCTAssertTrue(addWidgets.waitForExistence(timeout: 5), board.debugDescription)
        addWidgets.tap()
        let search = board.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), board.debugDescription)
        search.tap(); search.typeText("TokenTach")
        let result = board.cells["TokenTach"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5), board.debugDescription)
        result.tap()
        if ProcessInfo.processInfo.environment["COMPANION_WIDGET_STYLE"] == "medium" {
            board.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)).press(forDuration: 0.1,
                thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45)))
            let gallery = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            gallery.name = "Medium widget gallery — credits and reset"; gallery.lifetime = .keepAlways; add(gallery)
            let tree = XCTAttachment(string: board.debugDescription)
            tree.name = "Medium widget gallery accessibility"; tree.lifetime = .keepAlways; add(tree)
            // WidgetKit may retire the rendering extension's AX process after
            // snapshotting. Inspect the retained screenshot for layout; the
            // installed image below must show the distinct live fixture values.
        }
        let addWidget = board.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Add Widget")).firstMatch
        XCTAssertTrue(addWidget.waitForExistence(timeout: 5), board.debugDescription)
        addWidget.tap()
        let done = board.buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        try await Task.sleep(for: .seconds(8))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = ProcessInfo.processInfo.environment["COMPANION_WIDGET_STYLE"] == "medium" ? "Medium Home Screen widget — credits and reset" : "Home Screen allowance widget"; screenshot.lifetime = .keepAlways; add(screenshot)
        // Automated placement pass is separate from rendered-content review:
        // the installed image must show 63%, 137 credits, and 7 banked resets.
        if medium {
            app.activate(); app.buttons["Settings"].tap(); app.swipeDown()
            let row = app.staticTexts["Widget Acceptance Mac"].firstMatch
            if row.waitForExistence(timeout: 5) {
                row.swipeLeft(); app.buttons["Remove"].firstMatch.tap()
            }
        }
    }
    @MainActor func testViewingLinkPersistsInKeychainAndReconnectsAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-companionUITest", "-companionResetUITestLinks"]
        app.launchEnvironment["COMPANION_TEST_CLIPBOARD"] = "codexgauge://view?server=http%3A%2F%2F127.0.0.1%3A8789&id=33333333-3333-4333-8333-333333333333#" + String(repeating: "b", count: 64)
        app.launch()
        app.buttons["Link a Mac"].firstMatch.tap()
        app.buttons["companion.pasteLink"].tap()
        XCTAssertTrue(app.staticTexts["83%"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["-companionUITest"]
        app.launch()
        XCTAssertTrue(app.staticTexts["83%"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 10))
    }
    @MainActor func testLiveRelayUpdatesWithoutRefreshing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-companionRelayDemo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["83%"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "83%")).count, 1)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["Live relay task"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Review approval on Mac mini"].exists)
        XCTAssertFalse(app.staticTexts["Completed follow-up ready task"].exists)
        let updates = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Live update "))
        XCTAssertTrue(updates.firstMatch.exists)
        let before = updates.firstMatch.label
        let changed = NSPredicate { _, _ in updates.firstMatch.exists && updates.firstMatch.label != before }
        expectation(for: changed, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        app.staticTexts["Live relay task"].tap()
        XCTAssertTrue(app.navigationBars["Task"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recorded tokens"].exists)
        let detailUpdates = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Live update "))
        XCTAssertTrue(detailUpdates.firstMatch.waitForExistence(timeout: 5))
        let detailBefore = detailUpdates.firstMatch.label
        expectation(for: NSPredicate { _, _ in
            detailUpdates.firstMatch.exists && detailUpdates.firstMatch.label != detailBefore
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Live local relay — two Macs"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor func testOverviewCombinesAllowancesAndGroupsActiveTasks() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-companionDemo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["83%"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "83%")).count, 1)
        let overview = XCTAttachment(screenshot: app.screenshot())
        overview.name = "Companion overview"; overview.lifetime = .keepAlways; add(overview)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["Build the iPhone companion"].exists)
        XCTAssertTrue(app.staticTexts["Review library navigation"].exists)
        XCTAssertTrue(app.staticTexts["Run the integration checks"].exists)
        XCTAssertFalse(app.staticTexts["Optimize image exports"].exists)
        XCTAssertFalse(app.buttons["Approve"].exists)
        let tasks = XCTAttachment(screenshot: app.screenshot())
        tasks.name = "Tasks by Mac"; tasks.lifetime = .keepAlways; add(tasks)
        app.staticTexts["Run the integration checks"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mac mini")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Approval requested"].exists || app.staticTexts["Needs approval"].exists)
        XCTAssertFalse(app.buttons["Approve"].exists)
    }
}

extension CompanionUITests {
    @MainActor func testRefinedNavigationPairingAndTaskSummary() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-companionDemo"]; app.launchEnvironment["COMPANION_TEST_CLIPBOARD"] = "private-malformed-sentinel"; app.launch()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Settings"].exists)
        XCTAssertFalse(app.buttons["Link a Mac"].exists)
        func capture(_ name: String) { let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot) }
        capture("Refined overview — account allowances and Mac tasks")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send test notification"].isHittable)
        capture("Settings — linked Macs and alert choices")
        app.buttons["Link a Mac"].tap()
        XCTAssertTrue(app.navigationBars["Link a Mac"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["companion.pasteLink"].exists)
        XCTAssertFalse(app.textFields["companion.viewingLink"].exists)
        XCTAssertFalse(app.textViews["companion.viewingLink"].exists)
        XCTAssertFalse(app.buttons["Link Mac"].exists)
        app.buttons["companion.pasteLink"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "That isn’t a TokenTach pairing link.")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["private-malformed-sentinel"].exists)
        capture("Paste gives a helpful error without displaying the URL")
        app.buttons["Scan QR code"].tap()
        XCTAssertTrue(app.staticTexts["QR scanning isn’t available on this device. Tap Paste instead."].waitForExistence(timeout: 5))
        capture("Pairing — explicit scan action and paste fallback")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5)); app.buttons["Done"].tap()
        let session = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "Session")).firstMatch
        if session.exists { session.tap() } else { app.staticTexts["Session"].tap() }
        XCTAssertTrue(app.navigationBars["Limits"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["companion.accountIdentity"].firstMatch.exists)
        capture("Allowance opens limits with account identity last")
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Tasks"].tap(); app.staticTexts["Build the iPhone companion"].tap()
        XCTAssertTrue(app.navigationBars["Task"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["32% context"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Current turn elapsed")).firstMatch.exists)
        capture("Task summary — context elapsed and observed phase")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Model, gpt-6.1-sol"].exists)
        capture("Task statistics — supported desktop metrics")
        let mix = app.buttons["Recorded token mix · last five minutes"]
        for _ in 0..<3 { if mix.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mix.isHittable); mix.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Input,")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Output,")).firstMatch.exists)
        capture("Task statistics — expanded recorded token mix")
        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.staticTexts["Average per observed day"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["companion.activityDevice"].firstMatch.exists)
        capture("Activity — device and account section header")
        app.swipeUp(); capture("Activity — account statistics")
    }
    @MainActor func testRefinedLargeTypeLayouts() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-companionDemo", "-companionLargeType"]; app.launch()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 10))
        var shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Large type — allowance layout"; shot.lifetime = .keepAlways; add(shot)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.navigationBars["Tasks"].waitForExistence(timeout: 5))
        let task = app.staticTexts["Build the iPhone companion"]
        for _ in 0..<3 where !task.exists { app.swipeUp() }
        XCTAssertTrue(task.waitForExistence(timeout: 5)); task.tap()
        XCTAssertTrue(app.navigationBars["Task"].waitForExistence(timeout: 5))
        shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Large type — task summary"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertFalse(app.buttons["Approve"].exists)
    }
}

extension CompanionUITests {
    @MainActor func testSettingsOmitsLayoutPreview() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-companionDemo"]; app.launch()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 10)); app.buttons["Settings"].tap()
        for _ in 0..<4 {
            XCTAssertFalse(app.buttons["Live Activity layout preview"].exists)
            app.swipeUp()
        }
        XCTAssertTrue(app.switches["Follow active tasks"].exists)
    }
    @MainActor func testAlertsStayCleanWhenOffAndKeepDisclosures() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-companionDemo", "-companionAlertsOffReview"]; app.launch()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let top = XCTAttachment(screenshot: app.screenshot()); top.name = "Alerts off — clean settings"; top.lifetime = .keepAlways; add(top)
        for _ in 0..<3 {
            XCTAssertFalse(app.staticTexts["Off"].exists)
            XCTAssertFalse(app.buttons["Notification diagnostics"].exists)
            XCTAssertFalse(app.buttons["Send test notification"].exists)
            XCTAssertFalse(app.staticTexts["Waiting for a linked Mac."].exists)
            app.swipeUp()
        }
        XCTAssertTrue(app.switches["Follow active tasks"].exists)
        for text in ["Viewing links disclose account email and grant read-only access. They cannot send instructions or approve actions on a Mac.",
                     "A Mac must be awake and running TokenTach to provide fresh data.",
                     "Shows local Codex tasks. Cloud-only Work chats and live compaction status aren’t available."] {
            XCTAssertTrue(app.staticTexts[text].exists)
        }
        let bottom = XCTAttachment(screenshot: app.screenshot()); bottom.name = "Live toggle and intact disclosures"; bottom.lifetime = .keepAlways; add(bottom)
    }
    @MainActor func testOverviewWorkingIndicatorSurvivesTabAndScrollReuse() {
        let app = XCUIApplication(); app.launchArguments = ["-companionDemo"]; app.launch()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 10))
        for iteration in 0..<4 {
            app.tabBars.buttons["Tasks"].tap()
            XCTAssertTrue(app.staticTexts["Build the iPhone companion"].waitForExistence(timeout: 5))
            app.tabBars.buttons["Overview"].tap()
            app.swipeUp()
            let title = app.staticTexts["Build the iPhone companion"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Overview working glyph after tab and scroll reuse \(iteration)"; shot.lifetime = .keepAlways; add(shot)
            app.swipeDown()
        }
    }

}
