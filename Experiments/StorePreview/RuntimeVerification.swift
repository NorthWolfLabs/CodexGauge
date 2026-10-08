#if DEBUG && STORE_PREVIEW_VERIFICATION
import Foundation
import AppKit

/// Opt-in, bounded development diagnostic. Never writes task/account identifiers or contents.
@MainActor enum SandboxRuntimeVerification {
    private static var window: NSWindow?
    private struct TaskFingerprint: Equatable {
        let id: String
        let state: ConversationState
        let tokens: Int64
        let activity: Date
    }
    private struct Sample: Encodable {
        let date: Date
        let freshAccount: Bool
        let hasError: Bool
        let fetchedAt: Date?
        let tasksLoaded: Bool
        let taskCount: Int
        let running: Int
        let waiting: Int
        let taskEventChanges: Int
    }
    private struct Report: Encodable {
        let schema = 1
        let directoryGrantRestored: Bool
        let helperGrantRestored: Bool
        let complete: Bool
        let samples: [Sample]
    }

    static func start(_ state: AppState) {
        if ProcessInfo.processInfo.arguments.contains("-sandboxFixtureTransitions") {
            startFixtureTransitions()
            return
        }
        guard ProcessInfo.processInfo.arguments.contains("-sandboxVerification") else { return }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("sandbox-verification.json")
        let directoryRestored = state.codexAccess.directoryURL != nil
        let helperRestored = state.codexAccess.helperURL != nil
        let label = NSTextField(wrappingLabelWithString: "Checking sandbox runtime…")
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.frame = NSRect(x: 20, y: 20, width: 510, height: 260)
        let reportWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 300),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        reportWindow.title = "Sandbox Verification"
        reportWindow.isReleasedWhenClosed = false
        reportWindow.contentView?.addSubview(label)
        window = reportWindow
        reportWindow.center()
        reportWindow.makeKeyAndOrderFront(nil)
        Task { @MainActor [weak state] in
            var samples: [Sample] = []
            var previous: [TaskFingerprint]?
            var changes = 0
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            for index in 0...60 {
                guard let state, !Task.isCancelled else { return }
                if state.hasLoadedConversations {
                    let fingerprint = state.conversations.map {
                        TaskFingerprint(id: $0.id, state: $0.state, tokens: $0.totalTokens, activity: $0.lastActivity)
                    }.sorted { $0.id < $1.id }
                    if let previous, previous != fingerprint { changes += 1 }
                    previous = fingerprint
                }
                samples.append(Sample(date: .now, freshAccount: state.displayFreshness == .fresh,
                                      hasError: state.errorMessage != nil,
                                      fetchedAt: state.accountSnapshot?.fetchedAt,
                                      tasksLoaded: state.hasLoadedConversations,
                                      taskCount: state.conversations.count,
                                      running: state.conversations.filter { $0.state == .running }.count,
                                      waiting: state.conversations.filter { $0.state == .needsInput || $0.state == .needsApproval }.count,
                                      taskEventChanges: changes))
                let report = Report(directoryGrantRestored: directoryRestored,
                                    helperGrantRestored: helperRestored,
                                    complete: index == 60, samples: samples)
                if let data = try? encoder.encode(report) { try? data.write(to: file, options: .atomic) }
                if let sample = samples.last {
                    label.stringValue = """
                    Saved folder access restored: \(directoryRestored)
                    Saved helper access restored: \(helperRestored)
                    Account allowances fresh: \(sample.freshAccount)
                    Connection error: \(sample.hasError)
                    Tasks loaded: \(sample.tasksLoaded)
                    Tasks read: \(sample.taskCount)
                    Running: \(sample.running) · Needs input/approval: \(sample.waiting)
                    Task data changes observed: \(changes)
                    Check: \(index == 60 ? "Complete" : "\(index)/60 seconds")
                    """
                }
                if index < 60 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
    }

    private static func startFixtureTransitions() {
        let label = NSTextField(wrappingLabelWithString: "Checking synthetic task transitions…")
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.frame = NSRect(x: 20, y: 20, width: 570, height: 340)
        let reportWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 380),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        reportWindow.title = "Sandbox Task Verification"
        reportWindow.isReleasedWhenClosed = false
        reportWindow.contentView?.addSubview(label)
        window = reportWindow
        reportWindow.center()
        reportWindow.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            let check = SandboxFixtureTransitions()
            await check.run { label.stringValue = $0 }
        }
    }
}

/// Exercises the production reader inside the signed app's sandbox. Fixtures never
/// enter AppState, the helper, notification delivery, or companion publishing.
@MainActor private final class SandboxFixtureTransitions {
    private var monitor: LocalSessionMonitor?
    private var collector: Task<Void, Never>?
    private var latest: ConversationTelemetry?
    private var results: [String] = []
    private let id = UUID().uuidString.lowercased()

    func run(update: (String) -> Void) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "sandbox-task-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let directory = root.appending(path: "sessions/2026/09/30")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appending(path: "thread-writer-locks"), withIntermediateDirectories: true)
            let file = directory.appending(path: "rollout-2026-09-30T00-00-00-\(id).jsonl")
            try record(type: "session_meta", payload: ["id": id, "cwd": "/tmp/SandboxCheck", "model": "fixture"])
                .write(to: file)
            try append("task_started", to: file)
            await start(root)
            await check("Initial running task", state: .running, completion: false, update: update)
            try append("request_user_input", to: file)
            await check("Needs input", state: .needsInput, completion: false, update: update)
            try append("task_started", to: file)
            await check("Resumed running", state: .running, completion: false, update: update)
            try append("approval_request", to: file)
            await check("Needs approval", state: .needsApproval, completion: false, update: update)
            try append("task_completed", to: file)
            await check("Completed, excluded from live tasks", state: .recent, completion: true, update: update)

            // A fresh reader must reconstruct an event written while monitoring
            // was stopped, then continue tailing the same file after recovery.
            await stop()
            try append("task_started", to: file)
            await start(root)
            await check("Restart catches missed start", state: .running, completion: false, update: update)
            try append("task_completed", to: file)
            await check("Tailing works after restart", state: .recent, completion: true, update: update)
        } catch {
            results.append("FAIL: Fixture I/O: \(error.localizedDescription)")
        }
        await stop()
        update((results + ["Check: Complete"]).joined(separator: "\n"))
    }

    private func start(_ root: URL) async {
        latest = nil
        let reader = LocalSessionMonitor(codexHomeURL: root)
        monitor = reader
        let stream = await reader.snapshots()
        collector = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard let self, !Task.isCancelled else { return }
                self.latest = snapshot.first { $0.id == self.id }
            }
        }
    }

    private func stop() async {
        await monitor?.stop()
        collector?.cancel()
        await collector?.value
        collector = nil
        monitor = nil
        latest = nil
    }

    private func check(_ name: String, state: ConversationState, completion: Bool,
                       update: (String) -> Void) async {
        let clock = ContinuousClock()
        let start = clock.now
        var passed = false
        while start.duration(to: clock.now) < .seconds(8), !Task.isCancelled {
            if let latest, latest.state == state,
               (latest.completionEventAt != nil) == completion,
               latest.isLive == !completion,
               (latest.attentionEventAt != nil) == (state == .needsInput || state == .needsApproval) {
                passed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        results.append("\(passed ? "PASS" : "FAIL"): \(name) (\(String(format: "%.1f", seconds))s)")
        update((results + ["Check: Running"]).joined(separator: "\n"))
    }

    private func record(type: String, payload: [String: String]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "timestamp": Date.now.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)),
            "type": type, "payload": payload
        ])
        data.append(0x0A)
        return data
    }

    private func append(_ event: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: record(type: "event_msg", payload: ["type": event]))
        try handle.synchronize()
    }
}
#endif
