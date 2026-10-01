import Foundation

struct CompanionChartDay: Identifiable, Equatable, Sendable {
    var date: Date
    var tokens: Int64
    var id: Date { date }
}

enum CompanionChartData {
    static func days(_ source: [CompanionDay], count: Int?, endingAt now: Date, calendar: Calendar = .current) -> [CompanionChartDay] {
        guard count.map({ $0 > 0 && $0 <= 3660 }) ?? true, !source.isEmpty else { return [] }
        var values: [Date: Int64] = [:]
        for item in source {
            let parts = item.id.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  calendar.component(.year, from: date) == parts[0], calendar.component(.month, from: date) == parts[1],
                  calendar.component(.day, from: date) == parts[2] else { continue }
            // A day is an account observation, not a contribution from each Mac.
            values[date] = max(values[date] ?? 0, max(0, item.tokens))
        }
        guard !values.isEmpty else { return [] }
        let today = calendar.startOfDay(for: now)
        let start = count.flatMap { calendar.date(byAdding: .day, value: 1 - $0, to: today) } ?? .distantPast
        return values.keys.sorted().compactMap { date in
            guard date >= start, date <= today, let tokens = values[date] else { return nil }
            return CompanionChartDay(date: date, tokens: tokens)
        }
    }

    // A day-unit bar spans midnight through midnight. Nearest-midnight
    // selection would incorrectly show tomorrow's value after noon.
    static func selectedDay(in days: [CompanionChartDay], at date: Date, calendar: Calendar = .current) -> CompanionChartDay? {
        let day = calendar.startOfDay(for: date)
        return days.first { $0.date == day }
    }

    static func total(_ days: [CompanionChartDay]) -> Int64 {
        days.reduce(0) { total, day in
            let result = total.addingReportingOverflow(day.tokens)
            return result.overflow ? Int64.max : result.partialValue
        }
    }
}

struct CompanionTaskSample: Identifiable, Equatable, Sendable {
    var date: Date
    var rate: Double
    var segment: Date
    var id: Date { date }
}

struct CompanionTaskHistory {
    private var values: [String: [CompanionTaskSample]] = [:]
    static func key(mac: String, task: String) -> String { mac + ":" + task }
    func samples(mac: String, task: String) -> [CompanionTaskSample] { values[Self.key(mac: mac, task: task)] ?? [] }
    mutating func remove(mac: String) { values = values.filter { !$0.key.hasPrefix(mac + ":") } }
    mutating func record(_ snapshot: CompanionSnapshot, now: Date = .now) {
        guard !snapshot.isStale(at: now), snapshot.observedAt <= now.addingTimeInterval(120) else { return }
        let cutoff = now.addingTimeInterval(-300)
        values = values.mapValues { $0.filter { $0.date >= cutoff } }.filter { !$0.value.isEmpty }
        for task in snapshot.tasks {
            guard task.hasRate, !task.isStale(at: now) else { continue }
            let key = Self.key(mac: snapshot.id, task: task.id)
            if task.state == .completed && values[key] == nil { continue }
            var samples = values[key] ?? []
            if let last = samples.last, snapshot.observedAt.timeIntervalSince(last.date) < 2 { continue }
            let previous = samples.last
            let segment = previous.map { snapshot.observedAt.timeIntervalSince($0.date) <= 10 ? $0.segment : snapshot.observedAt } ?? snapshot.observedAt
            samples.append(.init(date: snapshot.observedAt, rate: task.state == .running ? max(0, task.tokensPerMinute) : 0, segment: segment))
            values[key] = Array(samples.suffix(150))
        }
        // Bound memory across many linked Macs. Recent task details take priority.
        if values.count > 64 {
            let keep = values.sorted { ($0.value.last?.date ?? .distantPast, $0.key) > ($1.value.last?.date ?? .distantPast, $1.key) }.prefix(64)
            values = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}
