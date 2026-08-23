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
    func testPopoverKeepsConversationSectionWhileTasksLoad() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestDemo", "-uiTestDelayedConversations"]
        app.launch()

        let statusItem = app.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let loading = app.descendants(matching: .any)["conversations-loading"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        capture("00-conversations-loading")

        let liveTask = app.descendants(matching: .any)["live-conversation-disclosure"].firstMatch
        XCTAssertTrue(liveTask.waitForExistence(timeout: 8))
        XCTAssertFalse(loading.exists)
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
        capture("01b-popover-activity")

        statusItem.rightClick()
        XCTAssertTrue(app.menuItems["Quit CodexGauge"].waitForExistence(timeout: 3), "Right-click should present the native context menu")

        statusItem.menuItems["Open Dashboard…"].click()
        let dashboard = app.windows["CodexGauge"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 3), "Dashboard should open in a full native window")
        capture("02-dashboard-overview")

        dashboard.staticTexts["Tasks"].firstMatch.click()
        XCTAssertTrue(dashboard.staticTexts["Live tasks"].waitForExistence(timeout: 3))
        capture("03-dashboard-conversations")

        dashboard.staticTexts["Activity"].firstMatch.click()
        XCTAssertTrue(dashboard.staticTexts["Token activity"].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.windows["Notifications"].staticTexts["Denied"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Open Notification Settings"].exists)
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
