import Foundation
import UIKit
import Security
import Observation
import WidgetKit
import UserNotifications

@MainActor @Observable final class CompanionStore {
    var snapshots: [String: CompanionSnapshot] = [:] {
        didSet {
            // Live task ticks do not change account history. Keep that observation
            // independent so they cannot rebuild every chart and navigation root.
            if oldValue.mapValues(\.account) != snapshots.mapValues(\.account) {
                accounts = CompanionMerge.accounts(orderedSnapshots)
            }
            let choices = CompanionActivityScope.choices(orderedSnapshots)
            if activityChoices != choices { activityChoices = choices }
        }
    }
    private(set) var accounts: [CompanionAccount] = []
    private(set) var activityChoices: [CompanionActivityScope] = []
    var taskHistory = CompanionTaskHistory()
    var links: [CompanionLink] = []
    var connectionStatus: [String: String] = [:]
    var error: String?
    var unlinkError: String?
    private(set) var removingLinks: Set<String> = []
    private(set) var isPairing = false
    var isPreview = false
    private var workers: [String: Task<Void, Never>] = [:]
    private var sockets: [String: URLSessionWebSocketTask] = [:]
    private let session = CompanionNoRedirect.session()
    private var foreground = false
    private var lastWidgetSave = Date.distantPast

    var orderedSnapshots: [CompanionSnapshot] { snapshots.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) } }

    init() {
        defer {
            accounts = CompanionMerge.accounts(orderedSnapshots)
            activityChoices = CompanionActivityScope.choices(orderedSnapshots)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-companionUITest") || ProcessInfo.processInfo.arguments.contains("-companionDemo"),
           let fixture = ProcessInfo.processInfo.environment["COMPANION_TEST_CLIPBOARD"] {
            UIPasteboard.general.string = fixture
        }
        if ProcessInfo.processInfo.arguments.contains("-companionLiveActivityReview") {
            isPreview = true
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-companionUITest") && ProcessInfo.processInfo.arguments.contains("-companionResetUITestLinks") {
            CompanionCredentialStore.remove("viewing-links")
        }
        if ProcessInfo.processInfo.arguments.contains("-companionDemo") {
            isPreview = true
            var fixtures = CompanionFixtures.snapshots()
            if ProcessInfo.processInfo.arguments.contains("-companionSingleDeviceDemo") { fixtures = Array(fixtures.prefix(1)) }
            if ProcessInfo.processInfo.arguments.contains("-companionTaskLayoutDemo") {
                fixtures = Array(fixtures.prefix(1))
                let now = Date.now
                fixtures[0].tasks[0].title = "output"
                fixtures[0].tasks[0].project = "Computer"
                fixtures[0].tasks[0].contextPercent = 67
                fixtures[0].tasks[0].observedAt = now.addingTimeInterval(-3600)
                fixtures[0].tasks[0].startedAt = now.addingTimeInterval(-3943)
                fixtures[0].tasks[1] = fixtures[0].tasks[0]
                fixtures[0].tasks[1].id = "task2"
                fixtures[0].tasks[1].title = "Review a very long task title with Unicode 🧑🏽‍💻 and an unbroken identifier ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
                fixtures[0].tasks[1].project = "A project with an unusually long name"
                fixtures[0].tasks[1].state = .running
                fixtures[0].tasks[1].activity = "Using a tool with a long descriptive name"
                fixtures[0].tasks[1].observedAt = now
                fixtures[0].tasks[1].startedAt = now.addingTimeInterval(-260000)
                fixtures[0].tasks[1].metrics?.contextIncludesAgent = true
            }
            if ProcessInfo.processInfo.arguments.contains("-companionSinglePointDemo") {
                for index in fixtures.indices {
                    let days = fixtures[index].account?.dailyTokens ?? []
                    fixtures[index].account?.dailyTokens = Array(days.suffix(1))
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-companionEmptyHistoryDemo") {
                for index in fixtures.indices { fixtures[index].account?.dailyTokens = [] }
            }
            if ProcessInfo.processInfo.arguments.contains("-companionMultiAccountDemo") {
                fixtures[1].account?.id = "demo-second-account"
                fixtures[1].account?.email = "sam@example.com"
                fixtures[1].account?.windows[0].remainingPercent = 42
                fixtures[1].account?.lifetimeTokens = 1_000
                let days = fixtures[1].account!.dailyTokens.map { CompanionDay(id: $0.id, tokens: 10) }
                fixtures[1].account?.dailyTokens = days
            }
            if ProcessInfo.processInfo.arguments.contains("-companionUnknownAccountDemo") {
                for index in fixtures.indices { fixtures[index].account?.email = nil }
            }
            if ProcessInfo.processInfo.arguments.contains("-companionStaleAccountDemo") {
                for index in fixtures.indices {
                    let old = Date.now.addingTimeInterval(-86400)
                    fixtures[index].observedAt = old; fixtures[index].account?.observedAt = old
                    fixtures[index].account?.historyObservedAt = old
                    fixtures[index].account?.dailyTokens.removeLast()
                    for task in fixtures[index].tasks.indices {
                        fixtures[index].tasks[task].observedAt = nil
                        if fixtures[index].tasks[task].startedAt != nil { fixtures[index].tasks[task].startedAt = old.addingTimeInterval(-318) }
                    }
                }
            }
            snapshots = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.id, $0) })
            let now = Date.now
            for seconds in stride(from: -118, through: 0, by: 2) {
                let observed = now.addingTimeInterval(Double(seconds))
                for var snapshot in orderedSnapshots {
                    snapshot.observedAt = observed
                    for index in snapshot.tasks.indices where snapshot.tasks[index].state == .running {
                        snapshot.tasks[index].tokensPerMinute = 1800 + 600 * sin(Double(seconds) / 13)
                    }
                    taskHistory.record(snapshot, now: observed)
                }
            }
            CompanionWidgetCache.save(orderedSnapshots)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-companionRelayDemo") {
            links = [
                CompanionLink(id: "33333333-3333-4333-8333-333333333333", server: URL(string: "http://127.0.0.1:8789")!, token: String(repeating: "b", count: 64), name: "Fixture MacBook"),
                CompanionLink(id: "44444444-4444-4444-8444-444444444444", server: URL(string: "http://127.0.0.1:8789")!, token: String(repeating: "b", count: 64), name: "Fixture Mac mini")
            ]
            return
        }
        #endif
        if let data = CompanionCredentialStore.read("viewing-links"),
           let saved = try? CompanionCoding.decoder.decode([CompanionLink].self, from: data) { links = saved }
        for item in CompanionWidgetCache.read() where links.contains(where: { $0.id == item.id }) { snapshots[item.id] = item }
    }

    func add(_ url: URL) async {
        guard !isPairing else { return }
        isPairing = true; defer { isPairing = false }
        do {
            let shared = try CompanionLink(url: url)
            guard links.count < 12 || links.contains(where: { $0.id == shared.id }) else {
                error = "You can link up to 12 Macs."; return
            }
            let link = try await pair(shared)
            do { try Task.checkCancellation() } catch { try? await unpair(link); throw error }
            let previous = links.first { $0.id == link.id }
            var next = links.filter { $0.id != link.id }; next.append(link)
            do { try CompanionCredentialStore.save(CompanionCoding.encoder.encode(next), key: "viewing-links") }
            catch { try? await unpair(link); throw error }
            if let previous, previous.deviceID != nil { try? await unpair(previous) }
            stop(link.id)
            // A replacement may grant usage-only access. Do not keep displaying
            // task data cached under the preceding capability while connecting.
            snapshots.removeValue(forKey: link.id)
            taskHistory.remove(mac: link.id)
            CompanionWidgetCache.save(orderedSnapshots)
            WidgetCenter.shared.reloadAllTimelines()
            links = next
            CompanionPush.shared.setLinks(links)
            error = nil
            if foreground { connect(link) }
        } catch is CancellationError { }
        catch let error as CompanionError { self.error = error.localizedDescription }
        catch { self.error = "Couldn’t reach the Mac’s connection service. Check your internet connection and try scanning or pasting again." }
    }

    private func pair(_ shared: CompanionLink) async throws -> CompanionLink {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CompanionError.invalidData }
        var paired = shared
        paired.deviceID = UUID().uuidString.lowercased()
        paired.token = bytes.map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: shared.server.appending(path: "v1/macs/\(shared.id)/pair"))
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("Bearer \(shared.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": paired.deviceID!, "name": CompanionText.prefix(UIDevice.current.name, utf16Limit: 80), "token": paired.token])
        let (stream, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CompanionError.rejected }
        var data = Data()
        for try await byte in stream { guard data.count < 4096 else { throw CompanionError.invalidData }; data.append(byte) }
        guard (try JSONSerialization.jsonObject(with: data) as? [String: Bool])?["ok"] == true else { throw CompanionError.invalidData }
        return paired
    }
    private func unpair(_ link: CompanionLink) async throws {
        guard link.deviceID != nil else { return }
        var request = URLRequest(url: link.server.appending(path: "v1/macs/\(link.id)/pair"))
        request.httpMethod = "DELETE"; request.timeoutInterval = 15
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode, code == 200 || code == 401 else { throw CompanionError.rejected }
        var count = 0
        for try await _ in bytes { count += 1; guard count <= 4096 else { throw CompanionError.invalidData } }
    }
    func remove(_ link: CompanionLink) async {
        guard removingLinks.insert(link.id).inserted else { return }
        defer { removingLinks.remove(link.id) }
        unlinkError = nil
        do {
            try await CompanionPush.shared.unlink(link)
            try await unpair(link)
            guard links.contains(link) else {
                CompanionPush.shared.setLinks(links)
                return
            }
            let next = links.filter { $0.id != link.id }
            try CompanionCredentialStore.save(CompanionCoding.encoder.encode(next), key: "viewing-links")
            stop(link.id); links = next; snapshots.removeValue(forKey: link.id)
            taskHistory.remove(mac: link.id)
            CompanionPush.shared.setLinks(links)
            CompanionWidgetCache.save(orderedSnapshots); WidgetCenter.shared.reloadAllTimelines()
        } catch {
            CompanionPush.shared.setLinks(links)
            unlinkError = "The Mac couldn’t be unlinked. Check your connection and try again so its push subscription can be removed too."
        }
    }

    func setForeground(_ active: Bool) {
        foreground = active
        guard !isPreview else { return }
        CompanionLiveActivities.shared.setForeground(active)
        if active {
            CompanionPush.shared.setLinks(links)
            for link in links where workers[link.id] == nil { connect(link) }
        } else {
            for id in Array(workers.keys) { stop(id) }
            CompanionWidgetCache.save(orderedSnapshots)
        }
    }

    private func stop(_ id: String) {
        workers.removeValue(forKey: id)?.cancel()
        sockets.removeValue(forKey: id)?.cancel(with: .normalClosure, reason: nil)
        connectionStatus[id] = "Disconnected"
    }

    @concurrent private static func decodeEnvelope(_ data: Data) async throws -> CompanionEnvelope {
        try CompanionCoding.decoder.decode(CompanionEnvelope.self, from: data)
    }

    private func connect(_ original: CompanionLink) {
        workers[original.id] = Task { [weak self] in
            guard let self else { return }
            var link = original
            if original.deviceID == nil, !self.isPreview, let paired = try? await self.pair(original) {
                if Task.isCancelled || !self.links.contains(original) { try? await self.unpair(paired); return }
                let next = self.links.map { $0 == original ? paired : $0 }
                do {
                    try CompanionCredentialStore.save(CompanionCoding.encoder.encode(next), key: "viewing-links")
                    self.links = next; link = paired
                    CompanionPush.shared.setLinks(next)
                } catch { try? await self.unpair(paired) }
            }
            var failures = 0
            while !Task.isCancelled {
                var parts = URLComponents(url: link.server.appending(path: "v1/macs/\(link.id)/stream"), resolvingAgainstBaseURL: false)!
                parts.scheme = link.server.scheme == "https" ? "wss" : "ws"
                var request = URLRequest(url: parts.url!)
                request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
                let socket = self.session.webSocketTask(with: request)
                socket.maximumMessageSize = 256 * 1024
                self.sockets[link.id] = socket
                self.connectionStatus[link.id] = "Connecting…"
                socket.resume()
                let heartbeat = CompanionSocket.keepAlive(socket)
                defer { heartbeat.cancel() }
                var receivedSnapshot = false
                do {
                    while !Task.isCancelled {
                        let message = try await CompanionSocket.receive(socket)
                        try Task.checkCancellation()
                        let data: Data
                        switch message {
                        case .data(let bytes): data = bytes
                        case .string(let string):
                            if string == "pong" { continue }
                            data = Data(string.utf8)
                        @unknown default: throw CompanionError.invalidData
                        }
                        let envelope = try await Self.decodeEnvelope(data)
                        if envelope.type == "waiting" { self.connectionStatus[link.id] = "Waiting for Mac"; continue }
                        guard envelope.type == "snapshot", let snapshot = envelope.snapshot,
                              snapshot.schemaVersion == 1, snapshot.id.lowercased() == link.id.lowercased() else { throw CompanionError.invalidData }
                        self.snapshots[link.id] = snapshot
                        self.taskHistory.record(snapshot)
                        CompanionLiveActivities.shared.update(snapshot, deliveryTimestamp: envelope.deliveryTimestamp)
                        self.connectionStatus[link.id] = "Connected"
                        if !receivedSnapshot {
                            receivedSnapshot = true
                            CompanionPush.shared.setLinks(self.links)
                        }
                        failures = 0
                        if Date.now.timeIntervalSince(self.lastWidgetSave) > 30 {
                            CompanionWidgetCache.save(self.orderedSnapshots)
                            WidgetCenter.shared.reloadAllTimelines()
                            self.lastWidgetSave = .now
                        }
                    }
                } catch {
                    let closeCode = socket.closeCode
                    let status = (socket.response as? HTTPURLResponse)?.statusCode
                    socket.cancel(with: .goingAway, reason: nil)
                    guard !Task.isCancelled else { break }
                    if closeCode == .policyViolation || status == 401 || status == 403 {
                        self.snapshots.removeValue(forKey: link.id)
                        self.taskHistory.remove(mac: link.id)
                        CompanionLiveActivities.shared.end(macID: link.id)
                        CompanionWidgetCache.save(self.orderedSnapshots)
                        WidgetCenter.shared.reloadAllTimelines()
                        self.connectionStatus[link.id] = "Access revoked — add a new link"
                        break
                    }
                    self.connectionStatus[link.id] = "Offline · reconnecting"
                    failures += 1
                    try? await Task.sleep(for: .seconds(min(30, pow(2, Double(min(failures, 5))))))
                }
            }
        }
    }
}
