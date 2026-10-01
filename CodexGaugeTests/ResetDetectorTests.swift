import Foundation
import Testing
@testable import CodexGauge

private let epoch = Date(timeIntervalSince1970: 2_000_000_000)

private func limits(_ seconds: Double, used: Int = 50, reset: Double? = 100,
                    count: Int? = 1, plan: String = "pro", duration: Int = 300,
                    credits: [ResetCredit]? = nil) -> RateLimitSnapshot {
    RateLimitSnapshot(plan: plan, buckets: [QuotaBucket(
        id: "codex", name: "Codex", plan: plan, windows: [QuotaWindow(id: "primary", kind: "Primary", usedPercent: used,
            durationMinutes: duration, resetsAt: reset.map { epoch.addingTimeInterval($0) })],
        credits: nil, spendControl: nil, spendControlReached: nil, reachedReason: nil
    )], earnedResetCount: count, fetchedAt: epoch.addingTimeInterval(seconds), resetCredits: credits)
}

struct ResetDetectorTests {
    @Test func bankedResetsKeepUnknownSeparateFromZero() {
        var detector = ResetDetector()
        #expect(detector.evaluate(limits(0, count: 2), banked: true, allowance: true).isEmpty)
        #expect(detector.evaluate(limits(1, count: nil), banked: true, allowance: true).isEmpty)
        let added = detector.evaluate(limits(2, count: 3), banked: true, allowance: true)
        #expect(added.count == 1)
        #expect(added.first?.added == 1)
        #expect(detector.evaluate(limits(3, count: 2), banked: true, allowance: true).isEmpty)
        #expect(detector.evaluate(limits(4, count: 2), banked: true, allowance: true).isEmpty)
    }

    @Test func creditDetailsFindNewGrantWithoutCountingNewlyExposedOldRows() {
        var detector = ResetDetector()
        _ = detector.evaluate(limits(0), banked: true, allowance: false)
        let old = ResetCredit(id: "old", grantedAt: Int64(epoch.timeIntervalSince1970 - 20), status: "available")
        let new = ResetCredit(id: "new", grantedAt: Int64(epoch.timeIntervalSince1970 + 1), status: "available")
        let alerts = detector.evaluate(limits(2, credits: [old, new]), banked: true, allowance: false)
        #expect(alerts.first?.added == 1)
        #expect(detector.evaluate(limits(3, credits: [old, new]), banked: true, allowance: false).isEmpty)
        // The list may be capped or absent; it is never the authoritative count.
        #expect(detector.evaluate(limits(4, count: 5, credits: []), banked: true, allowance: false).first?.added == 4)
    }

    @Test func naturalAndEarlyResetsHaveOneKind() {
        var scheduled = ResetDetector()
        _ = scheduled.evaluate(limits(0), banked: true, allowance: true)
        let events = scheduled.evaluate(limits(101, used: 70, reset: 200, count: 2), banked: true, allowance: true)
        #expect(Set(events.map(\.kind)) == [.banked, .allowance])
        #expect(scheduled.evaluate(limits(102, used: 70, reset: 200, count: 2), banked: true, allowance: true).isEmpty)
        var early = ResetDetector()
        _ = early.evaluate(limits(0), banked: true, allowance: true)
        #expect(early.evaluate(limits(1, used: 3, reset: 200), banked: true, allowance: true).isEmpty)
        #expect(early.evaluate(limits(2, used: 4, reset: 200), banked: true, allowance: true).first?.kind == .allowance)
    }

    @Test func timestampAndSmallCorrectionsDoNotReset() {
        var detector = ResetDetector()
        _ = detector.evaluate(limits(0), banked: true, allowance: true)
        #expect(detector.evaluate(limits(1, used: 49, reset: 200), banked: true, allowance: true).isEmpty)
        #expect(detector.evaluate(limits(2, used: 40, reset: 200), banked: true, allowance: true).isEmpty)
        #expect(detector.evaluate(limits(3, used: 49, reset: 200), banked: true, allowance: true).isEmpty)
        #expect(detector.evaluate(limits(4, used: 49, reset: 200), banked: true, allowance: true).isEmpty)
    }

    @Test func zeroAndMetadataChangesAndDisabling() {
        var detector = ResetDetector()
        _ = detector.evaluate(limits(0, used: 1, reset: nil), banked: true, allowance: true)
        #expect(detector.evaluate(limits(1, used: 0, reset: nil), banked: true, allowance: true).isEmpty)
        #expect(detector.evaluate(limits(2, used: 0, reset: nil), banked: true, allowance: true).count == 1)
        #expect(detector.evaluate(limits(3, count: 8, plan: "plus"), banked: true, allowance: true).isEmpty)
        #expect(detector.evaluate(limits(101, reset: 200, count: 8, plan: "plus", duration: 60), banked: true, allowance: true).isEmpty)
        detector.reset(.banked)
        #expect(detector.evaluate(limits(102, reset: 200, count: 10, plan: "plus", duration: 60), banked: true, allowance: true).isEmpty)
    }

    @Test func identityHashAndOldDecoderCompatibility() throws {
        let hash = try #require(ResetAccountIdentity.emailHash("Person@example.test", salt: "salt"))
        #expect(!hash.contains("Person"))
        #expect(hash != ResetAccountIdentity.emailHash("Person@example.test", salt: "other"))
        let identity = AccountIdentity(accountType: "chatgpt", plan: "pro", personalAccountHash: hash)
        #expect(ResetAccountIdentity.scope(limits: limits(0), identity: identity, salt: "s") != nil)
        #expect(ResetAccountIdentity.scope(limits: limits(0), identity: AccountIdentity(accountType: "chatgpt", plan: "business", personalAccountHash: hash), salt: "s") == nil)
        var identified = limits(0)
        identified.accountID = "account-2"
        #expect(ResetAccountIdentity.scope(limits: identified, identity: identity, salt: "s") != ResetAccountIdentity.scope(limits: limits(0), identity: identity, salt: "s"))
        let old = try JSONDecoder().decode(RateLimitsResponse.self, from: Data(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":2}}"#.utf8))
        #expect(old.accountId == nil)
        #expect(old.rateLimitResetCredits?.credits == nil)
        let detailed = try JSONDecoder().decode(RateLimitsResponse.self, from: Data(#"{"accountId":"opaque-id","rateLimits":{},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"reset-1","grantedAt":42,"status":"available","future":true}]}}"#.utf8))
        #expect(detailed.accountId == "opaque-id")
        #expect(detailed.rateLimitResetCredits?.credits?.first?.grantedAt == 42)
    }

}
