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

struct CompanionPairedDevice: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let scope: String
    let pairedAt: Date
    let lastSeen: Date
    let connected: Bool
}

@MainActor @Observable final class CompanionPublisher {
    // Pairing has one action, so its existing service must be configured in
    // every build rather than requiring a hidden manual address field.
    private var serverText = "https://codexgauge-relay-dev.north-wolf-labs.workers.dev"
    var error: String?
    var isBusy = false
    private(set) var devices: [CompanionPairedDevice] = []
    private(set) var devicesError: String?
    private(set) var isLoadingDevices = false
    private(set) var enabled = false
    private(set) var viewingLink: URL?
    private var credentials: CompanionPublisherCredentials?
    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var pushTask: Task<Void, Never>?
    private var journal = CompanionPushJournal()
    private var nextPushAt = Date.distantPast
    private var pushFailures = 0
    private var refreshRequested = false
    private var awaitingAckSince: Date?
    private var readerFailed = false
    private var connectionID = UUID()
    private var journalURL: URL? {
        guard let credentials else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: AppIdentity.current.supportDirectoryName)
            .appending(path: "relay-outbox-" + credentials.id + ".json")
    }
    private let session = CompanionNoRedirect.session()
    private var deviceRevision = 0
    private var isPreview = false
    private let snapshot: @MainActor (String) -> CompanionSnapshot?

    init(snapshot: @escaping @MainActor (String) -> CompanionSnapshot?) {
        self.snapshot = snapshot
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-companionDevicesDemo") {
            isPreview = true
            let url = URL(string: "https://example.invalid")!
            viewingLink = CompanionLink(id: "11111111-2222-4333-8444-555555555555", server: url, token: String(repeating: "b", count: 64), name: "Fixture Mac").shareURL
            enabled = true
            devices = [CompanionPairedDevice(id: "22222222-2222-4333-8444-555555555555", name: "Fixture iPhone", scope: "full", pairedAt: .now, lastSeen: .now, connected: true), CompanionPairedDevice(id: "33333333-2222-4333-8444-555555555555", name: "Spare iPhone", scope: "usage", pairedAt: .now, lastSeen: .now.addingTimeInterval(-86400), connected: false)]
            return
        }
        #endif
        if let data = CompanionCredentialStore.read("publisher"),
           let saved = try? CompanionCoding.decoder.decode(CompanionPublisherCredentials.self, from: data) {
            credentials = saved; serverText = saved.server.absoluteString
            enabled = UserDefaults.standard.bool(forKey: "companionEnabled")
            updateLinks(saved)
            if let url = journalURL, let data = try? Data(contentsOf: url), data.count <= 32 * 1024 * 1024,
               let restored = try? CompanionCoding.decoder.decode(CompanionPushJournal.self, from: data) { journal = restored }
        }
    }
    func startIfEnabled() { if enabled { start() } }
    func setEnabled(_ value: Bool) {
        guard !isPreview else { return }
        enabled = value; UserDefaults.standard.set(value, forKey: "companionEnabled")
        stop()
        if value { start() }
    }
    func create() async {
        guard !isBusy, let server = URL(string: serverText.trimmingCharacters(in: .whitespacesAndNewlines)), CompanionLink.validServer(server) else {
            error = "Enter the HTTPS address of your CodexGauge relay."; return
        }
        isBusy = true; defer { isBusy = false }
        do {
            let value = CompanionPublisherCredentials(id: UUID().uuidString.lowercased(), server: server,
                publisher: try randomToken(), reader: try randomToken(), usageReader: try randomToken())
            try await configure(value)
            try CompanionCredentialStore.save(CompanionCoding.encoder.encode(value), key: "publisher")
            stop(); credentials = value; journal = CompanionPushJournal(); updateLinks(value); error = nil; setEnabled(true)
        } catch { self.error = "The relay couldn’t be configured. Check its address and connection." }
    }
    func refreshDevices() async {
        guard !isPreview, let value = credentials, !isLoadingDevices else { return }
        isLoadingDevices = true; defer { isLoadingDevices = false }
        let revision = deviceRevision
        do {
            let data = try await deviceRequest(value, method: "GET")
            struct Response: Decodable { let devices: [CompanionPairedDevice] }
            let response = try CompanionCoding.decoder.decode(Response.self, from: data)
            guard response.devices.count <= 16, response.devices.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.name.utf16.count <= 80 }) else { throw CompanionError.invalidData }
            guard credentials?.id == value.id, deviceRevision == revision else { return }
            devices = response.devices.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
            devicesError = nil
        } catch is CancellationError { }
        catch { if deviceRevision == revision { devicesError = "Paired devices couldn’t be loaded. Check your connection and try again." } }
    }
    func removeDevice(_ device: CompanionPairedDevice) async {
        guard let value = credentials, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        deviceRevision += 1
        do {
            _ = try await deviceRequest(value, method: "DELETE", deviceID: device.id)
            devices.removeAll { $0.id == device.id }; error = nil
            await refreshDevices()
        } catch { self.error = "The device couldn’t be removed. Check your connection and try again." }
    }
    private func deviceRequest(_ value: CompanionPublisherCredentials, method: String, deviceID: String? = nil) async throws -> Data {
        var request = URLRequest(url: value.server.appending(path: "v1/macs/\(value.id)/devices"))
        request.httpMethod = method; request.timeoutInterval = 15
        request.setValue("Bearer \(value.publisher)", forHTTPHeaderField: "Authorization")
        if let deviceID {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["id": deviceID])
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CompanionError.rejected }
        var data = Data()
        for try await byte in bytes { guard data.count < 16 * 1024 else { throw CompanionError.invalidData }; data.append(byte) }
        return data
    }
    func copyLink() {
        guard !isPreview else { return }
        guard let url = viewingLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    private func updateLinks(_ value: CompanionPublisherCredentials) {
        viewingLink = CompanionLink(id: value.id, server: value.server, token: value.reader, name: "Mac").shareURL
    }
    private func configure(_ value: CompanionPublisherCredentials) async throws {
        var request = URLRequest(url: value.server.appending(path: "v1/macs/\(value.id)/initialize"))
        request.httpMethod = "POST"
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
        connectionID = UUID()
        loop?.cancel(); loop = nil; pushTask?.cancel(); pushTask = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
    }
    private func saveJournal() throws {
        guard let url = journalURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CompanionCoding.encoder.encode(journal).write(to: url, options: .atomic)
    }
    private func publishPush(_ snapshot: CompanionSnapshot, using value: CompanionPublisherCredentials) throws {
        if try journal.observe(snapshot) { try saveJournal() }
        guard pushTask == nil, Date.now >= nextPushAt else { return }
        let batch = try journal.batch(latest: snapshot), owner = connectionID
        nextPushAt = .now.addingTimeInterval(5)
        pushTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.connectionID == owner { self.pushTask = nil } }
            do {
                var request = URLRequest(url: value.server.appending(path: "v1/macs/\(value.id)/push"))
                request.httpMethod = "POST"; request.timeoutInterval = 25
                request.setValue("Bearer \(value.publisher)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = batch
                let (data, response) = try await self.session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4096 else { throw CompanionError.rejected }
                struct Accepted: Decodable { let acceptedThrough: Date }
                let accepted = try CompanionCoding.decoder.decode(Accepted.self, from: data)
                try Task.checkCancellation()
                guard self.connectionID == owner else { return }
                if self.journal.acknowledge(through: accepted.acceptedThrough) { try self.saveJournal() }
                self.pushFailures = 0
            } catch is CancellationError { }
            catch {
                guard self.connectionID == owner else { return }
                self.pushFailures += 1
                self.nextPushAt = .now.addingTimeInterval(min(30, pow(2, Double(min(5, self.pushFailures)))))
                self.error = "Live viewing is connected. Phone alerts are waiting to reconnect."
            }
        }
    }
    private func start() {
        guard loop == nil, let value = credentials else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            // A fresh relay namespace intentionally has no old pairing state.
            // Initializing our own installation is idempotently rejected (409)
            // when it already exists; no remote credentials are overwritten.
            try? await self.configure(value)
            var failures = 0
            while !Task.isCancelled {
                let owner = UUID(); self.connectionID = owner
                self.readerFailed = false; self.awaitingAckSince = nil; self.refreshRequested = true
                self.nextPushAt = .distantPast; self.pushFailures = 0
                var components = URLComponents(url: value.server.appending(path: "v1/macs/\(value.id)/stream"), resolvingAgainstBaseURL: false)!
                components.scheme = value.server.scheme == "https" ? "wss" : "ws"
                var request = URLRequest(url: components.url!)
                request.setValue("Bearer \(value.publisher)", forHTTPHeaderField: "Authorization")
                let socket = self.session.webSocketTask(with: request)
                socket.maximumMessageSize = 1024
                self.socket = socket; socket.resume()
                // The only control message requests fresh display telemetry. It
                // cannot launch a process, approve a task, or execute a command.
                let reader = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let message = try await CompanionSocket.receive(socket, timeout: .seconds(75))
                            guard let self, self.connectionID == owner else { return }
                            let data: Data
                            switch message {
                            case .data(let bytes): data = bytes
                            case .string(let text): data = Data(text.utf8)
                            @unknown default: throw CompanionError.invalidData
                            }
                            guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CompanionError.invalidData }
                            if reply["type"] as? String == "refresh" { self.refreshRequested = true }
                            else if reply["type"] as? String == "accepted", reply["observedAt"] as? Double != nil {
                                self.awaitingAckSince = nil
                                if self.pushFailures == 0 { self.error = nil }
                            } else { throw CompanionError.invalidData }
                        }
                    } catch { if self?.connectionID == owner { self?.readerFailed = true } }
                }
                var previous: CompanionSnapshot?
                var lastSent = Date.distantPast
                do {
                    while !Task.isCancelled {
                        if self.readerFailed || self.awaitingAckSince.map({ Date.now.timeIntervalSince($0) > 15 }) == true { throw CompanionError.rejected }
                        if var current = self.snapshot(value.id) {
                            // The HTTP delivery task never blocks the foreground
                            // stream. Journal only semantic transitions locally.
                            let urgent = try current.notificationSignature() != previous?.notificationSignature()
                            if urgent && self.pushFailures == 0 { self.nextPushAt = .distantPast }
                            if !current.activeTasks.isEmpty || !self.journal.pending.isEmpty || Date.now.timeIntervalSince(lastSent) >= 30 || urgent {
                                try self.publishPush(current, using: value)
                            }
                            let observedAt = current.observedAt
                            current.observedAt = .distantPast
                            if self.awaitingAckSince == nil && (self.refreshRequested || current != previous || Date.now.timeIntervalSince(lastSent) >= 30) {
                                previous = current; current.observedAt = observedAt
                                let bytes = try current.encodedForTransport()
                                self.awaitingAckSince = .now; self.refreshRequested = false
                                try await CompanionSocket.send(.string(String(decoding: bytes, as: UTF8.self)), on: socket)
                                lastSent = .now; failures = 0
                            }
                        }
                        try await Task.sleep(for: .seconds(1))
                    }
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    if !Task.isCancelled {
                        failures += 1
                        self.error = "The relay is unavailable. Reconnecting automatically."
                    }
                }
                reader.cancel(); self.pushTask?.cancel(); self.pushTask = nil
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(min(30, pow(2, Double(min(5, failures))))))
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
    /// Loading local telemetry is not evidence that all tasks have finished.
    func companionSnapshotForPublication(installationID: String) -> CompanionSnapshot? {
        guard hasLoadedConversations else { return nil }
        return companionSnapshot(installationID: installationID)
    }

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
                activity: task.activityTitle, tokensPerMinute: max(0, task.tokensPerMinute), totalTokens: max(0, task.totalTokens),
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
