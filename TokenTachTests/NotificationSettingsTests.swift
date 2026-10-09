import AppKit
import Testing
@testable import TokenTach

@MainActor private final class PermissionFixture: NotificationScheduling {
    var status: NotificationAuthorizationState = .notDetermined
    var requests = 0
    var readToHold = false
    var heldRead: CheckedContinuation<NotificationAuthorizationState, Never>?
    func requestAuthorization() async -> Bool { requests += 1; status = .authorized; return true }
    func authorizationStatus() async -> NotificationAuthorizationState {
        if readToHold {
            readToHold = false
            return await withCheckedContinuation { heldRead = $0 }
        }
        return status
    }
    func evaluate(snapshot: AccountSnapshot, thresholds: [Int]) async {}
    func evaluate(conversations: [ConversationTelemetry]) async {}
}

@MainActor struct NotificationSettingsTests {
    @Test func permissionIsRequestedOnlyWhenUndeterminedAndRefreshNeverPrompts() async {
        let fixture = PermissionFixture()
        let state = AppState(notifications: fixture, startImmediately: false)
        await state.refreshNotificationAuthorization()
        #expect(state.notificationAuthorization == .notDetermined)
        #expect(fixture.requests == 0)
        let allowed = await state.requestNotificationPermission()
        #expect(allowed)
        #expect(fixture.requests == 1)
        #expect(!state.isRequestingNotificationPermission)
        _ = await state.requestNotificationPermission()
        #expect(fixture.requests == 1)
        fixture.status = .denied
        let denied = await state.requestNotificationPermission()
        #expect(!denied)
        #expect(state.notificationAuthorization == .denied)
        #expect(fixture.requests == 1)
        fixture.status = .authorized
        await state.refreshNotificationAuthorization()
        #expect(state.notificationAuthorization == .authorized)
        #expect(fixture.requests == 1)
    }

    @Test func stalePermissionReadCannotOverwriteCompletedRequest() async {
        let fixture = PermissionFixture()
        fixture.readToHold = true
        let state = AppState(notifications: fixture, startImmediately: false)
        let oldRead = Task { await state.refreshNotificationAuthorization() }
        while fixture.heldRead == nil { await Task.yield() }
        _ = await state.requestNotificationPermission()
        fixture.heldRead?.resume(returning: .denied)
        await oldRead.value
        #expect(state.notificationAuthorization == .authorized)
    }

    @Test func betaIconMigratesPersistsAndKeepsWarningSymbols() throws {
        var configuration = try JSONDecoder().decode(MenuBarConfiguration.self, from: Data("{}".utf8))
        #expect(configuration.usesBetaIcon)
        let beta = AppIdentity(bundleIdentifier: AppIdentity.betaBundleIdentifier)
        let stable = AppIdentity(bundleIdentifier: AppIdentity.stableBundleIdentifier)
        let snapshot = DemoData.state().accountSnapshot
        func presentation(_ freshness: DataFreshness = .fresh) -> MenuBarPresentation {
            MenuBarPresentationBuilder.make(snapshot: snapshot, freshness: freshness, configuration: configuration, now: .now)
        }
        #expect(presentation().usesBetaGlyph(configuration: configuration, identity: beta))
        #expect(!presentation().usesBetaGlyph(configuration: configuration, identity: stable))
        configuration.usesBetaIcon = false
        let decoded = try JSONDecoder().decode(MenuBarConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(!decoded.usesBetaIcon)
        #expect(!presentation().usesBetaGlyph(configuration: configuration, identity: beta))
        configuration.usesBetaIcon = true
        configuration.showsGauge = false
        #expect(!presentation().usesBetaGlyph(configuration: configuration, identity: beta))
        configuration.showsGauge = true
        let unavailable = MenuBarPresentationBuilder.make(snapshot: nil, freshness: .unavailable, configuration: configuration, now: .now)
        #expect(!unavailable.usesBetaGlyph(configuration: configuration, identity: beta))
        let image = try #require(StatusItemSymbolRenderer.image(named: "gauge.with.dots.needle.33percent", color: nil, usesBetaGlyph: true))
        #expect(image.isTemplate)
        #expect(image.size.width == 16 && image.size.height == 18)
    }
}
