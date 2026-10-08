//
//  CodexGaugeUITests.swift
//  CodexGaugeUITests
//
//  Created by George Curtis on 8/21/26.
//

import XCTest
import AppKit

final class CodexGaugeUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    @MainActor
    func testSignedSandboxCandidateKeepsCurrentSurfaces() throws {
        guard let path = ProcessInfo.processInfo.environment["CG_SANDBOX_CANDIDATE_APP"] else {
            throw XCTSkip("Run with the reviewed signed candidate app path.")
        }
        XCUIApplication(bundleIdentifier: ProcessInfo.processInfo.environment["CG_SANDBOX_BUNDLE_ID"] ?? "com.northwolflabs.CodexGauge.beta").terminate()
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-uiTestDemo"]
        app.launch()
        defer { app.terminate() }
        let status = app.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        func shot(_ name: String, _ element: XCUIElement) {
            let attachment = XCTAttachment(screenshot: element.screenshot())
            attachment.name = "Signed sandbox — " + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        status.click()
        let panel = app.descendants(matching: .any)["gauge-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.descendants(matching: .any)["account-allowance-card"].firstMatch.exists)
        shot("menu card", panel)
        status.rightClick()
        app.menuItems["Open Dashboard…"].click()
        let dashboard = app.windows["codexgauge.dashboardWindow"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
        app.activate()
        for section in ["Overview", "Limits", "Tasks", "Activity"] {
            dashboard.buttons[section].firstMatch.click()
            shot(section, dashboard)
        }
        sendSettingsShortcut(to: app)
        let general = app.windows["General"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        XCTAssertTrue(general.buttons["choose-codex-directory"].exists)
        XCTAssertTrue(general.buttons["choose-codex-helper"].exists)
        XCTAssertFalse(general.buttons["Check for Updates…"].exists)
        shot("General access", general)
        general.buttons["Menu Bar"].click()
        let menuBar = app.windows["Menu Bar"]
        XCTAssertTrue(menuBar.waitForExistence(timeout: 5))
        shot("Menu Bar settings", menuBar)
        menuBar.buttons["Notifications"].click()
        let notifications = app.windows["Notifications"]
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        shot("Notifications", notifications)
    }

    @MainActor
    func testSandboxMigrationPreservesExistingAppState() throws {
        guard let path = ProcessInfo.processInfo.environment["CG_SANDBOX_CANDIDATE_APP"],
              let expected = ProcessInfo.processInfo.environment["CG_SANDBOX_MIGRATION_EXPECTED"] else {
            throw XCTSkip("Run with the local verification app and migration hashes.")
        }
        XCUIApplication(bundleIdentifier: ProcessInfo.processInfo.environment["CG_SANDBOX_BUNDLE_ID"] ?? "com.northwolflabs.CodexGauge.beta").terminate()
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["-verifySandboxMigration", expected]
        app.launch()
        let verification = app.windows["Sandbox Migration Verification"]
        XCTAssertTrue(verification.waitForExistence(timeout: 8))
        let values = verification.staticTexts.allElementsBoundByIndex.compactMap { $0.value as? String }
        XCTAssertTrue(values.contains { $0.contains("Verification: Passed") }, values.joined(separator: "\n"))
        let report = XCTAttachment(screenshot: verification.screenshot())
        report.name = "Native sandbox migration — preservation counts"
        report.lifetime = .keepAlways
        add(report)
        sendSettingsShortcut(to: app)
        XCTAssertTrue(app.windows["General"].waitForExistence(timeout: 5))
        // Leave the native General window open for the user's existing data grants.
    }

    @MainActor
    func testSandboxRealAccountAndTasksRestoreAfterRelaunch() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CG_SANDBOX_REAL_ACCOUNT_CHECK"] == "1",
              let path = environment["CG_SANDBOX_CANDIDATE_APP"],
              let bundle = environment["CG_SANDBOX_BUNDLE_ID"] else {
            throw XCTSkip("Opt in only for the authorized local account check.")
        }
        XCUIApplication(bundleIdentifier: bundle).terminate()
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        let expected = Data("{\"preferences\":{},\"files\":{}}".utf8).base64EncodedString()
        app.launchArguments = ["-verifySandboxMigration", expected, "-showDashboard"]
        app.launch()
        let report = app.windows["Sandbox Migration Verification"].staticTexts["sandbox-migration-result"]
        let ready = NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@ AND value CONTAINS %@", "Account fresh: true", "Tasks loaded: true", "Error: false")
        expectation(for: ready, evaluatedWith: report)
        waitForExpectations(timeout: 30)
        let dashboard = app.windows["codexgauge.dashboardWindow"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
        dashboard.buttons["Tasks"].click()
        let shot = XCTAttachment(screenshot: dashboard.screenshot())
        shot.name = "Restored real local tasks in sandbox — \(bundle)"
        shot.lifetime = .keepAlways
        add(shot)
        sendSettingsShortcut(to: app)
        XCTAssertTrue(app.windows["General"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testInstalledSandboxConnectsWithSavedGrants() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CG_SANDBOX_REAL_ACCOUNT_CHECK"] == "1",
              let path = environment["CG_SANDBOX_CANDIDATE_APP"],
              let bundle = environment["CG_SANDBOX_BUNDLE_ID"] else {
            throw XCTSkip("Opt in only for the authorized installed-app check.")
        }
        XCUIApplication(bundleIdentifier: bundle).terminate()
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = []
        app.launch()
        sendSettingsShortcut(to: app)
        let general = app.windows["General"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        let connected = general.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Connected to Codex.", "Connected to Codex.")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 30))
        XCTAssertFalse(general.buttons["Check for Updates…"].exists)
        let shot = XCTAttachment(screenshot: general.screenshot())
        shot.name = "Installed sandbox connection — \(bundle)"
        shot.lifetime = .keepAlways
        add(shot)
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

        let loading = app.descendants(matching: .any)["usage-unavailable"].firstMatch
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
    func testPopoverDismissesWhenAnotherMenuBarItemOpens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo", "-uiTestMenuBarPeer"]
        app.launch()
        let status = app.statusItems["codexgauge.statusItem"]
        let peer = app.statusItems["codexgauge.testPeer"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            status.click()
            let panel = app.descendants(matching: .any)["gauge-panel"].firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 3))
            let attachment = XCTAttachment(screenshot: panel.screenshot())
            attachment.name = "native-popover-glass"
            attachment.lifetime = .keepAlways
            add(attachment)
            peer.click()
            XCTAssertTrue(app.menuItems["Peer menu opened"].waitForExistence(timeout: 3))
            XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
            app.typeKey(.escape, modifierFlags: [])
        }
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

        let panelScrollView = panel.scrollViews.firstMatch
        XCTAssertTrue(panelScrollView.exists)
        panelScrollView.swipeUp()
        let activity = panel.descendants(matching: .any)["popover-activity-disclosure"]
        XCTAssertTrue(activity.waitForExistence(timeout: 3))
        activity.click()
        XCTAssertEqual(activity.value as? String, "Expanded")
        Thread.sleep(forTimeInterval: 0.25)
        panelScrollView.swipeUp()
        XCTAssertTrue(panel.descendants(matching: .any)["popover-activity-chart"].firstMatch.exists)
        capture("01b-popover-activity")

        statusItem.rightClick()
        XCTAssertTrue(app.menuItems["Quit CodexGauge"].waitForExistence(timeout: 3), "Right-click should present the native context menu")
        XCTAssertFalse(app.menuItems["Refresh"].exists)

        statusItem.menuItems["Open Dashboard…"].click()
        let dashboard = app.windows["codexgauge.dashboardWindow"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 3), "Dashboard should open in a full native window")
        XCTAssertFalse(dashboard.buttons["Refresh allowances"].exists)
        capture("02-dashboard-overview")

        dashboard.buttons["Tasks"].firstMatch.click()
        XCTAssertTrue(dashboard.staticTexts["Live tasks"].waitForExistence(timeout: 3))
        capture("03-dashboard-conversations")

        dashboard.buttons["Activity"].firstMatch.click()
        XCTAssertTrue(dashboard.staticTexts["Token activity"].waitForExistence(timeout: 3))
        let rangePicker = dashboard.descendants(matching: .any)["activity-range-picker"].firstMatch
        XCTAssertTrue(rangePicker.waitForExistence(timeout: 2))
        let pickerSize = rangePicker.frame.size
        for range in ["Today", "30 days", "7 days", "1 year", "All"] {
            let control = rangePicker.descendants(matching: .any)[range].firstMatch
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
            if range == "7 days" {
                XCTAssertTrue(dashboard.descendants(matching: .any)["activity-detail-chart"].firstMatch.exists)
                capture("04b-dashboard-activity-week")
            }
        }
        dashboard.buttons["Tasks"].firstMatch.click()
        dashboard.buttons["Activity"].firstMatch.click()
        XCTAssertTrue(rangePicker.waitForExistence(timeout: 2))
        XCTAssertEqual(rangePicker.frame.width, pickerSize.width, accuracy: 1)
        XCTAssertEqual(rangePicker.frame.height, pickerSize.height, accuracy: 1)
        dashboard.descendants(matching: .any)["30 days"].firstMatch.click()
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
        XCTAssertTrue(settingsWindow.buttons["Menu Bar"].exists)
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
        sendSettingsShortcut(to: app)
        XCTAssertTrue(app.windows["Notifications"].waitForExistence(timeout: 5), "Command-Comma should reopen the same native Settings window")
        capture("07b-settings-keyboard-shortcut")

        statusItem.rightClick()
        statusItem.menuItems["CodexGauge Help"].click()
        let reopenedHelp = app.windows["CodexGauge Help"]
        XCTAssertTrue(reopenedHelp.waitForExistence(timeout: 3), "Help should open outside Settings")
        reopenedHelp.staticTexts["Privacy"].firstMatch.click()
        capture("08-help-privacy")
    }

    @MainActor
    func testMenuBarCustomizationIsNativePreviewedAndRestorable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo", "-uiTestMenuBarCustomization"]
        app.launch()

        let statusItem = app.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        XCTAssertTrue(statusItem.label.contains("Suggested pace"))

        statusItem.click()
        let statusNotice = app.descendants(matching: .any)["menu-bar-status-notice"].firstMatch
        XCTAssertTrue(statusNotice.waitForExistence(timeout: 3), "A colored warning should explain itself at the top of the popover")
        statusItem.click()

        sendSettingsShortcut(to: app)
        let general = app.windows["General"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        general.buttons["Menu Bar"].click()
        let menuBarWindow = app.windows["Menu Bar"]
        XCTAssertTrue(menuBarWindow.waitForExistence(timeout: 3))
        XCTAssertTrue(menuBarWindow.descendants(matching: .any)["menu-bar-preview"].firstMatch.exists)
        XCTAssertTrue(menuBarWindow.descendants(matching: .any)["menu-bar-primary-allowance"].firstMatch.exists)
        XCTAssertTrue(menuBarWindow.descendants(matching: .any)["menu-bar-secondary-allowance"].firstMatch.exists)
        XCTAssertTrue(menuBarWindow.descendants(matching: .any)["menu-bar-reset-style"].firstMatch.exists)
        XCTAssertTrue(menuBarWindow.descendants(matching: .any)["menu-bar-pace-display"].firstMatch.exists)
        XCTAssertTrue(menuBarWindow.descendants(matching: .any)["menu-bar-color-basis"].firstMatch.exists)
        XCTAssertTrue(menuBarWindow.descendants(matching: .any)["menu-bar-color-target"].firstMatch.exists)
        capture("09-settings-menu-bar-customized")

        let restore = menuBarWindow.buttons["menu-bar-restore-defaults"].firstMatch
        XCTAssertTrue(restore.isEnabled)
        restore.click()
        let confirmRestore = menuBarWindow.sheets.firstMatch.buttons["Restore"]
        XCTAssertTrue(confirmRestore.waitForExistence(timeout: 2))
        confirmRestore.click()
        XCTAssertFalse(statusItem.label.contains("Suggested pace"))
        XCTAssertFalse(menuBarWindow.descendants(matching: .any)["menu-bar-color-basis"].firstMatch.exists)
        XCTAssertFalse(menuBarWindow.descendants(matching: .any)["menu-bar-color-target"].firstMatch.exists)
        capture("09b-settings-menu-bar-default")
    }

    @MainActor
    func testMenuBarVisibilityControlsStayActionableAndHideIrrelevantChoices() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()
        sendSettingsShortcut(to: app)

        let general = app.windows["General"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        general.buttons["Menu Bar"].click()
        let menuBarWindow = app.windows["Menu Bar"]
        XCTAssertTrue(menuBarWindow.waitForExistence(timeout: 3))

        let gauge = menuBarWindow.descendants(matching: .any)["menu-bar-show-gauge"].firstMatch
        let percentage = menuBarWindow.descendants(matching: .any)["menu-bar-show-percentage"].firstMatch
        XCTAssertTrue(gauge.isEnabled)
        XCTAssertTrue(percentage.isEnabled)

        percentage.click()
        XCTAssertTrue(gauge.isEnabled)
        XCTAssertTrue(percentage.isEnabled)
        XCTAssertFalse(menuBarWindow.descendants(matching: .any)["menu-bar-primary-allowance"].firstMatch.exists)
        XCTAssertFalse(menuBarWindow.descendants(matching: .any)["menu-bar-secondary-allowance"].firstMatch.exists)

        gauge.click()
        XCTAssertTrue(gauge.isEnabled)
        XCTAssertTrue(percentage.isEnabled)
        XCTAssertTrue(menuBarWindow.descendants(matching: .any)["menu-bar-primary-allowance"].firstMatch.exists)
    }

    @MainActor
    func testMissingMenuBarSelectionFallsBackWithoutDiscardingTheChoice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo", "-uiTestMissingMenuBarSelection"]
        app.launch()
        sendSettingsShortcut(to: app)

        let general = app.windows["General"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        general.buttons["Menu Bar"].click()
        let menuBarWindow = app.windows["Menu Bar"]
        XCTAssertTrue(menuBarWindow.waitForExistence(timeout: 3))
        XCTAssertTrue(menuBarWindow.descendants(matching: .any)["menu-bar-primary-fallback"].firstMatch.exists)
        XCTAssertTrue(menuBarWindow.descendants(matching: .any)["menu-bar-secondary-fallback"].firstMatch.exists)
    }

    @MainActor
    func testTransientPopoverStateResetsAfterClosing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()

        let statusItem = app.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let panel = app.descendants(matching: .any)["gauge-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        var liveTask = panel.descendants(matching: .any)["live-conversation-disclosure"].firstMatch
        XCTAssertTrue(liveTask.waitForExistence(timeout: 3))
        liveTask.click()
        XCTAssertEqual(liveTask.value as? String, "Expanded")

        // Expanding the task reflows the popover. Resolve Activity from the new
        // accessibility hierarchy so the click does not use its old geometry.
        panel.scrollViews.firstMatch.swipeUp()
        let activity = panel.descendants(matching: .any)["popover-activity-disclosure"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 3))
        activity.click()
        XCTAssertEqual(activity.value as? String, "Expanded")

        statusItem.click()
        XCTAssertFalse(app.descendants(matching: .any)["gauge-panel"].firstMatch.waitForExistence(timeout: 1))
        statusItem.click()

        liveTask = app.descendants(matching: .any)["live-conversation-disclosure"].firstMatch
        let reopenedActivity = app.descendants(matching: .any)["popover-activity-disclosure"].firstMatch
        XCTAssertTrue(liveTask.waitForExistence(timeout: 3))
        XCTAssertEqual(liveTask.value as? String, "Collapsed")
        app.descendants(matching: .any)["gauge-panel"].firstMatch.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(reopenedActivity.waitForExistence(timeout: 3))
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
        sendSettingsShortcut(to: app)
        let settingsWindow = app.windows["General"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        settingsWindow.buttons["Notifications"].click()
        let notificationsWindow = app.windows["Notifications"]
        XCTAssertTrue(notificationsWindow.waitForExistence(timeout: 3))

        let toggle = notificationsWindow.descendants(matching: .any)["alert-destination-low"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        XCTAssertFalse(notificationsWindow.textFields["allowance-threshold-field"].firstMatch.exists)

        app.terminate()
        let enabledApp = XCUIApplication()
        enabledApp.launchArguments = ["-uiTestDemo", "-quotaNotifications", "YES"]
        enabledApp.launch()
        XCTAssertTrue(enabledApp.statusItems["codexgauge.statusItem"].waitForExistence(timeout: 5))
        sendSettingsShortcut(to: enabledApp)
        let enabledSettings = enabledApp.windows["General"]
        XCTAssertTrue(enabledSettings.waitForExistence(timeout: 5))
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
    func testNotificationPreferencesOnlyShowAlertChoices() throws {
        for flag in ["-uiTestDeniedNotifications", "-uiTestUnrequestedNotifications", "-uiTestAuthorizedNotifications"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTestDemo", flag]
            app.launch()
            XCTAssertTrue(app.statusItems["codexgauge.statusItem"].waitForExistence(timeout: 5))
            sendSettingsShortcut(to: app)
            app.windows["General"].buttons["Notifications"].click()
            let window = app.windows["Notifications"]
            let allowance = window.descendants(matching: .any)["alert-destination-low"].firstMatch
            XCTAssertTrue(allowance.waitForExistence(timeout: 3))
            XCTAssertTrue(window.descendants(matching: .any)["alert-destination-attention"].firstMatch.exists)
            XCTAssertFalse(window.buttons["slack-setup-button"].exists)
            XCTAssertFalse(window.buttons["ntfy-setup"].exists)
            XCTAssertFalse(window.staticTexts["Delivery"].exists)
            XCTAssertFalse(window.buttons["Open System Settings…"].exists)
            XCTAssertFalse(window.buttons["Notification Settings…"].exists)
            XCTAssertFalse(window.buttons["Allow Notifications…"].exists)
            XCTAssertFalse(window.descendants(matching: .any)["notification-delivery-status"].firstMatch.exists)
            allowance.click()
            XCTAssertEqual(String(describing: allowance.value ?? ""), "1")
            XCTAssertTrue(window.textFields["allowance-threshold-field"].firstMatch.waitForExistence(timeout: 3))
            XCTAssertFalse(window.buttons["Open System Settings…"].exists)
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "notification-choices-\(flag)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    @MainActor
    func testBetaIconMatchesPreviewAndCanBeDisabled() throws {
        for style in ["Light", "Dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTestDemo", "-uiTestBeta", "-AppleInterfaceStyle", style]
            app.launch()
            XCTAssertTrue(app.statusItems["codexgauge.statusItem"].waitForExistence(timeout: 5))
            sendSettingsShortcut(to: app)
            app.windows["General"].buttons["Menu Bar"].click()
            let window = app.windows["Menu Bar"]
            let preview = window.descendants(matching: .any)["menu-bar-preview"].firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 3))
            XCTAssertTrue(preview.label.contains("Beta icon"))
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "beta-menu-bar-\(style)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.descendants(matching: .any)["menu-bar-beta-icon"].firstMatch.click()
            XCTAssertFalse(preview.label.contains("Beta icon"))
            window.descendants(matching: .any)["menu-bar-beta-icon"].firstMatch.click()
            XCTAssertTrue(preview.label.contains("Beta icon"))
            window.descendants(matching: .any)["menu-bar-show-gauge"].firstMatch.click()
            XCTAssertFalse(preview.label.contains("Beta icon"))
            XCTAssertFalse(window.descendants(matching: .any)["menu-bar-beta-icon"].firstMatch.isEnabled)
            app.terminate()
        }
    }

    @MainActor
    func testDevicesSettingsAndWrappedPairingSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo", "-companionDevicesDemo"]
        app.launch(); sendSettingsShortcut(to: app)
        let general = app.windows["General"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        XCTAssertFalse(general.buttons["Pair iPhone…"].exists)
        general.buttons["Devices"].click()
        let devices = app.windows["Devices"]
        XCTAssertTrue(devices.waitForExistence(timeout: 5))
        XCTAssertTrue(devices.staticTexts["Fixture iPhone"].exists)
        XCTAssertTrue(devices.buttons["Remove Fixture iPhone"].exists)
        XCTAssertFalse(devices.buttons["Copy viewing link"].exists)
        XCTAssertFalse(devices.staticTexts["Connection"].exists)
        XCTAssertFalse(devices.disclosureTriangles["Advanced"].exists)
        func save(_ name: String) {
            let shot = XCTAttachment(screenshot: devices.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        save("Devices — primary pairing and removable devices")
        devices.buttons["companion.pairPhone"].click()
        let sheet = devices.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let instructions = sheet.staticTexts["companion.pairInstructions"]
        XCTAssertTrue(instructions.exists)
        XCTAssertGreaterThan(instructions.frame.height, 28, "Instructions must wrap to their full height")
        XCTAssertTrue(sheet.buttons["Done"].isHittable)
        let qr = XCTAttachment(screenshot: sheet.screenshot())
        qr.name = "Pair iPhone — complete sheet including actions"
        qr.lifetime = .keepAlways; add(qr)
        sheet.buttons["Done"].click()
        XCTAssertFalse(sheet.exists)
    }

    @MainActor
    private func sendSettingsShortcut(to app: XCUIApplication) {
        // Menu-bar-only apps do not always own keyboard focus immediately after
        // XCTest observes their status item. Make the shortcut deterministic
        // without bypassing the Command-Comma behavior under test.
        app.activate()
        app.typeKey(",", modifierFlags: .command)
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
            (["-uiTestLoading"], "usage-unavailable"),
            (["-uiTestEmpty"], "No local tasks found"),
            (["-uiTestStale"], "Last known data"),
            (["-uiTestOffline"], "Last known data"),
            (["-uiTestMissingHelper"], "usage-unavailable"),
            (["-uiTestMissingHelperCached"], "usage-unavailable"),
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
            if arguments.contains("-uiTestMissingHelper") || arguments.contains("-uiTestMissingHelperCached") || arguments.contains("-uiTestSignedOut") {
                XCTAssertFalse(app.buttons["Retry"].exists)
                XCTAssertTrue(app.buttons["Settings…"].exists)
                XCTAssertFalse(app.descendants(matching: .any)["limits-section"].exists)
                XCTAssertFalse(app.staticTexts["Tasks"].exists)
                let open = app.buttons["Open ChatGPT"].firstMatch
                XCTAssertTrue(open.isHittable)
                XCTAssertGreaterThan(open.frame.width, 105)
                let attachment = XCTAttachment(screenshot: app.descendants(matching: .any)["gauge-panel"].firstMatch.screenshot())
                attachment.name = "disconnected-\(arguments.joined(separator: "-"))"
                attachment.lifetime = .keepAlways
                add(attachment)
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
        XCTAssertTrue(app.windows["Notifications"].descendants(matching: .any)["alert-destination-low"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Open System Settings…"].exists)
        XCTAssertFalse(app.windows["Notifications"].staticTexts["Delivery"].exists)
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

    @MainActor func testAccountBalancesAndCalendarRangesInActualMacWindows() throws {
        for appearance in ["Light", "Dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTestDemo", "-uiTestNarrowDashboard", "-AppleInterfaceStyle", appearance]
            app.launch()
            defer { app.terminate() }
            func shot(_ name: String, _ element: XCUIElement) {
                let image = XCTAttachment(screenshot: element.screenshot())
                image.name = appearance + " — " + name; image.lifetime = .keepAlways; add(image)
                let tree = XCTAttachment(string: element.debugDescription)
                tree.name = appearance + " — " + name + " hierarchy"; tree.lifetime = .keepAlways; add(tree)
            }
            func checkCard(_ surface: XCUIElement) {
                let card = surface.descendants(matching: .any)["account-allowance-card"].firstMatch
                XCTAssertTrue(card.waitForExistence(timeout: 5))
                XCTAssertEqual(surface.descendants(matching: .any).matching(identifier: "account-allowance-card").count, 1)
                XCTAssertFalse(surface.staticTexts["Account balances"].exists)
                let identity = card.descendants(matching: .any)["account-identity"].firstMatch
                let balances = card.descendants(matching: .any)["account-balances"].firstMatch
                XCTAssertTrue(identity.exists)
                XCTAssertTrue(balances.exists)
                XCTAssertLessThanOrEqual(identity.frame.maxY, balances.frame.minY)
                XCTAssertTrue(card.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Limit resets: 2")).firstMatch.exists)
                XCTAssertTrue(card.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Credits available: 12.5")).firstMatch.exists)
                XCTAssertGreaterThanOrEqual(balances.frame.minX, card.frame.minX)
                XCTAssertLessThanOrEqual(balances.frame.maxX, card.frame.maxX)
            }
            let status = app.statusItems["codexgauge.statusItem"]
            XCTAssertTrue(status.waitForExistence(timeout: 5)); status.click()
            let panel = app.descendants(matching: .any)["gauge-panel"].firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            shot("menu account card", panel); checkCard(panel)
            status.rightClick(); app.menuItems["Open Dashboard…"].click()
            let dashboard = app.windows["codexgauge.dashboardWindow"]
            XCTAssertTrue(dashboard.waitForExistence(timeout: 5)); app.activate()
            XCTAssertEqual(dashboard.frame.width, 780, accuracy: 2)
            XCTAssertEqual(dashboard.frame.height, 640, accuracy: 2)
            for destination in ["Overview", "Limits"] {
                dashboard.buttons[destination].firstMatch.click()
                shot("narrow " + destination, dashboard); checkCard(dashboard)
            }
            dashboard.buttons["Activity"].firstMatch.click()
            let picker = dashboard.descendants(matching: .any)["activity-range-picker"].firstMatch
            XCTAssertTrue(picker.exists)
            for title in ["Today", "7 days", "30 days", "90 days", "1 year", "All"] {
                let item = picker.descendants(matching: .any)[title].firstMatch
                XCTAssertTrue(item.exists); XCTAssertTrue(item.isHittable); item.click()
                shot("Activity " + title, dashboard)
            }
            app.terminate()
        }
    }

    @MainActor func testDashboardNativeChromeAndSinglePointInLightMode() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo", "-uiTestSingleActivity", "-showDashboard", "-performanceDashboardActivity", "-AppleInterfaceStyle", "Light"]
        app.launch()
        defer { app.terminate() }
        let dashboard = app.windows["codexgauge.dashboardWindow"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
        app.activate()
        for identifier in ["_XCUI:CloseWindow", "_XCUI:ZoomWindow", "_XCUI:MinimizeWindow"] {
            XCTAssertTrue(dashboard.buttons[identifier].isHittable)
        }
        let picker = dashboard.descendants(matching: .any)["activity-range-picker"].firstMatch
        picker.descendants(matching: .any)["90 days"].firstMatch.click()
        let initial = dashboard.frame
        let titlebar = dashboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        titlebar.click(forDuration: 0.2, thenDragTo: titlebar.withOffset(CGVector(dx: 60, dy: 40)))
        XCTAssertEqual(dashboard.frame.minX, initial.minX + 60, accuracy: 3)
        XCTAssertEqual(dashboard.frame.minY, initial.minY + 40, accuracy: 3)
        let beforeResize = dashboard.frame
        let corner = dashboard.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.click(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: -60, dy: -30)))
        XCTAssertLessThan(dashboard.frame.width, beforeResize.width - 30)
        XCTAssertLessThan(dashboard.frame.height, beforeResize.height - 10)
        let image = XCTAttachment(screenshot: dashboard.screenshot())
        image.name = "Light native chrome — moved resized single observation line"
        image.lifetime = .keepAlways; add(image)
        dashboard.buttons["Limits"].click()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.windows["Tasks"].exists)
        dashboard.buttons["_XCUI:CloseWindow"].click()
        XCTAssertFalse(dashboard.exists)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["General"].waitForExistence(timeout: 3))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.windows["General"].exists)
    }

    @MainActor func testAlreadyOpenInstalledBetaDashboard() throws {
        guard ProcessInfo.processInfo.environment["CG_SANDBOX_REAL_ACCOUNT_CHECK"] == "1" else {
            throw XCTSkip("Opt in for the authorized installed dashboard check.")
        }
        let app = XCUIApplication(bundleIdentifier: "com.northwolflabs.CodexGauge.beta")
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningForeground)
        let dashboard = app.windows["codexgauge.dashboardWindow"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5), "Open the installed dashboard before this read-only check.")
        app.activate()
        for section in ["Overview", "Tasks", "Limits", "Activity"] {
            dashboard.buttons[section].firstMatch.click()
            if section == "Tasks" {
                let title = "Refine account card"
                let rows = dashboard.staticTexts.matching(NSPredicate(
                    format: "identifier == %@ OR label == %@ OR value == %@", title, title, title))
                XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
                XCTAssertEqual(rows.count, 1)
            } else if section == "Limits" {
                XCTAssertTrue(dashboard.descendants(matching: .any)["account-allowance-card"].firstMatch.exists)
            } else if section == "Activity" {
                XCTAssertTrue(dashboard.descendants(matching: .any)["activity-range-picker"].firstMatch.exists)
            }
            let image = XCTAttachment(screenshot: dashboard.screenshot())
            image.name = "Already open installed Beta — " + section
            image.lifetime = .keepAlways; add(image)
            let tree = XCTAttachment(string: dashboard.debugDescription)
            tree.name = "Already open installed Beta hierarchy — " + section
            tree.lifetime = .keepAlways; add(tree)
        }
        dashboard.buttons["Tasks"].firstMatch.click()
        // Leave the user's installed dashboard open, without relaunching the app.
    }

    @MainActor func testInstalledBetaCurrentChatAppearsOnce() throws {
        let app = XCUIApplication(bundleIdentifier: "com.northwolflabs.CodexGauge.beta")
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningForeground)
        app.activate()
        let status = app.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.rightClick(); app.menuItems["Open Dashboard…"].click()
        let dashboard = app.windows["codexgauge.dashboardWindow"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
        defer { if dashboard.exists { dashboard.buttons[XCUIIdentifierCloseWindow].click() } }
        dashboard.buttons["Tasks"].firstMatch.click()
        let title = "Refine account card"
        XCTAssertTrue(dashboard.staticTexts[title].firstMatch.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: dashboard.screenshot())
        shot.name = "Duplicate fix installed Mac Tasks"; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: dashboard.debugDescription)
        tree.name = "Duplicate fix installed Mac Tasks hierarchy"; tree.lifetime = .keepAlways; add(tree)
        // SwiftUI macOS Text can expose the displayed title as its value.
        XCTAssertEqual(dashboard.staticTexts.matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR value == %@", title, title, title)).count, 1)
    }

    @MainActor func testInstalledBetaReadOnlyAccountLayoutCapture() throws {
        let app = XCUIApplication(bundleIdentifier: "com.northwolflabs.CodexGauge.beta")
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningForeground)
        app.activate()
        let status = app.statusItems["codexgauge.statusItem"]
        XCTAssertTrue(status.waitForExistence(timeout: 5)); status.click()
        let panel = app.descendants(matching: .any)["gauge-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.descendants(matching: .any)["account-allowance-card"].firstMatch.exists)
        let popover = XCTAttachment(screenshot: panel.screenshot()); popover.name = "Installed beta actual popover"; popover.lifetime = .keepAlways; add(popover)
        status.rightClick(); app.menuItems["Open Dashboard…"].click()
        let dashboard = app.windows["codexgauge.dashboardWindow"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
        defer { if dashboard.exists { dashboard.buttons[XCUIIdentifierCloseWindow].click() } }
        dashboard.buttons["Limits"].firstMatch.click()
        XCTAssertTrue(dashboard.descendants(matching: .any)["account-allowance-card"].firstMatch.exists)
        let limits = XCTAttachment(screenshot: dashboard.screenshot()); limits.name = "Installed beta actual Limits"; limits.lifetime = .keepAlways; add(limits)
        dashboard.buttons["Activity"].firstMatch.click()
        XCTAssertTrue(dashboard.descendants(matching: .any)["activity-range-picker"].firstMatch.exists)
        let activity = XCTAttachment(screenshot: dashboard.screenshot()); activity.name = "Installed beta actual Activity"; activity.lifetime = .keepAlways; add(activity)
        XCTAssertTrue(app.state == .runningForeground)
    }

    @MainActor
    private func capture(_ name: String) {
        let app = XCUIApplication()
        let panel = app.descendants(matching: .any)["gauge-panel"].firstMatch
        let window = app.windows.firstMatch
        let screenshot = panel.exists ? panel.screenshot() : window.exists ? window.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
