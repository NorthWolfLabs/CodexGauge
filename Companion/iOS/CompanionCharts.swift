import SwiftUI
import Charts

struct CompanionAccountChart: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.account == rhs.account }
    let account: CompanionAccount
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var range = CompanionActivityRange.month
    @State private var selectedDate: Date?
    var body: some View {
        let days = CompanionChartData.days(account.dailyTokens, count: range.dayCount(at: .now), endingAt: .now)
        let selected = selectedDate.flatMap { CompanionChartData.selectedDay(in: days, at: $0) }
        VStack(alignment: .leading, spacing: 12) {
            Picker("Period", selection: $range) {
                ForEach(CompanionActivityRange.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).labelsHidden().accessibilityIdentifier("companion.chart.range")
                .onChange(of: range) { selectedDate = nil }
                .onChange(of: account.id) { selectedDate = nil }
            if days.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No token history")
                            .lineLimit(nil)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "chart.bar") }
                } description: {
                    Text("Daily activity will appear when Codex provides it.")
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text((selected?.tokens ?? CompanionChartData.total(days)).formatted()).font(.title2.bold()).monospacedDigit()
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("companion.chart.value")
                    Text(selected.map { $0.date.formatted(date: .abbreviated, time: .omitted) } ?? "Observed tokens · \(range.periodName.lowercased())").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("companion.chart.period")
                }
                Chart(days) { day in
                    if range.usesLineChart {
                        LineMark(x: .value("Date", day.date, unit: .day), y: .value("Tokens", day.tokens))
                            .foregroundStyle(.blue).interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                            .accessibilityValue("\(day.tokens.formatted()) tokens")
                        // A single observation still needs a visible mark.
                        if days.count == 1 || selected?.date == day.date {
                            PointMark(x: .value("Date", day.date, unit: .day), y: .value("Tokens", day.tokens))
                                .foregroundStyle(.blue).accessibilityHidden(true)
                        }
                    } else {
                        BarMark(x: .value("Date", day.date, unit: .day), y: .value("Tokens", day.tokens))
                            .foregroundStyle(.blue.gradient)
                            .opacity(selected == nil || selected?.date == day.date ? 1 : 0.35)
                            .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                            .accessibilityValue("\(day.tokens.formatted()) tokens")
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartGesture { proxy in
                    SpatialTapGesture().onEnded { event in proxy.selectXValue(at: event.location.x) }
                }
                .chartXAxis {
                    if days.count == 1 {
                        AxisMarks(values: [days[0].date]) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) }
                    } else if dynamicTypeSize.isAccessibilitySize, let first = days.first, let last = days.last {
                        AxisMarks(values: [first.date, last.date]) { value in
                            AxisGridLine()
                            AxisValueLabel(anchor: value.index == 0 ? .topLeading : .topTrailing) {
                                Text((value.index == 0 ? first.date : last.date).formatted(.dateTime.month(.abbreviated).day())).font(.caption)
                            }
                        }
                    } else {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let amount = value.as(Double.self) { Text(amount.formatted(.number.notation(.compactName))).font(.caption) }
                        }
                    }
                }
                .frame(height: 210)
                .accessibilityIdentifier("companion.accountChart")
                HStack {
                    Text("Average per observed day").foregroundStyle(.secondary)
                    Spacer()
                    Text((CompanionChartData.total(days) / Int64(days.count)).formatted()).monospacedDigit()
                        .accessibilityIdentifier("companion.chart.average")
                }.font(.subheadline)
            }
            if account.historyTruncated == true { Text("Showing available history.").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 8)
    }
}

struct CompanionRateChart: View {
    let samples: [CompanionTaskSample]
    var isCollecting = true
    var body: some View {
        if samples.count < 2 {
            Label(isCollecting ? "Collecting live activity…" : "No recent live samples", systemImage: "waveform.path").foregroundStyle(.secondary)
        } else {
            Chart(samples) { sample in
                LineMark(x: .value("Time", sample.date), y: .value("Tokens/min", sample.rate), series: .value("Connection", sample.segment))
                    .foregroundStyle(.blue).interpolationMethod(.linear)
                    .accessibilityLabel(sample.date.formatted(date: .omitted, time: .standard))
                    .accessibilityValue("\(sample.rate.formatted(.number.precision(.fractionLength(0)))) tokens per minute")
                // A newly reconnected segment may have only one observation.
                // A line alone would hide it until a second sample arrives.
                PointMark(x: .value("Time", sample.date), y: .value("Tokens/min", sample.rate))
                    .foregroundStyle(.blue).symbolSize(8)
                    .accessibilityHidden(true)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.minute().second()) } }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 150)
            .accessibilityIdentifier("companion.rateChart")
        }
    }
}
