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

struct TokenMixChartValue: Sendable {
    let name: String
    let tokens: Int64
}

struct TokenMixChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let values: [TokenMixChartValue]

    func makeChartDescriptor() -> AXChartDescriptor {
        let categories = values.map(\.name)
        let maximum = max(1, values.map { max(0, $0.tokens) }.max() ?? 1)
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Token type", categoryOrder: categories)
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Tokens",
            range: 0...Double(maximum),
            gridlinePositions: [0, Double(maximum)],
            valueDescriptionProvider: { value in
                "\(GaugeFormatting.tokenCount(GaugeFormatting.nonnegativeInt64(value))) tokens"
            }
        )
        let points = values.map { value in
            AXDataPoint(
                x: value.name,
                y: Double(max(0, value.tokens)),
                label: "\(value.name), \(GaugeFormatting.tokenCount(max(0, value.tokens))) tokens"
            )
        }
        return AXChartDescriptor(
            title: title,
            summary: "Input, cached input, output, and reasoning tokens recorded locally.",
            xAxis: xAxis,
            yAxis: yAxis,
            series: [AXDataSeriesDescriptor(name: "Token mix", isContinuous: false, dataPoints: points)]
        )
    }
}
