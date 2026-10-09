import AppKit
import Observation
import SwiftUI

final class MainActorNotificationRelay: NSObject {
    private let action: @MainActor @Sendable () -> Void

    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    @objc func receive(_ notification: Notification) {
        let action = action
        Task { @MainActor in action() }
    }
}

@MainActor
enum StatusItemSymbolRenderer {
    static let configuration = NSImage.SymbolConfiguration(
        pointSize: 13,
        weight: .medium,
        scale: .medium
    )

    static func image(named symbolName: String, color: NSColor?, usesBetaGlyph: Bool = false) -> NSImage? {
        if usesBetaGlyph {
            let text = NSAttributedString(string: "β", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: color ?? NSColor.black
            ])
            let image = NSImage(size: NSSize(width: 16, height: 18), flipped: false) { _ in
                text.draw(at: NSPoint(x: (16 - text.size().width) / 2, y: 0))
                return true
            }
            image.isTemplate = color == nil
            return image
        }
        guard let source = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        let symbolConfiguration = color.map {
            configuration.applying(.init(hierarchicalColor: $0))
        } ?? configuration
        guard let symbol = source.withSymbolConfiguration(symbolConfiguration) else { return nil }

        // NSStatusBarButton centers an image's complete bounds beside its title.
        // Give the symbol two transparent points below its artwork so the visible
        // glyph moves up one point: its bottom meets the text while its slightly
        // greater height extends above it. Drawing into a real image is deliberate;
        // NSButtonCell does not consistently honor a symbol's custom alignmentRect.
        let image = NSImage(
            size: NSSize(width: symbol.size.width, height: symbol.size.height + 2),
            flipped: false
        ) { _ in
            symbol.draw(
                in: NSRect(origin: NSPoint(x: 0, y: 2), size: symbol.size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

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
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var pointerMonitorID: UUID?
    private var testPeerStatusItem: NSStatusItem?
    private var opening: Task<Void, Never>?
    private var openingRequest: PopoverOpeningRequest?
    private var closing = false
    private weak var trackingMenu: NSMenu?
    private lazy var anchorTracker = PopoverAnchorTracker(
        canUpdate: { [weak self] in
            guard let self else { return false }
            return self.popover.isShown && !self.closing && self.trackingMenu == nil
        },
        update: { [weak self] view in
            self?.popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    )
    private var expandedDisclosureCount = 0
    private var popoverClock: VisibleSurfaceClock?
    private var statusUpdateTimer: Timer?
    private lazy var systemTimeNotificationRelay = MainActorNotificationRelay { [weak self] in
        self?.updateStatusItem()
    }

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
        installSystemTimeObservers()
        installMainMenu()
        installKeyboardShortcuts()
        installDismissalObservers()
        if ProcessInfo.processInfo.arguments.contains("-uiTestMenuBarPeer") {
            let peer = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            peer.button?.title = "Peer"
            peer.button?.setAccessibilityIdentifier("codexgauge.testPeer")
            let menu = NSMenu()
            menu.addItem(withTitle: "Peer menu opened", action: nil, keyEquivalent: "")
            peer.menu = menu
            testPeerStatusItem = peer
        }
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    func popoverDidShow(_ notification: Notification) { anchorTracker.changed() }

    func popoverWillClose(_ notification: Notification) {
        closing = true
        anchorTracker.stop()
        stopPointerMonitoring()
    }

    func popoverDidClose(_ notification: Notification) {
        closing = false
        popoverClock?.stop()
        popoverClock = nil
        popover.contentViewController = nil
        expandedDisclosureCount = 0
        updatePopoverSize()
        RuntimeMemory.scheduleUnusedPageRelease()
    }

    private func togglePopover(from button: NSStatusBarButton) {
        guard openingRequest == nil else { return }
        if popover.isShown && !closing {
            dismissPopover()
            return
        }
        let request = PopoverOpeningRequest(originPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        openingRequest = request
        startPointerMonitoring()
        opening = Task { @MainActor [weak self, weak button] in
            guard let self, let button else { return }
            defer {
                if self.openingRequest?.id == request.id {
                    self.opening = nil
                    self.openingRequest = nil
                    if !self.popover.isShown { self.stopPointerMonitoring() }
                }
            }
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                if !closing { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard !Task.isCancelled, !closing else { return }
            _ = ForegroundActivation.request()
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                if isFrontmost, button.window != nil { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard !Task.isCancelled, isFrontmost, button.window != nil else { return }
            let presentationStartedAt = ProcessInfo.processInfo.systemUptime
            installPopoverContent()
            popoverClock?.start()
            updatePopoverSize()
            popover.appearance = NSApp.effectiveAppearance
            startPointerMonitoring()
            anchorTracker.start(view: button)
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

    private var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier
    }

    private func dismissPopover() {
        opening?.cancel()
        opening = nil
        openingRequest = nil
        stopPointerMonitoring()
        let menu = trackingMenu
        trackingMenu = nil
        menu?.cancelTracking()
        if popover.isShown { popover.performClose(nil) }
    }

    private func startPointerMonitoring() {
        guard pointerMonitorID == nil else { return }
        let id = UUID()
        pointerMonitorID = id
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handlePointer(at: NSEvent.mouseLocation, isLocal: true)
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, self.pointerMonitorID == id else { return }
                self.handlePointer(at: point, isLocal: false)
            }
        }
    }

    private func stopPointerMonitoring() {
        pointerMonitorID = nil
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        localPointerMonitor = nil
        globalPointerMonitor = nil
    }

    private func handlePointer(at point: NSPoint, isLocal: Bool) {
        guard popover.isShown || openingRequest != nil else { return }
        let button = statusItem.button
        let statusFrame = button.flatMap { view in view.window?.convertToScreen(view.convert(view.bounds, to: nil)) }
        if PopoverInteractionPolicy.shouldDismissPointer(at: point, statusFrame: statusFrame,
                popoverFrame: popover.contentViewController?.view.window?.frame,
                isLocal: isLocal, trackingOwnMenu: trackingMenu != nil) {
            dismissPopover()
        }
    }

    private func installDismissalObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(applicationResigned), name: NSApplication.didResignActiveNotification, object: NSApp)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontmostChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func applicationResigned() {
        if openingRequest == nil, popover.isShown { dismissPopover() }
    }

    @objc private func frontmostChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        if openingRequest != nil {
            if openingRequest!.shouldCancel(activatedPID: app.processIdentifier, currentPID: NSRunningApplication.current.processIdentifier) {
                dismissPopover()
            }
        } else if !isFrontmost, popover.isShown { dismissPopover() }
    }

    @objc private func menuBegan(_ notification: Notification) {
        if popover.isShown { trackingMenu = notification.object as? NSMenu }
    }

    @objc private func menuEnded() {
        trackingMenu = nil
        if openingRequest == nil, popover.isShown, !NSApp.isActive || !isFrontmost { dismissPopover() }
        else { anchorTracker.changed() }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        dismissPopover()
        statusItem.menu = contextMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Dashboard…", action: #selector(showDashboard), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        let helpItem = menu.addItem(withTitle: "TokenTach Help", action: #selector(showHelp), keyEquivalent: "?")
        helpItem.keyEquivalentModifierMask = [.command]
        helpItem.target = self
        menu.addItem(withTitle: "Open ChatGPT", action: #selector(openChatGPT), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(AppIdentity.current.displayName)", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    private func makePopoverMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Dashboard…", action: #selector(showDashboard), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "TokenTach Help", action: #selector(showHelp), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open ChatGPT", action: #selector(openChatGPT), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(AppIdentity.current.displayName)", action: #selector(quit), keyEquivalent: "").target = self
        return menu
    }

    private func showPopoverMenu() {
        let point = NSEvent.mouseLocation
        // Let the button's mouse-up finish before opening AppKit's tracking loop.
        // Otherwise the first click can also dismiss the menu it just opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard self?.popover.isShown == true, self?.closing == false else { return }
            self?.popoverMenu.popUp(
                positioning: nil,
                at: NSPoint(x: point.x - 8, y: point.y - 8),
                in: nil
            )
        }
    }

    @objc private func showSettings() {
        dismissPopover()
        // Menu and popover tracking can otherwise reclaim key status after the
        // Settings window is ordered forward. Present on the next run-loop turn.
        DispatchQueue.main.async { [weak self] in
            self?.settingsWindow.show()
        }
    }

    #if DEBUG
    func showNotificationPreferencesForDevelopment() {
        dismissPopover()
        settingsWindow.show(.notifications)
    }

    func showDashboardForDevelopment() { dashboardWindow.show() }
    #endif

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
        let applicationMenu = NSMenu(title: AppIdentity.current.displayName)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        applicationMenu.addItem(withTitle: "About \(AppIdentity.current.displayName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "").target = NSApplication.shared
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Hide \(AppIdentity.current.displayName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h").target = NSApplication.shared
        let hideOthers = applicationMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApplication.shared
        applicationMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "").target = NSApplication.shared
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit \(AppIdentity.current.displayName)", action: #selector(quit), keyEquivalent: "q").target = self

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                     ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }

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
        let help = helpMenu.addItem(withTitle: "TokenTach Help", action: #selector(showHelp), keyEquivalent: "?")
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
            _ = state.accountSnapshot
            _ = state.executableURL
            _ = state.freshness
            _ = state.settings.refreshInterval
            _ = state.settings.menuBarConfiguration
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusItem()
                self?.observeState()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let now = Date.now
        let presentation = MenuBarPresentationBuilder.make(
            snapshot: state.showsAccountSnapshot ? state.accountSnapshot : nil,
            freshness: state.displayFreshness,
            configuration: state.settings.menuBarConfiguration,
            now: now
        )

        if let symbolName = presentation.symbolName {
            let color = renderedStatusColor(presentation.symbolSeverity, for: button)
            let image = StatusItemSymbolRenderer.image(named: symbolName, color: color,
                usesBetaGlyph: presentation.usesBetaGlyph(configuration: state.settings.menuBarConfiguration, identity: state.identity))
            button.image = image
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = nil
        } else {
            button.image = nil
            button.contentTintColor = nil
        }

        let displaySegments = presentation.displaySegments
        let hasColoredText = displaySegments.contains { $0.severity != .neutral }
        if hasColoredText {
            let title = NSMutableAttributedString()
            for segment in displaySegments {
                let font: NSFont = segment.usesMonospacedDigits
                    ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                    : .menuBarFont(ofSize: NSFont.systemFontSize)
                var attributes: [NSAttributedString.Key: Any] = [.font: font]
                if let color = renderedStatusColor(segment.severity, for: button) {
                    attributes[.foregroundColor] = color
                }
                title.append(NSAttributedString(string: segment.text, attributes: attributes))
            }
            button.title = ""
            button.attributedTitle = title
        } else {
            // A plain NSStatusBarButton title automatically follows the menu
            // bar's contrast treatment, including wallpaper tint and highlight.
            button.attributedTitle = NSAttributedString()
            button.font = .monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            )
            button.title = displaySegments.map(\.text).joined()
        }
        button.imagePosition = presentation.symbolName == nil ? .noImage : displaySegments.isEmpty ? .imageOnly : .imageLeading
        statusItem.length = NSStatusItem.variableLength
        let channelPrefix = AppIdentity.current.showsBetaBranding ? "TokenTach Beta: " : ""
        button.toolTip = channelPrefix + presentation.tooltip
        button.setAccessibilityLabel(channelPrefix + presentation.accessibilityLabel)
        scheduleStatusUpdate(at: presentation.nextUpdateAt, now: now)
    }

    private func scheduleStatusUpdate(at date: Date?, now: Date) {
        statusUpdateTimer?.invalidate()
        statusUpdateTimer = nil
        guard let date, date > now else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        timer.tolerance = min(5, max(0.1, date.timeIntervalSince(now) * 0.02))
        RunLoop.main.add(timer, forMode: .common)
        statusUpdateTimer = timer
    }

    private func statusColor(_ severity: MenuBarSeverity) -> NSColor? {
        switch severity {
        case .neutral: nil
        case .normal: .systemGreen
        case .caution: .systemYellow
        case .critical: .systemRed
        }
    }

    private func renderedStatusColor(_ severity: MenuBarSeverity, for _: NSStatusBarButton) -> NSColor? {
        guard let color = statusColor(severity) else { return nil }
        return color.usingColorSpace(.deviceRGB) ?? color
    }

    private func installSystemTimeObservers() {
        NotificationCenter.default.addObserver(
            systemTimeNotificationRelay,
            selector: #selector(MainActorNotificationRelay.receive(_:)),
            name: .NSSystemClockDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            systemTimeNotificationRelay,
            selector: #selector(MainActorNotificationRelay.receive(_:)),
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            systemTimeNotificationRelay,
            selector: #selector(MainActorNotificationRelay.receive(_:)),
            name: .NSCalendarDayChanged,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            systemTimeNotificationRelay,
            selector: #selector(MainActorNotificationRelay.receive(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private var preferredPopoverHeight: CGFloat {
        if !state.showsAccountSnapshot { return 300 }
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
        let menuBarPresentation = MenuBarPresentationBuilder.make(
            snapshot: state.accountSnapshot,
            freshness: state.displayFreshness,
            configuration: state.settings.menuBarConfiguration,
            now: .now
        )
        if menuBarPresentation.statusNotice != nil { height += 58 }
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
