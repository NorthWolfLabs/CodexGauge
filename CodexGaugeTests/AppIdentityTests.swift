import Testing
@testable import CodexGauge

struct AppIdentityTests {
    @Test func betaStateIsIsolatedAndStableLocationsRemainCompatible() {
        let stable = AppIdentity(bundleIdentifier: AppIdentity.stableBundleIdentifier)
        let beta = AppIdentity(bundleIdentifier: AppIdentity.betaBundleIdentifier)
        #expect(stable.supportDirectoryName == "CodexGauge")
        #expect(!stable.isBeta)
        #expect(beta.isBeta)
        #expect(beta.displayName == "CodexGauge Beta")
        #expect(beta.supportDirectoryName != stable.supportDirectoryName)
        let preview = AppIdentity(bundleIdentifier: AppIdentity.storePreviewBundleIdentifier)
        #expect(preview.isStorePreview)
        #expect(preview.supportDirectoryName == "CodexGauge Store Preview")
        #expect(preview.supportDirectoryName != beta.supportDirectoryName)
    }
}
