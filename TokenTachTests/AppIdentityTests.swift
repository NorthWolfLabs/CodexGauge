import Testing
@testable import TokenTach

struct AppIdentityTests {
    @Test func releaseCandidateKeepsPairingStorageWithoutBetaBranding() {
        let candidate = AppIdentity(bundleIdentifier: AppIdentity.betaBundleIdentifier,
                                    installedDisplayName: "TokenTach")
        #expect(candidate.displayName == "TokenTach")
        #expect(candidate.supportDirectoryName == "CodexGauge Beta")
        #expect(candidate.isBeta)
        #expect(!candidate.showsBetaBranding)
    }
    @Test func betaStateIsIsolatedAndStableLocationsRemainCompatible() {
        let stable = AppIdentity(bundleIdentifier: AppIdentity.stableBundleIdentifier)
        let beta = AppIdentity(bundleIdentifier: AppIdentity.betaBundleIdentifier)
        #expect(stable.supportDirectoryName == "CodexGauge")
        #expect(stable.displayName == "TokenTach")
        #expect(AppIdentity.stableBundleIdentifier == "com.northwolflabs.CodexGauge")
        #expect(!stable.isBeta)
        #expect(beta.isBeta)
        #expect(beta.displayName == "TokenTach Beta")
        #expect(beta.supportDirectoryName == "CodexGauge Beta")
        #expect(beta.supportDirectoryName != stable.supportDirectoryName)
        let preview = AppIdentity(bundleIdentifier: AppIdentity.storePreviewBundleIdentifier)
        #expect(preview.isStorePreview)
        #expect(preview.supportDirectoryName == "CodexGauge Store Preview")
        #expect(preview.supportDirectoryName != beta.supportDirectoryName)
    }
}
