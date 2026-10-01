import SwiftUI
import ActivityKit
import WidgetKit

@available(iOS 18.0, *)
struct CompanionLiveActivity: Widget {
    var body: some WidgetConfiguration { CompanionLegacyLiveActivity().body.supplementalActivityFamilies([.small, .medium]) }
}

struct CompanionLegacyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CompanionActivityAttributes.self) { context in
            Group {
            if #available(iOS 18.0, *) { CompanionLiveFamilyCard(context: context) }
            else {
                CompanionLiveCard(state: context.state, macName: context.attributes.macName, stale: context.isStale)
            }
            }
                .activityBackgroundTint(Color(.secondarySystemBackground))
                .widgetURL(context.state.url(macID: context.attributes.macID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { status(context) }
                DynamicIslandExpandedRegion(.trailing) { Text(context.attributes.macName).font(.caption).lineLimit(1) }
                DynamicIslandExpandedRegion(.center) { if context.state.hasActiveTasks { Text(context.state.title).font(.headline).lineLimit(2) } }
                DynamicIslandExpandedRegion(.bottom) { if context.state.hasActiveTasks { counts(context) } }
            } compactLeading: {
                Image(systemName: symbol(context)).foregroundStyle(context.isStale ? Color.secondary : context.state.attention > 0 ? Color.orange : Color.blue)
            } compactTrailing: {
                Text("\(context.state.running + context.state.attention)").monospacedDigit()
            } minimal: {
                Image(systemName: symbol(context)).foregroundStyle(context.isStale ? Color.secondary : context.state.attention > 0 ? Color.orange : Color.blue)
                    .accessibilityLabel("\(context.attributes.macName), \(context.isStale ? "last known state" : context.state.statusTitle)")
            }
            .widgetURL(context.state.url(macID: context.attributes.macID))
            .keylineTint(context.state.attention > 0 ? .orange : .blue)
        }
    }
    private func symbol(_ context: ActivityViewContext<CompanionActivityAttributes>) -> String {
        context.isStale ? "clock" : context.state.attention > 0 ? "bubble.left.and.exclamationmark.bubble.right" : context.state.hasActiveTasks ? "waveform.path" : "checkmark"
    }
    private func status(_ context: ActivityViewContext<CompanionActivityAttributes>) -> some View {
        Label(context.isStale ? "Last known state" : context.state.statusTitle, systemImage: symbol(context))
            .font(.caption.weight(.medium)).foregroundStyle(!context.isStale && context.state.attention > 0 ? .orange : .secondary)
    }
    private func counts(_ context: ActivityViewContext<CompanionActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            if context.state.running > 0 { Label("\(context.state.running) working", systemImage: "waveform.path") }
            if context.state.attention > 0 { Label("\(context.state.attention) waiting", systemImage: "text.bubble").foregroundStyle(.orange) }
            Spacer(minLength: 4)
            if !context.isStale && context.state.running > 0 && context.state.hasRate == true {
                Text("\(context.state.tokensPerMinute.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))) tok/min").monospacedDigit()
            }
        }.font(.caption).lineLimit(1).minimumScaleFactor(0.8)
    }
}



@available(iOS 18.0, *)
private struct CompanionLiveFamilyCard: View {
    let context: ActivityViewContext<CompanionActivityAttributes>
    @Environment(\.activityFamily) private var family
    var body: some View {
        CompanionLiveCard(state: context.state, macName: context.attributes.macName, stale: context.isStale, isSmall: family == .small)
    }
}
