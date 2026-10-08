#if os(iOS)
import SwiftUI

struct CompanionLiveCard: View {
    let state: CompanionLiveState
    let macName: String
    let stale: Bool
    var macID = ""
    var isSmall = false
    var isIsland = false
    private func positionLabel(_ position: String) -> some View {
        Text(position).font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 44, minHeight: 44)
            .background(.white.opacity(0.16), in: Capsule())
            .contentShape(Capsule()).fixedSize()
            .accessibilityLabel(state.taskPositionDescription)
    }
    private var secondaryText: Color { .white.opacity(0.75) }
    private var primaryNeedsAttention: Bool { ["needsInput", "needsApproval"].contains(state.state) }
    var body: some View {
        VStack(alignment: .leading, spacing: isIsland ? 0 : 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: isIsland ? 1 : 3) {
                    Text(state.title)
                    .font(isSmall || isIsland ? .subheadline.weight(.semibold) : .headline)
                    .foregroundStyle(Color.white)
                    .contentTransition(.opacity)
                    .invalidatableContent()
                    .animation(.easeInOut(duration: 0.25), value: state.taskID)
                    .lineLimit(isIsland ? 1 : 2).fixedSize(horizontal: false, vertical: true)
                    if let project = state.project, !project.isEmpty {
                        Label(project, systemImage: "folder")
                            .font(isIsland ? .caption2 : .caption).foregroundStyle(secondaryText).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let position = state.taskPosition {
                    if !macID.isEmpty {
                        Button(intent: CycleLiveTaskIntent(macID: macID)) { positionLabel(position) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(state.taskPositionDescription + ". Show next task")
                            .accessibilityValue(state.selectionPending == true ? "Confirming selection" : "Selection confirmed")
                            .accessibilityIdentifier("live.taskPicker")
                    } else { positionLabel(position) }
                }
            }
            Label(macName, systemImage: "laptopcomputer").font(.caption2).foregroundStyle(secondaryText).lineLimit(1)
            if let account = state.account, !account.isEmpty {
                Text(account).font(.caption2).foregroundStyle(secondaryText).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(stale ? "Last known state" : state.activityTitle,
                      systemImage: stale ? "clock" : primaryNeedsAttention ? "text.bubble" : state.hasActiveTasks ? "waveform.path" : "checkmark")
                    .foregroundStyle(!stale && primaryNeedsAttention ? Color.orange : secondaryText)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                if let start = state.startedAt, state.hasActiveTasks {
                    if stale {
                        Text(Duration.seconds(max(0, (state.taskObservedAt ?? state.updatedAt) - start)).formatted(.time(pattern: .hourMinuteSecond)))
                            .monospacedDigit().lineLimit(1)
                    } else {
                        Text(timerInterval: Date(timeIntervalSince1970: start)...Date.distantFuture, countsDown: false)
                            .monospacedDigit().lineLimit(1).multilineTextAlignment(.trailing)
                            .frame(width: isSmall ? 64 : 80, alignment: .trailing)
                    }
                }
            }.font(.caption.weight(.medium))
            if isIsland {
                // Task position belongs in the header, away from task metrics.
                HStack(spacing: 8) {
                    if !stale, let percent = state.contextPercent {
                        HStack(spacing: 3) {
                            Image(systemName: "circle.dashed").accessibilityHidden(true)
                            Text("\(Int(percent))%").accessibilityLabel("\(Int(percent))% context")
                        }
                    }
                    if let rate = state.displayedRate(stale: stale) {
                        Text("\(rate.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))) tok/min")
                            .monospacedDigit()
                    }
                }.font(.caption2).foregroundStyle(secondaryText).lineLimit(1)
            }
            if !isIsland && !isSmall && !stale && (state.contextPercent != nil || state.displayedRate(stale: stale) != nil) {
                HStack(spacing: 8) {
                    if let percent = state.contextPercent {
                        Text("\(Int(percent))% context")
                    }
                    Spacer(minLength: 0)
                    if let rate = state.displayedRate(stale: stale) {
                        Text("\(rate.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))) tok/min")
                            .monospacedDigit()
                    }
                }.font(.caption).foregroundStyle(secondaryText).lineLimit(1)
            }
        }
        // The expanded Island reserves space above this bottom region for the
        // camera. Keep every row within its height, including live metrics.
        .padding(.horizontal, isIsland ? 8 : isSmall ? 10 : 16)
        .padding(.vertical, isIsland ? 0 : isSmall ? 10 : 16)
        .foregroundStyle(.white)
        .background(.black)
        .contentTransition(.identity)
    }
}

#endif
