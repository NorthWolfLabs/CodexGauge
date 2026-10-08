import Foundation
import Security

/// Credentials stay in each app's Keychain, never in the widget snapshot.
struct CompanionCredentialStore {
    static func read(_ key: String) -> Data? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func save(_ data: Data, key: String) throws {
        let query = base(key)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        } else if status != errSecSuccess { throw CocoaError(.fileWriteUnknown) }
    }
    static func remove(_ key: String) { SecItemDelete(base(key) as CFDictionary) }
    private static func base(_ key: String) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "CodexGauge") + ".companion",
         kSecAttrAccount as String: key]
        #if os(iOS)
        value[kSecAttrService as String] = "com.northwolflabs.CodexGauge.mobile.companion"
        if let group = Bundle.main.object(forInfoDictionaryKey: "CompanionKeychainGroup") as? String, !group.isEmpty {
            value[kSecAttrAccessGroup as String] = group
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-companionUITest") {
            value[kSecAttrService as String] = "com.northwolflabs.CodexGauge.mobile.companion.uitests"
        }
        #endif
        #endif
        return value
    }
}

final class CompanionNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    static func session(timeout: TimeInterval = 15) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration, delegate: CompanionNoRedirect(), delegateQueue: nil)
    }
}

struct CompanionEnvelope: Decodable, Sendable {
    var deliveryTimestamp: Double?
    var type: String
    var snapshot: CompanionSnapshot?
}

enum CompanionSocket {
    static func receive(_ socket: URLSessionWebSocketTask, timeout: Duration = .seconds(75)) async throws -> URLSessionWebSocketTask.Message {
        try await withDeadline(socket, timeout: timeout) { try await socket.receive() }
    }

    static func send(_ message: URLSessionWebSocketTask.Message, on socket: URLSessionWebSocketTask,
                     timeout: Duration = .seconds(15)) async throws {
        try await withDeadline(socket, timeout: timeout) { try await socket.send(message) }
    }

    static func keepAlive(_ socket: URLSessionWebSocketTask) -> Task<Void, Never> {
        Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(30))
                    // The relay answers without waking its hibernating object.
                    // This only checks the relay connection, not Mac freshness.
                    try await send(.string("ping"), on: socket)
                }
            } catch {
                if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
            }
        }
    }

    private static func withDeadline<Value: Sendable>(_ socket: URLSessionWebSocketTask, timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    socket.cancel(with: .goingAway, reason: nil)
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}

enum CompanionRegistrationSync {
    /// ActivityKit can wake the app briefly to deliver a new token. Recover a
    /// transient request failure during that wake instead of waiting for a reopen.
    static func retryLiveRegistration(isolation: isolated (any Actor)? = #isolation,
                                     sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                                     register: () async throws -> Void) async throws {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { try await register(); return }
            catch CompanionError.rejected { throw CompanionError.rejected }
            catch is CancellationError { throw CancellationError() }
            catch {
                if attempt == 2 { throw error }
                try await sleep(.seconds(attempt == 0 ? 2 : 4))
            }
        }
    }
    /// Each Mac is independent. A disconnected or revoked link must not prevent
    /// other linked Macs from receiving this device's current alert choices.
    static func failures(links: [CompanionLink], isolation: isolated (any Actor)? = #isolation,
                         register: (CompanionLink) async throws -> Void) async -> Int {
        var failures = 0
        for link in links {
            do { try await register(link) }
            catch { failures += 1 }
        }
        return failures
    }
}

#if os(iOS)
import WidgetKit

enum CompanionWidgetCache {
    static let group = "group.com.northwolflabs.CodexGauge"
    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appending(path: "companion-snapshot.json")
    }
    static func read() -> [CompanionSnapshot] {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2_000_000), data.count < 2_000_000 else { return [] }
        return (try? CompanionCoding.decoder.decode([CompanionSnapshot].self, from: data)) ?? []
    }
    static func save(_ snapshots: [CompanionSnapshot]) {
        guard let url, let data = try? CompanionCoding.encoder.encode(snapshots) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func refresh() async -> [CompanionSnapshot] {
        guard let links = savedLinks() else { return [] }
        let session = CompanionNoRedirect.session(timeout: 4)
        defer { session.invalidateAndCancel() }
        let updates = await withTaskGroup(of: CompanionFetchUpdate.self) { group in
            for link in links.prefix(12) {
                group.addTask { CompanionFetchUpdate(link: link, result: await fetch(link, session: session)) }
            }
            var values: [CompanionFetchUpdate] = []
            for await result in group { values.append(result) }
            return values
        }
        // The app may remove/replace a link or publish fresher cached data while
        // these requests are in flight. Re-read both before creating the timeline.
        guard let currentLinks = savedLinks() else { return [] }
        let unchangedLinks = currentLinks.filter { links.contains($0) }
        // Only the app writes the shared cache. A widget must never overwrite it
        // with an older fetch, or resurrect a link removed during its refresh.
        return CompanionMerge.refreshedSnapshots(read(), updates: updates, currentLinks: unchangedLinks)
    }
    private static func savedLinks() -> [CompanionLink]? {
        guard let data = CompanionCredentialStore.read("viewing-links") else { return nil }
        return try? CompanionCoding.decoder.decode([CompanionLink].self, from: data)
    }
    private static func fetch(_ link: CompanionLink, session: URLSession) async -> CompanionFetchResult {
        var request = URLRequest(url: link.server.appending(path: "v1/macs/\(link.id)/snapshot"))
        request.timeoutInterval = 3
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        do {
            let (stream, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 401 || status == 403 { return .cleared }
            guard status == 200 else { return .unavailable }
            var data = Data()
            for try await byte in stream {
                guard data.count < 256 * 1024 else { throw CompanionError.invalidData }
                data.append(byte)
            }
            let envelope = try CompanionCoding.decoder.decode(CompanionEnvelope.self, from: data)
            if envelope.type == "waiting" { return .cleared }
            if envelope.type == "snapshot", let snapshot = envelope.snapshot,
               snapshot.schemaVersion == 1, snapshot.id == link.id { return .snapshot(snapshot) }
        } catch { return .unavailable }
        return .unavailable
    }
}
#endif
