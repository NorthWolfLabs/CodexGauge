import AppKit
import Observation
import SwiftUI

enum SettingsPane: String, CaseIterable {
    case general
    case notifications

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gear"
        case .notifications: "bell"
        }
    }

    var toolbarIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("com.northwolflabs.CodexGauge.settings.\(rawValue)")
    }

    init?(toolbarIdentifier: NSToolbarItem.Identifier) {
        self.init(rawValue: toolbarIdentifier.rawValue.components(separatedBy: ".").last ?? "")
    }
}

@MainActor
@Observable
final class SettingsNavigationModel {
    var selection: SettingsPane = .general
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let helpShortcut: HelpShortcutMonitor
    private let state: AppState
    private let navigation = SettingsNavigationModel()

    init(state: AppState, onShowHelp: @escaping () -> Void) {
        self.state = state
        helpShortcut = HelpShortcutMonitor(onShowHelp: onShowHelp)
        let hostingController = NSHostingController(
            rootView: SettingsView(state: state, navigation: navigation)
                .codexGaugeWritingToolsDisabled()
        )
        let window = CodexGaugeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.showHelp = onShowHelp
        window.title = navigation.selection.title
        window.identifier = NSUserInterfaceItemIdentifier("codexgauge.settingsWindow")
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        let toolbar = NSToolbar(identifier: "com.northwolflabs.CodexGauge.settingsToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        toolbar.sizeMode = .regular
        toolbar.selectedItemIdentifier = navigation.selection.toolbarIdentifier
        window.center()

        super.init(window: window)
        toolbar.delegate = self
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        toolbar.selectedItemIdentifier = navigation.selection.toolbarIdentifier
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        Task { await state.refreshNotificationAuthorization() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.toolbar?.selectedItemIdentifier = navigation.selection.toolbarIdentifier
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.toolbar?.selectedItemIdentifier = self.navigation.selection.toolbarIdentifier
        }
        helpShortcut.enable()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        helpShortcut.enable()
    }

    func windowDidResignKey(_ notification: Notification) {
        helpShortcut.disable()
    }

    func windowWillClose(_ notification: Notification) {
        helpShortcut.disable()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarIdentifier)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane(toolbarIdentifier: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(toolbarIdentifier: sender.itemIdentifier) else { return }
        navigation.selection = pane
        window?.toolbar?.selectedItemIdentifier = pane.toolbarIdentifier
        window?.title = pane.title
    }
}
