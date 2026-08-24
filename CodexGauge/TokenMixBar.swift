import SwiftUI

struct TokenMixBar: View {
    let mix: TokenBreakdown

    private var slices: [(String, Int64, Color)] {
        [
            ("Input", mix.input, .blue),
            ("Cached", mix.cachedInput, .cyan),
            ("Output", mix.output, .green),
            ("Reasoning", mix.reasoningOutput, .purple)
        ].filter { $0.1 > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                guard size.width.isFinite, size.height.isFinite,
                      size.width > 0, size.height > 0 else { return }

                let gap: CGFloat = 2
                let gapWidth = CGFloat(max(0, slices.count - 1)) * gap
                let availableWidth = max(0, size.width - gapWidth)
                let total = slices.reduce(0.0) { $0 + Double($1.1) }
                guard total.isFinite, total > 0 else { return }

                var x: CGFloat = 0
                for slice in slices {
                    let width = availableWidth * (Double(slice.1) / total)
                    guard width.isFinite, width >= 0 else { continue }
                    let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(slice.2))
                    x += width + gap
                }
            }
            .frame(height: 7)

            HStack(spacing: 10) {
                ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                    HStack(spacing: 3) {
                        Circle().fill(slice.2).frame(width: 5, height: 5)
                        Text("\(slice.0) \(GaugeFormatting.tokenCount(slice.1))")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token mix for the last five minutes")
        .accessibilityValue(slices.map { "\($0.0), \(GaugeFormatting.tokenCount($0.1)) tokens" }.joined(separator: "; "))
    }
}
