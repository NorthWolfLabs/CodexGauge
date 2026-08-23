import AppKit
import CryptoKit
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class UserNotificationScheduler: NotificationScheduling, @unchecked Sendable {
    private enum Key {
        static let quotaDeduplication = "quotaNotificationDeduplication"
        static let attentionDeduplication = "attentionNotificationDeduplication"
        static let activeAttentionTasks = "activeAttentionTasks"
    }

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let clock: any ClockProviding
    private var quotaKeys: Set<String>
    private var attentionKeys: Set<String>
    private var activeAttentionTasks: Set<String>

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard,
        clock: any ClockProviding = SystemClock()
    ) {
        self.center = center
        self.defaults = defaults
        self.clock = clock
        quotaKeys = Set(defaults.stringArray(forKey: Key.quotaDeduplication) ?? [])
        attentionKeys = Set(defaults.stringArray(forKey: Key.attentionDeduplication) ?? [])
        activeAttentionTasks = Set(defaults.stringArray(forKey: Key.activeAttentionTasks) ?? [])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    }

    func authorizationStatus() async -> NotificationAuthorizationState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional, .ephemeral: return .provisional
        @unknown default: return .unavailable
        }
    }

    func evaluate(snapshot: AccountSnapshot, thresholds: [Int]) async {
        for bucket in snapshot.buckets {
            for window in bucket.windows {
                let crossed = NotificationDecision.crossedThresholds(
                    remainingPercent: window.remainingPercent,
                    thresholds: thresholds
                )
                let newThresholds = crossed.filter {
                    !quotaKeys.contains(NotificationDedupeKey.quota(
                        bucket: bucket,
                        window: window,
                        threshold: $0,
                        now: clock.now
                    ))
                }
                guard let thresholdToSend = newThresholds.first else { continue }
                for threshold in crossed {
                    quotaKeys.insert(NotificationDedupeKey.quota(
                        bucket: bucket,
                        window: window,
                        threshold: threshold,
                        now: clock.now
                    ))
                }

                let key = NotificationDedupeKey.quota(
                    bucket: bucket,
                    window: window,
                    threshold: thresholdToSend,
                    now: clock.now
                )
                let content = UNMutableNotificationContent()
                content.title = "Codex allowance is at \(window.remainingPercent)%"
                content.body = window.resetsAt.map {
                    "\(bucket.name) \(window.durationName.lowercased()) allowance resets \($0.formatted(.relative(presentation: .named)))."
                } ?? "\(bucket.name) \(window.durationName.lowercased()) allowance is running low."
                content.sound = .default
                content.categoryIdentifier = NotificationDelegate.categoryIdentifier
                try? await center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
            }
        }
        trimAndPersist()
    }

    func evaluate(conversations: [ConversationTelemetry]) async {
        let actionable = conversations.filter { $0.state == .needsApproval || $0.state == .needsInput }
        let currentlyActionable = Set(actionable.map { NotificationDedupeKey.attentionTask(id: $0.id) })
        NotificationDecision.clearInactiveAttentionTasks(
            activeTasks: &activeAttentionTasks,
            currentlyActionable: currentlyActionable
        )
        for conversation in actionable {
            guard NotificationDecision.shouldSendAttention(
                for: conversation,
                activeTasks: &activeAttentionTasks
            ) else { continue }
            let digest = NotificationDedupeKey.attention(conversation: conversation)
            guard attentionKeys.insert(digest).inserted else { continue }

            let content = UNMutableNotificationContent()
            content.title = conversation.state == .needsApproval ? "Codex needs approval" : "Codex is waiting for input"
            content.body = "Open ChatGPT to respond."
            content.sound = .default
            content.categoryIdentifier = NotificationDelegate.categoryIdentifier
            try? await center.add(UNNotificationRequest(identifier: digest, content: content, trigger: nil))
        }
        trimAndPersist()
    }

    private func trimAndPersist() {
        if quotaKeys.count > 250 { quotaKeys = Set(quotaKeys.sorted().suffix(200)) }
        if attentionKeys.count > 250 { attentionKeys = Set(attentionKeys.sorted().suffix(200)) }
        defaults.set(Array(quotaKeys), forKey: Key.quotaDeduplication)
        defaults.set(Array(attentionKeys), forKey: Key.attentionDeduplication)
        defaults.set(Array(activeAttentionTasks), forKey: Key.activeAttentionTasks)
    }
}

enum NotificationDecision {
    static func crossedThresholds(remainingPercent: Int, thresholds: [Int]) -> [Int] {
        Array(Set(thresholds.map { max(1, min(99, $0)) }))
            .filter { remainingPercent <= $0 }
            .sorted()
    }

    static func clearInactiveAttentionTasks(
        activeTasks: inout Set<String>,
        currentlyActionable: Set<String>
    ) {
        activeTasks.formIntersection(currentlyActionable)
    }

    static func shouldSendAttention(
        for conversation: ConversationTelemetry,
        activeTasks: inout Set<String>
    ) -> Bool {
        guard conversation.attentionEventAt != nil,
              conversation.state == .needsApproval || conversation.state == .needsInput else { return false }
        return activeTasks.insert(NotificationDedupeKey.attentionTask(id: conversation.id)).inserted
    }
}

enum NotificationDedupeKey {
    static func attentionTask(id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func quota(
        bucket: QuotaBucket,
        window: QuotaWindow,
        threshold: Int,
        now: Date = .now
    ) -> String {
        let cycle: String
        if let reset = window.resetsAt {
            cycle = String(Int(reset.timeIntervalSince1970))
        } else if let minutes = window.durationMinutes, minutes > 0 {
            cycle = "estimated-\(Int(now.timeIntervalSince1970) / (minutes * 60))"
        } else {
            cycle = "unknown"
        }
        return "\(bucket.id)|\(window.id)|\(cycle)|\(threshold)"
    }

    static func attention(conversation: ConversationTelemetry) -> String {
        let event = conversation.attentionEventAt.map { String(Int($0.timeIntervalSince1970 * 1_000)) } ?? "unknown"
        let value = "\(conversation.id)|\(conversation.state.rawValue)|\(event)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let categoryIdentifier = "CODEX_GAUGE_OPEN_CHATGPT"

    func configure() {
        let open = UNNotificationAction(identifier: "OPEN_CHATGPT", title: "Open ChatGPT", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [open],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == "OPEN_CHATGPT" || response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run {
            let candidates = [
                "/Applications/ChatGPT.app",
                "\(NSHomeDirectory())/Applications/ChatGPT.app"
            ]
            guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        }
    }
}
