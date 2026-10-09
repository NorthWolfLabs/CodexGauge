import Foundation
import Testing
@testable import TokenTach

private actor PathValidator: CodexExecutableValidating {
    let accepted: String
    init(_ accepted: String) { self.accepted = accepted }
    func validate(_ candidate: URL) async throws -> URL {
        guard candidate.path == accepted else { throw CodexExecutableTrustError.untrusted }
        return candidate
    }
}

private struct MissingHelper: CodexExecutableLocating {
    func locate(override: String?) async -> URL? { nil }
}

private actor IndependentSessions: SessionTelemetryProviding {
    private(set) var started = false
    func snapshots() async -> AsyncStream<[ConversationTelemetry]> {
        started = true
        return AsyncStream { $0.yield([]); $0.finish() }
    }
    func stop() async {}
}

struct ConnectionRecoveryTests {
    @Test func discoversStandaloneAndUserBinOnlyAfterSignatureValidation() async {
        let home = URL(fileURLWithPath: "/fixture/home")
        for relative in [".codex/packages/standalone/current/bin/codex", ".local/bin/codex"] {
            let expected = home.appending(path: relative)
            let locator = DefaultCodexExecutableLocator(validator: PathValidator(expected.path), homeDirectory: home)
            #expect(await locator.locate(override: "/untrusted/codex") == expected)
        }
        let rejecting = DefaultCodexExecutableLocator(validator: PathValidator("/never"), homeDirectory: home)
        #expect(await rejecting.locate(override: nil) == nil)
    }

    @MainActor @Test func sessionMonitoringStartsEvenWhenAccountHelperIsMissing() async throws {
        let suite = "ConnectionRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = IndependentSessions()
        let access = ScopedCodexAccess(defaults: defaults, required: true, backend: FakeBookmarks())
        try access.select(URL(fileURLWithPath: "/fixture/data"), for: .directory)
        let state = AppState(settings: SettingsStore(defaults: defaults), locator: MissingHelper(),
                             startImmediately: false, sessionProvider: sessions, codexAccess: access)
        await state.reconnect()
        for _ in 0..<20 where !state.hasLoadedConversations {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await sessions.started)
        #expect(state.hasLoadedConversations)
        #expect(state.executableURL == nil)
        #expect(!state.showsAccountSnapshot)
        state.accountSnapshot = AccountSnapshot(accountType: "chatgpt", plan: "pro", buckets: [],
            earnedResetCount: nil, activity: .empty, fetchedAt: .now)
        #expect(!state.showsAccountSnapshot)
    }
}

private actor SwitchingAccount: AccountTelemetryProviding {
    var id = "A"
    var activityFails = false
    var hold = false
    var pending: CheckedContinuation<AccountActivity, any Error>?
    func switchTo(_ value: String, failing: Bool = false) { id = value; activityFails = failing }
    func holdActivity() { hold = true }
    func isPending() -> Bool { pending != nil }
    func releaseActivity() { pending?.resume(returning: Self.activity); pending = nil; hold = false }
    static let activity = AccountActivity(lifetimeTokens: 999, peakDailyTokens: 999, longestRunningTurnSeconds: nil,
        currentStreakDays: nil, longestStreakDays: nil, dailyUsage: [])
    func fetchAccountIdentity() async throws -> AccountIdentity {
        // Same type, plan and personal identity; workspace account ID differs.
        AccountIdentity(accountType: "chatgpt", plan: "pro", personalAccountHash: "same-person", email: "alex@example.com")
    }
    func fetchRateLimits() async throws -> RateLimitSnapshot {
        RateLimitSnapshot(plan: "pro", buckets: [], earnedResetCount: nil, fetchedAt: .now, accountID: id)
    }
    func fetchAccountActivity() async throws -> AccountActivity {
        if hold { return try await withCheckedThrowingContinuation { pending = $0 } }
        if activityFails { throw CocoaError(.fileReadUnknown) }
        return Self.activity
    }
    func events() async -> AsyncStream<AppServerEvent> { AsyncStream { $0.finish() } }
    func stop() async {}
}

extension ConnectionRecoveryTests {
    @MainActor @Test func accountSwitchDoesNotRelabelPreviousActivityWhenNewActivityFails() async {
        let suite = "AccountBindingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = SwitchingAccount()
        let cacheURL = FileManager.default.temporaryDirectory.appending(path: "AccountBindingTests-\(UUID().uuidString)/snapshot.json")
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let cache = SnapshotCache(fileURL: cacheURL)
        let state = AppState(settings: SettingsStore(defaults: defaults), cache: cache, startImmediately: false, accountProvider: account)
        await state.refreshIdentityAndActivity(using: account)
        let original = state.accountSnapshot!.accountKey
        #expect(state.accountSnapshot?.activity.lifetimeTokens == 999)
        await account.switchTo("B", failing: true)
        await state.refreshIdentityAndActivity(using: account)
        #expect(state.accountSnapshot?.accountKey != original)
        #expect(state.accountSnapshot?.activity == .empty)
        #expect(state.accountSnapshot?.email == "alex@example.com")
    }

    @MainActor @Test func inFlightActivityFromPreviousAccountCannotOverwriteFreshAccount() async {
        let suite = "AccountBindingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = SwitchingAccount()
        let cacheURL = FileManager.default.temporaryDirectory.appending(path: "AccountBindingTests-\(UUID().uuidString)/snapshot.json")
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let cache = SnapshotCache(fileURL: cacheURL)
        let state = AppState(settings: SettingsStore(defaults: defaults), cache: cache, startImmediately: false, accountProvider: account)
        await state.refreshLimits()
        await account.holdActivity()
        let refresh = Task { await state.refreshIdentityAndActivity(using: account) }
        for _ in 0..<100 where !(await account.isPending()) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await account.isPending())
        await account.switchTo("B", failing: true)
        await state.refreshLimits()
        let key = state.accountSnapshot?.accountKey
        await account.releaseActivity()
        await refresh.value
        #expect(state.accountSnapshot?.accountKey == key)
        #expect(state.accountSnapshot?.activity == .empty)
    }

    @MainActor @Test func persistedLegacyCacheCannotBecomeVerifiedHistoryAndMatchedCacheCan() async throws {
        let suite = "AccountBindingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cacheURL = FileManager.default.temporaryDirectory.appending(path: "AccountBindingTests-\(UUID().uuidString)/snapshot.json")
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let cache = SnapshotCache(fileURL: cacheURL)
        let legacy = AccountSnapshot(accountType: "chatgpt", plan: "pro", buckets: [], earnedResetCount: nil,
            activity: SwitchingAccount.activity, fetchedAt: .now)
        await cache.save(legacy)
        let account = SwitchingAccount()
        let state = AppState(settings: SettingsStore(defaults: defaults), cache: cache, startImmediately: false, accountProvider: account)
        await state.loadCachedSnapshot()
        #expect(state.accountSnapshot?.activity.lifetimeTokens == 999)
        await state.refreshLimits()
        #expect(state.accountSnapshot?.activity == .empty)
        await state.refreshIdentityAndActivity(using: account)
        let verified = state.accountSnapshot!
        await cache.save(verified)
        let reopened = AppState(settings: SettingsStore(defaults: defaults), cache: cache, startImmediately: false, accountProvider: account)
        await reopened.loadCachedSnapshot()
        await reopened.refreshLimits()
        #expect(reopened.accountSnapshot?.activity.lifetimeTokens == 999)
        await account.switchTo("B", failing: true)
        await reopened.refreshIdentityAndActivity(using: account)
        #expect(reopened.accountSnapshot?.activity == .empty)
        #expect((await cache.load())?.accountKey == reopened.accountSnapshot?.accountKey)
    }

    @Test func legacyCacheCannotBecomeVerifiedHistoryWithoutMatchingIdentity() {
        #expect(AccountHistoryIdentity.activity(SwitchingAccount.activity, recordedKey: nil, currentKey: "B") == .empty)
        #expect(AccountHistoryIdentity.activity(SwitchingAccount.activity, recordedKey: "A", currentKey: "B") == .empty)
        #expect(AccountHistoryIdentity.activity(SwitchingAccount.activity, recordedKey: "A", currentKey: "A").lifetimeTokens == 999)
    }
}
