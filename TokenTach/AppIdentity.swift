import Foundation

/// Stable and beta builds share read-only Codex telemetry, but never writable app state.
struct AppIdentity: Sendable {
    static let stableBundleIdentifier = "com.northwolflabs.CodexGauge"
    static let betaBundleIdentifier = stableBundleIdentifier + ".beta"
    static let storePreviewBundleIdentifier = stableBundleIdentifier + ".store-preview"
    static let current = AppIdentity(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? stableBundleIdentifier,
        installedDisplayName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
    )

    let isBeta: Bool
    let isStorePreview: Bool
    let showsBetaBranding: Bool

    init(bundleIdentifier: String, installedDisplayName: String? = nil) {
        isBeta = bundleIdentifier == Self.betaBundleIdentifier
        isStorePreview = bundleIdentifier == Self.storePreviewBundleIdentifier
        // Local release candidates retain the existing test container and pairing
        // credentials while adopting the ordinary product name and gauge.
        showsBetaBranding = isBeta && installedDisplayName != "TokenTach"
    }

    var displayName: String { isStorePreview ? "TokenTach Store Preview" : showsBetaBranding ? "TokenTach Beta" : "TokenTach" }
    // Keep existing containers, caches, bookmarks and notification records after the rename.
    var supportDirectoryName: String {
        isStorePreview ? "CodexGauge Store Preview" : isBeta ? "CodexGauge Beta" : "CodexGauge"
    }
}
