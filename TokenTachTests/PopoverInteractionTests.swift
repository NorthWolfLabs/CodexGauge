import AppKit
import Testing
@testable import TokenTach

@MainActor struct PopoverInteractionTests {
    @Test func anchorTracksScreenMovementDefersMenusAndStopsCleanly() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 30),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        window.contentView = anchor
        let originalFrame = anchor.postsFrameChangedNotifications
        let originalBounds = anchor.postsBoundsChangedNotifications
        var updates = 0
        var menuOpen = false
        let tracker = PopoverAnchorTracker(canUpdate: { !menuOpen }, update: { _ in updates += 1 })
        tracker.start(view: anchor)
        defer { tracker.stop() }
        window.setFrameOrigin(NSPoint(x: 140, y: 100))
        window.setFrameOrigin(NSPoint(x: 160, y: 100))
        try await Task.sleep(for: .milliseconds(40))
        #expect(updates == 1)
        tracker.changed()
        try await Task.sleep(for: .milliseconds(40))
        #expect(updates == 1)
        menuOpen = true
        window.setFrameOrigin(NSPoint(x: 200, y: 100))
        try await Task.sleep(for: .milliseconds(40))
        #expect(updates == 1)
        menuOpen = false
        tracker.changed()
        try await Task.sleep(for: .milliseconds(40))
        #expect(updates == 2)
        window.setFrameOrigin(NSPoint(x: 220, y: 100))
        tracker.stop()
        try await Task.sleep(for: .milliseconds(40))
        #expect(updates == 2)
        #expect(anchor.postsFrameChangedNotifications == originalFrame)
        #expect(anchor.postsBoundsChangedNotifications == originalBounds)
    }

    @Test func outsideClickDismissalDoesNotRequireAppActivation() {
        let status = NSRect(x: 400, y: 900, width: 60, height: 24)
        let panel = NSRect(x: 250, y: 500, width: 390, height: 400)
        #expect(PopoverInteractionPolicy.shouldDismissPointer(at: NSPoint(x: 470, y: 910),
            statusFrame: status, popoverFrame: panel, isLocal: false, trackingOwnMenu: false))
        #expect(PopoverInteractionPolicy.shouldDismissPointer(at: NSPoint(x: 470, y: 910),
            statusFrame: status, popoverFrame: panel, isLocal: true, trackingOwnMenu: false))
        #expect(!PopoverInteractionPolicy.shouldDismissPointer(at: NSPoint(x: 430, y: 910),
            statusFrame: status, popoverFrame: panel, isLocal: true, trackingOwnMenu: false))
        #expect(!PopoverInteractionPolicy.shouldDismissPointer(at: NSPoint(x: 430, y: 600),
            statusFrame: status, popoverFrame: panel, isLocal: true, trackingOwnMenu: false))
        #expect(!PopoverInteractionPolicy.shouldDismissPointer(at: NSPoint(x: 700, y: 600),
            statusFrame: status, popoverFrame: panel, isLocal: true, trackingOwnMenu: true))
        #expect(PopoverInteractionPolicy.shouldDismissPointer(at: NSPoint(x: 700, y: 910),
            statusFrame: status, popoverFrame: panel, isLocal: false, trackingOwnMenu: true))
    }

    @Test func activationHandoffDoesNotCancelOpeningOrStealFocusLater() {
        var request = PopoverOpeningRequest(originPID: 41)
        let staleOrigin = request.shouldCancel(activatedPID: 41, currentPID: 42)
        let ownActivation = request.shouldCancel(activatedPID: 42, currentPID: 42)
        let leaving = request.shouldCancel(activatedPID: 41, currentPID: 42)
        #expect(!staleOrigin)
        #expect(!ownActivation)
        #expect(leaving)
        var fresh = PopoverOpeningRequest(originPID: 41)
        let otherApplication = fresh.shouldCancel(activatedPID: 99, currentPID: 42)
        #expect(otherApplication)
    }
}
