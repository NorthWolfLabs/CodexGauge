//
//  CodexGaugeUITests.swift
//  CodexGaugeUITests
//
//  Created by George Curtis on 8/21/26.
//

import XCTest

final class CodexGaugeUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    @MainActor
    func testMenuBarAgentLaunchesWithoutAWindow() throws {
        let app = XCUIApplication()
        app.launch()
        let launched = app.wait(for: .runningForeground, timeout: 5) || app.state == .runningBackground
        XCTAssertTrue(launched)
        XCTAssertEqual(app.windows.count, 0, "CodexGauge should remain a menu-bar-only agent at launch")
    }

    @MainActor
    func testPopoverPresentsLoadingAndLoadedConversationStates() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestDemo", "-uiTestLoading"]
        app.launch()

        let statusItem = app.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let loading = app.descendants(matching: .any)["conversations-loading"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        capture("00-conversations-loading")
        app.terminate()

        let loadedApp = XCUIApplication()
        loadedApp.launchArguments += ["-uiTestDemo"]
        loadedApp.launch()

        let loadedStatusItem = loadedApp.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(loadedStatusItem.waitForExistence(timeout: 5))
        loadedStatusItem.click()
        let liveTask = loadedApp.descendants(matching: .any)["live-conversation-disclosure"].firstMatch
        XCTAssertTrue(liveTask.waitForExistence(timeout: 3))
        XCTAssertFalse(loadedApp.descendants(matching: .any)["conversations-loading"].firstMatch.exists)
        capture("00b-conversations-loaded")
    }

    @MainActor
    func testStatusItemSupportsPopoverAndContextMenu() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestDemo", "-quotaNotifications", "YES"]
        app.launch()

        let statusItem = app.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))

        statusItem.click()
        let panel = app.descendants(matching: .any).matching(identifier: "gauge-panel").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3), "Left-click should present the telemetry popover")
        XCTAssertFalse(app.buttons["Refresh allowances"].exists)
        capture("01-popover")

        let more = app.buttons["popover-more-button"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.click()
        XCTAssertTrue(app.menuItems["Settings…"].waitForExistence(timeout: 2), "The More menu should remain open on its first click")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        let liveTask = panel.descendants(matching: .any)["live-conversation-disclosure"].firstMatch
        XCTAssertTrue(liveTask.waitForExistence(timeout: 3))
        liveTask.click()
        XCTAssertEqual(liveTask.value as? String, "Expanded")
        capture("01a-popover-live-details")
        liveTask.click()

        let activity = panel.descendants(matching: .any)["popover-activity-disclosure"]
        XCTAssertTrue(activity.waitForExistence(timeout: 3))
        activity.click()
        XCTAssertEqual(activity.value as? String, "Expanded")
        Thread.sleep(forTimeInterval: 0.25)
        let panelScrollView = panel.scrollViews.firstMatch
        XCTAssertTrue(panelScrollView.exists)
        panelScrollView.swipeUp()
        XCTAssertTrue(panel.descendants(matching: .any)["popover-activity-chart"].firstMatch.exists)
        capture("01b-popover-activity")

        statusItem.rightClick()
        XCTAssertTrue(app.menuItems["Quit CodexGauge"].waitForExistence(timeout: 3), "Right-click should present the native context menu")
        XCTAssertFalse(app.menuItems["Refresh"].exists)

        statusItem.menuItems["Open Dashboard…"].click()
        let dashboard = app.windows["CodexGauge"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 3), "Dashboard should open in a full native window")
        XCTAssertFalse(dashboard.buttons["Refresh allowances"].exists)
        capture("02-dashboard-overview")

        dashboard.staticTexts["Tasks"].firstMatch.click()
        XCTAssertTrue(dashboard.staticTexts["Live tasks"].waitForExistence(timeout: 3))
        capture("03-dashboard-conversations")

        dashboard.staticTexts["Activity"].firstMatch.click()
        XCTAssertTrue(dashboard.staticTexts["Token activity"].waitForExistence(timeout: 3))
        let rangePicker = dashboard.descendants(matching: .any)["activity-range-picker"].firstMatch
        XCTAssertTrue(rangePicker.waitForExistence(timeout: 2))
        let pickerSize = rangePicker.frame.size
        for range in ["Today", "30 Days", "7 Days", "1 Year", "All"] {
            let control = dashboard.descendants(matching: .any)[range].firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 2))
            control.click()
            Thread.sleep(forTimeInterval: 0.25)
            XCTAssertEqual(rangePicker.frame.width, pickerSize.width, accuracy: 1)
            XCTAssertEqual(rangePicker.frame.height, pickerSize.height, accuracy: 1)
            if range == "Today" {
                XCTAssertFalse(dashboard.descendants(matching: .any)["activity-detail-chart"].firstMatch.exists)
                XCTAssertFalse(dashboard.staticTexts["Active-day average"].exists)
                XCTAssertFalse(dashboard.staticTexts["Busiest day"].exists)
                capture("04a-dashboard-activity-today")
            }
            if range == "7 Days" {
                XCTAssertTrue(dashboard.descendants(matching: .any)["activity-detail-chart"].firstMatch.exists)
                capture("04b-dashboard-activity-week")
            }
        }
        dashboard.staticTexts["Tasks"].firstMatch.click()
        dashboard.staticTexts["Activity"].firstMatch.click()
        XCTAssertTrue(rangePicker.waitForExistence(timeout: 2))
        XCTAssertEqual(rangePicker.frame.width, pickerSize.width, accuracy: 1)
        XCTAssertEqual(rangePicker.frame.height, pickerSize.height, accuracy: 1)
        dashboard.descendants(matching: .any)["30 Days"].firstMatch.click()
        capture("04-dashboard-activity")

        dashboard.typeKey("/", modifierFlags: [.command, .shift])
        let helpWindow = app.windows["CodexGauge Help"]
        XCTAssertTrue(helpWindow.waitForExistence(timeout: 3), "Command-Question Mark should open Help")
        capture("05-help")
        helpWindow.buttons[XCUIIdentifierCloseWindow].click()

        statusItem.rightClick()
        statusItem.menuItems["Settings…"].click()
        let settingsWindow = app.windows["General"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Settings should open in a reusable native window")
        XCTAssertTrue(settingsWindow.buttons["General"].exists)
        XCTAssertTrue(settingsWindow.staticTexts["Startup"].exists, "General should be the active pane on first presentation")
        XCTAssertFalse(settingsWindow.buttons["Check again"].exists)
        capture("06-settings-general")
        let notifications = settingsWindow.buttons["Notifications"]
        XCTAssertTrue(notifications.waitForExistence(timeout: 3), "Settings panes should be available from the window toolbar")
        notifications.click()
        let notificationsWindow = app.windows["Notifications"]
        XCTAssertTrue(notificationsWindow.waitForExistence(timeout: 3))
        capture("07-settings-notifications")

        notificationsWindow.buttons[XCUIIdentifierCloseWindow].click()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Notifications"].waitForExistence(timeout: 3), "Command-Comma should reopen the same native Settings window")
        capture("07b-settings-keyboard-shortcut")

        statusItem.rightClick()
        statusItem.menuItems["CodexGauge Help"].click()
        let reopenedHelp = app.windows["CodexGauge Help"]
        XCTAssertTrue(reopenedHelp.waitForExistence(timeout: 3), "Help should open outside Settings")
        reopenedHelp.staticTexts["Privacy"].firstMatch.click()
        capture("08-help-privacy")
    }

    @MainActor
    func testTransientPopoverStateResetsAfterClosing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()

        let statusItem = app.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        var liveTask = app.descendants(matching: .any)["live-conversation-disclosure"].firstMatch
        let activity = app.descendants(matching: .any)["popover-activity-disclosure"].firstMatch
        XCTAssertTrue(liveTask.waitForExistence(timeout: 3))
        XCTAssertTrue(activity.waitForExistence(timeout: 3))
        liveTask.click()
        activity.click()
        XCTAssertEqual(liveTask.value as? String, "Expanded")
        XCTAssertEqual(activity.value as? String, "Expanded")

        statusItem.click()
        XCTAssertFalse(app.descendants(matching: .any)["gauge-panel"].firstMatch.waitForExistence(timeout: 1))
        statusItem.click()

        liveTask = app.descendants(matching: .any)["live-conversation-disclosure"].firstMatch
        let reopenedActivity = app.descendants(matching: .any)["popover-activity-disclosure"].firstMatch
        XCTAssertTrue(liveTask.waitForExistence(timeout: 3))
        XCTAssertEqual(liveTask.value as? String, "Collapsed")
        XCTAssertEqual(reopenedActivity.value as? String, "Collapsed")

        XCTAssertEqual(reopenedActivity.elementType, .button)
        XCTAssertTrue(reopenedActivity.isEnabled, "Disclosures should expose native, focusable button semantics")
    }

    @MainActor
    func testAllowanceAlertsAreOffByDefaultWithPracticalPresets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()
        let statusItem = app.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["General"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        settingsWindow.buttons["Notifications"].click()
        let notificationsWindow = app.windows["Notifications"]
        XCTAssertTrue(notificationsWindow.waitForExistence(timeout: 3))

        let toggle = notificationsWindow.descendants(matching: .any)["allowance-alerts-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        XCTAssertFalse(notificationsWindow.textFields["allowance-threshold-field"].firstMatch.exists)

        app.terminate()
        let enabledApp = XCUIApplication()
        enabledApp.launchArguments = ["-uiTestDemo", "-quotaNotifications", "YES"]
        enabledApp.launch()
        XCTAssertTrue(enabledApp.statusItems["codexgauge.statusItem"].waitForExistence(timeout: 5))
        enabledApp.typeKey(",", modifierFlags: .command)
        let enabledSettings = enabledApp.windows["General"]
        XCTAssertTrue(enabledSettings.waitForExistence(timeout: 3))
        enabledSettings.buttons["Notifications"].click()
        let enabledNotifications = enabledApp.windows["Notifications"]
        XCTAssertTrue(enabledNotifications.waitForExistence(timeout: 3))
        let firstField = enabledNotifications.textFields["allowance-threshold-field"].firstMatch
        XCTAssertTrue(firstField.waitForExistence(timeout: 2))
        let fields = enabledNotifications.textFields
            .matching(identifier: "allowance-threshold-field")
            .allElementsBoundByIndex
        XCTAssertEqual(fields.compactMap { $0.value as? String }, ["20", "10", "5"])
    }

    @MainActor
    func testAllowanceThresholdValidation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo", "-uiTestInvalidThresholds"]
        app.launch()
        let statusItem = app.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.rightClick()
        statusItem.menuItems["Settings…"].click()
        let settingsWindow = app.windows["General"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        settingsWindow.buttons["Notifications"].click()
        let notificationsWindow = app.windows["Notifications"]
        XCTAssertTrue(notificationsWindow.waitForExistence(timeout: 3))

        let threshold = notificationsWindow.textFields["allowance-threshold-field"].firstMatch
        XCTAssertTrue(threshold.waitForExistence(timeout: 2))
        let thresholdValues = notificationsWindow.textFields
            .matching(identifier: "allowance-threshold-field")
            .allElementsBoundByIndex
            .compactMap { $0.value as? String }
        XCTAssertEqual(thresholdValues, ["99", "1"])
    }

    @MainActor
    func testDeterministicDemoStatesRemainPresentable() throws {
        let cases: [([String], String)] = [
            (["-uiTestLoading"], "conversations-loading"),
            (["-uiTestEmpty"], "No local tasks found"),
            (["-uiTestStale"], "Last known data"),
            (["-uiTestOffline"], "Last known data"),
            (["-uiTestMissingHelper"], "usage-unavailable"),
            (["-uiTestSignedOut"], "usage-unavailable"),
            (["-uiTestLowAllowances"], "3%"),
            (["-uiTestOversizedValues"], "gauge-panel")
        ]

        for (arguments, expectedIdentifierOrText) in cases {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTestDemo"] + arguments
            app.launch()
            let statusItem = app.statusItems["codexgauge.statusItem"]
            XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "Missing status item for \(arguments)")
            statusItem.click()
            XCTAssertTrue(app.descendants(matching: .any)["gauge-panel"].firstMatch.waitForExistence(timeout: 3))
            let identified = app.descendants(matching: .any)[expectedIdentifierOrText].firstMatch
            let text = app.staticTexts[expectedIdentifierOrText].firstMatch
            XCTAssertTrue(
                identified.waitForExistence(timeout: 2) || text.waitForExistence(timeout: 2),
                "Missing expected state \(expectedIdentifierOrText) for \(arguments)"
            )
            if arguments.contains("-uiTestMissingHelper") || arguments.contains("-uiTestSignedOut") {
                XCTAssertFalse(app.buttons["Retry"].exists)
                XCTAssertTrue(app.buttons["Settings…"].exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testDemoSupportsAccessibilityAppearancesAndDeniedNotifications() throws {
        let appearanceArguments = [
            ["-AppleInterfaceStyle", "Dark"],
            ["-NSReduceMotion", "YES"],
            ["-NSIncreaseContrast", "YES"]
        ]
        for arguments in appearanceArguments {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTestDemo"] + arguments
            app.launch()
            let statusItem = app.statusItems["codexgauge.statusItem"]
            XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
            statusItem.click()
            XCTAssertTrue(app.descendants(matching: .any)["gauge-panel"].firstMatch.waitForExistence(timeout: 3))
            app.terminate()
        }

        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo", "-uiTestDeniedNotifications"]
        app.launch()
        let statusItem = app.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.rightClick()
        statusItem.menuItems["Settings…"].click()
        let settingsWindow = app.windows["General"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        settingsWindow.buttons["Notifications"].click()
        XCTAssertTrue(app.windows["Notifications"].staticTexts["Not allowed"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Open Notification Settings"].exists)
    }

    @MainActor
    func testZeroAndOversizedVisualizationsRemainPresentable() throws {
        for arguments in [["-uiTestZeroActivity"], ["-uiTestOversizedValues"]] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTestDemo"] + arguments
            app.launch()
            let statusItem = app.statusItems["codexgauge.statusItem"]
            XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
            statusItem.click()
            let panel = app.descendants(matching: .any)["gauge-panel"].firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 3))
            let liveTask = panel.descendants(matching: .any)["live-conversation-disclosure"].firstMatch
            XCTAssertTrue(liveTask.waitForExistence(timeout: 3))
            liveTask.click()
            let activity = panel.descendants(matching: .any)["popover-activity-disclosure"].firstMatch
            XCTAssertTrue(activity.waitForExistence(timeout: 3))
            activity.click()
            XCTAssertTrue(panel.exists)
            XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground)
            app.terminate()
        }
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
