import SwiftUI

struct HelpView: View {
    private enum Topic: String, CaseIterable, Identifiable {
        case overview
        case menuBar
        case conversations
        case privacy
        case troubleshooting

        var id: Self { self }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .menuBar: "Menu Bar"
            case .conversations: "Tasks"
            case .privacy: "Privacy"
            case .troubleshooting: "Fix a Problem"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: "gauge.with.needle"
            case .menuBar: "menubar.rectangle"
            case .conversations: "bubble.left.and.bubble.right"
            case .privacy: "hand.raised"
            case .troubleshooting: "wrench.and.screwdriver"
            }
        }
    }

    @State private var selection: Topic? = .overview

    var body: some View {
        NavigationSplitView {
            List(Topic.allCases, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.systemImage)
                    .tag(topic)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 205)
        } detail: {
            ScrollView {
                Group {
                    switch selection ?? .overview {
                    case .overview: overview
                    case .menuBar: menuBar
                    case .conversations: conversations
                    case .privacy: privacy
                    case .troubleshooting: troubleshooting
                    }
                }
                .frame(maxWidth: 580, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var overview: some View {
        helpPage(
            title: "Using TokenTach",
            symbol: "gauge.with.needle",
            introduction: "TokenTach keeps your Codex allowances and current work one click away in the menu bar."
        ) {
            helpRow("Check allowances", symbol: "menubar.rectangle", detail: "By default, the menu bar shows the Codex allowance with the least remaining capacity.")
            helpRow("Customize the menu bar", symbol: "slider.horizontal.3", detail: "Settings includes a live preview and choices for content, timing, suggested pace, and optional status colors.")
            helpRow("Follow live tasks", symbol: "waveform", detail: "The popover shows tasks running on this Mac, including their current phase, recent token rate, and context use.")
            helpRow("Explore your activity", symbol: "chart.xyaxis.line", detail: "Open the Dashboard to compare activity periods and see more detail about live and recent tasks.")
            callout("Suggested pace is a local estimate, not a separate daily allowance issued by OpenAI. If a selected allowance is temporarily unavailable, TokenTach keeps your choice and uses the most constrained Codex allowance until it returns.", symbol: "info.circle")
        }
    }

    private var menuBar: some View {
        helpPage(
            title: "Customize the menu bar",
            symbol: "menubar.rectangle",
            introduction: "Choose the information TokenTach keeps visible without changing what appears in the popover or Dashboard."
        ) {
            helpRow("Gauge and percentage", symbol: "gauge.with.needle", detail: "Show either item or both. If turning one off would leave the normal menu-bar item empty, TokenTach keeps the other item visible.")
            helpRow("Main percentage", symbol: "percent", detail: "Lowest Codex Allowance chooses the Codex window with the least remaining. Lowest Allowance Overall also considers other returned allowance groups. A named choice follows that exact allowance and reset window.")
            helpRow("Additional percentage", symbol: "plus.forwardslash.minus", detail: "Show one optional second percentage. TokenTach hides a second choice that resolves to the same allowance as the main percentage.")
            helpRow("Reset timing", symbol: "calendar.badge.clock", detail: "Show a compact countdown, a localized reset date, or both. Countdown text changes locally and does not make extra account requests.")
            helpRow("Available per day or hour", symbol: "divide", detail: "Divides the percentage points currently remaining by the exact time until reset. During the final day, the estimate changes from a daily amount to an hourly amount.")
            helpRow("Remaining target", symbol: "scope", detail: "Shows the percentage that would remain at the end of the current allowance day—or hour during the final day—if the full allowance were used evenly across its reset window.")
            helpRow("Warnings Only", symbol: "exclamationmark.circle", detail: "Normal status stays monochrome. Yellow appears at 20% remaining or when projected usage reaches 90% of the allowance. Red appears at 10% remaining or when usage is projected to exhaust the allowance before reset. Pacing warnings wait until enough of a new window has elapsed for a meaningful estimate.")
            helpRow("Traffic Light", symbol: "circle.grid.3x3.fill", detail: "Uses the same warning rules and also shows healthy status in green. When both amount and projected usage are selected, the more urgent status wins.")
            helpRow("Color placement", symbol: "paintpalette", detail: "When both the gauge and values are visible, color can apply to either or both. If only one kind of item is visible, TokenTach applies color there automatically. Open the popover to see the reason for any warning; symbols and VoiceOver descriptions also reinforce color.")
            callout("Suggested pace and remaining targets are local estimates, not daily quotas issued by OpenAI. If a saved allowance temporarily disappears, TokenTach keeps the choice and uses the lowest Codex allowance until it returns.", symbol: "info.circle")
        }
    }

    private var conversations: some View {
        helpPage(
            title: "Task activity",
            symbol: "bubble.left.and.bubble.right",
            introduction: "Task details come from Codex activity stored on this Mac. Cloud-only Work chats are not exposed by this local source. Other Macs appear only when linked through the companion."
        ) {
            helpRow("Live", symbol: "circle.fill", detail: "The task is working on this Mac or is waiting for your input or approval.", tint: .green)
            helpRow("Recently active", symbol: "clock", detail: "TokenTach keeps up to 200 local root tasks seen during the past 24 hours. The popover shows the four newest tasks; the Dashboard starts with ten and shows ten more at a time.")
            helpRow("Began responding", symbol: "bolt", detail: "How long Codex took to begin producing a response after the current turn started.")
            helpRow("Token rate", symbol: "speedometer", detail: "A time-weighted rolling measure of tokens recorded during the previous 60 seconds. It updates about once a second and gradually falls during tool use or other pauses.")
            callout("Task token rates show local activity, not how much of an account allowance each task used. Status names come from lifecycle and bounded tool metadata; TokenTach does not inspect prompts, arguments or tool output to determine them. A zero rate never identifies a tool or compaction. Live compaction starts are not exposed by the passive rollout source.", symbol: "info.circle")
        }
    }

    private var privacy: some View {
        helpPage(
            title: "Data and privacy",
            symbol: "hand.raised",
            introduction: "TokenTach works locally and uses the Codex sign-in that is already active on your Mac."
        ) {
            informationGroup("TokenTach reads") {
                informationRow("Allowance and account activity from the installed Codex app", symbol: "gauge.with.needle")
                Divider()
                informationRow("Task names, workspaces, models, timestamps, status, and token counts from local Codex files", symbol: "internaldrive")
            }
            informationGroup("TokenTach does not read") {
                informationRow("Messages, reasoning, command output, or tool contents", symbol: "eye.slash")
                Divider()
                informationRow("Codex sign-in credentials or authentication tokens", symbol: "key.slash")
            }
            informationGroup("Stored on this Mac") {
                Text("TokenTach saves settings, alert records, the latest account summary, and configured reset-monitor state. Account IDs or personal account emails returned by Codex are hashed locally for comparison; raw identities are not saved. Pending task alerts retain their titles and project names until delivery. Detailed task telemetry and raw identifiers are not saved; salted identifier hashes and event timestamps prevent duplicate alerts.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            informationGroup("Notifications") {
                Text("Task alerts include their task and associated project names. If you enable the iPhone companion, usage and task status are sent to your configured relay. A usage-only viewing link excludes task and project names. No Codex credentials, workspace paths, task prompts, or answers are sent.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            callout("TokenTach has no analytics service.", symbol: "icloud.slash")
        }
    }

    private var troubleshooting: some View {
        helpPage(
            title: "Troubleshooting",
            symbol: "wrench.and.screwdriver",
            introduction: "Most connection issues can be resolved without signing in again."
        ) {
            helpRow("Allowance data is unavailable", symbol: "questionmark.circle", detail: "Open ChatGPT and confirm you are signed in. TokenTach keeps trying automatically; if it cannot find Codex, choose the helper in Settings.")
            helpRow("A task is missing", symbol: "rectangle.badge.xmark", detail: "Confirm the task has run on this Mac. Tasks that exist only on another linked computer cannot be discovered from local activity.")
            helpRow("Information looks old", symbol: "exclamationmark.triangle", detail: "TokenTach keeps the most recent successful update while your Mac is offline or Codex cannot respond, then updates automatically when the connection returns.")
            helpRow("Notifications", symbol: "bell", detail: "Choose which alerts appear on this Mac in Settings > Notifications. Configure iPhone alerts separately in the TokenTach companion app. Task completion requires an explicit completion event; existing history is not replayed. macOS asks for permission when needed as you enable an alert. macOS manages delivery permissions separately; your alert preferences are kept if permission is denied.")
            Link("Learn how Codex connects", destination: URL(string: "https://learn.chatgpt.com/docs/app-server")!)
        }
    }

    private func helpPage<Content: View>(
        title: String,
        symbol: String,
        introduction: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(title, systemImage: symbol)
                .font(.title2.weight(.semibold))
            Text(introduction)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
        }
    }

    private func helpRow(_ title: String, symbol: String, detail: String, tint: Color = .accentColor) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 24, alignment: .center)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func informationGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        } label: {
            Text(title)
                .font(.headline)
        }
    }

    private func informationRow(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func callout(_ text: String, symbol: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview("Help") {
    HelpView()
        .frame(width: 760, height: 520)
}
