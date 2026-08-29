import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private lazy var contextMenu = makeContextMenu()
    private lazy var popoverMenu = makePopoverMenu()
    private lazy var helpWindow = HelpWindowController()
    private lazy var dashboardWindow = DashboardWindowController(
        state: state,
        onShowHelp: { [weak self] in self?.helpWindow.show() }
    )
    private lazy var settingsWindow = SettingsWindowController(
        state: state,
        onShowHelp: { [weak self] in self?.helpWindow.show() }
    )
    private var keyMonitor: Any?
    private var expandedDisclosureCount = 0
    private var popoverClock: VisibleSurfaceClock?

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.identifier = NSUserInterfaceItemIdentifier("codexgauge.statusItem")
            button.setAccessibilityIdentifier("codexgauge.statusItem")
        }

        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentSize = NSSize(width: 390, height: preferredPopoverHeight)
        popover.delegate = self

        updateStatusItem()
        observeState()
        installMainMenu()
        installKeyboardShortcuts()
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClock?.stop()
        popoverClock = nil
        popover.contentViewController = nil
        expandedDisclosureCount = 0
        updatePopoverSize()
        RuntimeMemory.scheduleUnusedPageRelease()
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(button)
        } else {
            let presentationStartedAt = ProcessInfo.processInfo.systemUptime
            installPopoverContent()
            popoverClock?.start()
            updatePopoverSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
                // A mouse-opened popover should not look as though its first row
                // is permanently selected. Clearing the initial responder keeps
                // the surface neutral while Tab still enters the normal button
                // focus chain for keyboard navigation.
                window.makeFirstResponder(nil)
            }
            PerformanceSignposts.recordPresentation("popover", startedAt: presentationStartedAt)
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        statusItem.menu = contextMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Dashboard…", action: #selector(showDashboard), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        let helpItem = menu.addItem(withTitle: "CodexGauge Help", action: #selector(showHelp), keyEquivalent: "?")
        helpItem.keyEquivalentModifierMask = [.command]
        helpItem.target = self
        menu.addItem(withTitle: "Open ChatGPT", action: #selector(openChatGPT), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CodexGauge", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    private func makePopoverMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Dashboard…", action: #selector(showDashboard), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "CodexGauge Help", action: #selector(showHelp), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open ChatGPT", action: #selector(openChatGPT), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CodexGauge", action: #selector(quit), keyEquivalent: "").target = self
        return menu
    }

    private func showPopoverMenu() {
        let point = NSEvent.mouseLocation
        // Let the button's mouse-up finish before opening AppKit's tracking loop.
        // Otherwise the first click can also dismiss the menu it just opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.popoverMenu.popUp(
                positioning: nil,
                at: NSPoint(x: point.x - 8, y: point.y - 8),
                in: nil
            )
        }
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func showDashboard() {
        dashboardWindow.show()
    }

    @objc private func showHelp() {
        helpWindow.show()
    }

    @objc private func openChatGPT() {
        state.openChatGPT()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    func runPerformanceScenario(_ scenario: String) async {
        guard let button = statusItem.button else {
            PerformanceSignposts.recordReady(scenario)
            return
        }
        switch scenario {
        case "popover", "popover-expanded", "stress":
            await exercisePopoverPresentation(from: button, leaveOpen: true)
        case "dashboard", "dashboard-activity":
            await exerciseDashboardPresentation(leaveOpen: true)
        case "recovery":
            await exercisePopoverPresentation(from: button, leaveOpen: false)
        default:
            break
        }
        PerformanceSignposts.recordReady(scenario)
    }

    private func exercisePopoverPresentation(from button: NSStatusBarButton, leaveOpen: Bool) async {
        var completedPresentations = 0
        var attempts = 0
        while completedPresentations < 20, attempts < 60 {
            attempts += 1
            if popover.isShown {
                popover.close()
                await waitForPopoverToClose()
            }
            guard !popover.isShown else { continue }

            togglePopover(from: button)
            completedPresentations += 1
            try? await Task.sleep(for: .milliseconds(200))
            popover.close()
            await waitForPopoverToClose()
            try? await Task.sleep(for: .milliseconds(100))
        }
        if leaveOpen, !popover.isShown { togglePopover(from: button) }
    }

    private func waitForPopoverToClose() async {
        for _ in 0..<80 where popover.isShown {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func exerciseDashboardPresentation(leaveOpen: Bool) async {
        for _ in 0..<20 {
            dashboardWindow.show()
            try? await Task.sleep(for: .milliseconds(150))
            dashboardWindow.close()
            for _ in 0..<20 where dashboardWindow.window != nil {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        if leaveOpen { dashboardWindow.show() }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "CodexGauge")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        applicationMenu.addItem(withTitle: "About CodexGauge", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "").target = NSApplication.shared
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Hide CodexGauge", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h").target = NSApplication.shared
        let hideOthers = applicationMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApplication.shared
        applicationMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "").target = NSApplication.shared
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit CodexGauge", action: #selector(quit), keyEquivalent: "q").target = self

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        let helpRoot = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpRoot.submenu = helpMenu
        mainMenu.addItem(helpRoot)
        let help = helpMenu.addItem(withTitle: "CodexGauge Help", action: #selector(showHelp), keyEquivalent: "?")
        help.keyEquivalentModifierMask = [.command]
        help.target = self

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }

    private func installKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isSettingsShortcut = modifiers.contains(.command)
                && !modifiers.contains(.option)
                && !modifiers.contains(.control)
                && event.charactersIgnoringModifiers == ","
            if isSettingsShortcut {
                self?.showSettings()
                return nil
            }
            let isHelpShortcut = modifiers.contains(.command)
                && (event.characters == "?" || (modifiers.contains(.shift) && event.charactersIgnoringModifiers == "/"))
            if isHelpShortcut {
                self?.showHelp()
                return nil
            }
            return event
        }
    }

    private func observeState() {
        withObservationTracking {
            _ = state.menuBarTitle
            _ = state.menuBarSymbol
            _ = state.menuBarAccessibilityLabel
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusItem()
                self?.observeState()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: state.menuBarSymbol, accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image
        button.title = " \(state.menuBarTitle)"
        button.toolTip = state.menuBarAccessibilityLabel
        button.setAccessibilityLabel(state.menuBarAccessibilityLabel)
    }

    private var preferredPopoverHeight: CGFloat {
        let bucketCount = max(1, state.accountSnapshot?.buckets.count ?? 1)
        let liveCount = min(3, state.conversations.filter(\.isLive).count)
        let recentCount = state.conversations.filter { !$0.isLive }.count
        let hasActivity = state.accountSnapshot?.activity != nil && state.accountSnapshot?.activity != .empty

        var height: CGFloat = 270
        height += CGFloat(max(0, bucketCount - 1)) * 30
        if state.hasLoadedConversations && !state.conversations.isEmpty {
            height += 60 + CGFloat(liveCount) * 78
            if recentCount > 0 { height += 34 }
        } else {
            height += 60
        }
        if hasActivity { height += 46 }
        height += CGFloat(expandedDisclosureCount) * 116
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let screenLimit = max(330, (screen?.visibleFrame.height ?? 700) - 48)
        let clamped = min(screenLimit, min(650, max(330, height)))
        return clamped.isFinite ? clamped : 520
    }

    private func updatePopoverSize() {
        let target = NSSize(width: 390, height: preferredPopoverHeight)
        guard popover.contentSize != target else { return }
        popover.contentSize = target
    }

    private func installPopoverContent() {
        guard popover.contentViewController == nil else { return }
        let signpost = PerformanceSignposts.begin("Popover construction")
        defer { PerformanceSignposts.end("Popover construction", signpost) }
        let clock = VisibleSurfaceClock()
        popoverClock = clock
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                state: state,
                clock: clock,
                onShowDashboard: { [weak self] in self?.dashboardWindow.show() },
                onShowSettings: { [weak self] in self?.settingsWindow.show() },
                onShowHelp: { [weak self] in self?.helpWindow.show() },
                onShowMenu: { [weak self] in self?.showPopoverMenu() },
                onContentSizeInvalidated: { [weak self] in self?.updatePopoverSize() },
                onDisclosureExpansionChanged: { [weak self] isExpanded in
                    guard let self else { return }
                    self.expandedDisclosureCount = max(0, self.expandedDisclosureCount + (isExpanded ? 1 : -1))
                    self.updatePopoverSize()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                        guard self?.popover.isShown == true else { return }
                        self?.updatePopoverSize()
                    }
                }
            )
            .codexGaugeWritingToolsDisabled()
        )
    }
}
