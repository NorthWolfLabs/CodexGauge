import Accessibility
import Charts
import SwiftUI

struct DashboardView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case overview, limits, conversations, activity
        var id: Self { self }
        var title: String {
            switch self {
            case .conversations: "Tasks"
            default: rawValue.capitalized
            }
        }
        var systemImage: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .limits: "gauge.with.needle"
            case .conversations: "bubble.left.and.bubble.right"
            case .activity: "chart.xyaxis.line"
            }
        }
    }

    private enum ActivityRange: String, CaseIterable, Identifiable {
        case today, week, month, year, all
        var id: Self { self }
        var title: String {
            switch self {
            case .today: "Today"
            case .week: "7 Days"
            case .month: "30 Days"
            case .year: "1 Year"
            case .all: "All"
            }
        }
        var dayCount: Int? {
            switch self {
            case .today: 1
            case .week: 7
            case .month: 30
            case .year: 365
            case .all: nil
            }
        }
        var periodName: String {
            switch self {
            case .today: "Today"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            case .year: "Last year"
            case .all: "All recorded days"
            }
        }
    }

    private struct ThroughputSample: Identifiable, Hashable {
        let taskID: String
        let taskTitle: String
        let date: Date
        let rate: Double
        var id: String { "\(taskID)-\(date.timeIntervalSinceReferenceDate)" }
    }

    private struct ThroughputChartDescriptor: AXChartDescriptorRepresentable {
        let samples: [ThroughputSample]
        let start: Date
        let end: Date
        let maximumRate: Double

        func makeChartDescriptor() -> AXChartDescriptor {
            let startValue = start.timeIntervalSinceReferenceDate
            let endValue = max(startValue + 1, end.timeIntervalSinceReferenceDate)
            let safeMaximum = min(1_000_000_000_000, max(1, maximumRate))
            let xAxis = AXNumericDataAxisDescriptor(
                title: "Time",
                range: startValue...endValue,
                gridlinePositions: [],
                valueDescriptionProvider: { value in
                    Date(timeIntervalSinceReferenceDate: value).formatted(date: .omitted, time: .standard)
                }
            )
            let yAxis = AXNumericDataAxisDescriptor(
                title: "Tokens per minute",
                range: 0...safeMaximum,
                gridlinePositions: [0, safeMaximum],
                valueDescriptionProvider: { value in
                    "\(GaugeFormatting.tokenRate(value)) tokens per minute"
                }
            )
            let series = Dictionary(grouping: samples, by: \.taskID).values.map { taskSamples in
                let sorted = taskSamples.sorted { $0.date < $1.date }
                return AXDataSeriesDescriptor(
                    name: sorted.first?.taskTitle ?? "Local task",
                    isContinuous: true,
                    dataPoints: sorted.map { sample in
                        AXDataPoint(
                            x: sample.date.timeIntervalSinceReferenceDate,
                            y: sample.rate,
                            label: "\(sample.taskTitle), \(GaugeFormatting.tokenRate(sample.rate)) tokens per minute"
                        )
                    }
                )
            }
            return AXChartDescriptor(
                title: "Live task throughput",
                summary: "Local token rates during the last five minutes.",
                xAxis: xAxis,
                yAxis: yAxis,
                series: series
            )
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var state: AppState
    @Bindable var clock: VisibleSurfaceClock
    @State private var selection: Section? = .overview
    @State private var activityRange: ActivityRange = .week
    @State private var selectedActivityDate: Date?
    @State private var throughputHistory: [ThroughputSample] = []
    @State private var recentTaskLimit = 10

    init(state: AppState, clock: VisibleSurfaceClock) {
        self.state = state
        self.clock = clock
        let showActivity = ProcessInfo.processInfo.arguments.contains("-performanceDashboardActivity")
        _selection = State(initialValue: showActivity ? .activity : .overview)
    }

    private var liveConversations: [ConversationTelemetry] {
        state.conversations.filter(\.isLive).sorted {
            ($0.turnStartedAt ?? $0.lastActivity) > ($1.turnStartedAt ?? $1.lastActivity)
        }
    }
    private var recentConversations: [ConversationTelemetry] {
        state.conversations.filter { !$0.isLive }.sorted { $0.lastActivity > $1.lastActivity }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: overview
                case .limits: limits
                case .conversations: conversations
                case .activity: activity
                }
            }
            .navigationTitle("CodexGauge")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await state.refresh() }
                } label: {
                    Label("Refresh allowances", systemImage: "arrow.clockwise")
                }
                .help(refreshHelp)
                .disabled(state.isRefreshing || state.executableURL == nil)
            }
        }
        .onAppear { recordThroughput() }
        .onChange(of: liveConversations) { _, _ in
            guard selection == .overview else { return }
            recordThroughput()
        }
        .onChange(of: activityRange) { _, _ in selectedActivityDate = nil }
        .onChange(of: selection) { _, newValue in
            if newValue == .overview { recordThroughput() }
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    dashboardMetric("Allowance remaining", state.remainingPercent.map { "\($0)%" } ?? "—", detail: state.accountSnapshot?.limitingWindow?.durationName ?? "Unavailable", symbol: "gauge.with.needle")
                    dashboardMetric("Live tasks", "\(liveConversations.count)", detail: liveConversations.isEmpty ? "None on this Mac" : liveSummary, symbol: "desktopcomputer")
                    dashboardMetric("Last 7 days", GaugeFormatting.tokenCount(recentUsage(days: 7).reduce(0) { $0.addingWithoutOverflow($1.tokens) }), detail: "account activity", symbol: "chart.bar")
                    dashboardMetric("Lifetime", state.accountSnapshot?.activity.lifetimeTokens.map(GaugeFormatting.tokenCount) ?? "—", detail: "account tokens", symbol: "sum")
                }

                let recent = recentUsage(days: 14)
                if !recent.isEmpty {
                    GroupBox("Account tokens · last 14 days") {
                        usageChart(recent).frame(height: 220).padding(.top, 8)
                    }
                }

                if !liveConversations.isEmpty && throughputHistory.count > liveConversations.count {
                    GroupBox("Live rate · last 5 minutes") {
                        liveThroughputChart
                            .frame(height: max(150, CGFloat(liveConversations.count) * 44))
                            .padding(.top, 8)
                    }
                }
            }
            .padding(24)
        }
    }

    private var limits: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let snapshot = state.accountSnapshot {
                    ForEach(snapshot.buckets) { bucket in
                        GroupBox {
                            VStack(spacing: 16) {
                                ForEach(bucket.windows) { window in
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack {
                                            Text(window.durationName).font(.headline)
                                            Spacer()
                                            Text("\(window.remainingPercent)% remaining").monospacedDigit().foregroundStyle(.secondary)
                                        }
                                        Gauge(value: Double(window.clampedUsedPercent), in: 0...100) { Text(window.durationName) }
                                            .gaugeStyle(.linearCapacity)
                                            .tint(limitColor(window.remainingPercent))
                                            .accessibilityLabel("\(window.durationName) Codex allowance")
                                            .accessibilityValue(limitAccessibilityValue(window))
                                        if let reset = window.resetsAt {
                                            Text("\(GaugeFormatting.resetCountdown(to: reset, now: state.currentDate)) · \(GaugeFormatting.exactDate(reset))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            HStack {
                                Label(bucket.name, systemImage: "gauge.with.needle")
                                Spacer()
                                if let limiting = bucket.limitingWindow {
                                    Text("\(limiting.remainingPercent)%").monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Limits unavailable", systemImage: "gauge.with.needle")
                }
            }
            .padding(24)
        }
    }

    private var conversations: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Current and recent tasks").font(.title2.weight(.semibold))
                        Text("Activity recorded on this Mac").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(liveConversations.count) live · \(recentConversations.count) recent")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    conversationSummary("Working now", "\(liveConversations.filter { $0.state == .running }.count)", symbol: "waveform", tint: .green)
                    conversationSummary("Needs attention", "\(liveConversations.filter { $0.state == .needsInput || $0.state == .needsApproval }.count)", symbol: "exclamationmark.bubble", tint: .orange)
                    conversationSummary("Recorded tokens", GaugeFormatting.tokenCount(state.conversations.reduce(0) { $0.addingWithoutOverflow($1.totalTokens) }), symbol: "sum", tint: .accentColor)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Live tasks").font(.title3.weight(.semibold))
                    if liveConversations.isEmpty {
                        ContentUnavailableView("No tasks are running", systemImage: "pause.circle").frame(maxWidth: .infinity)
                    } else {
                        ForEach(liveConversations) { conversation in liveConversationCard(conversation) }
                    }
                }

                if !recentConversations.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recent tasks").font(.title3.weight(.semibold))
                        VStack(spacing: 0) {
                            ForEach(Array(recentConversations.prefix(recentTaskLimit))) { conversation in
                                recentConversationRow(conversation)
                                if conversation.id != recentConversations.prefix(recentTaskLimit).last?.id { Divider() }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        if recentTaskLimit < recentConversations.count {
                            Button("Show 10 more") { recentTaskLimit += 10 }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var activity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let accountActivity = state.accountSnapshot?.activity, accountActivity != .empty {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Token activity").font(.title2.weight(.semibold))
                            Text("Account-wide activity by day").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Time range", selection: $activityRange) {
                            ForEach(ActivityRange.allCases) { range in Text(range.title).tag(range) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                        .accessibilityIdentifier("activity-range-picker")
                    }

                    let usage = filteredUsage(accountActivity.dailyUsage)
                    if usage.isEmpty {
                        ContentUnavailableView("No activity in \(activityRange.periodName.lowercased())", systemImage: "chart.bar.xaxis")
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        activitySummary(usage: usage)

                        GroupBox("Tokens by day · \(activityRange.periodName)") {
                            detailedUsageChart(usage).frame(height: 290).padding(.top, 8)
                        }

                        if let selected = selectedUsage(in: usage) {
                            HStack(spacing: 10) {
                                Image(systemName: "calendar").foregroundStyle(.tint)
                                Text(selected.date.formatted(date: .complete, time: .omitted))
                                Spacer()
                                Text("\(GaugeFormatting.tokenCount(selected.tokens)) tokens").fontWeight(.semibold).monospacedDigit()
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                            .accessibilityElement(children: .combine)
                        } else {
                            Text("Select a bar or point to inspect a day.").font(.caption).foregroundStyle(.secondary)
                        }

                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            Text("All-time records").font(.title3.weight(.semibold))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                                dashboardMetric("Lifetime tokens", accountActivity.lifetimeTokens.map(GaugeFormatting.tokenCount) ?? "—", detail: "account total", symbol: "sum")
                                dashboardMetric("Current streak", accountActivity.currentStreakDays.map { "\($0) days" } ?? "—", detail: "consecutive active days", symbol: "flame")
                                dashboardMetric("Longest streak", accountActivity.longestStreakDays.map { "\($0) days" } ?? "—", detail: "account record", symbol: "trophy")
                                dashboardMetric("Longest turn", accountActivity.longestRunningTurnSeconds.map { GaugeFormatting.duration(Double($0)) } ?? "—", detail: "single turn", symbol: "timer")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Activity unavailable", systemImage: "chart.xyaxis.line")
                }
            }
            .padding(24)
        }
    }

    private var liveThroughputChart: some View {
        let now = throughputHistory.last?.date ?? state.currentDate
        let cutoff = now.addingTimeInterval(-300)
        let samples = throughputHistory.filter { $0.date >= cutoff && $0.rate.isFinite && $0.rate >= 0 }
        let sampleCounts = Dictionary(grouping: samples, by: \.taskID).mapValues(\.count)
        let maximumRate = min(1_000_000_000_000, max(1, samples.map(\.rate).max() ?? 1))
        return Chart(samples) { sample in
            if sampleCounts[sample.taskID, default: 0] > 1 {
                LineMark(x: .value("Time", sample.date), y: .value("Tokens per minute", sample.rate), series: .value("Task", sample.taskTitle))
                    .foregroundStyle(by: .value("Task", sample.taskTitle))
                    .interpolationMethod(.catmullRom)
            }
            PointMark(x: .value("Time", sample.date), y: .value("Tokens per minute", sample.rate))
                .foregroundStyle(by: .value("Task", sample.taskTitle))
                .symbolSize(samples.count < 15 ? 22 : 8)
        }
        .chartYScale(domain: 0...(maximumRate * 1.08))
        .chartXScale(domain: cutoff...now)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.hour().minute().second())
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(); AxisTick()
                AxisValueLabel { if let rate = value.as(Double.self) { Text(GaugeFormatting.tokenRate(rate)) } }
            }
        }
        .chartYAxisLabel("Tokens per minute")
        .chartLegend(position: .bottom, alignment: .leading)
        .accessibilityChartDescriptor(ThroughputChartDescriptor(
            samples: samples,
            start: cutoff,
            end: now,
            maximumRate: maximumRate
        ))
    }

    private func liveConversationCard(_ conversation: ConversationTelemetry) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conversation.title).font(.headline).lineLimit(2)
                        Text([conversation.workspace, conversation.model].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(phaseTitle(conversation), systemImage: phaseSymbol(conversation))
                        .font(.caption.weight(.medium)).foregroundStyle(phaseColor(conversation))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(phaseColor(conversation).opacity(0.12), in: Capsule())
                        .id("\(conversation.state.rawValue)-\(conversation.activity.rawValue)")
                        .transition(.opacity)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: conversation.activity)
                }

                HStack(spacing: 12) {
                    dashboardValue("Current rate", "\(GaugeFormatting.tokenRate(conversation.tokensPerMinute)) tokens/min", symbol: "speedometer")
                    dashboardValue("5-minute average", "\(GaugeFormatting.tokenRate(conversation.tokensPerFiveMinutes)) tokens/min", symbol: "chart.line.uptrend.xyaxis")
                    if let calls = conversation.callsPerMinute {
                        dashboardValue("Model calls", String(format: "%.1f/min", calls), symbol: "cpu")
                    }
                    DashboardTurnDurationValue(startedAt: conversation.turnStartedAt, clock: clock)
                }

                if let rawContext = conversation.latestContextPercent, rawContext.isFinite {
                    let context = min(100, max(0, rawContext))
                    Gauge(value: context, in: 0...100) { Text("Latest context window") } currentValueLabel: {
                        Text("\(Int(context.rounded()))%").monospacedDigit()
                    }
                    .gaugeStyle(.linearCapacity)
                    .accessibilityLabel("Latest context window")
                    .accessibilityValue("\(Int(context.rounded())) percent filled; minimum 0, maximum 100")
                }

                if conversation.recentTokenMix.total > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Token mix · last 5 minutes").font(.caption.weight(.medium))
                        TokenMixBar(mix: conversation.recentTokenMix)
                    }
                }

                HStack(spacing: 18) {
                    detailValue("Latest output", conversation.latestOutputTokens.map { GaugeFormatting.tokenCount($0) + " tokens" } ?? "—")
                    detailValue("Began responding", conversation.timeToFirstTokenMilliseconds.map { String(format: "%.1f sec", Double($0) / 1_000) } ?? "—")
                    detailValue("Linked agents", "\(conversation.agentCount)")
                }
            }
            .padding(10)
        }
    }

    private func recentConversationRow(_ conversation: ConversationTelemetry) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text([conversation.workspace, conversation.model].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            detailValue("Tokens", GaugeFormatting.tokenCount(conversation.totalTokens))
                .frame(width: 82)
            detailValue("Last turn", conversation.lastTurnDurationSeconds.map(GaugeFormatting.coarseDuration) ?? "—")
                .frame(width: 72)
            Text(GaugeFormatting.coarseRelativeAge(since: conversation.lastActivity, now: state.currentDate))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
                .help("Last active \(GaugeFormatting.exactDate(conversation.lastActivity))")
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private func activitySummary(usage: [DailyUsage]) -> some View {
        let total = usage.reduce(Int64(0)) { $0.addingWithoutOverflow($1.tokens) }
        let activeDays = usage.filter { $0.tokens > 0 }
        let average = activeDays.isEmpty ? 0 : total / Int64(activeDays.count)
        let peak = usage.max { $0.tokens < $1.tokens }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            dashboardMetric(activityTotalTitle, GaugeFormatting.tokenCount(total), detail: "tokens", symbol: "sum")
            dashboardMetric("Active-day average", GaugeFormatting.tokenCount(average), detail: "\(activeDays.count) active day\(activeDays.count == 1 ? "" : "s")", symbol: "divide")
            dashboardMetric("Busiest day", peak.map { GaugeFormatting.tokenCount($0.tokens) } ?? "—", detail: busiestDate(peak?.date), symbol: "chart.bar.fill")
            if activityRange != .all {
                let comparison = periodComparison(currentTotal: total)
                dashboardMetric("Change", comparison.value, detail: comparison.detail, symbol: comparison.symbol)
            }
        }
    }

    private func detailedUsageChart(_ usage: [DailyUsage]) -> some View {
        let maximumTokens = min(Int64(1_000_000_000_000_000), max(Int64(1), usage.map(\.tokens).max() ?? 1))
        return Chart {
            ForEach(usage) { day in
                if usage.count > 90 {
                    LineMark(x: .value("Day", day.date), y: .value("Tokens", min(day.tokens, maximumTokens)))
                        .foregroundStyle(.tint).interpolationMethod(.monotone)
                } else {
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", min(day.tokens, maximumTokens)))
                        .foregroundStyle(.tint).cornerRadius(3)
                }
            }
            if let selected = selectedUsage(in: usage) {
                RuleMark(x: .value("Selected day", selected.date))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(GaugeFormatting.tokenCount(selected.tokens))
                            .font(.caption.weight(.medium).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    }
            }
        }
        .chartYScale(domain: 0...max(1, Double(maximumTokens) * 1.08))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: max(1, min(8, usage.count)))) {
                AxisGridLine(); AxisTick()
                AxisValueLabel(format: usage.count <= 7 ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(); AxisTick()
                AxisValueLabel {
                    if let tokens = value.as(Int64.self) { Text(GaugeFormatting.tokenCount(tokens)) }
                    else if let tokens = value.as(Double.self) { Text(GaugeFormatting.tokenRate(tokens)) }
                }
            }
        }
        .chartYAxisLabel("Tokens")
        .chartXSelection(value: $selectedActivityDate)
        .accessibilityChartDescriptor(TokenActivityChartDescriptor(
            title: "Codex activity for \(activityRange.periodName.lowercased())",
            summary: "A daily chart of account-wide token activity.",
            usage: usage
        ))
    }

    private func usageChart(_ usage: [DailyUsage]) -> some View {
        let maximumTokens = min(Int64(1_000_000_000_000_000), max(Int64(1), usage.map(\.tokens).max() ?? 1))
        return Chart(usage) { day in
            BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", min(day.tokens, maximumTokens)))
                .foregroundStyle(.tint).cornerRadius(3)
        }
        .chartYScale(domain: 0...max(1, Double(maximumTokens) * 1.08))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: max(1, min(7, usage.count)))) {
                AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(); AxisTick()
                AxisValueLabel {
                    if let tokens = value.as(Int64.self) { Text(GaugeFormatting.tokenCount(tokens)) }
                    else if let tokens = value.as(Double.self) { Text(GaugeFormatting.tokenRate(tokens)) }
                }
            }
        }
        .chartYAxisLabel("Tokens")
        .accessibilityChartDescriptor(TokenActivityChartDescriptor(
            title: "Codex activity for the last fourteen days",
            summary: "A daily chart of account-wide token activity.",
            usage: usage
        ))
    }

    private func dashboardMetric(_ title: String, _ value: String, detail: String, symbol: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.semibold).monospacedDigit())
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func conversationSummary(_ title: String, _ value: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(tint)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func dashboardValue(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium).monospacedDigit()).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func detailValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium).monospacedDigit()).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var refreshHelp: String {
        if state.isRefreshing { return "Refreshing allowances" }
        guard let fetchedAt = state.accountSnapshot?.fetchedAt else { return "Refresh allowances" }
        return "Refresh allowances. \(GaugeFormatting.updatedText(since: fetchedAt, now: state.currentDate))."
    }

    private var liveSummary: String {
        let attention = liveConversations.filter { $0.state == .needsInput || $0.state == .needsApproval }.count
        if attention > 0 { return "\(attention) needs attention" }
        if liveConversations.count == 1, let first = liveConversations.first { return phaseTitle(first) }
        return "Active on this Mac"
    }

    private func recentUsage(days: Int) -> [DailyUsage] {
        guard let usage = state.accountSnapshot?.activity.dailyUsage else { return [] }
        return ActivitySeries.trailing(usage, days: days, endingAt: state.currentDate)
    }

    private func filteredUsage(_ usage: [DailyUsage]) -> [DailyUsage] {
        guard let count = activityRange.dayCount else { return ActivitySeries.normalized(usage) }
        return ActivitySeries.trailing(usage, days: count, endingAt: state.currentDate)
    }

    private func selectedUsage(in usage: [DailyUsage]) -> DailyUsage? {
        if activityRange == .today { return usage.first }
        guard let selectedActivityDate else { return nil }
        return usage.min { abs($0.date.timeIntervalSince(selectedActivityDate)) < abs($1.date.timeIntervalSince(selectedActivityDate)) }
    }

    private func periodComparison(currentTotal: Int64) -> (value: String, detail: String, symbol: String) {
        guard let count = activityRange.dayCount,
              let allUsage = state.accountSnapshot?.activity.dailyUsage,
              let previous = ActivitySeries.previousTotal(
                allUsage,
                days: count,
                endingAt: state.currentDate
              ) else { return ("—", "not enough earlier data", "equal") }
        guard previous > 0 else { return ("—", "no activity in the prior period", "equal") }
        let delta = currentTotal.subtractingWithoutOverflow(previous)
        let change = (Double(delta) / Double(previous)) * 100
        let formatted = change.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())) + "%"
        return (formatted, comparisonDetail, change >= 0 ? "arrow.up.right" : "arrow.down.right")
    }

    private func recordThroughput() {
        PerformanceSignposts.event("Chart update")
        let now = state.currentDate
        let samples = liveConversations.map { conversation in
            let finiteRate = conversation.tokensPerMinute.isFinite ? conversation.tokensPerMinute : 0
            return ThroughputSample(
                taskID: conversation.id,
                taskTitle: conversation.title,
                date: now,
                rate: min(1_000_000_000_000, max(0, finiteRate))
            )
        }
        let cutoff = now.addingTimeInterval(-300)
        throughputHistory.removeAll { $0.date < cutoff }
        throughputHistory.append(contentsOf: samples)
        if throughputHistory.count > 3_000 {
            throughputHistory.removeFirst(throughputHistory.count - 3_000)
        }
    }

    private var activityTotalTitle: String {
        switch activityRange {
        case .today: "Today total"
        case .week: "7-day total"
        case .month: "30-day total"
        case .year: "1-year total"
        case .all: "Recorded total"
        }
    }

    private var comparisonDetail: String {
        switch activityRange {
        case .today: "compared with yesterday"
        case .week: "compared with the prior 7 days"
        case .month: "compared with the prior 30 days"
        case .year: "compared with the prior year"
        case .all: ""
        }
    }

    private func busiestDate(_ date: Date?) -> String {
        guard let date else { return "No activity" }
        if activityRange == .year || activityRange == .all {
            return date.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func phaseTitle(_ conversation: ConversationTelemetry) -> String {
        switch conversation.state {
        case .needsApproval: "Approval needed"
        case .needsInput: "Input needed"
        default: conversation.activity.title
        }
    }

    private func phaseSymbol(_ conversation: ConversationTelemetry) -> String {
        switch conversation.state {
        case .needsApproval, .needsInput: conversation.state.systemImage
        default: conversation.activity.systemImage
        }
    }

    private func phaseColor(_ conversation: ConversationTelemetry) -> Color {
        switch conversation.state {
        case .needsApproval: .red
        case .needsInput: .orange
        case .running: .green
        case .idle, .recent: .secondary
        }
    }

    private func limitColor(_ remaining: Int) -> Color {
        if remaining <= 5 { return .red }
        if remaining <= 20 { return .orange }
        return .accentColor
    }

    private func limitAccessibilityValue(_ window: QuotaWindow) -> String {
        let base = "\(window.clampedUsedPercent) percent used, \(window.remainingPercent) percent remaining; minimum 0, maximum 100"
        guard let reset = window.resetsAt else { return base }
        return "\(base); resets \(GaugeFormatting.exactDate(reset))"
    }
}

#Preview("Dashboard") {
    DashboardView(state: DemoData.state(), clock: VisibleSurfaceClock())
        .frame(width: 920, height: 640)
}

private struct DashboardTurnDurationValue: View {
    let startedAt: Date?
    @Bindable var clock: VisibleSurfaceClock

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Turn", systemImage: "timer")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(startedAt.map { GaugeFormatting.duration(clock.now.timeIntervalSince($0)) } ?? "—")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
