import os
import Foundation

enum PerformanceSignposts {
    static let log = OSLog(subsystem: "com.northwolflabs.CodexGauge", category: .pointsOfInterest)

    static func begin(_ name: StaticString) -> OSSignpostID {
        let identifier = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: identifier)
        return identifier
    }

    static func end(_ name: StaticString, _ identifier: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: identifier)
    }

    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }

    static func recordPresentation(_ surface: String, startedAt: TimeInterval) {
        guard ProcessInfo.processInfo.arguments.contains("-performanceDemo") else { return }
        let milliseconds = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        let line = "PERFORMANCE_METRIC \(surface)_ms \(milliseconds)\n"
        try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
    }

    static func recordReady(_ scenario: String) {
        guard ProcessInfo.processInfo.arguments.contains("-performanceDemo") else { return }
        let line = "PERFORMANCE_READY \(scenario)\n"
        try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
    }
}
