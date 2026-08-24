import Accessibility
import Foundation
import SwiftUI

struct TokenActivityChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let summary: String
    let usage: [DailyUsage]

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = usage.map { $0.date.formatted(date: .abbreviated, time: .omitted) }
        let maximum = max(1, usage.map { max(0, $0.tokens) }.max() ?? 1)
        let upperBound = Double(maximum)
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: labels)
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Tokens",
            range: 0...upperBound,
            gridlinePositions: [0, upperBound],
            valueDescriptionProvider: { value in
                "\(GaugeFormatting.tokenCount(GaugeFormatting.nonnegativeInt64(value))) tokens"
            }
        )
        let points = zip(labels, usage).map { label, day in
            AXDataPoint(
                x: label,
                y: Double(max(0, day.tokens)),
                label: "\(label), \(GaugeFormatting.tokenCount(max(0, day.tokens))) tokens"
            )
        }
        let series = AXDataSeriesDescriptor(name: "Daily token activity", isContinuous: false, dataPoints: points)
        return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis, series: [series])
    }
}
