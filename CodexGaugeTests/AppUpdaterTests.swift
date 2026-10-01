import Foundation
import Testing
@testable import CodexGauge

struct AppUpdaterTests {
    private var info: [String: Any] {
        ["SUFeedURL": "https://updates.example.com/appcast.xml",
         "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]
    }

    @Test func developmentAndBetaBuildsCannotEnterTheStableUpdateChannel() {
        #expect(UpdateConfiguration(bundleIdentifier: AppIdentity.stableBundleIdentifier,
                                    developmentBuild: true, info: info) == nil)
        #expect(UpdateConfiguration(bundleIdentifier: AppIdentity.betaBundleIdentifier,
                                    developmentBuild: false, info: info) == nil)
        #expect(UpdateConfiguration(bundleIdentifier: "another.app", developmentBuild: false, info: info) == nil)
        #expect(UpdateConfiguration(bundleIdentifier: AppIdentity.stableBundleIdentifier,
                                    developmentBuild: false, info: info) != nil)
    }

    @Test func incompleteOrUnsafeReleaseConfigurationCannotStartAnUpdater() {
        for feed in ["", "http://updates.example.com/appcast.xml", "file:///tmp/appcast.xml",
                     "https://user:secret@example.com/feed", "https://example.com/feed#key"] {
            var candidate = info; candidate["SUFeedURL"] = feed
            #expect(UpdateConfiguration(bundleIdentifier: AppIdentity.stableBundleIdentifier,
                                        developmentBuild: false, info: candidate) == nil)
        }
        for key in ["", "invalid", Data(repeating: 1, count: 31).base64EncodedString()] {
            var candidate = info; candidate["SUPublicEDKey"] = key
            #expect(UpdateConfiguration(bundleIdentifier: AppIdentity.stableBundleIdentifier,
                                        developmentBuild: false, info: candidate) == nil)
        }
    }
}
