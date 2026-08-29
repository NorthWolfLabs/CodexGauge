import AppKit
import Foundation
import CoreServices
import Darwin
import LightweightCodeRequirements
import Security
import Testing
@testable import CodexGauge

private func testHostHasTeamSignature() -> Bool {
    guard let executableURL = Bundle.main.executableURL else { return false }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess,
          let code else {
        return false
    }

    var information: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
          let values = information as? [String: Any],
          let teamID = values[kSecCodeInfoTeamIdentifier as String] as? String else {
        return false
    }
    return !teamID.isEmpty
}

struct CodexGaugeTests {
    @MainActor
    @Test func statusItemSymbolsUseBoundedAlignedGeometry() throws {
        let gauge = try #require(
            StatusItemSymbolRenderer.image(named: "gauge.with.dots.needle.33percent", color: nil)
        )
        let warning = try #require(
            StatusItemSymbolRenderer.image(named: "exclamationmark.triangle.fill", color: .systemRed)
        )
        let unalignedGauge = try #require(
            NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)?
                .withSymbolConfiguration(StatusItemSymbolRenderer.configuration)
        )

        for image in [gauge, warning] {
            #expect(image.size.width >= 15)
            #expect(image.size.width <= 17)
            #expect(image.size.height >= 17)
            #expect(image.size.height <= 19)
        }

        #expect(gauge.isTemplate)
        #expect(!warning.isTemplate)
        #expect(abs(gauge.size.width - warning.size.width) < 0.5)
        #expect(gauge.size.height == unalignedGauge.size.height + 2)
    }

    @MainActor
    @Test func allowanceAlertsStartOffWithPracticalPresets() {
        let suite = "CodexGaugeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)

        #expect(!settings.quotaNotificationsEnabled)
        #expect(settings.notificationThresholds == [20, 10, 5])
    }

    @MainActor
    @Test func prereleaseFixturePreferencesAreRepairedOnce() {
        let suite = "CodexGaugeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "quotaNotifications")
        defaults.set([99, 1], forKey: "notificationThresholds")

        let settings = SettingsStore(defaults: defaults)

        #expect(!settings.quotaNotificationsEnabled)
        #expect(settings.notificationThresholds == [20, 10, 5])

        settings.quotaNotificationsEnabled = true
        settings.notificationThresholds = [30, 12]
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.quotaNotificationsEnabled)
        #expect(reloaded.notificationThresholds == [30, 12])
    }

    @MainActor
    @Test func notificationThresholdCountIsUserConfigurable() {
        let suite = "CodexGaugeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)

        settings.notificationThresholds = [5, 25, 15, 2, 25]

        #expect(settings.notificationThresholds == [25, 15, 5, 2])
        #expect(defaults.array(forKey: "notificationThresholds") as? [Int] == [25, 15, 5, 2])
    }

    @MainActor
    @Test func persistedAllowanceThresholdsAreClampedAndDeduplicated() {
        let suite = "CodexGaugeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([0, 5, 5, 100, -20], forKey: "notificationThresholds")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.notificationThresholds == [99, 5, 1])
    }

    @MainActor
    @Test func menuBarPreferencesDefaultPersistAndRestoreWithoutChangingExistingSettings() {
        let suite = "CodexGaugeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)

        #expect(settings.menuBarConfiguration == .default)
        var customized = settings.menuBarConfiguration
        customized.showsGauge = false
        customized.primaryAllowance = .lowestOverall
        customized.secondaryAllowance = .specific(bucketID: "codex", windowID: "codex-primary")
        customized.resetDisplay = .timeRemaining
        customized.showsSuggestedPace = true
        customized.colorMode = .trafficLight
        customized.colorBasis = .usagePace
        customized.colorTarget = .gaugeAndValues
        settings.menuBarConfiguration = customized

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.menuBarConfiguration == customized.normalized)
        reloaded.restoreMenuBarDefaults()
        #expect(reloaded.menuBarConfiguration == .default)
    }

    @MainActor
    @Test func menuBarConfigurationCannotPersistAnInvisibleStatusItem() {
        let suite = "CodexGaugeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        var hidden = settings.menuBarConfiguration
        hidden.showsGauge = false
        hidden.showsPercentage = false
        hidden.resetDisplay = .hidden
        hidden.showsSuggestedPace = false

        settings.menuBarConfiguration = hidden

        #expect(settings.menuBarConfiguration.showsGauge)
        #expect(settings.menuBarConfiguration.hasVisibleContent)
    }

    @MainActor
    @Test func invalidPersistedMenuBarConfigurationFallsBackToDefaults() {
        let suite = "CodexGaugeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: "menuBarConfiguration")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.menuBarConfiguration == .default)
    }

    @Test func menuBarAllowanceResolutionSupportsCanonicalOverallAndSpecificWindows() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = menuBarSnapshot(now: now)

        #expect(AllowanceResolver.resolve(.limitingCodex, in: snapshot)?.window.id == "codex-secondary")
        #expect(AllowanceResolver.resolve(.lowestOverall, in: snapshot)?.window.id == "spark-primary")
        #expect(AllowanceResolver.resolve(
            .specific(bucketID: "codex", windowID: "codex-primary"),
            in: snapshot
        )?.window.durationMinutes == 300)
        #expect(AllowanceResolver.options(in: snapshot).map(\.title).contains("Codex · 5-hour"))
    }

    @Test func defaultMenuBarPresentationRemainsMonochromeGaugeAndLimitingCodexPercentage() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let presentation = MenuBarPresentationBuilder.make(
            snapshot: menuBarSnapshot(now: now),
            freshness: .fresh,
            configuration: .default,
            now: now
        )

        #expect(presentation.symbolName == "gauge.with.needle")
        #expect(presentation.symbolSeverity == .neutral)
        #expect(presentation.plainText == "28%")
        #expect(presentation.segments.allSatisfy { $0.severity == .neutral })
        #expect(presentation.nextUpdateAt == nil)
    }

    @Test func menuBarPresentationSupportsEveryVisibleContentCombinationAndUnavailableState() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = menuBarSnapshot(now: now)

        var iconOnly = MenuBarConfiguration.default
        iconOnly.showsPercentage = false
        let iconPresentation = MenuBarPresentationBuilder.make(
            snapshot: snapshot,
            freshness: .fresh,
            configuration: iconOnly,
            now: now
        )
        #expect(iconPresentation.symbolName == "gauge.with.needle")
        #expect(iconPresentation.plainText.isEmpty)

        var percentageOnly = MenuBarConfiguration.default
        percentageOnly.showsGauge = false
        let percentagePresentation = MenuBarPresentationBuilder.make(
            snapshot: snapshot,
            freshness: .fresh,
            configuration: percentageOnly,
            now: now
        )
        #expect(percentagePresentation.symbolName == nil)
        #expect(percentagePresentation.plainText == "28%")

        var resetOnly = MenuBarConfiguration.default
        resetOnly.showsGauge = false
        resetOnly.showsPercentage = false
        resetOnly.resetDisplay = .timeRemaining
        let resetPresentation = MenuBarPresentationBuilder.make(
            snapshot: snapshot,
            freshness: .fresh,
            configuration: resetOnly,
            now: now
        )
        #expect(resetPresentation.symbolName == nil)
        #expect(resetPresentation.plainText == "2d 18h")

        var paceOnly = MenuBarConfiguration.default
        paceOnly.showsGauge = false
        paceOnly.showsPercentage = false
        paceOnly.showsSuggestedPace = true
        let pacePresentation = MenuBarPresentationBuilder.make(
            snapshot: snapshot,
            freshness: .fresh,
            configuration: paceOnly,
            now: now,
            locale: Locale(identifier: "en_US")
        )
        #expect(pacePresentation.symbolName == nil)
        #expect(pacePresentation.plainText == "≈10%/day")
        #expect(pacePresentation.tooltip.contains("percentage points"))
        #expect(pacePresentation.tooltip.contains("10.1"))

        let unavailablePresentation = MenuBarPresentationBuilder.make(
            snapshot: nil,
            freshness: .unavailable,
            configuration: .default,
            now: now
        )
        #expect(unavailablePresentation.symbolName == "questionmark.circle")
        #expect(unavailablePresentation.plainText == "—")
        #expect(unavailablePresentation.accessibilityLabel.contains("unavailable"))

        let stalePresentation = MenuBarPresentationBuilder.make(
            snapshot: nil,
            freshness: .stale,
            configuration: .default,
            now: now
        )
        #expect(stalePresentation.symbolName == "exclamationmark.triangle.fill")
        #expect(stalePresentation.accessibilityLabel.contains("out of date"))
    }

    @Test func missingSpecificAllowanceFallsBackWithoutLosingItsUnavailableState() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var configuration = MenuBarConfiguration.default
        configuration.primaryAllowance = .specific(bucketID: "missing", windowID: "missing-primary")
        configuration.secondaryAllowance = .specific(bucketID: "also-missing", windowID: "missing-secondary")

        let presentation = MenuBarPresentationBuilder.make(
            snapshot: menuBarSnapshot(now: now),
            freshness: .fresh,
            configuration: configuration,
            now: now,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(presentation.primarySelectionUnavailable)
        #expect(presentation.secondarySelectionUnavailable)
        #expect(presentation.plainText == "28%")
    }

    @Test func primaryAndSecondaryAllowancesProduceAnUnambiguousCompactLabel() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var configuration = MenuBarConfiguration.default
        configuration.primaryAllowance = .specific(bucketID: "codex", windowID: "codex-primary")
        configuration.secondaryAllowance = .specific(bucketID: "codex", windowID: "codex-secondary")

        let presentation = MenuBarPresentationBuilder.make(
            snapshot: menuBarSnapshot(now: now),
            freshness: .fresh,
            configuration: configuration,
            now: now
        )

        #expect(presentation.plainText == "5h 62% · 1w 28%")
        #expect(presentation.tooltip.components(separatedBy: "Resets").count - 1 == 1)
    }

    @Test func allowancesFromDifferentBucketsIncludeTheirNames() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var configuration = MenuBarConfiguration.default
        configuration.primaryAllowance = .specific(bucketID: "codex", windowID: "codex-primary")
        configuration.secondaryAllowance = .specific(bucketID: "codex-spark", windowID: "spark-primary")

        let presentation = MenuBarPresentationBuilder.make(
            snapshot: menuBarSnapshot(now: now),
            freshness: .fresh,
            configuration: configuration,
            now: now
        )

        #expect(presentation.plainText == "Codex 5h 62% · Codex Spark 1d 5%")
    }

    @Test func duplicateResolvedSecondaryAllowanceIsSuppressed() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var configuration = MenuBarConfiguration.default
        configuration.primaryAllowance = .limitingCodex
        configuration.secondaryAllowance = .specific(bucketID: "codex", windowID: "codex-secondary")

        let presentation = MenuBarPresentationBuilder.make(
            snapshot: menuBarSnapshot(now: now),
            freshness: .fresh,
            configuration: configuration,
            now: now
        )

        #expect(presentation.plainText == "28%")
    }

    @Test func hiddenPercentagesAlsoSuppressTheAdditionalAllowanceFromStatusAndColor() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var configuration = MenuBarConfiguration.default
        configuration.showsPercentage = false
        configuration.primaryAllowance = .specific(bucketID: "codex", windowID: "codex-primary")
        configuration.secondaryAllowance = .specific(bucketID: "codex-spark", windowID: "spark-primary")
        configuration.colorMode = .warningsOnly
        configuration.colorBasis = .remainingAllowance
        configuration.colorTarget = .gaugeOnly

        let presentation = MenuBarPresentationBuilder.make(
            snapshot: menuBarSnapshot(now: now),
            freshness: .fresh,
            configuration: configuration,
            now: now
        )

        #expect(presentation.symbolName == "gauge.with.needle")
        #expect(presentation.symbolSeverity == .neutral)
        #expect(presentation.plainText.isEmpty)
        #expect(!presentation.tooltip.contains("Codex Spark"))
    }

    @Test func unavailableSuggestedPaceCannotCreateAnInvisibleStatusItem() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var configuration = MenuBarConfiguration.default
        configuration.showsGauge = false
        configuration.showsPercentage = false
        configuration.showsSuggestedPace = true
        configuration.primaryAllowance = .specific(bucketID: "codex", windowID: "codex-primary")

        let presentation = MenuBarPresentationBuilder.make(
            snapshot: menuBarSnapshot(now: now),
            freshness: .fresh,
            configuration: configuration,
            now: now
        )

        #expect(presentation.symbolName == "gauge.with.needle")
        #expect(presentation.segments.isEmpty)
    }

    @Test func resetCountdownUsesStableCompactBoundaries() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(MenuBarPresentationBuilder.compactCountdown(to: now.addingTimeInterval(6 * 86_400 + 5 * 3_600), now: now) == "6d 5h")
        #expect(MenuBarPresentationBuilder.compactCountdown(to: now.addingTimeInterval(5 * 3_600 + 18 * 60), now: now) == "5h 18m")
        #expect(MenuBarPresentationBuilder.compactCountdown(to: now.addingTimeInterval(42 * 60), now: now) == "42m")
        #expect(MenuBarPresentationBuilder.compactCountdown(to: now.addingTimeInterval(42), now: now) == "<1m")
        #expect(MenuBarPresentationBuilder.compactCountdown(to: now, now: now) == "Now")
    }

    @Test func menuBarPresentationNeverLeavesAnOrphanedDivider() {
        let presentation = MenuBarPresentation(
            symbolName: "gauge.with.needle",
            symbolSeverity: .normal,
            segments: [
                MenuBarTextSegment(text: "99%", severity: .normal, usesMonospacedDigits: true),
                MenuBarTextSegment(text: " · ", severity: .neutral, usesMonospacedDigits: false)
            ],
            tooltip: "Test",
            accessibilityLabel: "Test",
            nextUpdateAt: nil,
            primarySelectionUnavailable: false,
            secondarySelectionUnavailable: false,
            statusNotice: nil
        )

        #expect(presentation.plainText == "99%")
        #expect(presentation.displaySegments.count == 1)
    }

    @Test func absoluteResetPresentationUsesTheSelectedTimeZoneAcrossADaylightSavingBoundary() {
        let reset = ISO8601DateFormatter().date(from: "2026-11-01T05:30:00Z")!
        let now = reset.addingTimeInterval(-2 * 86_400)
        let window = QuotaWindow(
            id: "codex-secondary",
            kind: "Secondary",
            usedPercent: 20,
            durationMinutes: 10_080,
            resetsAt: reset
        )
        let snapshot = singleWindowSnapshot(window: window, now: now)
        var configuration = MenuBarConfiguration.default
        configuration.resetDisplay = .timeRemainingAndResetTime
        let locale = Locale(identifier: "en_US")

        let newYork = MenuBarPresentationBuilder.make(
            snapshot: snapshot,
            freshness: .fresh,
            configuration: configuration,
            now: now,
            locale: locale,
            timeZone: TimeZone(identifier: "America/New_York")!
        )
        let utc = MenuBarPresentationBuilder.make(
            snapshot: snapshot,
            freshness: .fresh,
            configuration: configuration,
            now: now,
            locale: locale,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let newYorkText = newYork.plainText.replacingOccurrences(of: "\u{202F}", with: " ")
        let utcText = utc.plainText.replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(newYorkText.contains("1:30 AM"))
        #expect(utcText.contains("5:30 AM"))
        #expect(newYork.plainText.hasPrefix("80% · 2d 0h"))
        #expect(newYork.nextUpdateAt != nil)
    }

    @Test func suggestedPaceUsesExactRemainingTimeAndSwitchesToHoursOnTheFinalDay() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let daily = QuotaWindow(
            id: "weekly",
            kind: "Secondary",
            usedPercent: 16,
            durationMinutes: 10_080,
            resetsAt: now.addingTimeInterval(6 * 86_400 + 5 * 3_600)
        )
        let hourly = QuotaWindow(
            id: "weekly",
            kind: "Secondary",
            usedPercent: 16,
            durationMinutes: 10_080,
            resetsAt: now.addingTimeInterval(12 * 3_600)
        )

        let dailyPace = MenuBarPresentationBuilder.suggestedPace(for: daily, now: now, isFresh: true)
        let hourlyPace = MenuBarPresentationBuilder.suggestedPace(for: hourly, now: now, isFresh: true)
        #expect(dailyPace?.unit == .day)
        #expect(abs((dailyPace?.percentagePoints ?? 0) - (84 / (6 + 5.0 / 24))) < 0.001)
        #expect(dailyPace?.compactText(style: .usageRate) == "≈14%/day")
        #expect(dailyPace?.compactText(style: .remainingTarget) == "Target 86%")
        #expect(hourlyPace?.unit == .hour)
        #expect(hourlyPace?.percentagePoints == 7)
        #expect(hourlyPace?.compactText(style: .remainingTarget) == "Target 7%")
        #expect(MenuBarPresentationBuilder.suggestedPace(
            for: QuotaWindow(id: "short", kind: "Primary", usedPercent: 10, durationMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
            now: now,
            isFresh: true
        ) == nil)
        #expect(MenuBarPresentationBuilder.suggestedPace(for: daily, now: now, isFresh: false) == nil)
    }

    @Test func remainingTargetPresentationUsesTheCurrentAllowanceDayBoundary() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let window = QuotaWindow(
            id: "weekly",
            kind: "Secondary",
            usedPercent: 16,
            durationMinutes: 10_080,
            resetsAt: now.addingTimeInterval(6 * 86_400 + 5 * 3_600)
        )
        var configuration = MenuBarConfiguration.default
        configuration.showsSuggestedPace = true
        configuration.suggestedPaceDisplay = .remainingTarget

        let presentation = MenuBarPresentationBuilder.make(
            snapshot: singleWindowSnapshot(window: window, now: now),
            freshness: .fresh,
            configuration: configuration,
            now: now,
            locale: Locale(identifier: "en_US")
        )

        #expect(presentation.plainText == "84% · Target 86%")
        #expect(presentation.tooltip.contains("finish this allowance day"))
        #expect(presentation.nextUpdateAt?.timeIntervalSince(now) ?? 0 > 5 * 3_600)
        #expect(presentation.nextUpdateAt?.timeIntervalSince(now) ?? .infinity < 5 * 3_600 + 1)
    }

    @Test func menuBarConfigurationDecodesOlderPreferencesAndRepairsUnavailableColorTargets() throws {
        let oldJSON = Data(#"{"showsGauge":false,"showsPercentage":true,"primaryAllowance":{"limitingCodex":{}},"resetDisplay":"hidden","showsSuggestedPace":false,"colorMode":"trafficLight","colorBasis":"combined","colorTarget":"gaugeOnly"}"#.utf8)
        let decoded = try JSONDecoder().decode(MenuBarConfiguration.self, from: oldJSON)

        #expect(decoded.suggestedPaceDisplay == .usageRate)
        #expect(decoded.normalized.colorTarget == .valuesOnly)

        var gaugeOnly = MenuBarConfiguration.default
        gaugeOnly.showsPercentage = false
        gaugeOnly.colorTarget = .valuesOnly
        #expect(gaugeOnly.normalized.colorTarget == .gaugeOnly)
    }

    @Test func menuBarSeverityUsesBuiltInRemainingAndPacingRules() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func window(used: Int, resetAfter: TimeInterval = 3_000) -> QuotaWindow {
            QuotaWindow(id: "test", kind: "Primary", usedPercent: used, durationMinutes: 100, resetsAt: now.addingTimeInterval(resetAfter))
        }

        #expect(MenuBarPresentationBuilder.severity(for: window(used: 79), basis: .remainingAllowance, now: now, isFresh: true) == .normal)
        #expect(MenuBarPresentationBuilder.severity(for: window(used: 80), basis: .remainingAllowance, now: now, isFresh: true) == .caution)
        #expect(MenuBarPresentationBuilder.severity(for: window(used: 90), basis: .remainingAllowance, now: now, isFresh: true) == .critical)
        #expect(MenuBarPresentationBuilder.severity(for: window(used: 45), basis: .usagePace, now: now, isFresh: true) == .caution)
        #expect(MenuBarPresentationBuilder.severity(for: window(used: 51), basis: .usagePace, now: now, isFresh: true) == .critical)
        #expect(MenuBarPresentationBuilder.severity(for: window(used: 80), basis: .combined, now: now, isFresh: false) == .neutral)
    }

    @Test func pacingDoesNotWarnFromCoarseDataImmediatelyAfterAReset() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let earlyWeeklyWindow = QuotaWindow(
            id: "weekly",
            kind: "Secondary",
            usedPercent: 1,
            durationMinutes: 10_080,
            resetsAt: now.addingTimeInterval(6 * 86_400 + 22 * 3_600)
        )
        var configuration = MenuBarConfiguration.default
        configuration.primaryAllowance = .specific(bucketID: "codex", windowID: "weekly")
        configuration.resetDisplay = .timeRemaining
        configuration.colorMode = .warningsOnly
        configuration.colorBasis = .combined
        configuration.colorTarget = .gaugeAndValues

        let presentation = MenuBarPresentationBuilder.make(
            snapshot: singleWindowSnapshot(window: earlyWeeklyWindow, now: now),
            freshness: .fresh,
            configuration: configuration,
            now: now
        )

        #expect(earlyWeeklyWindow.pacing(now: now) == nil)
        #expect(presentation.symbolName == "gauge.with.needle")
        #expect(presentation.symbolSeverity == .neutral)
        #expect(presentation.statusNotice == nil)
        #expect(presentation.plainText == "99% · 6d 22h")
    }

    @Test func genuineMenuBarWarningIncludesAPopoverExplanation() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let weeklyWindow = QuotaWindow(
            id: "weekly",
            kind: "Secondary",
            usedPercent: 72,
            durationMinutes: 10_080,
            resetsAt: now.addingTimeInterval(240_000)
        )
        var configuration = MenuBarConfiguration.default
        configuration.primaryAllowance = .specific(bucketID: "codex", windowID: "weekly")
        configuration.colorMode = .warningsOnly
        configuration.colorBasis = .combined

        let presentation = MenuBarPresentationBuilder.make(
            snapshot: singleWindowSnapshot(window: weeklyWindow, now: now),
            freshness: .fresh,
            configuration: configuration,
            now: now
        )

        #expect(presentation.statusNotice?.severity == .critical)
        #expect(presentation.statusNotice?.title == "Usage may exceed this allowance")
        #expect(presentation.statusNotice?.detail.contains("Codex weekly allowance") == true)
    }

    @Test func stalePresentationSuppressesPaceAndOverridesConfiguredColors() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var configuration = MenuBarConfiguration.default
        configuration.primaryAllowance = .specific(bucketID: "codex", windowID: "codex-secondary")
        configuration.showsSuggestedPace = true
        configuration.colorMode = .trafficLight
        configuration.colorTarget = .gaugeAndValues

        let presentation = MenuBarPresentationBuilder.make(
            snapshot: menuBarSnapshot(now: now),
            freshness: .stale,
            configuration: configuration,
            now: now
        )

        #expect(presentation.symbolName == "exclamationmark.triangle.fill")
        #expect(presentation.symbolSeverity == .neutral)
        #expect(!presentation.plainText.contains("/day"))
        #expect(presentation.segments.allSatisfy { $0.severity == .neutral })
        #expect(presentation.accessibilityLabel.contains("out of date"))
    }

    @Test func warningsOnlyAndTrafficLightModesApplyTheirConfiguredTargets() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let window = QuotaWindow(
            id: "codex-primary",
            kind: "Primary",
            usedPercent: 5,
            durationMinutes: 300,
            resetsAt: now.addingTimeInterval(4 * 3_600)
        )
        let snapshot = singleWindowSnapshot(window: window, now: now)
        var configuration = MenuBarConfiguration.default
        configuration.colorBasis = .remainingAllowance
        configuration.colorMode = .warningsOnly
        configuration.colorTarget = .gaugeAndValues

        let warnings = MenuBarPresentationBuilder.make(
            snapshot: snapshot,
            freshness: .fresh,
            configuration: configuration,
            now: now
        )
        #expect(warnings.symbolSeverity == .neutral)
        #expect(warnings.segments.allSatisfy { $0.severity == .neutral })

        configuration.colorMode = .trafficLight
        let traffic = MenuBarPresentationBuilder.make(
            snapshot: snapshot,
            freshness: .fresh,
            configuration: configuration,
            now: now
        )
        #expect(traffic.symbolSeverity == .normal)
        #expect(traffic.segments.contains { $0.severity == .normal })
    }

    @Test func countdownPresentationSchedulesOnlyItsNextVisibleBoundary() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var configuration = MenuBarConfiguration.default
        configuration.primaryAllowance = .specific(bucketID: "codex", windowID: "codex-secondary")
        configuration.resetDisplay = .timeRemaining

        let presentation = MenuBarPresentationBuilder.make(
            snapshot: menuBarSnapshot(now: now),
            freshness: .fresh,
            configuration: configuration,
            now: now
        )
        let delay = presentation.nextUpdateAt?.timeIntervalSince(now)
        #expect(delay != nil)
        #expect((delay ?? 0) > 0)
        #expect((delay ?? .infinity) <= 3_600.1)

        configuration.resetDisplay = .resetDateAndTime
        let staticPresentation = MenuBarPresentationBuilder.make(
            snapshot: menuBarSnapshot(now: now),
            freshness: .fresh,
            configuration: configuration,
            now: now
        )
        #expect(staticPresentation.nextUpdateAt == nil)
    }

    @Test func suggestedPaceNeverCreatesASubminuteUpdateLoop() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let window = QuotaWindow(
            id: "codex-secondary",
            kind: "Secondary",
            usedPercent: 16,
            durationMinutes: 10_080,
            resetsAt: now.addingTimeInterval(120)
        )
        var configuration = MenuBarConfiguration.default
        configuration.showsSuggestedPace = true
        let presentation = MenuBarPresentationBuilder.make(
            snapshot: singleWindowSnapshot(window: window, now: now),
            freshness: .fresh,
            configuration: configuration,
            now: now
        )
        let delay = presentation.nextUpdateAt?.timeIntervalSince(now)

        #expect((delay ?? 0) >= 60)
        #expect((delay ?? .infinity) <= 120.1)
    }

    @Test func remainingPercentageIsClamped() {
        let over = QuotaWindow(id: "a", kind: "Primary", usedPercent: 130, durationMinutes: nil, resetsAt: nil)
        let under = QuotaWindow(id: "b", kind: "Primary", usedPercent: -10, durationMinutes: nil, resetsAt: nil)
        #expect(over.remainingPercent == 0)
        #expect(under.remainingPercent == 100)
        #expect(over.clampedUsedPercent == 100)
        #expect(under.clampedUsedPercent == 0)
    }

    @Test func invalidTokenRatesAreSafeToDisplay() {
        #expect(GaugeFormatting.tokenRate(.nan) == "0")
        #expect(GaugeFormatting.tokenRate(.infinity) == "0")
        #expect(GaugeFormatting.tokenRate(-1) == "0")
        #expect(!GaugeFormatting.tokenRate(.greatestFiniteMagnitude).isEmpty)
        #expect(GaugeFormatting.nonnegativeInt64(.greatestFiniteMagnitude) == .max)
        #expect(GaugeFormatting.tokenRate(549_000) == GaugeFormatting.tokenRate(549_200))
    }

    @Test func recentDurationsUseStableCoarseUnits() {
        #expect(GaugeFormatting.coarseDuration(42) == "< 1 min")
        #expect(GaugeFormatting.coarseDuration(125) == "2 min")
        #expect(GaugeFormatting.coarseDuration(7_200) == "2 hr")
        #expect(GaugeFormatting.coarseDuration(172_800) == "2 days")
    }

    @Test func refreshBackoffIsBoundedAndNeverBecomesAOneSecondRetryLoop() {
        #expect(RefreshBackoff.delay(forFailureCount: 0) == 0)
        #expect(RefreshBackoff.delay(forFailureCount: 1) == 2)
        #expect(RefreshBackoff.delay(forFailureCount: 4) == 16)
        #expect(RefreshBackoff.delay(forFailureCount: 20) == 120)
        #expect(ConnectionRecoveryBackoff.delay(forAttempt: 1) == 15)
        #expect(ConnectionRecoveryBackoff.delay(forAttempt: 4) == 16)
        #expect(ConnectionRecoveryBackoff.delay(forAttempt: 20) == 120)
    }

    @Test func snapshotWritesAreCoalescedExceptForResetChanges() {
        var policy = SnapshotPersistencePolicy()
        let start = Date(timeIntervalSince1970: 2_000_000_000)

        let initial = policy.shouldPersist(at: start, resetSignature: "primary|reset-a", remainingPercentages: ["primary": 80])
        let immediateDuplicate = policy.shouldPersist(at: start.addingTimeInterval(1), resetSignature: "primary|reset-a", remainingPercentages: ["primary": 79])
        let resetChange = policy.shouldPersist(at: start.addingTimeInterval(2), resetSignature: "primary|reset-b", remainingPercentages: ["primary": 79])
        let materialAllowanceChange = policy.shouldPersist(at: start.addingTimeInterval(3), resetSignature: "primary|reset-b", remainingPercentages: ["primary": 73])
        let earlyDuplicate = policy.shouldPersist(at: start.addingTimeInterval(59), resetSignature: "primary|reset-b", remainingPercentages: ["primary": 72])
        let elapsed = policy.shouldPersist(at: start.addingTimeInterval(63), resetSignature: "primary|reset-b", remainingPercentages: ["primary": 72])
        #expect(initial)
        #expect(!immediateDuplicate)
        #expect(resetChange)
        #expect(materialAllowanceChange)
        #expect(!earlyDuplicate)
        #expect(elapsed)
    }

    @Test func droppedFSEventsRequireAFullDiscoveryPass() {
        #expect(!FSEventRescanPolicy.requiresRescan([0, UInt32(kFSEventStreamEventFlagItemModified)]))
        #expect(FSEventRescanPolicy.requiresRescan([UInt32(kFSEventStreamEventFlagMustScanSubDirs)]))
        #expect(FSEventRescanPolicy.requiresRescan([UInt32(kFSEventStreamEventFlagUserDropped)]))
        #expect(FSEventRescanPolicy.requiresRescan([UInt32(kFSEventStreamEventFlagKernelDropped)]))
    }

    @Test func semanticallyIdenticalSnapshotsAreNotRepublished() {
        var policy = SemanticSnapshotPolicy<[Int]>()
        let initial = policy.shouldPublish([1, 2, 3])
        let duplicate = policy.shouldPublish([1, 2, 3])
        let changed = policy.shouldPublish([1, 2, 4])
        policy.reset()
        let afterReset = policy.shouldPublish([1, 2, 4])
        #expect(initial)
        #expect(!duplicate)
        #expect(changed)
        #expect(afterReset)
    }

    @Test func quotaNotificationEvaluationOnlyRunsAtThresholdOrResetBoundaries() {
        func snapshot(remaining: Int, reset: Date) -> AccountSnapshot {
            AccountSnapshot(
                accountType: "chatgpt",
                plan: "pro",
                buckets: [
                    QuotaBucket(
                        id: "codex",
                        name: "Codex",
                        plan: "pro",
                        windows: [
                            QuotaWindow(
                                id: "primary",
                                kind: "Primary",
                                usedPercent: 100 - remaining,
                                durationMinutes: 300,
                                resetsAt: reset
                            )
                        ],
                        credits: nil,
                        spendControl: nil,
                        spendControlReached: nil,
                        reachedReason: nil
                    )
                ],
                earnedResetCount: nil,
                activity: .empty,
                fetchedAt: reset.addingTimeInterval(-60)
            )
        }

        let reset = Date(timeIntervalSince1970: 2_000_000_000)
        var policy = QuotaNotificationEvaluationPolicy()
        let initialEvaluation = policy.shouldEvaluate(snapshot(remaining: 30, reset: reset), thresholds: [20, 10, 5])
        let sameBandEvaluation = policy.shouldEvaluate(snapshot(remaining: 25, reset: reset), thresholds: [20, 10, 5])
        let thresholdEvaluation = policy.shouldEvaluate(snapshot(remaining: 19, reset: reset), thresholds: [20, 10, 5])
        let repeatedBandEvaluation = policy.shouldEvaluate(snapshot(remaining: 18, reset: reset), thresholds: [20, 10, 5])
        let resetEvaluation = policy.shouldEvaluate(
            snapshot(remaining: 18, reset: reset.addingTimeInterval(300)),
            thresholds: [20, 10, 5]
        )

        #expect(initialEvaluation)
        #expect(!sameBandEvaluation)
        #expect(thresholdEvaluation)
        #expect(!repeatedBandEvaluation)
        #expect(resetEvaluation)
    }

    @MainActor
    @Test func visibleSurfaceClockStopsWithItsSurface() {
        let clock = VisibleSurfaceClock(now: Date(timeIntervalSince1970: 0))
        #expect(!clock.isRunning)
        clock.start()
        #expect(clock.isRunning)
        clock.stop()
        #expect(!clock.isRunning)
    }

    @Test func canonicalCodexBucketSelectsItsMostConstrainedWindow() {
        let snapshot = AccountSnapshot(
            accountType: "chatgpt",
            plan: "pro",
            buckets: [
                bucket(id: "other", remaining: 1),
                QuotaBucket(
                    id: "codex",
                    name: "Codex",
                    plan: "pro",
                    windows: [window(id: "primary", remaining: 70), window(id: "secondary", remaining: 18)],
                    credits: nil,
                    spendControl: nil,
                    spendControlReached: nil,
                    reachedReason: nil
                )
            ],
            earnedResetCount: nil,
            activity: .empty,
            fetchedAt: .now
        )
        #expect(snapshot.limitingWindow?.id == "secondary")
        #expect(snapshot.limitingWindow?.remainingPercent == 18)
    }

    @Test func fallbackSelectsMostConstrainedReturnedBucket() {
        let snapshot = AccountSnapshot(
            accountType: "chatgpt",
            plan: nil,
            buckets: [bucket(id: "fast", remaining: 55), bucket(id: "slow", remaining: 7)],
            earnedResetCount: nil,
            activity: .empty,
            fetchedAt: .now
        )
        #expect(snapshot.limitingWindow?.remainingPercent == 7)
    }

    @Test func pacingRequiresCompleteFreshWindowMetadata() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let complete = QuotaWindow(
            id: "complete",
            kind: "Primary",
            usedPercent: 50,
            durationMinutes: 100,
            resetsAt: now.addingTimeInterval(3_000)
        )
        #expect(complete.pacing(now: now) != nil)
        #expect(complete.pacing(now: now, isFresh: false) == nil)
        #expect(QuotaWindow(id: "missing", kind: "Primary", usedPercent: 50, durationMinutes: nil, resetsAt: nil).pacing(now: now) == nil)
    }

    @Test func rateLimitDecoderHandlesMultipleBucketsAndUnknownFields() throws {
        let data = Data(#"""
        {
          "rateLimits": {"limitId":"codex","limitName":"Codex","planType":"pro","primary":{"usedPercent":12}},
          "rateLimitsByLimitId": {
            "codex": {
              "limitId":"codex","limitName":"Codex","planType":"pro",
              "primary":{"usedPercent":34,"windowDurationMins":300,"resetsAt":2000000000,"future":"ignored"},
              "secondary":{"usedPercent":71,"windowDurationMins":10080,"resetsAt":2000500000},
              "credits":{"hasCredits":true,"unlimited":false,"balance":"9.25"},
              "spendControlReached":false
            },
            "reviews": {"limitId":"reviews","limitName":"Code Reviews","primary":{"usedPercent":5}}
          },
          "rateLimitResetCredits":{"availableCount":3,"credits":null},
          "futureTopLevel":{"anything":true}
        }
        """#.utf8)
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)
        #expect(response.buckets.count == 2)
        #expect(response.buckets.first?.id == "codex")
        #expect(response.buckets.first?.windows.count == 2)
        #expect(response.rateLimitResetCredits?.availableCount == 3)
    }

    @Test func activityDecoderSummarizesDailyUsage() throws {
        let data = Data(#"""
        {
          "summary":{"lifetimeTokens":1200000,"peakDailyTokens":450000,"longestRunningTurnSec":91,"currentStreakDays":4,"longestStreakDays":8},
          "dailyUsageBuckets":[{"startDate":"2026-08-20","tokens":100},{"startDate":"2026-08-21","tokens":250}],
          "unknown":"ignored"
        }
        """#.utf8)
        let activity = try JSONDecoder().decode(AccountUsageResponse.self, from: data).activity
        #expect(activity.lifetimeTokens == 1_200_000)
        #expect(activity.dailyUsage.map(\.tokens) == [100, 250])
        #expect(activity.currentStreakDays == 4)
    }

    @Test func quotaNotificationDeduplicationChangesOnlyWithCycleOrThreshold() {
        let firstReset = Date(timeIntervalSince1970: 2_000_000_000)
        let firstWindow = QuotaWindow(id: "primary", kind: "Primary", usedPercent: 80, durationMinutes: 300, resetsAt: firstReset)
        let secondWindow = QuotaWindow(id: "primary", kind: "Primary", usedPercent: 80, durationMinutes: 300, resetsAt: firstReset.addingTimeInterval(300))
        let value = bucket(id: "codex", remaining: 20)
        let original = NotificationDedupeKey.quota(bucket: value, window: firstWindow, threshold: 20)
        #expect(original == NotificationDedupeKey.quota(bucket: value, window: firstWindow, threshold: 20))
        #expect(original != NotificationDedupeKey.quota(bucket: value, window: firstWindow, threshold: 10))
        #expect(original != NotificationDedupeKey.quota(bucket: value, window: secondWindow, threshold: 20))
    }

    @Test func quotaThresholdDecisionCollapsesToMostUrgentCrossedAlert() {
        #expect(NotificationDecision.crossedThresholds(remainingPercent: 4, thresholds: [20, 10, 5, 20]) == [5, 10, 20])
        #expect(NotificationDecision.crossedThresholds(remainingPercent: 12, thresholds: [20, 10, 5]) == [20])
        #expect(NotificationDecision.crossedThresholds(remainingPercent: 30, thresholds: [20, 10, 5]).isEmpty)
    }

    @Test func quotaCycleUsesInjectedTimeWhenResetIsUnavailable() {
        let value = bucket(id: "codex", remaining: 20)
        let window = QuotaWindow(id: "primary", kind: "Primary", usedPercent: 80, durationMinutes: 60, resetsAt: nil)
        let first = NotificationDedupeKey.quota(
            bucket: value,
            window: window,
            threshold: 20,
            now: Date(timeIntervalSince1970: 7_200)
        )
        let second = NotificationDedupeKey.quota(
            bucket: value,
            window: window,
            threshold: 20,
            now: Date(timeIntervalSince1970: 10_800)
        )
        #expect(first != second)
    }

    @Test func attentionAlertsRequireThePreviousRequestToClear() {
        var activeTasks = Set<String>()
        let first = attentionConversation(event: Date(timeIntervalSince1970: 100))
        let replacementWhileActive = attentionConversation(event: Date(timeIntervalSince1970: 101))

        #expect(NotificationDecision.shouldSendAttention(for: first, activeTasks: &activeTasks))
        #expect(!NotificationDecision.shouldSendAttention(for: replacementWhileActive, activeTasks: &activeTasks))

        NotificationDecision.clearInactiveAttentionTasks(activeTasks: &activeTasks, currentlyActionable: [])
        #expect(NotificationDecision.shouldSendAttention(for: replacementWhileActive, activeTasks: &activeTasks))
    }

    @Test func appServerClientInitializesAndCorrelatesResponses() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appending(path: "fake-codex")
        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/')
          case "$line" in
            *initialize*)
              if [ "$id" != "$line" ]; then
                printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2"}}\n' "$id"
              fi
              ;;
            *rateLimits*read*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"rateLimits":{"limitId":"codex","limitName":"Codex","planType":"pro","primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":2000000000}}}}\n' "$id"
              ;;
            *usage*read*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"summary":{"lifetimeTokens":1234},"dailyUsageBuckets":[]}}\n' "$id"
              ;;
            *account*read*)
              printf 'account request received\n' >&2
              printf '{"jsonrpc":"2.0","id":%s,"result":{"account":{"type":"chatgpt","planType":"pro","email":"discard@example.test"},"requiresOpenaiAuth":true}}\n' "$id"
              ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = CodexAppServerClient(
            executableURL: executable,
            codexHomeURL: temporary,
            skipTrustValidation: true
        )
        let identity = try await client.fetchAccountIdentity()
        let limits = try await client.fetchRateLimits()
        let activity = try await client.fetchAccountActivity()
        await client.stop()

        #expect(identity.accountType == "chatgpt")
        #expect(identity.plan == "pro")
        #expect(limits.buckets.first?.windows.first?.remainingPercent == 58)
        #expect(activity.lifetimeTokens == 1_234)
    }

    @Test func helperStaticTrustRejectsAProcessFromAnotherSigner() throws {
        var rejected = false
        do {
            _ = try CodexExecutableTrust.validate(URL(fileURLWithPath: "/bin/echo"))
        } catch {
            rejected = true
        }

        #expect(rejected)
    }

    @Test(
        .disabled(
            if: !testHostHasTeamSignature(),
            "An Apple Development or Developer ID signed XCTest host is required to enforce parent launch constraints."
        )
    )
    func helperLaunchRequirementRejectsAProcessFromAnotherSigner() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/echo")
        child.arguments = ["must-not-run"]
        child.launchRequirement = try CodexExecutableTrust.launchRequirement()

        var rejected = false
        do {
            try child.run()
            child.waitUntilExit()
            rejected = child.terminationReason == .uncaughtSignal || child.terminationStatus != 0
        } catch {
            rejected = true
        }

        #expect(rejected)
    }

    @Test func boundedFileReaderRejectsSymlinksAndOversizedFiles() throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let regular = temporary.appending(path: "regular.json")
        let link = temporary.appending(path: "link.json")
        try Data("12345".utf8).write(to: regular)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)

        #expect(BoundedFileReader.read(regular, maximumBytes: 5) == Data("12345".utf8))
        #expect(BoundedFileReader.read(regular, maximumBytes: 4) == nil)
        #expect(BoundedFileReader.read(link, maximumBytes: 5) == nil)
    }

    @Test func anchoredFileAccessRejectsAnIntermediateDirectorySymlinkSwap() throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let root = temporary.appending(path: "sessions", directoryHint: .isDirectory)
        let original = root.appending(path: "2026", directoryHint: .isDirectory)
        let displaced = root.appending(path: "2026-original", directoryHint: .isDirectory)
        let outside = temporary.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("inside".utf8).write(to: original.appending(path: "rollout.jsonl"))
        try Data("outside".utf8).write(to: outside.appending(path: "rollout.jsonl"))

        let directory = try #require(AnchoredFileAccess.openDirectory(root))
        defer { close(directory.descriptor) }
        let originalDescriptor = try #require(AnchoredFileAccess.openRegularFile(
            relativePath: "2026/rollout.jsonl",
            directoryDescriptor: directory.descriptor
        ))
        close(originalDescriptor)

        try FileManager.default.moveItem(at: original, to: displaced)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)

        #expect(AnchoredFileAccess.openRegularFile(
            relativePath: "2026/rollout.jsonl",
            directoryDescriptor: directory.descriptor
        ) == nil)
    }

    @Test func directoryEntryEnumerationIsBoundedBeforeLockProbing() throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for index in 0..<600 {
            _ = FileManager.default.createFile(
                atPath: temporary.appending(path: "\(index).lock").path,
                contents: Data()
            )
        }

        let directory = try #require(AnchoredFileAccess.openDirectory(temporary))
        defer { close(directory.descriptor) }
        let stream = try #require(AnchoredFileAccess.DirectoryStream(directoryDescriptor: directory.descriptor))
        let first = stream.nextBatch(maximumEntries: 512)
        let second = stream.nextBatch(maximumEntries: 512)

        #expect(first.names.count == 512)
        #expect(!first.reachedEnd)
        #expect(second.names.count == 88)
        #expect(second.reachedEnd)
    }

    @Test func localSessionMonitorDecodesMetadataWithoutMessageContent() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sessionDirectory = temporary.appending(path: "sessions/2026/08/21", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary.appending(path: "thread-writer-locks"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let id = "11111111-2222-3333-4444-555555555555"
        let lines = [
            #"{"timestamp":"2026-08-21T20:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/Sample","model":"gpt-test","source":"cli","base_instructions":"must not be retained"}}"#,
            #"{"timestamp":"2026-08-21T20:00:01.000Z","type":"event_msg","payload":{"type":"task_started","started_at":1787342401,"model_context_window":100000}}"#,
            #"{"timestamp":"2026-08-21T20:00:02.000Z","type":"response_item","payload":{"type":"message","content":"fixture content that must be ignored"}}"#,
            #"{"timestamp":"2026-08-21T20:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9800,"cached_input_tokens":9000,"cache_write_input_tokens":0,"output_tokens":200,"reasoning_output_tokens":0,"total_tokens":10000},"last_token_usage":{"input_tokens":80,"cached_input_tokens":50,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":100},"model_context_window":100000}}}"#,
            #"{"timestamp":"2026-08-21T20:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10200,"cached_input_tokens":9300,"cache_write_input_tokens":0,"output_tokens":300,"reasoning_output_tokens":0,"total_tokens":10500},"last_token_usage":{"input_tokens":420,"cached_input_tokens":300,"cache_write_input_tokens":0,"output_tokens":80,"reasoning_output_tokens":0,"total_tokens":500},"model_context_window":100000}}}"#,
            #"{"timestamp":"2026-08-21T20:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":100,"cache_write_input_tokens":0,"output_tokens":30,"reasoning_output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":170,"cached_input_tokens":100,"cache_write_input_tokens":0,"output_tokens":30,"reasoning_output_tokens":0,"total_tokens":200},"model_context_window":100000}}}"#,
            #"{"timestamp":"2026-08-21T20:00:06.000Z","type":"event_msg","payload":{"type":"agent_reasoning","content":"must not be retained"}}"#
        ]
        let file = sessionDirectory.appending(path: "rollout-2026-08-21T20-00-00-\(id).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let monitor = LocalSessionMonitor(
            codexHomeURL: temporary,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1_787_342_410))
        )
        let stream = await monitor.snapshots()
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next()
        await monitor.stop()

        #expect(result?.count == 1)
        #expect(result?.first?.id == id)
        #expect(result?.first?.workspace == "Sample")
        #expect(result?.first?.totalTokens == 800)
        #expect(result?.first?.model == "gpt-test")
        #expect(result?.first?.state == .running)
        #expect(result?.first?.activity == .thinking)
        #expect(result?.first?.callsPerMinute == 3)
        #expect(abs((result?.first?.latestContextPercent ?? 0) - 0.17) < 0.000_001)
    }

    @Test func liveTaskFallbackTailsAnUnlockedTaskWhenFilesystemEventsAreUnavailable() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sessionDirectory = temporary.appending(path: "sessions/2026/08/21", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary.appending(path: "thread-writer-locks"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let id = "11111111-2222-3333-4444-666666666666"
        let initialLines = [
            #"{"timestamp":"2026-08-21T20:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/LiveFallback","model":"gpt-test"}}"#,
            #"{"timestamp":"2026-08-21T20:00:01.000Z","type":"event_msg","payload":{"type":"task_started"}}"#
        ]
        let file = sessionDirectory.appending(path: "rollout-2026-08-21T20-00-00-\(id).jsonl")
        try Data((initialLines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let monitor = LocalSessionMonitor(
            codexHomeURL: temporary,
            clock: FixedClock(now: ISO8601DateFormatter().date(from: "2026-08-21T20:00:10Z")!),
            maintenanceInterval: .milliseconds(25),
            watchesFilesystemEvents: false
        )
        let stream = await monitor.snapshots()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial?.first?.state == .running)
        #expect(initial?.first?.totalTokens == 0)

        let tokenRecord = #"{"timestamp":"2026-08-21T20:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":50,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":80,"cached_input_tokens":50,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":100},"model_context_window":100000}}}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((tokenRecord + "\n").utf8))
        try handle.close()

        try await Task.sleep(for: .milliseconds(200))
        await monitor.stop()
        let updated = await iterator.next()

        #expect(updated?.first?.state == .running)
        #expect(updated?.first?.totalTokens == 100)
        #expect(updated?.first?.tokensPerMinute == 100)
    }

    @Test func localTokenRatesDecayEachMaintenanceTickWithoutNewFileData() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sessionDirectory = temporary.appending(path: "sessions/2026/08/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary.appending(path: "thread-writer-locks"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let now = ISO8601DateFormatter().date(from: "2026-08-29T16:00:10Z")!
        let clock = AdjustableClock(now: now)
        let id = "11111111-2222-3333-4444-888888888888"
        let lines = [
            #"{"timestamp":"2026-08-29T16:00:09.000Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/Decay","model":"gpt-test"}}"#,
            #"{"timestamp":"2026-08-29T16:00:09.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-08-29T16:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":600},"last_token_usage":{"input_tokens":500,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":600}}}}"#
        ]
        let file = sessionDirectory.appending(path: "rollout-2026-08-29T16-00-09-\(id).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let monitor = LocalSessionMonitor(
            codexHomeURL: temporary,
            clock: clock,
            maintenanceInterval: .milliseconds(25),
            watchesFilesystemEvents: false
        )
        let stream = await monitor.snapshots()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial?.first?.tokensPerMinute == 600)
        #expect(initial?.first?.tokensPerFiveMinutes == 120)

        clock.advance(by: 1)
        let decayed = await iterator.next()
        await monitor.stop()

        #expect(abs((decayed?.first?.tokensPerMinute ?? 0) - 590) < 0.000_001)
        #expect(abs((decayed?.first?.tokensPerFiveMinutes ?? 0) - 119.6) < 0.000_001)
    }

    @Test func liveTaskFallbackSkipsAStaleBacklogToPublishTheNewestState() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sessionDirectory = temporary.appending(path: "sessions/2026/08/29", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary.appending(path: "thread-writer-locks"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let id = "11111111-2222-3333-4444-777777777777"
        let initialLines = [
            #"{"timestamp":"2026-08-29T16:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/TailCatchUp","model":"gpt-test"}}"#,
            #"{"timestamp":"2026-08-29T16:00:01.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-08-29T16:00:02.000Z","type":"response_item","payload":{"type":"reasoning"}}"#
        ]
        let file = sessionDirectory.appending(path: "rollout-2026-08-29T16-00-00-\(id).jsonl")
        try Data((initialLines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let monitor = LocalSessionMonitor(
            codexHomeURL: temporary,
            clock: FixedClock(now: ISO8601DateFormatter().date(from: "2026-08-29T16:00:10Z")!),
            maintenanceInterval: .milliseconds(25),
            watchesFilesystemEvents: false
        )
        let stream = await monitor.snapshots()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial?.first?.activity == .thinking)

        let oversizedIrrelevantRecord = #"{"timestamp":"2026-08-29T16:00:03.000Z","type":"response_item","payload":{"content":"\#(String(repeating: "x", count: 10 * 1_024 * 1_024))"}}"#
        let completion = #"{"timestamp":"2026-08-29T16:00:04.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((oversizedIrrelevantRecord + "\n" + completion + "\n").utf8))
        try handle.close()

        try await Task.sleep(for: .milliseconds(200))
        await monitor.stop()
        let updated = await iterator.next()

        #expect(updated?.first?.state == .recent)
        #expect(updated?.first?.activity == .waiting)
        #expect(updated?.first?.turnStartedAt == nil)
    }

    @Test func taskIDCreationDateLocatesResumedRolloutDay() throws {
        let date = try #require(LocalSessionMonitor.creationDate(
            fromTaskID: "01a025ed-8084-7551-9e8d-7288c78518ce"
        ))
        #expect(ISO8601DateFormatter().string(from: date) == "2026-08-21T20:05:17Z")
        #expect(LocalSessionMonitor.creationDate(
            fromTaskID: "11111111-2222-3333-4444-555555555555"
        ) == nil)
    }

    @Test func lockedLargeRolloutRemainsLiveWhenBoundedTailStartsAfterTaskStart() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sessionDirectory = temporary.appending(path: "sessions/2026/08/21", directoryHint: .isDirectory)
        let lockDirectory = temporary.appending(path: "thread-writer-locks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let id = "01a025ed-8084-7551-9e8d-7288c78518ce"
        let lines = [
            #"{"timestamp":"2026-08-21T20:05:17.000Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/Resumed","model":"gpt-test"}}"#,
            #"{"timestamp":"2026-08-21T20:06:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
            String(repeating: "x", count: 6 * 1_024 * 1_024),
            #"{"timestamp":"2026-08-29T11:59:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            String(repeating: "y", count: 18 * 1_024 * 1_024),
            #"{"timestamp":"2026-08-29T12:00:00.000Z","type":"response_item","payload":{"type":"reasoning"}}"#
        ]
        let file = sessionDirectory.appending(path: "rollout-2026-08-21T20-05-17-\(id).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let lock = lockDirectory.appending(path: "\(id).lock")
        #expect(FileManager.default.createFile(atPath: lock.path, contents: Data()))
        let lockDescriptor = open(lock.path, O_RDONLY | O_CLOEXEC)
        #expect(lockDescriptor >= 0)
        defer {
            if lockDescriptor >= 0 {
                flock(lockDescriptor, LOCK_UN)
                close(lockDescriptor)
            }
        }
        #expect(flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0)

        let monitor = LocalSessionMonitor(
            codexHomeURL: temporary,
            clock: FixedClock(now: ISO8601DateFormatter().date(from: "2026-08-29T12:00:10Z")!)
        )
        let stream = await monitor.snapshots()
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next()
        await monitor.stop()

        #expect(result?.count == 1)
        #expect(result?.first?.id == id)
        #expect(result?.first?.state == .running)
        #expect(result?.first?.activity == .thinking)
    }

    @Test func localSessionMonitorSkipsOversizedContentAndIgnoresPropertyOrder() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sessionDirectory = temporary.appending(path: "sessions/2026/08/23", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary.appending(path: "thread-writer-locks"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let padding = String(repeating: "x", count: 12_000)
        let oversized = String(repeating: "y", count: 2_100_000)
        let lines = [
            #"{"payload":{"cwd":"/tmp/Reordered","id":"\#(id)","model":"gpt-test"},"type":"session_meta","timestamp":"2026-08-23T15:00:00.000Z"}"#,
            #"{"type":"response_item","payload":{"content":"\#(oversized)"},"timestamp":"2026-08-23T15:00:01.000Z"}"#,
            #"{"payload":{"unmodeled":"\#(padding)","type":"token_count","info":{"model_context_window":100000,"last_token_usage":{"total_tokens":750,"input_tokens":600,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":150,"reasoning_output_tokens":0},"total_token_usage":{"total_tokens":750,"input_tokens":600,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":150,"reasoning_output_tokens":0}}},"timestamp":"2026-08-23T15:00:02.000Z","type":"event_msg"}"#
        ]
        let file = sessionDirectory.appending(path: "rollout-2026-08-23T15-00-00-\(id).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let monitor = LocalSessionMonitor(
            codexHomeURL: temporary,
            clock: FixedClock(now: ISO8601DateFormatter().date(from: "2026-08-23T15:00:10Z")!)
        )
        let stream = await monitor.snapshots()
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next()
        await monitor.stop()

        #expect(result?.count == 1)
        #expect(result?.first?.workspace == "Reordered")
        #expect(result?.first?.totalTokens == 750)
        #expect(result?.first?.latestContextPercent == 0.6)
    }

    @Test func localSessionMonitorKeepsAllLiveTasksPlusTwoHundredRecentTasks() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sessionDirectory = temporary.appending(path: "sessions/2026/08/23", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary.appending(path: "thread-writer-locks"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        for index in 0..<210 {
            let id = String(format: "00000000-0000-0000-0000-%012d", index)
            var lines = [#"{"timestamp":"2026-08-23T15:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/Task-\#(index)","model":"gpt-test"}}"#]
            if index >= 205 {
                lines.append(#"{"timestamp":"2026-08-23T15:00:01.000Z","type":"event_msg","payload":{"type":"task_started"}}"#)
            }
            let file = sessionDirectory.appending(path: "rollout-2026-08-23T15-00-00-\(id).jsonl")
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        }

        let monitor = LocalSessionMonitor(
            codexHomeURL: temporary,
            clock: FixedClock(now: ISO8601DateFormatter().date(from: "2026-08-23T15:00:10Z")!)
        )
        let stream = await monitor.snapshots()
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next()
        await monitor.stop()

        #expect(result?.count == 205)
        #expect(result?.filter(\.isLive).count == 5)
        #expect(result?.filter { !$0.isLive }.count == 200)
    }

    @Test func activitySeriesUsesCalendarBoundariesAndZeroFillsMissingDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!
        let source = [
            DailyUsage(date: calendar.date(byAdding: .day, value: -2, to: now)!, tokens: 10),
            DailyUsage(date: now, tokens: 30)
        ]

        let result = ActivitySeries.trailing(source, days: 3, endingAt: now, calendar: calendar)

        #expect(result.map(\.tokens) == [10, 0, 30])
        #expect(result.count == 3)
    }

    @Test func activityDaySurvivesTimeZoneChangesAndYearBoundaries() {
        let day = ActivityDay(iso8601Date: "2026-12-31")!
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        #expect(ActivityDay(date: day.date(in: losAngeles)!, calendar: losAngeles) == day)
        #expect(ActivityDay(date: day.date(in: tokyo)!, calendar: tokyo) == day)

        let januaryFirst = tokyo.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 12))!
        let result = ActivitySeries.trailing([DailyUsage(day: day, tokens: 9)], days: 2, endingAt: januaryFirst, calendar: tokyo)
        #expect(result.map(\.tokens) == [9, 0])
    }

    @MainActor
    @Test func unsupportedRefreshValuesAreClampedToDefault() {
        let suite = "CodexGaugeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2.5, forKey: "refreshInterval")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.refreshInterval == 60)
        settings.refreshInterval = 7
        #expect(settings.refreshInterval == 60)
    }

    @MainActor
    @Test func freshnessUsesInjectedClockAndRefreshCadence() {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let state = AppState(clock: FixedClock(now: now), startImmediately: false)
        state.freshness = .fresh
        state.accountSnapshot = AccountSnapshot(
            accountType: "chatgpt",
            plan: "pro",
            buckets: [bucket(id: "codex", remaining: 50)],
            earnedResetCount: nil,
            activity: .empty,
            fetchedAt: now.addingTimeInterval(-181)
        )

        #expect(state.displayFreshness == .stale)
    }

    private func bucket(id: String, remaining: Int) -> QuotaBucket {
        QuotaBucket(
            id: id,
            name: id,
            plan: nil,
            windows: [window(id: id, remaining: remaining)],
            credits: nil,
            spendControl: nil,
            spendControlReached: nil,
            reachedReason: nil
        )
    }

    private func menuBarSnapshot(now: Date) -> AccountSnapshot {
        AccountSnapshot(
            accountType: "chatgpt",
            plan: "pro",
            buckets: [
                QuotaBucket(
                    id: "codex",
                    name: "Codex",
                    plan: "pro",
                    windows: [
                        QuotaWindow(
                            id: "codex-primary",
                            kind: "Primary",
                            usedPercent: 38,
                            durationMinutes: 300,
                            resetsAt: now.addingTimeInterval(8_400)
                        ),
                        QuotaWindow(
                            id: "codex-secondary",
                            kind: "Secondary",
                            usedPercent: 72,
                            durationMinutes: 10_080,
                            resetsAt: now.addingTimeInterval(240_000)
                        )
                    ],
                    credits: nil,
                    spendControl: nil,
                    spendControlReached: false,
                    reachedReason: nil
                ),
                QuotaBucket(
                    id: "codex-spark",
                    name: "Codex Spark",
                    plan: "pro",
                    windows: [
                        QuotaWindow(
                            id: "spark-primary",
                            kind: "Primary",
                            usedPercent: 95,
                            durationMinutes: 1_440,
                            resetsAt: now.addingTimeInterval(52_000)
                        )
                    ],
                    credits: nil,
                    spendControl: nil,
                    spendControlReached: false,
                    reachedReason: nil
                )
            ],
            earnedResetCount: nil,
            activity: .empty,
            fetchedAt: now
        )
    }

    private func singleWindowSnapshot(window: QuotaWindow, now: Date) -> AccountSnapshot {
        AccountSnapshot(
            accountType: "chatgpt",
            plan: "pro",
            buckets: [
                QuotaBucket(
                    id: "codex",
                    name: "Codex",
                    plan: "pro",
                    windows: [window],
                    credits: nil,
                    spendControl: nil,
                    spendControlReached: false,
                    reachedReason: nil
                )
            ],
            earnedResetCount: nil,
            activity: .empty,
            fetchedAt: now
        )
    }

    private func window(id: String, remaining: Int) -> QuotaWindow {
        QuotaWindow(id: id, kind: "Primary", usedPercent: 100 - remaining, durationMinutes: nil, resetsAt: nil)
    }

    private func attentionConversation(event: Date) -> ConversationTelemetry {
        ConversationTelemetry(
            id: "private-task-id",
            title: "Unattributed Codex Work",
            workspace: "",
            model: nil,
            state: .needsInput,
            activity: .waiting,
            tokensPerMinute: 0,
            tokensPerFiveMinutes: 0,
            callsPerMinute: nil,
            totalTokens: 0,
            recentTokenMix: .zero,
            latestContextPercent: nil,
            turnStartedAt: nil,
            lastTurnDurationSeconds: nil,
            latestOutputTokens: nil,
            timeToFirstTokenMilliseconds: nil,
            attentionEventAt: event,
            agentCount: 0,
            lastActivity: event
        )
    }
}

private struct FixedClock: ClockProviding {
    let now: Date
}

private final class AdjustableClock: ClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) {
        value = now
    }

    var now: Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}
