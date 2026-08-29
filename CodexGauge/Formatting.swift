import Foundation

enum GaugeFormatting {
    static let integer = IntegerFormatStyle<Int>().grouping(.automatic)
    static let integer64 = IntegerFormatStyle<Int64>().grouping(.automatic)

    static func tokenCount(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func nonnegativeInt64(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0 else { return 0 }
        if value >= 9_000_000_000_000_000_000 { return .max }
        return Int64(value.rounded())
    }

    static func tokenRate(_ value: Double) -> String {
        guard value.isFinite, value >= 1 else { return "0" }
        return nonnegativeInt64(value).formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0))
        )
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: min(3_155_695_200, max(0, seconds))) ?? "—"
    }

    static func coarseDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        let seconds = min(3_155_695_200, max(0, seconds))
        if seconds < 60 { return "< 1 min" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) hr" }
        if seconds < 604_800 { return "\(Int(seconds / 86_400)) day" + (seconds < 172_800 ? "" : "s") }
        if seconds < 31_556_952 { return "\(Int(seconds / 604_800)) wk" }
        return "\(Int(seconds / 31_556_952)) yr"
    }

    static func coarseRelativeAge(since date: Date, now: Date = .now) -> String {
        "\(coarseDuration(now.timeIntervalSince(date))) ago"
    }

    static func resetCountdown(to date: Date, now: Date = .now) -> String {
        guard date > now else { return "Resetting now" }
        return "Resets in \(duration(date.timeIntervalSince(now)))"
    }

    static func updatedText(since date: Date, now: Date = .now) -> String {
        "Updated \(relativeAge(since: date, now: now))"
    }

    static func relativeAge(since date: Date, now: Date = .now) -> String {
        let interval = now.timeIntervalSince(date)
        guard interval.isFinite else { return "an unknown time ago" }
        let seconds = max(0, Int(min(interval.rounded(.down), Double(Int.max))))
        if seconds < 60 {
            return seconds == 1 ? "1 second ago" : "\(seconds) seconds ago"
        }
        if seconds < 3_600 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        }
        if seconds < 86_400 {
            let hours = seconds / 3_600
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let days = seconds / 86_400
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    static func exactDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func planName(_ plan: String?) -> String {
        guard let plan, !plan.isEmpty else { return "Codex" }
        switch plan.lowercased() {
        case "pro": return "ChatGPT Pro"
        case "plus": return "ChatGPT Plus"
        case "team", "business", "self_serve_business_usage_based": return "ChatGPT Business"
        case "enterprise", "enterprise_cbp_usage_based", "ent26": return "ChatGPT Enterprise"
        case "edu": return "ChatGPT Edu"
        case "free": return "ChatGPT Free"
        default: return plan.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
