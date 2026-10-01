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
    let identity: AppIdentity
    let settings: SettingsStore
    let codexAccess: ScopedCodexAccess
    var codexDataURL: URL { codexAccess.directoryURL ?? settings.codexHomeURL }
    var isChoosingCodexAccess = false
    @ObservationIgnored lazy var companion = CompanionPublisher { [weak self] id in self?.companionSnapshot(installationID: id) }
    private(set) var companionAccountID: String?
    private let alertStore: any AlertMonitorStoring
    @ObservationIgnored private lazy var alertMonitor = AlertMonitor(settings: settings, local: notifications, store: alertStore)
    private let locator: any CodexExecutableLocating
    private let executableValidator: any CodexExecutableValidating
    private let cache: SnapshotCache
    private let notifications: any NotificationScheduling
    private let clock: any ClockProviding

    private var accountProvider: (any AccountTelemetryProviding)?
    private var sessionProvider: (any SessionTelemetryProviding)?
    private let injectedSessionProvider: (any SessionTelemetryProviding)?
    private var refreshLoop: Task<Void, Never>?
    private var activityLoop: Task<Void, Never>?
    private var eventLoop: Task<Void, Never>?
    private var sessionLoop: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var connectionRecoveryTask: Task<Void, Never>?
    private var failureCount = 0
    private var accountIdentity: AccountIdentity?
    private var accountActivity: AccountActivity = .empty
    private var activityObservedAt: Date?
    private var activityAccountKey: String?
    private var observedAccountKey: String?
    private var snapshotPersistencePolicy = SnapshotPersistencePolicy()
    private var quotaNotificationEvaluationPolicy = QuotaNotificationEvaluationPolicy()
    private var lastAttentionSignature: String?

    var accountSnapshot: AccountSnapshot?
    var conversations: [ConversationTelemetry] = []
    var hasLoadedConversations = false
    var freshness: DataFreshness = .loading
    var errorMessage: String?
    var executableURL: URL?
    var showsAccountSnapshot: Bool { executableURL != nil && accountSnapshot != nil }
    private var isRefreshing = false
    private var refreshRequested = false
    private var accountGeneration = 0
    private var connectionGeneration = 0
    private let automaticMonitoring: Bool
    var notificationAuthorization: NotificationAuthorizationState = .checking
    var isRequestingNotificationPermission = false
    private var notificationAuthorizationRevision = 0
    var executableValidationMessage: String?

    init(
        settings: SettingsStore = SettingsStore(),
        locator: (any CodexExecutableLocating)? = nil,
        executableValidator: any CodexExecutableValidating = DefaultCodexExecutableValidator(),
        cache: SnapshotCache = SnapshotCache(),
        notifications: (any NotificationScheduling)? = nil,
        identity: AppIdentity = .current,
        clock: any ClockProviding = SystemClock(),
        startImmediately: Bool = true,
        sessionProvider: (any SessionTelemetryProviding)? = nil,
        accountProvider: (any AccountTelemetryProviding)? = nil,
        alertStore: (any AlertMonitorStoring)? = nil,
        codexAccess: ScopedCodexAccess? = nil
    ) {
        self.settings = settings
        self.codexAccess = codexAccess ?? ScopedCodexAccess()
        self.alertStore = alertStore ?? (startImmediately ? AlertMonitorStore() : MemoryAlertMonitorStore())
        self.injectedSessionProvider = sessionProvider
        self.accountProvider = accountProvider
        self.automaticMonitoring = startImmediately
        self.executableValidator = executableValidator
        self.locator = locator ?? DefaultCodexExecutableLocator(validator: executableValidator)
        self.cache = cache
        self.clock = clock
        self.notifications = notifications ?? UserNotificationScheduler(clock: clock)
        self.identity = identity

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
        companion.startIfEnabled()
        if automaticMonitoring { RetiredIntegrationCleanup.run(identity: identity) }
        await loadCachedSnapshot()
        await refreshNotificationAuthorization()
        await connect()
    }

    func loadCachedSnapshot() async {
        if let cached = await cache.load() {
            accountSnapshot = cached
            accountActivity = cached.activity
            activityObservedAt = cached.activityObservedAt
            activityAccountKey = cached.accountKey
            observedAccountKey = cached.accountKey
            freshness = .stale
        }
    }

    func reconnect() async {
        guard !isChoosingCodexAccess else { return }
        connectionGeneration += 1
        connectionRecoveryTask?.cancel()
        connectionRecoveryTask = nil
        await stopProviders()
        executableURL = nil
        await connect()
    }

    func refreshLimits() async {
        guard let accountProvider else { return }
        guard !isRefreshing else { refreshRequested = true; return }
        let generation = accountGeneration
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequested {
                refreshRequested = false
                Task { [weak self] in await self?.refreshLimits() }
            }
        }
        do {
            let identity = try await accountProvider.fetchAccountIdentity()
            let limits = try await accountProvider.fetchRateLimits()
            let confirmedIdentity = try await accountProvider.fetchAccountIdentity()
            guard generation == accountGeneration, !Task.isCancelled else { return }
            guard identity == confirmedIdentity else {
                invalidateAccountComparison(); refreshRequested = true; return
            }
            let key = AccountHistoryIdentity.key(limits: limits, identity: identity, salt: settings.resetIdentitySalt)
            if observedAccountKey != key {
                accountGeneration += 1
                snapshotPersistencePolicy = SnapshotPersistencePolicy()
                alertMonitor.suspend()
            }
            if activityAccountKey != key { activityObservedAt = nil }
            accountActivity = AccountHistoryIdentity.activity(accountActivity, recordedKey: activityAccountKey, currentKey: key)
            activityAccountKey = key
            observedAccountKey = key
            accountIdentity = identity
            companionAccountID = limits.accountID.flatMap { value in
                value.isEmpty ? nil : ResetAccountIdentity.digest(value, salt: "CodexGauge companion account v1")
            }
            let snapshot = AccountSnapshot(
                accountType: identity.accountType,
                plan: identity.plan ?? limits.plan,
                buckets: limits.buckets,
                earnedResetCount: limits.earnedResetCount,
                activity: accountActivity,
                fetchedAt: limits.fetchedAt, accountKey: key, email: identity.email, activityObservedAt: activityObservedAt
            )
            accountSnapshot = snapshot
            freshness = .fresh
            errorMessage = nil
            failureCount = 0
            alertMonitor.observe(limits, scope: ResetAccountIdentity.scope(
                limits: limits, identity: identity,
                salt: settings.resetIdentitySalt + codexDataURL.standardizedFileURL.path
            ))
            await persistSnapshotIfNeeded(snapshot)
            alertMonitor.observeTasks(conversations, at: clock.now)
        } catch {
            guard generation == accountGeneration, !Task.isCancelled else { return }
            alertMonitor.suspend()
            accountIdentity = nil
            failureCount += 1
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            freshness = accountSnapshot == nil ? .unavailable : .stale
        }
    }

    func refreshAfterWake() {
        guard automaticMonitoring, !isChoosingCodexAccess else { return }
        invalidateAccountComparison()
        Task { [weak self] in
            guard let self else { return }
            if self.accountProvider == nil { await self.reconnect() }
            else { await self.refreshLimits() }
        }
    }

    private func invalidateAccountComparison() {
        accountGeneration += 1
        accountIdentity = nil
        alertMonitor.suspend()
    }

    func alertRoutesChanged() {
        alertMonitor.routesChanged()
        refreshAfterWake()
    }

    func requestNotificationPermission() async -> Bool {
        guard !isRequestingNotificationPermission else { return false }
        isRequestingNotificationPermission = true
        notificationAuthorizationRevision += 1
        defer { isRequestingNotificationPermission = false }
        // Read the system's current choice before considering a prompt. Denied
        // permission can only be changed in System Settings, not by re-requesting.
        notificationAuthorization = await notifications.authorizationStatus()
        if notificationAuthorization == .notDetermined {
            _ = await notifications.requestAuthorization()
            notificationAuthorization = await notifications.authorizationStatus()
        }
        return notificationAuthorization == .authorized || notificationAuthorization == .provisional
    }

    func refreshNotificationAuthorization() async {
        guard !isRequestingNotificationPermission else { return }
        notificationAuthorizationRevision += 1
        let revision = notificationAuthorizationRevision
        let status = await notifications.authorizationStatus()
        guard revision == notificationAuthorizationRevision, !isRequestingNotificationPermission else { return }
        notificationAuthorization = status
    }

    func validateAndUseExecutable(_ url: URL) async -> Bool {
        guard !isChoosingCodexAccess else { return false }
        isChoosingCodexAccess = true
        defer { isChoosingCodexAccess = false }
        let temporaryGrant: ScopedCodexResource?
        let trustedURL: URL
        do {
            temporaryGrant = codexAccess.isRequired ? try codexAccess.temporaryAccess(to: url) : nil
            trustedURL = try await executableValidator.validate(url)
        } catch {
            executableValidationMessage = (error as? LocalizedError)?.errorDescription ?? "Choose a Codex helper signed by OpenAI."
            return false
        }
        defer { withExtendedLifetime(temporaryGrant) {} }
        if codexAccess.isRequired {
            connectionGeneration += 1
            await stopProviders()
            do {
                try codexAccess.select(url, for: .helper)
                settings.executableOverride = trustedURL.path
                executableValidationMessage = nil
            } catch {
                executableValidationMessage = "Access could not be saved. Choose the Codex helper again."
            }
            isChoosingCodexAccess = false
            await reconnect()
            return executableValidationMessage == nil
        }
        let candidate = CodexAppServerClient(
            executableURL: trustedURL,
            codexHomeURL: codexDataURL,
            clock: clock,
            executableValidator: executableValidator
        )
        do {
            try await candidate.validateConnection()
            await candidate.stop()
            settings.executableOverride = trustedURL.path
            executableValidationMessage = "OpenAI-signed Codex helper verified."
            isChoosingCodexAccess = false
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

    func useCodexDirectory(_ url: URL) async {
        guard !isChoosingCodexAccess else { return }
        isChoosingCodexAccess = true
        defer { isChoosingCodexAccess = false }
        connectionGeneration += 1
        await stopProviders()
        do {
            if codexAccess.isRequired { try codexAccess.select(url, for: .directory) }
            settings.codexHomeOverride = url.path
            executableValidationMessage = nil
        } catch {
            executableValidationMessage = "Access could not be saved. Choose the Codex data folder again."
        }
        isChoosingCodexAccess = false
        await reconnect()
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
        guard !Task.isCancelled, !isChoosingCodexAccess else { return }
        let connection = connectionGeneration
        if codexAccess.isRequired, codexAccess.directoryURL == nil {
            freshness = accountSnapshot == nil ? .unavailable : .stale
            errorMessage = codexAccess.restorationMessage ?? "Choose your Codex data folder in Settings to begin."
            return
        }
        if sessionProvider == nil {
            let sessions = injectedSessionProvider ?? LocalSessionMonitor(codexHomeURL: codexDataURL, clock: clock,
                                                                           scopedResources: codexAccess.retainedGrants())
            sessionProvider = sessions
            hasLoadedConversations = false
            startSessionLoop(sessions: sessions)
        }
        // A sandbox build uses only explicitly granted resources, never discovery fallbacks.
        let locatedExecutable: URL?
        if codexAccess.isRequired {
            locatedExecutable = codexAccess.helperURL
        } else {
            locatedExecutable = await locator.locate(override: settings.executableOverride)
        }
        guard !Task.isCancelled, connection == connectionGeneration, !isChoosingCodexAccess else { return }
        guard let executable = locatedExecutable else {
            executableURL = nil
            freshness = accountSnapshot == nil ? .unavailable : .stale
            errorMessage = codexAccess.isRequired ? "Choose the installed Codex helper in Settings."
                : CodexAppServerError.executableUnavailable.localizedDescription
            if scheduleRecovery && !codexAccess.isRequired { startConnectionRecoveryLoop() }
            return
        }
        executableURL = executable
        let account = CodexAppServerClient(
            executableURL: executable,
            codexHomeURL: codexDataURL,
            clock: clock,
            executableValidator: executableValidator,
            personalIdentitySalt: settings.resetIdentitySalt,
            scopedResources: codexAccess.retainedGrants()
        )
        accountProvider = account
        startLoops(account: account)
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

    private func startLoops(account: any AccountTelemetryProviding) {
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
                    self?.invalidateAccountComparison()
                    await self?.refreshIdentityAndActivity(using: account)
                    await self?.refreshLimits()
                }
            }
        }
    }

    private func startSessionLoop(sessions: any SessionTelemetryProviding) {
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
                if changed {
                    self?.alertMonitor.observeTasks(telemetry, at: self?.clock.now ?? .now)
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

    func refreshIdentityAndActivity(using account: any AccountTelemetryProviding) async {
        await refreshLimits()
        let generation = accountGeneration
        guard let key = observedAccountKey, accountIdentity != nil else { return }
        let activity = try? await account.fetchAccountActivity()
        guard generation == accountGeneration, !Task.isCancelled else { return }
        do {
            // Check both account/read identity and rate-limit account ID after the
            // supplemental request. A delayed A response cannot be attached to B.
            let identity = try await account.fetchAccountIdentity()
            let limits = try await account.fetchRateLimits()
            guard generation == accountGeneration, !Task.isCancelled else { return }
            guard AccountHistoryIdentity.key(limits: limits, identity: identity, salt: settings.resetIdentitySalt) == key else {
                invalidateAccountComparison()
                await refreshLimits()
                return
            }
            guard let activity else { return } // Same account: keep its last observation.
            accountActivity = activity
            activityObservedAt = clock.now
            activityAccountKey = key
            if var snapshot = accountSnapshot, snapshot.accountKey == key {
                snapshot.activity = activity
                snapshot.activityObservedAt = activityObservedAt
                accountSnapshot = snapshot
                await persistSnapshotIfNeeded(snapshot)
            }
        } catch {
            // Identity continuity is unverified; do not promote a supplemental result.
        }
    }

    private func stopProviders() async {
        invalidateAccountComparison()
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
