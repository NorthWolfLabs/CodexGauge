import SwiftUI

struct HelpView: View {
    private enum Topic: String, CaseIterable, Identifiable {
        case overview
        case conversations
        case privacy
        case troubleshooting

        var id: Self { self }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .conversations: "Tasks"
            case .privacy: "Privacy"
            case .troubleshooting: "Fix a Problem"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: "gauge.with.needle"
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
            title: "Using CodexGauge",
            symbol: "gauge.with.needle",
            introduction: "CodexGauge keeps your Codex allowances and current work one click away in the menu bar."
        ) {
            helpRow("Check allowances", symbol: "menubar.rectangle", detail: "The menu-bar percentage shows the Codex allowance with the least remaining capacity.")
            helpRow("Follow live tasks", symbol: "waveform", detail: "The popover shows tasks running on this Mac, including their current phase, recent token rate, and context use.")
            helpRow("Explore your activity", symbol: "chart.xyaxis.line", detail: "Open the Dashboard to compare activity periods and see more detail about live and recent tasks.")
            callout("Click the menu-bar item to open the popover. Right-click it for app commands. Press Command–Question Mark (⌘?) to open Help.", symbol: "command")
        }
    }

    private var conversations: some View {
        helpPage(
            title: "Task activity",
            symbol: "bubble.left.and.bubble.right",
            introduction: "Task details come from Codex activity stored on this Mac. Work that exists only on another computer may not appear."
        ) {
            helpRow("Live", symbol: "circle.fill", detail: "The task is working on this Mac or is waiting for your input or approval.", tint: .green)
            helpRow("Recently active", symbol: "clock", detail: "CodexGauge keeps up to 200 local root tasks seen during the past 24 hours. The popover shows the four newest tasks; the Dashboard starts with ten and shows ten more at a time.")
            helpRow("Began responding", symbol: "bolt", detail: "How long Codex took to begin producing a response after the current turn started.")
            helpRow("Token rate", symbol: "speedometer", detail: "A rolling measure of tokens recorded during the previous 60 seconds. It updates as local activity arrives, with a three-second fallback check.")
            callout("Task token rates show local activity, not how much of an account allowance each task used. Status names come from task events; CodexGauge does not inspect message or tool content to determine them.", symbol: "info.circle")
        }
    }

    private var privacy: some View {
        helpPage(
            title: "Data and privacy",
            symbol: "hand.raised",
            introduction: "CodexGauge works locally and uses the Codex sign-in that is already active on your Mac."
        ) {
            informationGroup("CodexGauge reads") {
                informationRow("Allowance and account activity from the installed Codex app", symbol: "gauge.with.needle")
                Divider()
                informationRow("Task names, workspaces, models, timestamps, status, and token counts from local Codex files", symbol: "internaldrive")
            }
            informationGroup("CodexGauge does not read") {
                informationRow("Messages, reasoning, command output, or tool contents", symbol: "eye.slash")
                Divider()
                informationRow("Your email address, sign-in credentials, or authentication tokens", symbol: "key.slash")
            }
            informationGroup("Stored on this Mac") {
                Text("CodexGauge saves your settings, a record of alerts already sent, and the latest account activity summary. It does not save task details or task identifiers.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            informationGroup("Notifications") {
                Text("If you turn on alerts, CodexGauge sends privacy-safe allowance or attention notices through Notification Center. Task names are not included in notification text.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            callout("CodexGauge has no analytics service and does not upload its own telemetry.", symbol: "icloud.slash")
        }
    }

    private var troubleshooting: some View {
        helpPage(
            title: "Troubleshooting",
            symbol: "wrench.and.screwdriver",
            introduction: "Most connection issues can be resolved without signing in again."
        ) {
            helpRow("Allowance data is unavailable", symbol: "questionmark.circle", detail: "Open ChatGPT, confirm you are signed in, then choose Refresh. If CodexGauge still cannot connect, choose the Codex helper in Settings.")
            helpRow("A task is missing", symbol: "rectangle.badge.xmark", detail: "Confirm the task has run on this Mac. Tasks that exist only on another linked computer cannot be discovered from local activity.")
            helpRow("Information looks old", symbol: "exclamationmark.triangle", detail: "CodexGauge keeps the most recent successful update when your Mac is offline or Codex cannot respond. Refresh after the connection returns.")
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
