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
                CompanionLiveCard(state: context.state, macName: context.attributes.macName, stale: context.isStale, macID: context.attributes.macID)
            }
            }
                // The Lock Screen host can choose a different appearance from
                // UIKit. Resolve background and foreground as one palette.
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.state.url(macID: context.attributes.macID))
        } dynamicIsland: { context in
            DynamicIsland {
                // Side regions beside the camera are too narrow for status or
                // device names. Keep the expanded card entirely below it.
                DynamicIslandExpandedRegion(.bottom) {
                    CompanionLiveCard(state: context.state, macName: context.attributes.macName,
                                      stale: context.isStale, macID: context.attributes.macID, isIsland: true)
                }
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
}



@available(iOS 18.0, *)
private struct CompanionLiveFamilyCard: View {
    let context: ActivityViewContext<CompanionActivityAttributes>
    @Environment(\.activityFamily) private var family
    var body: some View {
        CompanionLiveCard(state: context.state, macName: context.attributes.macName, stale: context.isStale, macID: context.attributes.macID, isSmall: family == .small)
    }
}
