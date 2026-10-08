import SwiftUI
import WidgetKit
import AppIntents

enum AllowanceChoice: String, AppEnum {
    case lowest, session, weekly
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Allowance")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .lowest: "Lowest remaining", .session: "Session", .weekly: "Weekly"
    ]
}
struct AllowanceConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Allowance"
    @Parameter(title: "Show", default: .lowest) var allowance: AllowanceChoice
}
struct AllowanceEntry: TimelineEntry {
    let date: Date
    var window: CompanionWindow?
    var observedAt: Date?
    var bankedResets: Int? = nil
    var credits: [CompanionCredit] = []
    var isStale: Bool { observedAt.map { date.timeIntervalSince($0) >= 180 } ?? true }
}
struct AllowanceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AllowanceEntry {
        AllowanceEntry(date: .now, window: .init(id: "weekly", name: "Weekly", remainingPercent: 64, resetsAt: .now.addingTimeInterval(280000)), observedAt: .now,
            bankedResets: 2, credits: [.init(id: "codex", name: "Codex", hasCredits: true, unlimited: false, balance: "250")])
    }
    func snapshot(for configuration: AllowanceConfiguration, in context: Context) async -> AllowanceEntry {
        context.isPreview ? placeholder(in: context) : entry(configuration)
    }
    func timeline(for configuration: AllowanceConfiguration, in context: Context) async -> Timeline<AllowanceEntry> {
        let snapshots = await CompanionWidgetCache.refresh()
        let value = entry(configuration, snapshots: snapshots)
        // Never fabricate a replenished allowance at the expected reset time.
        // Refresh then; only the Mac can confirm the new observation.
        let next = max(Date.now.addingTimeInterval(60), min(value.window?.resetsAt ?? .distantFuture, Date.now.addingTimeInterval(900)))
        let entries = CompanionWidgetTimeline.dates(now: value.date, observedAt: value.observedAt, resetsAt: value.window?.resetsAt).map { date in
            // Expire the live presentation even if iOS defers network refresh.
            // Never fabricate replenishment when the reset time arrives.
            AllowanceEntry(date: date, window: value.window, observedAt: value.observedAt, bankedResets: value.bankedResets, credits: value.credits)
        }
        return Timeline(entries: entries, policy: .after(next))
    }
    private func entry(_ configuration: AllowanceConfiguration, snapshots: [CompanionSnapshot] = CompanionWidgetCache.read()) -> AllowanceEntry {
        let accounts = CompanionMerge.accounts(snapshots)
        let all = accounts.flatMap { account in account.windows.map { (account, $0) } }
        let candidates = all.filter { item in
            switch configuration.allowance {
            case .lowest: true
            case .weekly: item.1.name.localizedCaseInsensitiveContains("week")
            case .session: item.1.name.localizedCaseInsensitiveContains("session") || item.1.name.localizedCaseInsensitiveContains("5-hour")
            }
        }
        let selected = candidates.min { $0.1.remainingPercent < $1.1.remainingPercent }
        return AllowanceEntry(date: .now, window: selected?.1, observedAt: selected?.0.observedAt,
            bankedResets: selected?.0.bankedResets, credits: selected?.0.credits ?? [])
    }
}
struct AllowanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AllowanceEntry
    var body: some View {
        Group {
            if let window = entry.window {
                switch family {
                case .accessoryCircular:
                    Gauge(value: Double(window.remainingPercent), in: 0...100) {
                        Image(systemName: "gauge.with.needle")
                    } currentValueLabel: { Text("\(window.remainingPercent)") }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .accessibilityLabel("\(title(window)), \(window.remainingPercent) percent remaining\(entry.isStale ? ", last known usage" : "")")
                case .accessoryInline:
                    Text("\(title(window)): \(window.remainingPercent)%\(entry.isStale ? " · last known" : " remaining")")
                case .accessoryRectangular:
                    VStack(alignment: .leading) {
                        Text("\(title(window)) · \(window.remainingPercent)%").font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                        Group {
                            if entry.isStale { Label("Last known usage", systemImage: "clock") }
                            else { reset(window) }
                        }.font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                    }
                case .systemMedium:
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title(window)).font(.headline).lineLimit(1)
                            Text("\(window.remainingPercent)%").font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                            ProgressView(value: Double(window.remainingPercent), total: 100).tint(.blue)
                            Text(entry.isStale ? "Last known usage" : "Remaining").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 10) {
                            reset(window).font(.caption).lineLimit(2)
                            if let banked = entry.bankedResets {
                                LabeledContent("Limit resets", value: "\(banked)")
                            }
                            ForEach(entry.credits.prefix(2)) { credit in
                                LabeledContent(entry.credits.count > 1 ? "\(credit.name) credits" : "Credits", value: credit.displayBalance)
                            }
                            if let observed = entry.observedAt {
                                Text("Updated \(observed.formatted(date: Calendar.current.isDate(observed, inSameDayAs: entry.date) ? .omitted : .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                default:
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(title(window)).font(.headline).lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
                            Spacer()
                            Image(systemName: entry.isStale ? "clock" : "gauge.with.needle").foregroundStyle(.blue)
                        }
                        Text("\(window.remainingPercent)%").font(.system(size: 38, weight: .semibold, design: .rounded)).minimumScaleFactor(0.7)
                        ProgressView(value: Double(window.remainingPercent), total: 100).tint(.blue)
                        reset(window).font(.caption)
                        if let observed = entry.observedAt {
                            Text("\(entry.isStale ? "Last known" : "Updated") \(observed.formatted(date: Calendar.current.isDate(observed, inSameDayAs: entry.date) ? .omitted : .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading) {
                    Label("CodexGauge", systemImage: "gauge.with.needle")
                    Text("Open the app to link a Mac.").font(.caption)
                }
            }
        }.containerBackground(.fill.tertiary, for: .widget)
    }
    private func title(_ window: CompanionWindow) -> String {
        window.name.hasPrefix("Codex ") ? String(window.name.dropFirst(6)) : window.name
    }
    @ViewBuilder private func reset(_ window: CompanionWindow) -> some View {
        if let reset = window.resetsAt {
            if reset > entry.date { HStack(spacing: 3) { Text("Reset in"); Text(reset, style: .relative) } }
            else { Text("Reset awaiting confirmation") }
        }
    }
}
@main struct CodexGaugeWidgets: WidgetBundle {
    var body: some Widget { AllowanceWidget(); liveActivityWidget() }
    // WidgetBundleBuilder has no buildEither. Use its public availability
    // erasure so iOS 17 retains the legacy configuration and iOS 18+ receives
    // supplemental families, without registering duplicate activity types.
    private func liveActivityWidget() -> some Widget {
        if #available(iOS 18.0, *) {
            return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(CompanionLiveActivity()))
        } else {
            return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(CompanionLegacyLiveActivity()))
        }
    }
}

struct AllowanceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "CodexGaugeAllowance", intent: AllowanceConfiguration.self, provider: AllowanceProvider()) { entry in
            AllowanceWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex allowance")
        .description("Remaining allowance and the next reset reported by your linked Macs.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
