import Foundation
import LocalAuthentication
import Security

/// Remove only the retired prerelease integration's local credentials and outbox.
/// Keep notification preferences and the shared event detector's history.
enum RetiredIntegrationCleanup {
    static func run(identity: AppIdentity, defaults: UserDefaults = .standard) {
        // This isolated identity never contained the retired integration.
        guard !identity.isStorePreview else { return }
        guard !defaults.bool(forKey: "retiredIntegrationCleanupComplete") else { return }
        let context = LAContext()
        context.interactionNotAllowed = true
        let bundle = identity.isBeta ? AppIdentity.betaBundleIdentifier : AppIdentity.stableBundleIdentifier
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: bundle + ".slack",
            kSecAttrAccount as String: "incoming-webhook",
            kSecUseAuthenticationContext as String: context
        ]
        // No credential is read, and a locked Keychain can be retried on next launch.
        let status = SecItemDelete(query as CFDictionary)
        defaults.removeObject(forKey: "slackResetAlerts")
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: identity.supportDirectoryName).appending(path: "reset-monitor.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            if status == errSecSuccess || status == errSecItemNotFound {
                defaults.set(true, forKey: "retiredIntegrationCleanupComplete")
            }
        } catch { /* Retry local file cleanup on the next launch. */ }
    }
}
