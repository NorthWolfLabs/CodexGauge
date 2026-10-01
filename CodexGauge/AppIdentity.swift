import Foundation

/// Stable and beta builds share read-only Codex telemetry, but never writable app state.
struct AppIdentity: Sendable {
    static let stableBundleIdentifier = "com.northwolflabs.CodexGauge"
    static let betaBundleIdentifier = stableBundleIdentifier + ".beta"
    static let storePreviewBundleIdentifier = stableBundleIdentifier + ".store-preview"
    static let current = AppIdentity(bundleIdentifier: Bundle.main.bundleIdentifier ?? stableBundleIdentifier)

    let isBeta: Bool
    let isStorePreview: Bool

    init(bundleIdentifier: String) {
        isBeta = bundleIdentifier == Self.betaBundleIdentifier
        isStorePreview = bundleIdentifier == Self.storePreviewBundleIdentifier
    }

    var displayName: String { isStorePreview ? "CodexGauge Store Preview" : isBeta ? "CodexGauge Beta" : "CodexGauge" }
    var supportDirectoryName: String { displayName }
}
