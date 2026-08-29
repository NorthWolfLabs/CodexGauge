import Foundation

enum AllowanceSelection: Codable, Hashable, Sendable {
    case limitingCodex
    case lowestOverall
    case specific(bucketID: String, windowID: String)
}

enum ResetDisplayStyle: String, Codable, CaseIterable, Sendable {
    case hidden
    case timeRemaining
    case resetDate
    case resetDateAndTime
    case timeRemainingAndResetTime

    var title: String {
        switch self {
        case .hidden: "Hidden"
        case .timeRemaining: "Time Remaining"
        case .resetDate: "Reset Date"
        case .resetDateAndTime: "Reset Date and Time"
        case .timeRemainingAndResetTime: "Time Remaining and Reset Time"
        }
    }

    var includesCountdown: Bool {
        self == .timeRemaining || self == .timeRemainingAndResetTime
    }
}

enum StatusColorMode: String, Codable, CaseIterable, Sendable {
    case off
    case warningsOnly
    case trafficLight

    var title: String {
        switch self {
        case .off: "Off"
        case .warningsOnly: "Warnings Only"
        case .trafficLight: "Traffic Light"
        }
    }
}

enum StatusColorBasis: String, Codable, CaseIterable, Sendable {
    case remainingAllowance
    case usagePace
    case combined

    var title: String {
        switch self {
        case .remainingAllowance: "Amount Remaining"
        case .usagePace: "Projected Usage"
        case .combined: "More Urgent Status"
        }
    }
}

enum SuggestedPaceDisplayStyle: String, Codable, CaseIterable, Sendable {
    case usageRate
    case remainingTarget

    var title: String {
        switch self {
        case .usageRate: "Available per Day or Hour"
        case .remainingTarget: "Remaining Target"
        }
    }
}

enum StatusColorTarget: String, Codable, CaseIterable, Sendable {
    case gaugeOnly
    case valuesOnly
    case gaugeAndValues

    var title: String {
        switch self {
        case .gaugeOnly: "Gauge Only"
        case .valuesOnly: "Values Only"
        case .gaugeAndValues: "Gauge and Values"
        }
    }

    var colorsGauge: Bool { self != .valuesOnly }
    var colorsValues: Bool { self != .gaugeOnly }
}

struct MenuBarConfiguration: Codable, Equatable, Sendable {
    var showsGauge = true
    var showsPercentage = true
    var primaryAllowance: AllowanceSelection = .limitingCodex
    var secondaryAllowance: AllowanceSelection?
    var resetDisplay: ResetDisplayStyle = .hidden
    var showsSuggestedPace = false
    var suggestedPaceDisplay: SuggestedPaceDisplayStyle = .usageRate
    var colorMode: StatusColorMode = .off
    var colorBasis: StatusColorBasis = .combined
    var colorTarget: StatusColorTarget = .gaugeOnly

    static let `default` = MenuBarConfiguration()

    private enum CodingKeys: String, CodingKey {
        case showsGauge
        case showsPercentage
        case primaryAllowance
        case secondaryAllowance
        case resetDisplay
        case showsSuggestedPace
        case suggestedPaceDisplay
        case colorMode
        case colorBasis
        case colorTarget
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showsGauge = try values.decodeIfPresent(Bool.self, forKey: .showsGauge) ?? true
        showsPercentage = try values.decodeIfPresent(Bool.self, forKey: .showsPercentage) ?? true
        primaryAllowance = try values.decodeIfPresent(AllowanceSelection.self, forKey: .primaryAllowance) ?? .limitingCodex
        secondaryAllowance = try values.decodeIfPresent(AllowanceSelection.self, forKey: .secondaryAllowance)
        resetDisplay = try values.decodeIfPresent(ResetDisplayStyle.self, forKey: .resetDisplay) ?? .hidden
        showsSuggestedPace = try values.decodeIfPresent(Bool.self, forKey: .showsSuggestedPace) ?? false
        suggestedPaceDisplay = try values.decodeIfPresent(SuggestedPaceDisplayStyle.self, forKey: .suggestedPaceDisplay) ?? .usageRate
        colorMode = try values.decodeIfPresent(StatusColorMode.self, forKey: .colorMode) ?? .off
        colorBasis = try values.decodeIfPresent(StatusColorBasis.self, forKey: .colorBasis) ?? .combined
        colorTarget = try values.decodeIfPresent(StatusColorTarget.self, forKey: .colorTarget) ?? .gaugeOnly
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(showsGauge, forKey: .showsGauge)
        try values.encode(showsPercentage, forKey: .showsPercentage)
        try values.encode(primaryAllowance, forKey: .primaryAllowance)
        try values.encodeIfPresent(secondaryAllowance, forKey: .secondaryAllowance)
        try values.encode(resetDisplay, forKey: .resetDisplay)
        try values.encode(showsSuggestedPace, forKey: .showsSuggestedPace)
        try values.encode(suggestedPaceDisplay, forKey: .suggestedPaceDisplay)
        try values.encode(colorMode, forKey: .colorMode)
        try values.encode(colorBasis, forKey: .colorBasis)
        try values.encode(colorTarget, forKey: .colorTarget)
    }

    var hasVisibleContent: Bool {
        showsGauge || showsPercentage || resetDisplay != .hidden || showsSuggestedPace
    }

    var hasConfiguredTextContent: Bool {
        showsPercentage || resetDisplay != .hidden || showsSuggestedPace
    }

    var normalized: MenuBarConfiguration {
        var value = self
        if !value.hasVisibleContent {
            value.showsGauge = true
        }
        if !value.showsGauge, value.hasConfiguredTextContent {
            value.colorTarget = .valuesOnly
        } else if value.showsGauge, !value.hasConfiguredTextContent {
            value.colorTarget = .gaugeOnly
        }
        return value
    }
}

enum MenuBarSeverity: Int, Comparable, Sendable {
    case neutral = 0
    case normal = 1
    case caution = 2
    case critical = 3

    static func < (lhs: MenuBarSeverity, rhs: MenuBarSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

}

struct MenuBarTextSegment: Equatable, Sendable {
    let text: String
    let severity: MenuBarSeverity
    let usesMonospacedDigits: Bool
}

struct MenuBarPresentation: Equatable, Sendable {
    let symbolName: String?
    let symbolSeverity: MenuBarSeverity
    let segments: [MenuBarTextSegment]
    let tooltip: String
    let accessibilityLabel: String
    let nextUpdateAt: Date?
    let primarySelectionUnavailable: Bool
    let secondarySelectionUnavailable: Bool
    let statusNotice: MenuBarStatusNotice?

    var displaySegments: [MenuBarTextSegment] {
        var value = segments
        while value.first?.isDivider == true { value.removeFirst() }
        while value.last?.isDivider == true { value.removeLast() }
        return value
    }

    var plainText: String { displaySegments.map(\.text).joined() }
}

private extension MenuBarTextSegment {
    var isDivider: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "·"
    }
}

struct MenuBarStatusNotice: Equatable, Sendable {
    let severity: MenuBarSeverity
    let title: String
    let detail: String

    var symbolName: String {
        severity == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"
    }
}

struct AllowanceOption: Identifiable, Hashable, Sendable {
    let selection: AllowanceSelection
    let title: String

    var id: AllowanceSelection { selection }
}

struct ResolvedAllowance: Hashable, Sendable {
    let bucket: QuotaBucket
    let window: QuotaWindow

    var id: String { "\(bucket.id)|\(window.id)" }
}

enum AllowanceResolver {
    static func options(in snapshot: AccountSnapshot?) -> [AllowanceOption] {
        var values = [
            AllowanceOption(selection: .limitingCodex, title: "Lowest Codex Allowance"),
            AllowanceOption(selection: .lowestOverall, title: "Lowest Allowance Overall")
        ]
        guard let snapshot else { return values }
        for bucket in snapshot.buckets {
            for window in bucket.windows.sorted(by: windowOrder) {
                values.append(AllowanceOption(
                    selection: .specific(bucketID: bucket.id, windowID: window.id),
                    title: "\(bucket.name) · \(optionWindowLabel(window))"
                ))
            }
        }
        return values
    }

    static func resolve(_ selection: AllowanceSelection, in snapshot: AccountSnapshot?) -> ResolvedAllowance? {
        guard let snapshot else { return nil }
        switch selection {
        case .limitingCodex:
            return limitingCodex(in: snapshot)
        case .lowestOverall:
            return snapshot.buckets
                .flatMap { bucket in bucket.windows.map { ResolvedAllowance(bucket: bucket, window: $0) } }
                .min(by: allowanceOrder)
        case let .specific(bucketID, windowID):
            guard let bucket = snapshot.buckets.first(where: { $0.id == bucketID }),
                  let window = bucket.windows.first(where: { $0.id == windowID }) else { return nil }
            return ResolvedAllowance(bucket: bucket, window: window)
        }
    }

    static func limitingCodex(in snapshot: AccountSnapshot?) -> ResolvedAllowance? {
        guard let snapshot else { return nil }
        if let bucket = snapshot.buckets.first(where: { $0.id == "codex" }),
           let window = bucket.windows.min(by: windowAllowanceOrder) {
            return ResolvedAllowance(bucket: bucket, window: window)
        }
        return snapshot.buckets
            .flatMap { bucket in bucket.windows.map { ResolvedAllowance(bucket: bucket, window: $0) } }
            .min(by: allowanceOrder)
    }

    static func compactWindowLabel(_ window: QuotaWindow) -> String {
        guard let minutes = window.durationMinutes, minutes > 0 else { return window.kind }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080)w" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private static func optionWindowLabel(_ window: QuotaWindow) -> String {
        guard let minutes = window.durationMinutes, minutes > 0 else { return window.kind }
        if minutes == 10_080 { return "Weekly" }
        if minutes == 1_440 { return "Daily" }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080)-week" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }

    private static func windowOrder(_ lhs: QuotaWindow, _ rhs: QuotaWindow) -> Bool {
        switch (lhs.durationMinutes, rhs.durationMinutes) {
        case let (left?, right?) where left != right: left < right
        case (nil, _?): false
        case (_?, nil): true
        default: lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private static func windowAllowanceOrder(_ lhs: QuotaWindow, _ rhs: QuotaWindow) -> Bool {
        if lhs.remainingPercent != rhs.remainingPercent { return lhs.remainingPercent < rhs.remainingPercent }
        return windowOrder(lhs, rhs)
    }

    private static func allowanceOrder(_ lhs: ResolvedAllowance, _ rhs: ResolvedAllowance) -> Bool {
        if lhs.window.remainingPercent != rhs.window.remainingPercent {
            return lhs.window.remainingPercent < rhs.window.remainingPercent
        }
        if lhs.bucket.id != rhs.bucket.id {
            if lhs.bucket.id == "codex" { return true }
            if rhs.bucket.id == "codex" { return false }
        }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }
}

struct SuggestedAllowancePace: Equatable, Sendable {
    enum Unit: String, Sendable {
        case day
        case hour

        var seconds: TimeInterval { self == .day ? 86_400 : 3_600 }
    }

    let percentagePoints: Double
    let unit: Unit
    let targetRemainingPercent: Double
    let nextTargetUpdateAt: Date

    func compactText(style: SuggestedPaceDisplayStyle) -> String {
        switch style {
        case .usageRate:
            let safeValue = min(9_999, max(0, percentagePoints))
            return "≈\(Int(safeValue.rounded()))%/\(unit.rawValue)"
        case .remainingTarget:
            let safeValue = min(100, max(0, targetRemainingPercent))
            return "Target \(Int(safeValue.rounded()))%"
        }
    }

    func detailText(style: SuggestedPaceDisplayStyle, locale: Locale) -> String {
        switch style {
        case .usageRate:
            let value = min(9_999, max(0, percentagePoints))
                .formatted(.number.precision(.fractionLength(1)).locale(locale))
            return "About \(value) percentage points per \(unit.rawValue) until reset"
        case .remainingTarget:
            let value = min(100, max(0, targetRemainingPercent))
                .formatted(.number.precision(.fractionLength(1)).locale(locale))
            let period = unit == .day ? "this allowance day" : "this allowance hour"
            return "Aim to finish \(period) with at least \(value) percent remaining"
        }
    }
}

enum MenuBarPresentationBuilder {
    static func make(
        snapshot: AccountSnapshot?,
        freshness: DataFreshness,
        configuration rawConfiguration: MenuBarConfiguration,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> MenuBarPresentation {
        let configuration = rawConfiguration.normalized
        let requestedPrimary = AllowanceResolver.resolve(configuration.primaryAllowance, in: snapshot)
        let fallback = AllowanceResolver.limitingCodex(in: snapshot)
        let primary = requestedPrimary ?? fallback
        let primaryUnavailable = isMissingSpecific(configuration.primaryAllowance, resolved: requestedPrimary, snapshot: snapshot)

        let activeSecondarySelection = configuration.showsPercentage ? configuration.secondaryAllowance : nil
        let requestedSecondary = activeSecondarySelection.flatMap {
            AllowanceResolver.resolve($0, in: snapshot)
        }
        let secondaryFallback = activeSecondarySelection == nil ? nil : fallback
        let candidateSecondary = requestedSecondary ?? secondaryFallback
        let secondary = candidateSecondary?.id == primary?.id ? nil : candidateSecondary
        let secondaryUnavailable = activeSecondarySelection.map {
            isMissingSpecific($0, resolved: requestedSecondary, snapshot: snapshot)
        } ?? false

        guard let primary else {
            return unavailablePresentation(freshness: freshness, configuration: configuration)
        }

        let isFresh = freshness == .fresh
        let primaryHealth = health(for: primary.window, configuration: configuration, now: now, isFresh: isFresh)
        let secondaryHealth = secondary.map {
            health(for: $0.window, configuration: configuration, now: now, isFresh: isFresh)
        } ?? .neutral
        let worstHealth = max(primaryHealth, secondaryHealth)
        let effectivePrimaryHealth = textSeverity(primaryHealth, configuration: configuration)
        let effectiveSecondaryHealth = textSeverity(secondaryHealth, configuration: configuration)

        var segments: [MenuBarTextSegment] = []
        func append(_ text: String, severity: MenuBarSeverity = .neutral, monospaced: Bool = true) {
            guard !text.isEmpty else { return }
            if !segments.isEmpty {
                segments.append(MenuBarTextSegment(text: " · ", severity: .neutral, usesMonospacedDigits: false))
            }
            segments.append(MenuBarTextSegment(text: text, severity: severity, usesMonospacedDigits: monospaced))
        }

        if configuration.showsPercentage {
            if let secondary {
                let differentBuckets = primary.bucket.id != secondary.bucket.id
                append(
                    percentageLabel(primary, includesBucket: differentBuckets),
                    severity: effectivePrimaryHealth
                )
                append(
                    percentageLabel(secondary, includesBucket: differentBuckets),
                    severity: effectiveSecondaryHealth
                )
            } else {
                append("\(primary.window.remainingPercent)%", severity: effectivePrimaryHealth)
            }
        }

        if configuration.resetDisplay != .hidden,
           let reset = primary.window.resetsAt {
            append(
                resetText(
                    style: configuration.resetDisplay,
                    reset: reset,
                    now: now,
                    locale: locale,
                    timeZone: timeZone
                ),
                severity: effectivePrimaryHealth
            )
        }

        let pace = configuration.showsSuggestedPace
            ? suggestedPace(for: primary.window, now: now, isFresh: isFresh)
            : nil
        if let pace {
            append(
                pace.compactText(style: configuration.suggestedPaceDisplay),
                severity: effectivePrimaryHealth
            )
        }

        var status = statusSymbol(
            freshness: freshness,
            snapshotExists: snapshot != nil,
            configuration: configuration,
            worstHealth: worstHealth
        )
        if status.name == nil, segments.isEmpty {
            status = ("gauge.with.needle", .neutral)
        }
        let tooltip = tooltip(
            primary: primary,
            secondary: secondary,
            pace: pace,
            paceDisplay: configuration.suggestedPaceDisplay,
            freshness: freshness,
            worstHealth: worstHealth,
            colorBasis: configuration.colorBasis,
            locale: locale,
            timeZone: timeZone
        )
        let nextUpdate = nextUpdateDate(
            resetStyle: configuration.resetDisplay,
            reset: primary.window.resetsAt,
            pace: pace,
            paceDisplay: configuration.suggestedPaceDisplay,
            remainingPercent: primary.window.remainingPercent,
            now: now
        )
        let statusNotice = makeStatusNotice(
            primary: primary,
            primaryHealth: primaryHealth,
            secondary: secondary,
            secondaryHealth: secondaryHealth,
            configuration: configuration,
            now: now,
            isFresh: isFresh
        )

        return MenuBarPresentation(
            symbolName: status.name,
            symbolSeverity: status.severity,
            segments: segments,
            tooltip: tooltip,
            accessibilityLabel: tooltip,
            nextUpdateAt: nextUpdate,
            primarySelectionUnavailable: primaryUnavailable,
            secondarySelectionUnavailable: secondaryUnavailable,
            statusNotice: statusNotice
        )
    }

    static func suggestedPace(for window: QuotaWindow, now: Date, isFresh: Bool) -> SuggestedAllowancePace? {
        guard isFresh,
              let duration = window.durationMinutes,
              duration >= 1_440,
              let reset = window.resetsAt else { return nil }
        let remainingSeconds = reset.timeIntervalSince(now)
        guard remainingSeconds.isFinite, remainingSeconds > 0 else { return nil }
        let unit: SuggestedAllowancePace.Unit = remainingSeconds >= 86_400 ? .day : .hour
        let value = Double(window.remainingPercent) * unit.seconds / remainingSeconds
        let durationSeconds = TimeInterval(duration * 60)
        let windowStart = reset.addingTimeInterval(-durationSeconds)
        let elapsed = now.timeIntervalSince(windowStart)
        guard value.isFinite,
              durationSeconds.isFinite,
              durationSeconds > 0,
              elapsed.isFinite,
              elapsed >= 0,
              elapsed < durationSeconds else { return nil }
        let completedUnits = floor(elapsed / unit.seconds)
        let targetDate = min(reset, windowStart.addingTimeInterval((completedUnits + 1) * unit.seconds))
        let targetRemaining = 100 * reset.timeIntervalSince(targetDate) / durationSeconds
        guard targetRemaining.isFinite else { return nil }
        return SuggestedAllowancePace(
            percentagePoints: value,
            unit: unit,
            targetRemainingPercent: targetRemaining,
            nextTargetUpdateAt: targetDate
        )
    }

    static func severity(
        for window: QuotaWindow,
        basis: StatusColorBasis,
        now: Date,
        isFresh: Bool
    ) -> MenuBarSeverity {
        guard isFresh else { return .neutral }
        let remainingSeverity: MenuBarSeverity = window.remainingPercent <= 10
            ? .critical
            : window.remainingPercent <= 20 ? .caution : .normal

        let pacingSeverity: MenuBarSeverity
        if let pacing = window.pacing(now: now, isFresh: true) {
            if pacing.projectedExhaustion != nil || pacing.projectedUsedAtReset > 100 {
                pacingSeverity = .critical
            } else if pacing.projectedUsedAtReset >= 90 {
                pacingSeverity = .caution
            } else {
                pacingSeverity = .normal
            }
        } else {
            pacingSeverity = .normal
        }

        switch basis {
        case .remainingAllowance: return remainingSeverity
        case .usagePace: return pacingSeverity
        case .combined: return max(remainingSeverity, pacingSeverity)
        }
    }

    private static func health(
        for window: QuotaWindow,
        configuration: MenuBarConfiguration,
        now: Date,
        isFresh: Bool
    ) -> MenuBarSeverity {
        guard configuration.colorMode != .off else { return .neutral }
        return severity(for: window, basis: configuration.colorBasis, now: now, isFresh: isFresh)
    }

    private static func textSeverity(
        _ severity: MenuBarSeverity,
        configuration: MenuBarConfiguration
    ) -> MenuBarSeverity {
        guard configuration.colorMode != .off, configuration.colorTarget.colorsValues else { return .neutral }
        if configuration.colorMode == .warningsOnly, severity == .normal { return .neutral }
        return severity
    }

    private static func statusSymbol(
        freshness: DataFreshness,
        snapshotExists: Bool,
        configuration: MenuBarConfiguration,
        worstHealth: MenuBarSeverity
    ) -> (name: String?, severity: MenuBarSeverity) {
        switch freshness {
        case .loading:
            return ("gauge.with.needle", .neutral)
        case .stale:
            return ("exclamationmark.triangle.fill", .neutral)
        case .unavailable:
            return ("questionmark.circle", .neutral)
        case .fresh where !snapshotExists:
            return ("questionmark.circle", .neutral)
        case .fresh:
            break
        }

        if configuration.colorMode != .off, worstHealth >= .caution {
            let name = worstHealth == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"
            let severity = configuration.colorTarget.colorsGauge ? worstHealth : .neutral
            return (name, severity)
        }
        guard configuration.showsGauge else { return (nil, .neutral) }
        let severity: MenuBarSeverity
        if configuration.colorTarget.colorsGauge, configuration.colorMode == .trafficLight {
            severity = worstHealth
        } else {
            severity = .neutral
        }
        return ("gauge.with.needle", severity)
    }

    private static func unavailablePresentation(
        freshness: DataFreshness,
        configuration: MenuBarConfiguration
    ) -> MenuBarPresentation {
        let symbol: String
        let label: String
        switch freshness {
        case .loading:
            symbol = "gauge.with.needle"
            label = "Codex allowances are loading"
        case .stale:
            symbol = "exclamationmark.triangle.fill"
            label = "Codex allowance information is out of date"
        case .fresh, .unavailable:
            symbol = "questionmark.circle"
            label = "Codex allowances are unavailable"
        }
        let segments = configuration.showsPercentage || configuration.resetDisplay != .hidden || configuration.showsSuggestedPace
            ? [MenuBarTextSegment(text: "—", severity: .neutral, usesMonospacedDigits: true)]
            : []
        return MenuBarPresentation(
            symbolName: symbol,
            symbolSeverity: .neutral,
            segments: segments,
            tooltip: label,
            accessibilityLabel: label,
            nextUpdateAt: nil,
            primarySelectionUnavailable: false,
            secondarySelectionUnavailable: false,
            statusNotice: nil
        )
    }

    private static func makeStatusNotice(
        primary: ResolvedAllowance,
        primaryHealth: MenuBarSeverity,
        secondary: ResolvedAllowance?,
        secondaryHealth: MenuBarSeverity,
        configuration: MenuBarConfiguration,
        now: Date,
        isFresh: Bool
    ) -> MenuBarStatusNotice? {
        guard configuration.colorMode != .off, isFresh else { return nil }
        let allowance: ResolvedAllowance
        let health: MenuBarSeverity
        if let secondary, secondaryHealth > primaryHealth {
            allowance = secondary
            health = secondaryHealth
        } else {
            allowance = primary
            health = primaryHealth
        }
        guard health >= .caution else { return nil }

        let remainingSeverity: MenuBarSeverity = allowance.window.remainingPercent <= 10
            ? .critical
            : allowance.window.remainingPercent <= 20 ? .caution : .normal
        let pacing = allowance.window.pacing(now: now, isFresh: true)
        let pacingSeverity: MenuBarSeverity
        if let pacing {
            pacingSeverity = pacing.projectedExhaustion != nil || pacing.projectedUsedAtReset > 100
                ? .critical
                : pacing.projectedUsedAtReset >= 90 ? .caution : .normal
        } else {
            pacingSeverity = .normal
        }

        let usesPacing: Bool
        switch configuration.colorBasis {
        case .remainingAllowance: usesPacing = false
        case .usagePace: usesPacing = true
        case .combined: usesPacing = pacingSeverity > remainingSeverity
        }
        let allowanceName = "\(allowance.bucket.name) \(allowance.window.durationName.lowercased()) allowance"
        if usesPacing, let pacing {
            if pacingSeverity == .critical {
                return MenuBarStatusNotice(
                    severity: .critical,
                    title: "Usage may exceed this allowance",
                    detail: "At the current pace, the \(allowanceName) may run out before it resets."
                )
            }
            return MenuBarStatusNotice(
                severity: .caution,
                title: "Usage is approaching the allowance",
                detail: "The \(allowanceName) is estimated to reach \(Int(pacing.projectedUsedAtReset.rounded()))% used by reset."
            )
        }

        return MenuBarStatusNotice(
            severity: remainingSeverity,
            title: remainingSeverity == .critical ? "Allowance is critically low" : "Allowance is running low",
            detail: "The \(allowanceName) has \(allowance.window.remainingPercent)% remaining."
        )
    }

    private static func percentageLabel(_ allowance: ResolvedAllowance, includesBucket: Bool) -> String {
        let duration = AllowanceResolver.compactWindowLabel(allowance.window)
        let prefix = includesBucket ? "\(allowance.bucket.name) \(duration)" : duration
        return "\(prefix) \(allowance.window.remainingPercent)%"
    }

    private static func resetText(
        style: ResetDisplayStyle,
        reset: Date,
        now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let remaining = compactCountdown(to: reset, now: now)
        switch style {
        case .hidden: return ""
        case .timeRemaining: return remaining
        case .resetDate: return localizedDate(reset, includesTime: false, locale: locale, timeZone: timeZone)
        case .resetDateAndTime:
            return localizedDate(reset, includesTime: true, locale: locale, timeZone: timeZone)
        case .timeRemainingAndResetTime:
            let exact = localizedDate(reset, includesTime: true, locale: locale, timeZone: timeZone)
            return "\(remaining) · \(exact)"
        }
    }

    static func compactCountdown(to reset: Date, now: Date) -> String {
        let interval = reset.timeIntervalSince(now)
        guard interval.isFinite, interval > 0 else { return "Now" }
        let seconds = Int(interval.rounded(.down))
        if seconds >= 86_400 {
            return "\(seconds / 86_400)d \((seconds % 86_400) / 3_600)h"
        }
        if seconds >= 3_600 {
            return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
        }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "<1m"
    }

    private static func localizedDate(
        _ date: Date,
        includesTime: Bool,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(includesTime ? "MMM d jm" : "MMM d")
        return formatter.string(from: date)
    }

    private static func tooltip(
        primary: ResolvedAllowance,
        secondary: ResolvedAllowance?,
        pace: SuggestedAllowancePace?,
        paceDisplay: SuggestedPaceDisplayStyle,
        freshness: DataFreshness,
        worstHealth: MenuBarSeverity,
        colorBasis: StatusColorBasis,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        var parts = [allowanceDescription(primary, includesReset: true, locale: locale, timeZone: timeZone)]
        if let secondary {
            parts.append(allowanceDescription(secondary, includesReset: false, locale: locale, timeZone: timeZone))
        }
        if let pace {
            parts.append("Suggested pace: \(pace.detailText(style: paceDisplay, locale: locale)).")
        }
        switch freshness {
        case .loading:
            parts.append("Allowance information is updating.")
        case .stale:
            parts.append("Allowance information is out of date.")
        case .unavailable:
            parts.append("Current allowance information is unavailable.")
        case .fresh:
            break
        }
        if freshness == .fresh, worstHealth >= .caution {
            parts.append("Status: \(statusDescription(worstHealth, basis: colorBasis)).")
        }
        return parts.joined(separator: " ")
    }

    private static func statusDescription(_ severity: MenuBarSeverity, basis: StatusColorBasis) -> String {
        switch (basis, severity) {
        case (.remainingAllowance, .caution): "the allowance is running low"
        case (.remainingAllowance, .critical): "the allowance is critically low"
        case (.usagePace, .caution): "usage is approaching the sustainable pace"
        case (.usagePace, .critical): "usage is projected to run out before reset"
        case (.combined, .caution): "the allowance or usage pace needs attention"
        case (.combined, .critical): "the allowance is low or usage is projected to run out before reset"
        default: "current"
        }
    }

    private static func allowanceDescription(
        _ allowance: ResolvedAllowance,
        includesReset: Bool,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        var value = "\(allowance.bucket.name) \(allowance.window.durationName.lowercased()) allowance: \(allowance.window.remainingPercent) percent remaining."
        if includesReset, let reset = allowance.window.resetsAt {
            value += " Resets \(localizedDate(reset, includesTime: true, locale: locale, timeZone: timeZone))."
        }
        return value
    }

    private static func nextUpdateDate(
        resetStyle: ResetDisplayStyle,
        reset: Date?,
        pace: SuggestedAllowancePace?,
        paceDisplay: SuggestedPaceDisplayStyle,
        remainingPercent: Int,
        now: Date
    ) -> Date? {
        var candidates: [Date] = []
        if resetStyle.includesCountdown, let reset {
            let interval = reset.timeIntervalSince(now)
            if interval > 0 {
                let unit: TimeInterval = interval >= 86_400 ? 3_600 : 60
                let remainder = interval.truncatingRemainder(dividingBy: unit)
                let delay = remainder > 0.05 ? remainder + 0.05 : unit + 0.05
                candidates.append(now.addingTimeInterval(delay))
                candidates.append(reset.addingTimeInterval(0.05))
            }
        }
        if let pace, let reset {
            let remainingSeconds = reset.timeIntervalSince(now)
            switch paceDisplay {
            case .usageRate:
                let rounded = max(0, pace.percentagePoints.rounded())
                let nextRoundedBoundary = rounded + 0.5
                if nextRoundedBoundary > 0, remainingPercent > 0 {
                    let targetSeconds = Double(remainingPercent) * pace.unit.seconds / nextRoundedBoundary
                    let delay = remainingSeconds - targetSeconds
                    if delay > 0.05 {
                        candidates.append(now.addingTimeInterval(max(60, delay) + 0.05))
                    }
                }
            case .remainingTarget:
                candidates.append(pace.nextTargetUpdateAt.addingTimeInterval(0.05))
            }
            if pace.unit == .day, remainingSeconds > 86_400 {
                candidates.append(reset.addingTimeInterval(-86_400 + 0.05))
            }
            candidates.append(reset.addingTimeInterval(0.05))
        }
        return candidates.filter { $0 > now }.min()
    }

    private static func isMissingSpecific(
        _ selection: AllowanceSelection,
        resolved: ResolvedAllowance?,
        snapshot: AccountSnapshot?
    ) -> Bool {
        guard snapshot != nil else { return false }
        guard case .specific = selection else { return false }
        return resolved == nil
    }
}
