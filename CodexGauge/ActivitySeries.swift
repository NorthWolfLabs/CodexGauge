import Foundation

enum ActivitySeries {
    static func normalized(
        _ usage: [DailyUsage],
        calendar: Calendar = .current
    ) -> [DailyUsage] {
        let grouped = Dictionary(grouping: usage) { $0.day }
        return grouped.map { day, values in
            DailyUsage(day: day, tokens: values.reduce(0) { $0.addingWithoutOverflow($1.tokens) })
        }.sorted { $0.day < $1.day }
    }

    static func trailing(
        _ usage: [DailyUsage],
        days: Int,
        endingAt now: Date,
        calendar: Calendar = .current
    ) -> [DailyUsage] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let values = Dictionary(uniqueKeysWithValues: normalized(usage, calendar: calendar).map { ($0.day, $0.tokens) })
        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = ActivityDay(date: day, calendar: calendar)
            return DailyUsage(day: key, tokens: values[key, default: 0])
        }
    }

    static func previousTotal(
        _ usage: [DailyUsage],
        days: Int,
        endingAt now: Date,
        calendar: Calendar = .current
    ) -> Int64? {
        guard days > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let previousEnd = calendar.date(byAdding: .day, value: -days, to: today),
              let previousStart = calendar.date(byAdding: .day, value: -(days * 2 - 1), to: today) else { return nil }
        let source = normalized(usage, calendar: calendar)
        let startKey = ActivityDay(date: previousStart, calendar: calendar)
        let endKey = ActivityDay(date: previousEnd, calendar: calendar)
        guard source.contains(where: { $0.day >= startKey && $0.day <= endKey }) else { return nil }
        return source
            .filter { $0.day >= startKey && $0.day <= endKey }
            .reduce(0) { $0.addingWithoutOverflow($1.tokens) }
    }
}
