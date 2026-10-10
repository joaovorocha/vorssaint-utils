// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Charts

/// All charts share the same saved observations, time range, and selection.
/// Missing radio fields and explicit recording gaps start a new line segment.
struct TMobileCoverageChartsView: View {
    let observations: [TMobileCoverageObservation]
    var gaps: [TMobileCoverageGap] = []
    @Binding var selectedObservationID: UUID?

    private var sorted: [TMobileCoverageObservation] { observations.sorted { $0.date < $1.date } }
    private var pickerSamples: [TMobileCoverageObservation] {
        var samples = Array(observations.suffix(500).reversed())
        if let selected = observations.first(where: { $0.id == selectedObservationID }),
           !samples.contains(where: { $0.id == selected.id }) { samples.insert(selected, at: 0) }
        return samples
    }
    private var timeDomain: ClosedRange<Date> {
        let dates = observations.flatMap { [$0.date, $0.speedTest?.endedAt].compactMap { $0 } }
        let first = dates.min() ?? Date()
        let last = dates.max() ?? first
        return first.addingTimeInterval(-1)...max(last, first.addingTimeInterval(1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Measurements over time").font(.headline)
                Spacer()
                Text("\(observations.count) saved readings").font(.caption).foregroundStyle(.secondary)
            }
            if observations.isEmpty {
                ContentUnavailableView("No saved measurements", systemImage: "chart.xyaxis.line",
                                       description: Text("Start a recording session to compare signal strength, signal quality, tested speed, and Connection Score."))
                    .frame(minHeight: 170)
            } else {
                sampleSelection
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(TMobileCoverageMetric.allCases) { metric in
                        TMobileCoverageMetricChart(observations: sorted, gaps: gaps, metric: metric,
                                                   timeDomain: timeDomain, selectedObservationID: $selectedObservationID)
                    }
                }
                Text("Radio lines stop at missing readings or recorded gaps. Speed and score are individual recorded values; a missing speed test never becomes zero. Gray bands mark saved gaps, including location interruptions.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sampleSelection: some View {
        HStack(spacing: 10) {
            Text("Selected sample").fixedSize()
            Picker("Selected sample", selection: $selectedObservationID) {
                ForEach(pickerSamples) { sample in
                    Text(sample.date.formatted(date: .abbreviated, time: .standard)).tag(Optional(sample.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 340)
            Button("Latest") { selectedObservationID = observations.last?.id }.fixedSize()
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

enum TMobileCoverageChartDrawing {
    static let maximumPoints = 800
    static let maximumRadioInterval: TimeInterval = 180

    struct Point: Identifiable {
        let observationID: UUID
        let date: Date
        let value: Double
        let segment: Int
        let speedTestID: UUID?
        var id: UUID { observationID }
        init(observationID: UUID, date: Date, value: Double, segment: Int, speedTestID: UUID? = nil) {
            self.observationID = observationID; self.date = date; self.value = value
            self.segment = segment; self.speedTestID = speedTestID
        }
    }

    static func points(observations: [TMobileCoverageObservation], gaps: [TMobileCoverageGap], metric: TMobileCoverageMetric) -> [Point] {
        let sorted = observations.sorted { $0.date < $1.date }
        var result: [Point] = []
        var segment = 0
        var previousDate: Date?
        var speedIDs = Set<UUID>()
        for observation in sorted {
            guard let value = metric.value(in: observation), value.isFinite else {
                segment += 1; previousDate = nil; continue
            }
            let date = metric == .speed ? observation.speedTest?.endedAt ?? observation.date : observation.date
            if metric == .speed, let speedID = observation.speedTest?.id, !speedIDs.insert(speedID).inserted { continue }
            if let previousDate {
                let interrupted = date.timeIntervalSince(previousDate) > maximumRadioInterval
                    || gaps.contains { gap in
                        gap.startedAt <= date && (gap.endedAt ?? .distantFuture) >= previousDate
                    }
                if interrupted { segment += 1 }
            }
            result.append(Point(observationID: observation.id, date: date, value: value, segment: segment,
                                speedTestID: observation.speedTest?.id))
            previousDate = date
        }
        return result
    }

    /// Decimation preserves each bucket's extremes and original segment IDs.
    /// A skipped segment cannot connect lines across a recording gap.
    static func drawnPoints(_ points: [Point], selectedID: UUID?) -> [Point] {
        guard points.count > maximumPoints else { return points }
        let bucketSize = max(1, Int(ceil(Double(points.count) / Double(maximumPoints / 4))))
        var kept = Set<Int>()
        for start in stride(from: 0, to: points.count, by: bucketSize) {
            let end = min(start + bucketSize, points.count)
            let indices = start..<end
            kept.insert(start); kept.insert(end - 1)
            if let minimum = indices.min(by: { points[$0].value < points[$1].value }) { kept.insert(minimum) }
            if let maximum = indices.max(by: { points[$0].value < points[$1].value }) { kept.insert(maximum) }
        }
        if let selectedID, let index = points.firstIndex(where: { $0.observationID == selectedID }) { kept.insert(index) }
        return kept.sorted().map { points[$0] }
    }

    static func domain(_ points: [Point], metric: TMobileCoverageMetric) -> ClosedRange<Double> {
        let lower: Double, upper: Double
        switch metric {
        case .rsrp: lower = -140; upper = -40
        case .sinr: lower = -30; upper = 40
        case .speed: lower = 0; upper = 100
        case .score: lower = 0; upper = 100
        }
        return min(lower, points.map(\.value).min() ?? lower)...max(upper, points.map(\.value).max() ?? upper)
    }
}

private struct TMobileCoverageMetricChart: View {
    let observations: [TMobileCoverageObservation]
    let gaps: [TMobileCoverageGap]
    let metric: TMobileCoverageMetric
    let timeDomain: ClosedRange<Date>
    @Binding var selectedObservationID: UUID?

    private var allPoints: [TMobileCoverageChartDrawing.Point] {
        TMobileCoverageChartDrawing.points(observations: observations, gaps: gaps, metric: metric)
    }
    private func selectedPoint(in points: [TMobileCoverageChartDrawing.Point]) -> TMobileCoverageChartDrawing.Point? {
        if metric == .speed, let speedID = observations.first(where: { $0.id == selectedObservationID })?.speedTest?.id {
            return points.first { $0.speedTestID == speedID }
        }
        return points.first { $0.observationID == selectedObservationID }
    }
    private var selectedDate: Date? {
        guard let observation = observations.first(where: { $0.id == selectedObservationID }) else { return nil }
        return metric == .speed ? observation.speedTest?.endedAt ?? observation.date : observation.date
    }
    private var supportsLine: Bool { metric == .rsrp || metric == .sinr }

    var body: some View {
        let points = allPoints
        let selected = selectedPoint(in: points)
        let selectedPointID = selected?.observationID ?? selectedObservationID
        let drawn = TMobileCoverageChartDrawing.drawnPoints(points, selectedID: selectedPointID)
        let domain = TMobileCoverageChartDrawing.domain(points, metric: metric)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.title).font(.callout.weight(.semibold))
                Spacer()
                if let selected {
                    Text(TMobileCoverageMapDrawing.valueText(selected.value, metric: metric)).font(.caption.monospacedDigit())
                } else {
                    Text(metric.unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            if points.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(.secondary)
                    Text(metric == .score ? "No complete Connection Score" : "No \(metric.title) measurements")
                        .font(.caption).foregroundStyle(.secondary)
                    if metric == .score {
                        Text("Needs signal readings and a recent speed test at the same stop.")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }.frame(maxWidth: .infinity, minHeight: 135)
            } else {
                Chart {
                    ForEach(gaps) { gap in
                        if gap.startedAt < timeDomain.upperBound, (gap.endedAt ?? timeDomain.upperBound) > timeDomain.lowerBound {
                            RectangleMark(xStart: .value("Gap start", max(gap.startedAt, timeDomain.lowerBound)),
                                          xEnd: .value("Gap end", min(gap.endedAt ?? timeDomain.upperBound, timeDomain.upperBound)),
                                          yStart: .value("Minimum", domain.lowerBound), yEnd: .value("Maximum", domain.upperBound))
                                .foregroundStyle(.secondary.opacity(0.12))
                                .accessibilityLabel("Recording gap: \(gap.reason.title)")
                        }
                    }
                    ForEach(drawn) { point in
                        if supportsLine {
                            LineMark(x: .value("Time", point.date), y: .value(metric.unit, point.value),
                                     series: .value("Continuous segment", point.segment))
                                .foregroundStyle(Color.accentColor.opacity(0.65))
                                .lineStyle(StrokeStyle(lineWidth: 1.5))
                        }
                        PointMark(x: .value("Time", point.date), y: .value(metric.unit, point.value))
                            .foregroundStyle(Color(nsColor: TMobileCoverageMapDrawing.color(value: point.value, metric: metric)))
                            .symbolSize(point.observationID == selectedPointID ? 55 : supportsLine ? 10 : 28)
                            .accessibilityLabel("\(point.date.formatted(date: .abbreviated, time: .standard)): \(TMobileCoverageMapDrawing.valueText(point.value, metric: metric)), \(TMobileCoverageMapDrawing.quality(value: point.value, metric: metric).label)")
                    }
                    if let selectedDate {
                        RuleMark(x: .value("Selected reading", selectedDate))
                            .foregroundStyle(.primary.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .accessibilityLabel("Selected reading")
                    }
                }
                .chartXScale(domain: timeDomain)
                .chartYScale(domain: domain)
                .chartYAxisLabel(metric.unit)
                .chartLegend(.hidden)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { event in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let frame = geometry[plotFrame]
                                guard frame.contains(event.location),
                                      let date: Date = proxy.value(atX: event.location.x - frame.minX) else { return }
                                selectedObservationID = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.observationID
                            })
                    }
                }
                .frame(height: 150)
                .accessibilityLabel("\(metric.title) over time. Select readings with the readings list.")
            }
            Text("\(drawn.count) of \(points.count) values drawn")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
    }
}
