import Foundation

@MainActor
final class PerformanceWorkloadController {
    private var workloadTask: Task<Void, Never>?

    func start() {
        guard workloadTask == nil else { return }
        workloadTask = Task.detached(priority: .utility) {
            await Self.runSessionStress()
        }
    }

    private nonisolated static func runSessionStress() async {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "CodexGaugePerformance-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sessionDirectory = root.appending(path: "sessions/2026/08/24", directoryHint: .isDirectory)
        let lockDirectory = root.appending(path: "thread-writer-locks", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: .now)
            var files: [URL] = []
            for index in 0..<200 {
                let id = String(format: "10000000-0000-0000-0000-%012d", index)
                let file = sessionDirectory.appending(path: "rollout-2026-08-24T00-00-00-\(id).jsonl")
                let metadata = #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/Performance-\#(index)","model":"gpt-performance"}}"#
                try Data((metadata + "\n").utf8).write(to: file, options: .atomic)
                files.append(file)
            }

            let oversized = #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","content":"\#(String(repeating: "x", count: 2_100_000))"}}"#
            if let file = files.first {
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((oversized + "\n").utf8))
                try handle.close()
            }

            let monitor = LocalSessionMonitor(codexHomeURL: root)
            let stream = await monitor.snapshots()
            let consumer = Task.detached(priority: .utility) {
                for await _ in stream where !Task.isCancelled {}
            }

            for sequence in 1...1_800 where !Task.isCancelled {
                let file = files[sequence % 25]
                let total = sequence * 1_000
                let record = #"{"timestamp":"\#(ISO8601DateFormatter().string(from: .now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total - 100),"cached_input_tokens":\#(total / 2),"output_tokens":100,"reasoning_output_tokens":10,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":900,"cached_input_tokens":500,"output_tokens":100,"reasoning_output_tokens":10,"total_tokens":1000},"model_context_window":200000}}}"#
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((record + "\n").utf8))
                try handle.close()
                try? await Task.sleep(for: .milliseconds(100))
            }

            // Leave a quiet interval so the performance gate can verify that queued
            // FSEvents drain and the bounded monitor returns to its maintenance cadence.
            try? await Task.sleep(for: .seconds(30))
            consumer.cancel()
            await monitor.stop()
        } catch {
            PerformanceSignposts.event("Performance workload failed")
        }
        try? fileManager.removeItem(at: root)
    }
}
