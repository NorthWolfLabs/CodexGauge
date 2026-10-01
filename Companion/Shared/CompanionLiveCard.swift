#if os(iOS)
import SwiftUI

struct CompanionLiveCard: View {
    let state: CompanionLiveState
    let macName: String
    let stale: Bool
    var isSmall = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: stale ? "clock" : state.attention > 0 ? "text.bubble" : "waveform.path")
                    .foregroundStyle(!stale && state.attention > 0 ? Color.orange : Color.blue)
                Text(stale ? "Last known state" : state.statusTitle).font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if let start = state.startedAt, state.hasActiveTasks {
                    if stale {
                        Text(Duration.seconds(max(0, (state.taskObservedAt ?? state.updatedAt) - start)).formatted(.time(pattern: .hourMinuteSecond))).font(.caption).monospacedDigit()
                    } else {
                        Text(timerInterval: Date(timeIntervalSince1970: start)...Date.distantFuture, countsDown: false)
                            .font(.caption).monospacedDigit().fixedSize()
                    }
                }
            }
            Text(state.title).font(isSmall ? .subheadline.weight(.semibold) : .headline).lineLimit(isSmall ? 2 : 3)
            Text(macName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !stale && !isSmall, let phase = state.activity, state.state == "running" {
                Text(phase).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("\(state.running) working")
                if state.attention > 0 { Text("\(state.attention) need you").foregroundStyle(.orange) }
                if !isSmall, let percent = state.contextPercent { Spacer(minLength: 0); Text("\(Int(percent))% context") }
            }.font(.caption).lineLimit(1)
        }.padding(isSmall ? 10 : 16)
    }
}

#endif
