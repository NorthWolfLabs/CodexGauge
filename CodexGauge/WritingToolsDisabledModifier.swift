import SwiftUI

private struct WritingToolsDisabledModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.writingToolsBehavior(.disabled)
        } else {
            content
        }
    }
}

extension View {
    /// CodexGauge's surfaces display telemetry, paths, and numeric preferences;
    /// none benefit from prose rewriting. Disabling Writing Tools avoids creating
    /// Apple Intelligence sessions for each short-lived popover hierarchy.
    func codexGaugeWritingToolsDisabled() -> some View {
        modifier(WritingToolsDisabledModifier())
    }
}
