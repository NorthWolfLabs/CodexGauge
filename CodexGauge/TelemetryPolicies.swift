import CoreServices
import Foundation

struct SnapshotPersistencePolicy: Sendable {
    private(set) var lastWriteAt: Date?
    private(set) var lastResetSignature = ""
    private var lastRemainingPercentages: [String: Int] = [:]
    let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 60) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldPersist(
        at now: Date,
        resetSignature: String,
        remainingPercentages: [String: Int]
    ) -> Bool {
        let resetChanged = !lastResetSignature.isEmpty && resetSignature != lastResetSignature
        let allowanceChanged = !lastRemainingPercentages.isEmpty && (
            Set(lastRemainingPercentages.keys) != Set(remainingPercentages.keys)
                || remainingPercentages.contains { key, value in
                    abs(value - lastRemainingPercentages[key, default: value]) >= 5
                }
        )
        let intervalElapsed = lastWriteAt.map { now.timeIntervalSince($0) >= minimumInterval } ?? true
        guard resetChanged || allowanceChanged || intervalElapsed else { return false }
        lastWriteAt = now
        lastResetSignature = resetSignature
        lastRemainingPercentages = remainingPercentages
        return true
    }
}

enum FSEventRescanPolicy {
    private static let rescanMask = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
    )

    static func requiresRescan(_ flags: [FSEventStreamEventFlags]) -> Bool {
        flags.contains { $0 & rescanMask != 0 }
    }
}

struct SemanticSnapshotPolicy<Value: Equatable & Sendable>: Sendable {
    private var lastValue: Value?

    mutating func shouldPublish(_ value: Value) -> Bool {
        guard value != lastValue else { return false }
        lastValue = value
        return true
    }

    mutating func reset() {
        lastValue = nil
    }
}

struct QuotaNotificationEvaluationPolicy: Sendable {
    private var lastSignature: String?

    mutating func shouldEvaluate(_ snapshot: AccountSnapshot, thresholds: [Int]) -> Bool {
        let normalizedThresholds = Array(Set(thresholds.map { max(1, min(99, $0)) })).sorted(by: >)
        let signature = snapshot.buckets.flatMap { bucket in
            bucket.windows.map { window in
                let cycle = window.resetsAt?.timeIntervalSince1970 ?? -1
                let crossings = normalizedThresholds.map { threshold in
                    "\(threshold):\(window.remainingPercent <= threshold)"
                }.joined(separator: ",")
                return "\(bucket.id)|\(window.id)|\(cycle)|\(crossings)"
            }
        }.joined(separator: ";")
        guard signature != lastSignature else { return false }
        lastSignature = signature
        return true
    }
}
