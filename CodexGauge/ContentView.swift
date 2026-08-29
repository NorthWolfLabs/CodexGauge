import AppKit
import Charts
import SwiftUI

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var state: AppState
    @Bindable var clock: VisibleSurfaceClock
    let onShowDashboard: () -> Void
    let onShowSettings: () -> Void
    let onShowHelp: () -> Void
    let onShowMenu: () -> Void
    let onContentSizeInvalidated: () -> Void
    let onDisclosureExpansionChanged: (Bool) -> Void

    init(
        state: AppState,
        clock: VisibleSurfaceClock,
        onShowDashboard: @escaping () -> Void = {},
        onShowSettings: @escaping () -> Void = {},
        onShowHelp: @escaping () -> Void = {},
        onShowMenu: @escaping () -> Void = {},
        onContentSizeInvalidated: @escaping () -> Void = {},
        onDisclosureExpansionChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.state = state
        self.clock = clock
        self.onShowDashboard = onShowDashboard
        self.onShowSettings = onShowSettings
        self.onShowHelp = onShowHelp
        self.onShowMenu = onShowMenu
        self.onContentSizeInvalidated = onContentSizeInvalidated
        self.onDisclosureExpansionChanged = onDisclosureExpansionChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    statusSection
                    Divider()
                    limitsSection
                    Divider()
                    conversationsSection
                    if let activity = state.accountSnapshot?.activity, activity != .empty {
                        Divider()
                        activitySection(activity)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 390)
        .frame(maxHeight: 730)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gauge-panel")
        .onChange(of: state.hasLoadedConversations) { _, _ in onContentSizeInvalidated() }
        .onChange(of: state.conversations.count) { _, _ in onContentSizeInvalidated() }
        .onChange(of: state.accountSnapshot?.buckets.count) { _, _ in onContentSizeInvalidated() }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = state.accountSnapshot, let limiting = snapshot.limitingWindow {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(limiting.remainingPercent)%")
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(statusColor(for: limiting.remainingPercent))
                            .contentTransition(.numericText())
                        Text("\(limiting.durationName) allowance remaining")
                            .font(.headline)
                    }
                    Spacer()
                    Text(GaugeFormatting.planName(snapshot.plan))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    freshnessLabel
                    if let reset = limiting.resetsAt {
                        Text("•").foregroundStyle(.tertiary)
                        ResetCountdownText(reset: reset, clock: clock)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView {
                    Label("Allowance data unavailable", systemImage: "gauge.with.needle")
                } description: {
                    Text(state.errorMessage ?? "Looking for Codex on this Mac…")
                } actions: {
                    HStack {
                        Button("Open ChatGPT", action: state.openChatGPT)
                        Button("Retry") { Task { await state.reconnect() } }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .accessibilityIdentifier("usage-unavailable")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var freshnessLabel: some View {
        switch state.displayFreshness {
        case .loading:
            Label("Refreshing", systemImage: "arrow.clockwise")
        case .fresh:
            Label("Current", systemImage: "checkmark.circle.fill")
        case .stale:
            Label("Last known data", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unavailable:
            Label("Unavailable", systemImage: "exclamationmark.circle")
        }
    }

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Limits").font(.headline)
            if let snapshot = state.accountSnapshot {
                ForEach(snapshot.buckets) { bucket in
                    QuotaBucketView(
                        bucket: bucket,
                        earnedResetCount: snapshot.earnedResetCount,
                        isFresh: state.displayFreshness == .fresh,
                        now: state.currentDate,
                        clock: clock,
                        onExpansionChanged: onDisclosureExpansionChanged
                    )
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .padding(16)
        .accessibilityIdentifier("limits-section")
    }

    private var conversationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tasks").font(.headline)
                Spacer()
                Text("This Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let live = state.conversations.filter(\.isLive).sorted {
                ($0.turnStartedAt ?? $0.lastActivity) > ($1.turnStartedAt ?? $1.lastActivity)
            }
            let recent = state.conversations.filter { !$0.isLive }.sorted { $0.lastActivity > $1.lastActivity }

            if !state.hasLoadedConversations {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking this Mac for recent tasks…")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 5)
                .transition(.opacity)
                .accessibilityIdentifier("conversations-loading")
            } else if live.isEmpty && recent.isEmpty {
                Label("No local tasks found", systemImage: "pause.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                if live.isEmpty {
                    Label("No live local tasks", systemImage: "pause.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(live.prefix(3))) { conversation in
                        LiveConversationRow(
                            conversation: conversation,
                            clock: clock,
                            onExpansionChanged: onDisclosureExpansionChanged
                        )
                    }
                    if live.count > 3 {
                        Text("+\(live.count - 3) more live task\(live.count - 3 == 1 ? "" : "s") in the dashboard")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !recent.isEmpty {
                    FullWidthDisclosure(onExpansionChanged: onDisclosureExpansionChanged) {
                        VStack(spacing: 10) {
                            ForEach(Array(recent.prefix(4))) { conversation in
                                RecentConversationRow(
                                    conversation: conversation,
                                    now: state.currentDate,
                                    onExpansionChanged: onDisclosureExpansionChanged
                                )
                            }
                            if recent.count > 4 {
                                Button("Show more in the dashboard", action: onShowDashboard)
                                    .buttonStyle(.link)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.leading, 18)
                    } label: {
                        HStack {
                            Label("Recently active", systemImage: "clock")
                            Spacer()
                            Text("\(recent.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(16)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.hasLoadedConversations)
    }

    private func activitySection(_ activity: AccountActivity) -> some View {
        let week = ActivitySeries.trailing(activity.dailyUsage, days: 7, endingAt: state.currentDate)
        let weekTotal = week.reduce(Int64(0)) { $0.addingWithoutOverflow($1.tokens) }
        let activeDays = week.filter { $0.tokens > 0 }
        let dailyAverage = activeDays.isEmpty ? 0 : weekTotal / Int64(activeDays.count)
        let peak = week.max { $0.tokens < $1.tokens }
        let chartMaximum = max(Int64(1), week.map(\.tokens).max() ?? 1)
        let chartUpperBound = max(1, Double(chartMaximum) * 1.12)

        return FullWidthDisclosure(
            identifier: "popover-activity-disclosure",
            onExpansionChanged: onDisclosureExpansionChanged
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if !week.isEmpty {
                    Chart(week) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.tokens))
                            .foregroundStyle(.tint)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { value in
                            AxisTick().foregroundStyle(.clear)
                            AxisGridLine().foregroundStyle(.clear)
                            AxisValueLabel(centered: true) {
                                if let date = value.as(Date.self) {
                                    Text(date, format: .dateTime.weekday(.narrow))
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [Int64(0), chartMaximum]) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let tokens = value.as(Int64.self) {
                                    Text(GaugeFormatting.tokenCount(tokens))
                                }
                            }
                        }
                    }
                    .chartYScale(domain: 0...chartUpperBound)
                    .chartPlotStyle { plot in
                        plot
                            .padding(.horizontal, 4)
                            .padding(.top, 6)
                    }
                    .frame(height: 106)
                    .accessibilityChartDescriptor(TokenActivityChartDescriptor(
                        title: "Codex activity for the last seven days",
                        summary: "A daily chart of account-wide token activity.",
                        usage: week
                    ))
                }

                HStack(spacing: 0) {
                    activityStat("7-day total", GaugeFormatting.tokenCount(weekTotal))
                    Divider().frame(height: 34)
                    activityStat("Active-day average", GaugeFormatting.tokenCount(dailyAverage))
                    Divider().frame(height: 34)
                    activityStat("Busiest day", peak.map { GaugeFormatting.tokenCount($0.tokens) })
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Text("Last 7 days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private func activityStat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—")
                .font(.subheadline.weight(.medium).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            RefreshAllowancesButton(state: state, clock: clock)

            Button(action: onShowDashboard) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open Dashboard")
            .accessibilityLabel("Open Dashboard")

            Button(action: onShowMenu) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("More")
            .accessibilityLabel("More")
            .accessibilityIdentifier("popover-more-button")
        }
        .font(.caption)
        .padding(12)
    }

    private func statusColor(for remaining: Int) -> Color {
        if remaining <= 5 { return .red }
        if remaining <= 20 { return .orange }
        return .primary
    }
}

private struct QuotaBucketView: View {
    let bucket: QuotaBucket
    let earnedResetCount: Int?
    let isFresh: Bool
    let now: Date
    @Bindable var clock: VisibleSurfaceClock
    let onExpansionChanged: (Bool) -> Void

    var body: some View {
        FullWidthDisclosure(
            indicatorTrailing: true,
            identifier: "allowance-\(bucket.id)-disclosure",
            onExpansionChanged: onExpansionChanged
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(bucket.windows) { window in
                    QuotaWindowView(window: window, isFresh: isFresh, now: now, clock: clock)
                }
                if let credits = bucket.credits, credits.hasCredits {
                    detail("Credits", credits.unlimited ? "Unlimited" : credits.balance ?? "Available")
                }
                if let spend = bucket.spendControl {
                    detail("Spend control", "\(spend.used) of \(spend.limit)")
                    detail("Spend allowance", "\(spend.remainingPercent)% remaining")
                }
                if bucket.spendControlReached == true {
                    Label("Spend control reached", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                if let earnedResetCount { detail("Earned resets", "\(earnedResetCount)") }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Text(bucket.name)
                Spacer()
                if let limiting = bucket.limitingWindow {
                    Text("\(limiting.remainingPercent)% remaining")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }
}

private struct QuotaWindowView: View {
    let window: QuotaWindow
    let isFresh: Bool
    let now: Date
    @Bindable var clock: VisibleSurfaceClock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.durationName).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(window.clampedUsedPercent)% used · \(window.remainingPercent)% left")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Gauge(value: Double(window.clampedUsedPercent), in: 0...100) { Text(window.durationName) }
                .gaugeStyle(.linearCapacity)
                .tint(window.remainingPercent <= 5 ? .red : window.remainingPercent <= 20 ? .orange : .accentColor)
                .accessibilityLabel("\(window.durationName) Codex allowance")
                .accessibilityValue(gaugeAccessibilityValue)
            if let reset = window.resetsAt {
                HStack {
                    ResetCountdownText(reset: reset, clock: clock)
                    Spacer()
                    Text(GaugeFormatting.exactDate(reset))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let pacing = window.pacing(now: now, isFresh: isFresh) {
                Label(pacingText(pacing), systemImage: pacing.isAheadOfPace ? "speedometer" : "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(pacing.isAheadOfPace ? .orange : .secondary)
            }
        }
    }

    private var gaugeAccessibilityValue: String {
        let base = "\(window.clampedUsedPercent) percent used, \(window.remainingPercent) percent remaining; minimum 0, maximum 100"
        guard let reset = window.resetsAt else { return base }
        return "\(base); resets \(GaugeFormatting.exactDate(reset))"
    }

    private func pacingText(_ pacing: PacingEstimate) -> String {
        if let exhaustion = pacing.projectedExhaustion {
            return "Estimated to run out \(exhaustion.formatted(.relative(presentation: .named)))"
        }
        return "Estimated \(Int(pacing.projectedUsedAtReset.rounded()))% used at reset"
    }
}

private struct LiveConversationRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversation: ConversationTelemetry
    @Bindable var clock: VisibleSurfaceClock
    let onExpansionChanged: (Bool) -> Void

    var body: some View {
        FullWidthDisclosure(
            indicatorTrailing: true,
            identifier: "live-conversation-disclosure",
            onExpansionChanged: onExpansionChanged
        ) {
            LiveConversationDetails(conversation: conversation)
                .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 10) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayTitle)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(metadataLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 1) {
                        AnimatedTokenRateText(rate: conversation.tokensPerMinute)
                            .font(.subheadline.weight(.medium).monospacedDigit())
                        Text("tokens/min")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Label(phaseTitle, systemImage: phaseSymbol)
                        .id("\(conversation.state.rawValue)-\(conversation.activity.rawValue)")
                        .transition(.opacity)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: conversation.activity)
                    if let rawContext = conversation.latestContextPercent, rawContext.isFinite {
                        let context = min(100, max(0, rawContext))
                        Label("\(Int(context.rounded()))% context", systemImage: "circle.dotted")
                            .contentTransition(.numericText())
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: context)
                    }
                    if let startedAt = conversation.turnStartedAt {
                        TurnDurationLabel(startedAt: startedAt, clock: clock)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(displayTitle), \(phaseTitle), \(GaugeFormatting.tokenRate(conversation.tokensPerMinute)) tokens per minute")
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var displayTitle: String {
        conversation.title == "Unattributed Codex Work" ? "Background Codex work" : conversation.title
    }

    private var metadataLine: String {
        [Optional(conversation.workspace), conversation.model].compactMap { value in
            guard let value, !value.isEmpty, value != "Unattributed Codex Work" else { return nil }
            return value
        }.joined(separator: " · ")
    }

    private var phaseTitle: String {
        switch conversation.state {
        case .needsApproval: "Approval needed"
        case .needsInput: "Input needed"
        default: conversation.activity.title
        }
    }

    private var phaseSymbol: String {
        switch conversation.state {
        case .needsApproval, .needsInput: conversation.state.systemImage
        default: conversation.activity.systemImage
        }
    }

    private var stateColor: Color {
        switch conversation.state {
        case .needsApproval: .red
        case .needsInput: .orange
        case .running: .green
        case .idle, .recent: .secondary
        }
    }
}

private struct RecentConversationRow: View {
    let conversation: ConversationTelemetry
    let now: Date
    let onExpansionChanged: (Bool) -> Void

    var body: some View {
        FullWidthDisclosure(onExpansionChanged: onExpansionChanged) {
            RecentConversationDetails(conversation: conversation)
                .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(GaugeFormatting.coarseRelativeAge(since: conversation.lastActivity, now: now))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Last active \(GaugeFormatting.exactDate(conversation.lastActivity))")
                }

                HStack(spacing: 8) {
                    if conversation.workspace != "Unattributed Codex Work" { Text(conversation.workspace) }
                    if conversation.totalTokens > 0 { Text("\(GaugeFormatting.tokenCount(conversation.totalTokens)) tokens") }
                    if let duration = conversation.lastTurnDurationSeconds { Text(GaugeFormatting.coarseDuration(duration)) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var displayTitle: String {
        conversation.title == "Unattributed Codex Work" ? "Background Codex work" : conversation.title
    }
}

private struct LiveConversationDetails: View {
    let conversation: ConversationTelemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AnimatedConversationMetricCard(
                    title: "5-minute pace",
                    rate: conversation.tokensPerFiveMinutes,
                    unit: "tokens/min"
                )
                if let calls = conversation.callsPerMinute {
                    ConversationMetricCard(
                        title: "Model calls",
                        value: String(format: "%.1f", calls),
                        unit: "per minute"
                    )
                }
            }

            if conversation.recentTokenMix.total > 0 {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Tokens · last 5 minutes")
                        .font(.caption.weight(.medium))
                    TokenMixBar(mix: conversation.recentTokenMix)
                }
            }

            HStack(spacing: 16) {
                compactValue("Latest output", conversation.latestOutputTokens.map { GaugeFormatting.tokenCount($0) + " tokens" } ?? "—")
                compactValue("Began responding", conversation.timeToFirstTokenMilliseconds.map { String(format: "%.1f sec", Double($0) / 1_000) } ?? "—")
                compactValue("Linked agents", "\(conversation.agentCount)")
            }
        }
        .font(.caption)
    }

    private func compactValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AnimatedConversationMetricCard: View {
    let title: String
    let rate: Double
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            AnimatedTokenRateText(rate: rate)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

private struct RecentConversationDetails: View {
    let conversation: ConversationTelemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ConversationMetricCard(title: "Total tokens", value: GaugeFormatting.tokenCount(conversation.totalTokens), unit: "tokens")
                ConversationMetricCard(title: "Last turn", value: conversation.lastTurnDurationSeconds.map(GaugeFormatting.coarseDuration) ?? "—", unit: "duration")
                ConversationMetricCard(
                    title: "Latest output",
                    value: conversation.latestOutputTokens.map(GaugeFormatting.tokenCount) ?? "—",
                    unit: "tokens"
                )
            }
            HStack(spacing: 12) {
                Label(conversation.model ?? "Model unavailable", systemImage: "cpu")
                if conversation.agentCount > 0 {
                    Label("\(conversation.agentCount) linked agent\(conversation.agentCount == 1 ? "" : "s")", systemImage: "person.2")
                }
                if let latency = conversation.timeToFirstTokenMilliseconds {
                    Label(String(format: "Responded in %.1f sec", Double(latency) / 1_000), systemImage: "bolt")
                        .help("Time from turn start to the first response token")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ConversationMetricCard: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

private struct FullWidthDisclosure<Label: View, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = ProcessInfo.processInfo.arguments.contains("-performanceExpanded")
    var indicatorTrailing = false
    var identifier = "disclosure-control"
    var onExpansionChanged: (Bool) -> Void = { _ in }
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                let nextValue = !isExpanded
                if reduceMotion {
                    isExpanded = nextValue
                } else {
                    withAnimation(.snappy(duration: 0.2)) { isExpanded = nextValue }
                }
                onExpansionChanged(nextValue)
            } label: {
                HStack(spacing: 7) {
                    if !indicatorTrailing { disclosureIndicator }
                    label()
                    if indicatorTrailing { disclosureIndicator }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")

            if isExpanded { content() }
        }
    }

    private var disclosureIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isExpanded)
    }
}

private struct ResetCountdownText: View {
    let reset: Date
    @Bindable var clock: VisibleSurfaceClock

    var body: some View {
        Text(GaugeFormatting.resetCountdown(to: reset, now: clock.now))
            .monospacedDigit()
            .help(GaugeFormatting.exactDate(reset))
    }
}

private struct TurnDurationLabel: View {
    let startedAt: Date
    @Bindable var clock: VisibleSurfaceClock

    var body: some View {
        Label(GaugeFormatting.duration(clock.now.timeIntervalSince(startedAt)), systemImage: "timer")
            .monospacedDigit()
    }
}

private struct RefreshAllowancesButton: View {
    @Bindable var state: AppState
    @Bindable var clock: VisibleSurfaceClock

    var body: some View {
        Button {
            Task { await state.refresh() }
        } label: {
            Group {
                if state.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(helpText)
        .accessibilityLabel("Refresh allowances")
        .accessibilityHint(helpText)
        .disabled(state.isRefreshing || state.executableURL == nil)
    }

    private var helpText: String {
        if state.isRefreshing { return "Refreshing allowances" }
        guard let fetchedAt = state.accountSnapshot?.fetchedAt else {
            return "Refresh allowances. No update available yet."
        }
        return "Refresh allowances. \(GaugeFormatting.updatedText(since: fetchedAt, now: clock.now))."
    }
}

#Preview("Populated") {
    ContentView(state: DemoData.state(), clock: VisibleSurfaceClock())
}
