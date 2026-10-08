import CryptoKit
import Foundation

struct ResetCredit: Codable, Hashable, Sendable {
    let id: String
    let grantedAt: Int64
    let status: String
}

enum ResetAccountIdentity {
    static func digest(_ value: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + "\u{0}" + value).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func emailHash(_ email: String, salt: String) -> String? {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? nil : digest(value, salt: salt)
    }

    static func scope(limits: RateLimitSnapshot, identity: AccountIdentity, salt: String) -> String? {
        if let id = limits.accountID, !id.isEmpty {
            return digest("account:\(id)|\(identity.personalAccountHash ?? "")", salt: salt)
        }
        let personalPlans = ["free", "go", "plus", "pro", "prolite", "promax"]
        guard identity.accountType == "chatgpt", personalPlans.contains(identity.plan ?? ""),
              let hash = identity.personalAccountHash else { return nil }
        return "personal:" + hash
    }
}

enum ResetAlertKind: String, Codable, Sendable, CaseIterable {
    case banked, allowance, low, attention, completed, working

    var title: String {
        switch self {
        case .banked: "Limit reset added"
        case .allowance: "Allowance reset"
        case .low: "Allowance low"
        case .attention: "Task needs input or approval"
        case .completed: "Task completed"
        case .working: "Task working"
        }
    }
}

struct ResetAlert: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    let kind: ResetAlertKind
    let key: String
    var name: String
    var added: Int
    var available: Int
    var since: Date
    var observedAt: Date
    var projectName: String? = nil
    // Nil preserves conservative wording for records from older builds.
    var isCatchUp: Bool? = nil
    var taskID: String? = nil
    var taskStatus: String? = nil
    var resetsAt: Date? = nil
}

struct ResetWindowObservation: Codable, Equatable, Sendable {
    var window: QuotaWindow
    var at: Date
    var plan: String?
    var candidateUsed: Int?
    var candidateSince: Date?
    var candidateIsCatchUp: Bool?
}

/// Pure snapshot comparison. No timers, network access, or credential handling.
struct ResetDetector: Codable, Equatable, Sendable {
    var plan: String?
    var lastAt: Date?
    var count: Int?
    var countAt: Date?
    var creditIDs: Set<String> = []
    var windows: [String: ResetWindowObservation] = [:]

    mutating func reset(_ kind: ResetAlertKind) {
        switch kind {
        case .banked:
            count = nil
            countAt = nil
            creditIDs = []
        case .allowance:
            windows = [:]
        case .low, .attention, .completed, .working: break
        }
    }

    mutating func evaluate(_ snapshot: RateLimitSnapshot, banked: Bool, allowance: Bool, catchUp: Bool = true) -> [ResetAlert] {
        guard lastAt.map({ snapshot.fetchedAt > $0 }) ?? true else { return [] }
        if let before = plan, let after = snapshot.plan, before != after { self = ResetDetector() }
        plan = snapshot.plan ?? plan
        let now = snapshot.fetchedAt
        var alerts: [ResetAlert] = []
        if let value = snapshot.earnedResetCount, value >= 0 {
            let details = snapshot.resetCredits ?? []
            if banked, let old = count, let since = countAt {
                let newGrants = details.filter {
                    $0.status == "available" && !creditIDs.contains($0.id)
                        && TimeInterval($0.grantedAt) > since.timeIntervalSince1970
                        && TimeInterval($0.grantedAt) <= now.timeIntervalSince1970
                }
                let increase = max(value - old, Set(newGrants.map(\.id)).count)
                if increase > 0 {
                    alerts.append(ResetAlert(kind: .banked, key: "banked", name: "Limit resets",
                                             added: increase, available: value, since: since, observedAt: now,
                                             isCatchUp: catchUp || (lastAt.map { since < $0 } ?? false)))
                }
            }
            count = value
            countAt = now
            // Grant timestamps prevent newly exposed old rows from becoming new alerts.
            creditIDs = Set(details.map(\.id))
        }

        var next: [String: ResetWindowObservation] = [:]
        for bucket in snapshot.buckets {
            for window in bucket.windows {
                let key = "\(bucket.id)|\(window.id)"
                var observation = ResetWindowObservation(window: window, at: now, plan: bucket.plan)
                if allowance, let old = windows[key], old.plan == bucket.plan,
                   old.window.durationMinutes == window.durationMinutes {
                    let cycleChanged: Bool
                    if let before = old.window.resetsAt, let after = window.resetsAt {
                        cycleChanged = before <= now && after > now && after > before
                    } else {
                        cycleChanged = false
                    }
                    let confirmsDrop = old.candidateUsed.map { Self.isDrop(from: $0, to: window.usedPercent) } ?? false
                    if cycleChanged || confirmsDrop {
                        alerts.append(ResetAlert(kind: .allowance, key: key,
                                                 name: "\(bucket.name) \(window.durationName)", added: 0,
                                                 available: window.remainingPercent,
                                                 since: old.candidateSince ?? old.at, observedAt: now,
                                                 isCatchUp: catchUp || old.candidateIsCatchUp == true))
                    } else if Self.isDrop(from: old.window.usedPercent, to: window.usedPercent) {
                        observation.candidateUsed = old.window.usedPercent
                        observation.candidateSince = old.at
                        observation.candidateIsCatchUp = catchUp
                    }
                }
                next[key] = observation
            }
        }
        windows = next
        lastAt = now
        return alerts
    }

    private static func isDrop(from old: Int, to new: Int) -> Bool {
        old - new >= 5 || (old > 0 && new == 0)
    }

    func hasSameEvidence(as other: ResetDetector) -> Bool {
        guard plan == other.plan, count == other.count, creditIDs == other.creditIDs,
              Set(windows.keys) == Set(other.windows.keys) else { return false }
        return windows.allSatisfy { key, value in
            guard let previous = other.windows[key] else { return false }
            return value.window == previous.window && value.plan == previous.plan && value.candidateUsed == previous.candidateUsed
                && value.candidateSince == previous.candidateSince && value.candidateIsCatchUp == previous.candidateIsCatchUp
        }
    }
}
