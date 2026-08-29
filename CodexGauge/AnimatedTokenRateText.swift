import SwiftUI

/// Uses SwiftUI's numeric content transition for one calm, consistent rate
/// animation across the popover and Dashboard.
struct AnimatedTokenRateText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let rate: Double

    var body: some View {
        Text(GaugeFormatting.tokenRate(safeRate))
            .contentTransition(.numericText(value: safeRate))
            .animation(reduceMotion ? nil : .smooth(duration: 0.8), value: safeRate)
            .accessibilityValue("\(GaugeFormatting.tokenRate(safeRate)) tokens per minute")
    }

    private var safeRate: Double {
        guard rate.isFinite else { return 0 }
        return min(1_000_000_000_000, max(0, rate))
    }
}
