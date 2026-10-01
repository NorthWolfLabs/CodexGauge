import AppKit
import Foundation
import Observation
import Security

private struct CompanionPublisherCredentials: Codable {
    var id: String
    var server: URL
    var publisher: String
    var reader: String
    var usageReader: String
}

@MainActor @Observable final class CompanionPublisher {
    #if DEBUG
    var serverText = "https://codexgauge-relay-dev.north-wolf-labs.workers.dev"
    #else
    var serverText = ""
    #endif
    var status = "Not linked"
    var error: String?
    var isBusy = false
    private(set) var enabled = false
    private(set) var viewingLink: URL?
    private(set) var usageLink: URL?
    private var credentials: CompanionPublisherCredentials?
    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private let session = CompanionNoRedirect.session()
    private let snapshot: @MainActor (String) -> CompanionSnapshot?

    init(snapshot: @escaping @MainActor (String) -> CompanionSnapshot?) {
        self.snapshot = snapshot
        if let data = CompanionCredentialStore.read("publisher"),
           let saved = try? CompanionCoding.decoder.decode(CompanionPublisherCredentials.self, from: data) {
            credentials = saved; serverText = saved.server.absoluteString
            enabled = UserDefaults.standard.bool(forKey: "companionEnabled")
            updateLinks(saved)
        }
    }
    func startIfEnabled() { if enabled { start() } }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value, forKey: "companionEnabled")
        stop()
        if value { start() } else { status = "Paused" }
    }
    func create() async {
        guard !isBusy, let server = URL(string: serverText.trimmingCharacters(in: .whitespacesAndNewlines)), CompanionLink.validServer(server) else {
            error = "Enter the HTTPS address of your CodexGauge relay."; return
        }
        isBusy = true; defer { isBusy = false }
        do {
            let value = CompanionPublisherCredentials(id: UUID().uuidString.lowercased(), server: server,
                publisher: try randomToken(), reader: try randomToken(), usageReader: try randomToken())
            try await configure(value, action: "initialize")
            try CompanionCredentialStore.save(CompanionCoding.encoder.encode(value), key: "publisher")
            stop(); credentials = value; updateLinks(value); error = nil; setEnabled(true)
        } catch { self.error = "The relay couldn’t be configured. Check its address and connection." }
    }
    func revokeViewingLinks() async {
        guard var value = credentials, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            value.reader = try randomToken(); value.usageReader = try randomToken()
            try await configure(value, action: "rotate")
            try CompanionCredentialStore.save(CompanionCoding.encoder.encode(value), key: "publisher")
            credentials = value; updateLinks(value); error = nil
        } catch { self.error = "Viewing links couldn’t be replaced. Try again." }
    }
    func copyLink(usageOnly: Bool) {
        guard let url = usageOnly ? usageLink : viewingLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    func disconnect() async {
        guard let value = credentials, !isBusy else { return }
        isBusy = true; stop()
        defer { isBusy = false }
        do {
            try await configure(value, action: "feed")
            setEnabled(false)
            CompanionCredentialStore.remove("publisher")
            credentials = nil; viewingLink = nil; usageLink = nil
            status = "Not linked"; error = nil
        } catch {
            self.error = "Relay data couldn’t be removed. Check the connection and try again."
            if enabled { start() }
        }
    }
    private func updateLinks(_ value: CompanionPublisherCredentials) {
        viewingLink = CompanionLink(id: value.id, server: value.server, token: value.reader, name: "Mac").shareURL
        usageLink = CompanionLink(id: value.id, server: value.server, token: value.usageReader, name: "Mac").shareURL
    }
    private func configure(_ value: CompanionPublisherCredentials, action: String) async throws {
        var request = URLRequest(url: value.server.appending(path: "v1/macs/\(value.id)/\(action)"))
        request.httpMethod = action == "feed" ? "DELETE" : "POST"
        request.setValue("Bearer \(value.publisher)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["reader": value.reader, "usageReader": value.usageReader])
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CompanionError.rejected }
        var count = 0
        for try await _ in bytes {
            count += 1
            guard count <= 4096 else { throw CompanionError.invalidData }
        }
    }
    private func stop() {
        loop?.cancel(); loop = nil; socket?.cancel(with: .normalClosure, reason: nil); socket = nil
    }
    private func start() {
        guard loop == nil, let value = credentials else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            var failures = 0
            while !Task.isCancelled {
                var components = URLComponents(url: value.server.appending(path: "v1/macs/\(value.id)/stream"), resolvingAgainstBaseURL: false)!
                components.scheme = value.server.scheme == "https" ? "wss" : "ws"
                var request = URLRequest(url: components.url!)
                request.setValue("Bearer \(value.publisher)", forHTTPHeaderField: "Authorization")
                let socket = self.session.webSocketTask(with: request)
                socket.maximumMessageSize = 1024
                self.socket = socket; socket.resume(); self.status = "Connecting…"
                var previous: CompanionSnapshot?
                var lastSent = Date.distantPast
                do {
                    while !Task.isCancelled {
                        if var current = self.snapshot(value.id) {
                            let observedAt = current.observedAt
                            current.observedAt = .distantPast
                            if current != previous || Date.now.timeIntervalSince(lastSent) >= 30 {
                                previous = current; current.observedAt = observedAt
                                let bytes = try current.encodedForTransport()
                                guard bytes.count < 128 * 1024 else { throw CompanionError.invalidData }
                                try await CompanionSocket.send(.string(String(decoding: bytes, as: UTF8.self)), on: socket)
                                // An acknowledgment is the only inbound application message.
                                // Nothing from this connection is dispatched to Codex or a shell.
                                let response = try await CompanionSocket.receive(socket, timeout: .seconds(15))
                                let data: Data
                                switch response {
                                case .data(let bytes): data = bytes
                                case .string(let text): data = Data(text.utf8)
                                @unknown default: throw CompanionError.invalidData
                                }
                                let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                                guard reply?["type"] as? String == "accepted" else { throw CompanionError.invalidData }
                                try Task.checkCancellation()
                                self.status = "Publishing"; self.error = nil; failures = 0; lastSent = .now
                            }
                        }
                        try await Task.sleep(for: .seconds(1))
                    }
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    guard !Task.isCancelled else { break }
                    failures += 1; self.status = "Offline · reconnecting"
                    try? await Task.sleep(for: .seconds(min(30, pow(2, Double(min(5, failures))))))
                }
            }
        }
    }
    private func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.coderInvalidValue) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension AppState {
    func companionSnapshot(installationID: String) -> CompanionSnapshot {
        let account = accountSnapshot.map { snapshot in
            CompanionAccount(id: companionAccountID ?? "unverified:\(installationID)", plan: snapshot.plan.map { CompanionText.prefix($0) },
                observedAt: snapshot.fetchedAt,
                windows: snapshot.buckets.flatMap { bucket in bucket.windows.map { window in
                    CompanionWindow(id: bucket.id + ":" + window.id, name: CompanionText.prefix(bucket.name + " " + window.durationName),
                        remainingPercent: window.remainingPercent, resetsAt: window.resetsAt)
                }}.prefix(30).map { $0 }, bankedResets: snapshot.earnedResetCount,
                lifetimeTokens: snapshot.activity.lifetimeTokens,
                dailyTokens: snapshot.activity.dailyUsage.suffix(2000).map { day in
                    CompanionDay(id: String(format: "%04d-%02d-%02d", day.day.year, day.day.month, day.day.day), tokens: day.tokens)
                }, credits: snapshot.buckets.prefix(30).compactMap { bucket in
                    bucket.credits.map { credit in
                        CompanionCredit(id: CompanionText.prefix(bucket.id), name: CompanionText.prefix(bucket.name),
                            hasCredits: credit.hasCredits, unlimited: credit.unlimited,
                            balance: credit.balance.map { CompanionText.prefix($0) })
                    }
                }, metrics: CompanionAccountMetrics(peakDailyTokens: snapshot.activity.peakDailyTokens,
                    longestTurnSeconds: snapshot.activity.longestRunningTurnSeconds,
                    currentStreakDays: snapshot.activity.currentStreakDays, longestStreakDays: snapshot.activity.longestStreakDays),
                email: snapshot.email.map { CompanionText.prefix($0) }, accountType: CompanionText.prefix(snapshot.accountType),
                historyTruncated: snapshot.activity.dailyUsage.count > 2000, historyObservedAt: snapshot.activityObservedAt)
        }
        var selected = Array(conversations.lazy.filter(\.isLive).prefix(200))
        if selected.count < 200 {
            selected.append(contentsOf: conversations.lazy.filter { !$0.isLive && $0.completionEventAt != nil }.prefix(200 - selected.count))
        }
        let tasks = selected.map { task in
            let hasTokens = task.hasTokenObservation ?? (task.tokensPerMinute > 0)
            let hasRecordedTokens = hasTokens || task.totalTokens > 0
            return CompanionTask(id: ResetAccountIdentity.digest(task.id, salt: installationID), title: CompanionText.prefix(task.title),
                project: task.projectName.map { CompanionText.prefix($0) },
                state: task.state == .needsApproval ? .needsApproval : task.state == .needsInput ? .needsInput : task.state == .running ? .running : .completed,
                activity: task.activity.title, tokensPerMinute: max(0, task.tokensPerMinute), totalTokens: max(0, task.totalTokens),
                contextPercent: task.latestContextPercent.map { min(100, max(0, $0)) }, startedAt: task.turnStartedAt,
                eventAt: task.isLive ? task.attentionEventAt : task.completionEventAt, agentCount: task.agentCount,
                observedAt: task.lastActivity, hasTokenObservation: hasTokens,
                metrics: CompanionTaskMetrics(model: task.model.map { CompanionText.prefix($0) },
                    fiveMinuteRate: !hasTokens ? nil : task.tokensPerFiveMinutes,
                    callsPerMinute: task.callsPerMinute,
                    input: !hasRecordedTokens ? nil : task.recentTokenMix.input,
                    cachedInput: !hasRecordedTokens ? nil : task.recentTokenMix.cachedInput,
                    cacheWriteInput: !hasRecordedTokens ? nil : task.recentTokenMix.cacheWriteInput,
                    output: !hasRecordedTokens ? nil : task.recentTokenMix.output,
                    reasoning: !hasRecordedTokens ? nil : task.recentTokenMix.reasoningOutput,
                    latestOutput: task.latestOutputTokens, firstTokenMilliseconds: task.timeToFirstTokenMilliseconds,
                    lastTurnSeconds: task.lastTurnDurationSeconds, contextIncludesAgent: task.contextIncludesAgent, tokenTotalsComplete: task.hasCompleteTokenTotals))
        }
        let name = CompanionText.prefix(Host.current().localizedName ?? "Mac", utf16Limit: 80)
        return CompanionSnapshot(id: installationID, name: name.isEmpty ? "Mac" : name,
                                 observedAt: .now, account: account, tasks: tasks)
    }
}
