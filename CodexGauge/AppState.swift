import AppKit
import Foundation
import Observation

enum RefreshBackoff {
    static func delay(forFailureCount failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return 0 }
        return min(120, pow(2, Double(min(7, failureCount))))
    }
}

enum ConnectionRecoveryBackoff {
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        min(120, max(15, RefreshBackoff.delay(forFailureCount: max(1, attempt))))
    }
}

@MainActor
@Observable
final class AppState {
    let settings: SettingsStore
    private let locator: any CodexExecutableLocating
    private let executableValidator: any CodexExecutableValidating
    private let cache: SnapshotCache
    private let notifications: any NotificationScheduling
    private let clock: any ClockProviding

    private var accountProvider: (any AccountTelemetryProviding)?
    private var sessionProvider: (any SessionTelemetryProviding)?
    private var refreshLoop: Task<Void, Never>?
    private var activityLoop: Task<Void, Never>?
    private var eventLoop: Task<Void, Never>?
    private var sessionLoop: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var connectionRecoveryTask: Task<Void, Never>?
    private var failureCount = 0
    private var accountIdentity: AccountIdentity?
    private var accountActivity: AccountActivity = .empty
    private var snapshotPersistencePolicy = SnapshotPersistencePolicy()
    private var quotaNotificationEvaluationPolicy = QuotaNotificationEvaluationPolicy()
    private var lastAttentionSignature: String?

    var accountSnapshot: AccountSnapshot?
    var conversations: [ConversationTelemetry] = []
    var hasLoadedConversations = false
    var freshness: DataFreshness = .loading
    var errorMessage: String?
    var executableURL: URL?
    private var isRefreshing = false
    var notificationAuthorization: NotificationAuthorizationState = .notDetermined
    var executableValidationMessage: String?

    init(
        settings: SettingsStore = SettingsStore(),
        locator: (any CodexExecutableLocating)? = nil,
        executableValidator: any CodexExecutableValidating = DefaultCodexExecutableValidator(),
        cache: SnapshotCache = SnapshotCache(),
        notifications: (any NotificationScheduling)? = nil,
        clock: any ClockProviding = SystemClock(),
        startImmediately: Bool = true
    ) {
        self.settings = settings
        self.executableValidator = executableValidator
        self.locator = locator ?? DefaultCodexExecutableLocator(validator: executableValidator)
        self.cache = cache
        self.clock = clock
        self.notifications = notifications ?? UserNotificationScheduler(clock: clock)
        if startImmediately {
            Task { await bootstrap() }
        }
    }

    var remainingPercent: Int? { accountSnapshot?.limitingWindow?.remainingPercent }
    var currentDate: Date { clock.now }
    var displayFreshness: DataFreshness {
        guard freshness == .fresh, let fetchedAt = accountSnapshot?.fetchedAt else { return freshness }
        let maximumAge = max(180, settings.refreshInterval * 3)
        return clock.now.timeIntervalSince(fetchedAt) > maximumAge ? .stale : .fresh
    }

    func bootstrap() async {
        if let cached = await cache.load() {
            accountSnapshot = cached
            accountActivity = cached.activity
            freshness = .stale
        }
        notificationAuthorization = await notifications.authorizationStatus()
        await connect()
    }

    func reconnect() async {
        connectionRecoveryTask?.cancel()
        connectionRecoveryTask = nil
        await stopProviders()
        executableURL = nil
        await connect()
    }

    private func refreshLimits() async {
        guard let accountProvider, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let limits = try await accountProvider.fetchRateLimits()
            let identity: AccountIdentity
            if let accountIdentity {
                identity = accountIdentity
            } else if let snapshot = accountSnapshot {
                identity = AccountIdentity(accountType: snapshot.accountType, plan: snapshot.plan)
            } else {
                identity = try await accountProvider.fetchAccountIdentity()
            }
            accountIdentity = identity
            let snapshot = AccountSnapshot(
                accountType: identity.accountType,
                plan: identity.plan ?? limits.plan,
                buckets: limits.buckets,
                earnedResetCount: limits.earnedResetCount,
                activity: accountActivity,
                fetchedAt: limits.fetchedAt
            )
            accountSnapshot = snapshot
            freshness = .fresh
            errorMessage = nil
            failureCount = 0
            await persistSnapshotIfNeeded(snapshot)
            if settings.quotaNotificationsEnabled,
               quotaNotificationEvaluationPolicy.shouldEvaluate(
                   snapshot,
                   thresholds: settings.notificationThresholds
               ) {
                await notifications.evaluate(snapshot: snapshot, thresholds: settings.notificationThresholds)
            }
        } catch {
            failureCount += 1
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            freshness = accountSnapshot == nil ? .unavailable : .stale
        }
    }

    func requestNotificationPermission() async -> Bool {
        let granted = await notifications.requestAuthorization()
        notificationAuthorization = await notifications.authorizationStatus()
        return granted
    }

    func refreshNotificationAuthorization() async {
        notificationAuthorization = await notifications.authorizationStatus()
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func validateAndUseExecutable(_ url: URL) async -> Bool {
        let trustedURL: URL
        do {
            trustedURL = try await executableValidator.validate(url)
        } catch {
            executableValidationMessage = (error as? LocalizedError)?.errorDescription ?? "Choose a Codex helper signed by OpenAI."
            return false
        }
        let candidate = CodexAppServerClient(
            executableURL: trustedURL,
            codexHomeURL: settings.codexHomeURL,
            clock: clock,
            executableValidator: executableValidator
        )
        do {
            try await candidate.validateConnection()
            await candidate.stop()
            settings.executableOverride = trustedURL.path
            executableValidationMessage = "OpenAI-signed Codex helper verified."
            await reconnect()
            executableValidationMessage = nil
            return true
        } catch {
            await candidate.stop()
            executableValidationMessage = "This executable could not start the Codex app server."
            return false
        }
    }

    func rescheduleRefresh() {
        guard accountProvider != nil else { return }
        refreshLoop?.cancel()
        startRefreshLoop()
    }

    func openChatGPT() {
        let locations = [
            "/Applications/ChatGPT.app",
            "\(NSHomeDirectory())/Applications/ChatGPT.app"
        ]
        if let path = locations.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        }
    }

    private func connect(scheduleRecovery: Bool = true) async {
        guard !Task.isCancelled else { return }
        let locatedExecutable = await locator.locate(override: settings.executableOverride)
        guard !Task.isCancelled else { return }
        guard let executable = locatedExecutable else {
            executableURL = nil
            hasLoadedConversations = true
            freshness = accountSnapshot == nil ? .unavailable : .stale
            errorMessage = CodexAppServerError.executableUnavailable.localizedDescription
            if scheduleRecovery { startConnectionRecoveryLoop() }
            return
        }
        executableURL = executable
        hasLoadedConversations = false
        let account = CodexAppServerClient(
            executableURL: executable,
            codexHomeURL: settings.codexHomeURL,
            clock: clock,
            executableValidator: executableValidator
        )
        let sessions = LocalSessionMonitor(codexHomeURL: settings.codexHomeURL, clock: clock)
        accountProvider = account
        sessionProvider = sessions
        startLoops(account: account, sessions: sessions)
        await refreshIdentityAndActivity(using: account)
        await refreshLimits()
    }

    private func startConnectionRecoveryLoop() {
        guard connectionRecoveryTask == nil else { return }
        connectionRecoveryTask = Task { [weak self] in
            var attempt = 1
            while !Task.isCancelled {
                let delay = ConnectionRecoveryBackoff.delay(forAttempt: attempt)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { break }
                guard self.accountProvider == nil else { break }
                await self.connect(scheduleRecovery: false)
                guard self.accountProvider == nil else { break }
                attempt += 1
            }
        }
    }

    private func startLoops(
        account: any AccountTelemetryProviding,
        sessions: any SessionTelemetryProviding
    ) {
        startRefreshLoop()
        activityLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                guard !Task.isCancelled else { break }
                await self?.refreshIdentityAndActivity(using: account)
            }
        }
        eventLoop = Task { [weak self] in
            let events = await account.events()
            for await event in events {
                guard !Task.isCancelled else { break }
                switch event.kind {
                case .rateLimitsChanged:
                    self?.scheduleEventLimitRefresh()
                case .accountChanged:
                    await self?.refreshIdentityAndActivity(using: account)
                    await self?.refreshLimits()
                }
            }
        }
        sessionLoop = Task { [weak self] in
            let stream = await sessions.snapshots()
            for await telemetry in stream {
                guard !Task.isCancelled else { break }
                let changed = await MainActor.run {
                    guard let self else { return false }
                    let changed = self.conversations != telemetry
                    if changed { self.conversations = telemetry }
                    self.hasLoadedConversations = true
                    return changed
                }
                let shouldEvaluateAttention = await MainActor.run { [weak self] in
                    guard let self, changed, self.settings.attentionNotificationsEnabled else { return false }
                    let signature = telemetry
                        .filter { $0.state == .needsApproval || $0.state == .needsInput }
                        .map {
                            "\($0.id)|\($0.state.rawValue)|\($0.attentionEventAt?.timeIntervalSince1970 ?? -1)"
                        }
                        .sorted()
                        .joined(separator: ";")
                    guard signature != self.lastAttentionSignature else { return false }
                    self.lastAttentionSignature = signature
                    return true
                }
                if shouldEvaluateAttention {
                    await self?.notifications.evaluate(conversations: telemetry)
                }
            }
        }
    }

    private func startRefreshLoop() {
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = await MainActor.run { self?.settings.refreshInterval ?? 60 }
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { break }
                await self?.refreshWithBackoff()
            }
        }
    }

    private func refreshWithBackoff() async {
        let delay = RefreshBackoff.delay(forFailureCount: failureCount)
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
        await refreshLimits()
    }

    private func scheduleEventLimitRefresh() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.refreshLimits()
        }
    }

    private func refreshIdentityAndActivity(using account: any AccountTelemetryProviding) async {
        do {
            accountIdentity = try await account.fetchAccountIdentity()
        } catch {
            if accountSnapshot == nil {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        do {
            let activity = try await account.fetchAccountActivity()
            accountActivity = activity
            if var snapshot = accountSnapshot {
                snapshot.activity = activity
                accountSnapshot = snapshot
                await persistSnapshotIfNeeded(snapshot)
            }
        } catch {
            // Aggregate activity is supplemental; retain the last successful value.
        }
    }

    private func stopProviders() async {
        refreshLoop?.cancel()
        activityLoop?.cancel()
        eventLoop?.cancel()
        sessionLoop?.cancel()
        eventRefreshTask?.cancel()
        refreshLoop = nil
        activityLoop = nil
        eventLoop = nil
        sessionLoop = nil
        eventRefreshTask = nil
        await accountProvider?.stop()
        await sessionProvider?.stop()
        accountProvider = nil
        accountIdentity = nil
        sessionProvider = nil
        conversations = []
        hasLoadedConversations = false
        lastAttentionSignature = nil
    }

    private func persistSnapshotIfNeeded(_ snapshot: AccountSnapshot) async {
        let resetSignature = snapshot.buckets.flatMap { bucket in
            bucket.windows.map { "\(bucket.id)|\($0.id)|\($0.resetsAt?.timeIntervalSince1970 ?? -1)" }
        }.joined(separator: ";")
        let remainingPercentages = Dictionary(uniqueKeysWithValues: snapshot.buckets.flatMap { bucket in
            bucket.windows.map { ("\(bucket.id)|\($0.id)", $0.remainingPercent) }
        })
        guard snapshotPersistencePolicy.shouldPersist(
            at: clock.now,
            resetSignature: resetSignature,
            remainingPercentages: remainingPercentages
        ) else { return }
        await cache.save(snapshot)
    }

}
