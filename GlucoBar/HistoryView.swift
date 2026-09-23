import SwiftUI
import Charts

struct HistoryView: View {
    @EnvironmentObject var service: LibreLinkUpService
    @State private var tab = 0
    @State private var end = Date()
    @State private var hours = 24
    @State private var live = true
    @State private var comparisonDays = 7
    @State private var typicalDays = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Glucose history").font(.title2.bold())
                    Text(service.privacyMode ? "Privacy mode" : (service.activePersonName ?? service.sourceDisplayName))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Privacy mode", isOn: $service.privacyMode).toggleStyle(.switch)
                    .fixedSize()
                Button("Export CSV…") { service.exportHistory() }
                    .disabled(service.historyStore.isEmpty || service.privacyMode)
            }
            if service.privacyMode {
                ContentUnavailableView("Readings hidden", systemImage: "eye.slash", description: Text("Turn off privacy mode to view your history."))
            } else {
                Picker("History view", selection: $tab) {
                    Text("Graph").tag(0)
                    Text("Compare periods").tag(1)
                    Text("Typical day").tag(2)
                }.pickerStyle(.segmented)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch tab {
                        case 1: comparison
                        case 2: typicalDay
                        default: graph
                        }
                    }.padding(.vertical, 6)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 780, minHeight: 560)
    }

    private var visibleEnd: Date { live ? service.statusTick : end }
    private var visibleStart: Date { visibleEnd.addingTimeInterval(-Double(hours) * 3600) }
    private var readings: [GlucoseReading] {
        // Use the five-minute archive for browsing, with recent sensor readings taking precedence.
        var bins: [Int: GlucoseReading] = [:]
        for sample in service.historyStore.samples where sample.date >= visibleStart && sample.date <= visibleEnd {
            bins[sample.t] = GlucoseReading(timestamp: sample.date, valueMgDl: sample.v)
        }
        for reading in service.readingHistory where reading.timestamp >= visibleStart && reading.timestamp <= visibleEnd {
            let bin = Int(reading.timestamp.timeIntervalSince1970) / 300 * 300
            bins[bin] = reading
        }
        return bins.values.sorted { $0.timestamp < $1.timestamp }
    }
    private var bounds: (min: Double, max: Double) {
        let values = readings.map(\.valueMgDl) + [service.effectiveLowMgDl, service.effectiveHighMgDl].compactMap { $0 }
        return (max(0, floor(((values.min() ?? 60) - 20) / 20) * 20), ceil(((values.max() ?? 200) + 20) / 20) * 20)
    }

    private var graph: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous time window")
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(live).accessibilityLabel("Next time window")
                DatePicker("Ending", selection: Binding(get: { visibleEnd }, set: { end = $0; live = false }), in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                Button("Now") { live = true }
                Spacer()
                Picker("Zoom", selection: $hours) {
                    ForEach([3, 6, 12, 24, 48, 72], id: \.self) { Text("\($0)h").tag($0) }
                }.frame(width: 150)
            }
            if readings.isEmpty {
                ContentUnavailableView("No readings in this window", systemImage: "chart.xyaxis.line", description: Text("Choose a different date or wait for readings to arrive."))
                    .frame(height: 330)
            } else {
                ReadingChartView(
                    readings: readings, windowEnd: visibleEnd, windowInterval: Double(hours) * 3600,
                    formatValue: { service.formattedValue(for: $0) },
                    yLabels: (service.formattedValue(for: bounds.max), "", service.formattedValue(for: bounds.min)),
                    targetLabels: service.graphTargetLabels, bounds: bounds,
                    bandLow: service.targetLowMgDl, bandHigh: service.targetHighMgDl,
                    rangeLow: service.effectiveLowMgDl, rangeHigh: service.effectiveHighMgDl,
                    isStale: false, prediction: live ? service.activePrediction : nil,
                    showPredictionBand: service.predictionBandEnabled,
                    rollingAverage: service.rollingAverageEnabled ? GlucoseAnalytics.movingAverage(readings, window: Double(service.rollingAverageMinutes) * 60) : [],
                    typicalDay: service.typicalDayOverlayProfile, chartHeight: 320
                ).frame(height: 345)
            }
            Text("\(visibleStart.formatted(date: .abbreviated, time: .shortened)) – \(visibleEnd.formatted(date: .abbreviated, time: .shortened)) · \(service.displayUnitLabel)")
                .font(.caption).foregroundStyle(.secondary)
            Text("Gaps longer than 10 minutes are left blank. Older readings are stored in five-minute bins. This window stays open while you work.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func move(_ direction: Int) {
        let candidate = visibleEnd.addingTimeInterval(Double(direction * hours) * 3600)
        end = min(candidate, .now)
        live = candidate >= Date()
    }

    private var comparison: some View {
        let ranges = GlucoseAnalytics.comparisonRanges(days: comparisonDays, now: service.statusTick)
        let current = stats(from: ranges.currentStart, to: ranges.currentEnd)
        let previous = stats(from: ranges.previousStart, to: ranges.previousEnd)
        return VStack(alignment: .leading, spacing: 20) {
            Picker("Compare", selection: $comparisonDays) {
                Text("Today so far").tag(0)
                Text("Last 7 days").tag(7)
                Text("Last 14 days").tag(14)
                Text("Last 30 days").tag(30)
            }.pickerStyle(.segmented)
            Text(comparisonDays == 0 ? "Today compared with the same part of yesterday" : "Most recent \(comparisonDays) days compared with the preceding \(comparisonDays) days")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 18) {
                GridRow { Text("Metric"); Text("Current"); Text("Previous"); Text("Change") }.fontWeight(.semibold)
                comparisonRow("Coverage", current: current.map { $0.coverage * 100 }, previous: previous.map { $0.coverage * 100 }, unit: "%", differenceUnit: "pp")
                comparisonRow("In range", current: current?.timeInRangePercent, previous: previous?.timeInRangePercent, unit: "%", differenceUnit: "pp")
                comparisonRow("Below range", current: current?.timeBelowPercent, previous: previous?.timeBelowPercent, unit: "%", differenceUnit: "pp")
                comparisonRow("Above range", current: current?.timeAbovePercent, previous: previous?.timeAbovePercent, unit: "%", differenceUnit: "pp")
                comparisonRow("Average", current: current.map { service.useMmolPerL ? $0.meanMgDl / 18 : $0.meanMgDl }, previous: previous.map { service.useMmolPerL ? $0.meanMgDl / 18 : $0.meanMgDl }, unit: service.displayUnitLabel, differenceUnit: service.displayUnitLabel)
                comparisonRow("Variability", current: current?.variabilityPercent, previous: previous?.variabilityPercent, unit: "%", differenceUnit: "pp")
            }
            .monospacedDigit()
            Text("Current: \(ranges.currentStart.formatted()) – \(ranges.currentEnd.formatted())\nPrevious: \(ranges.previousStart.formatted()) – \(ranges.previousEnd.formatted())")
                .font(.caption).foregroundStyle(.secondary)
            Text("Both periods use your current thresholds. Missing readings are excluded; compare coverage before interpreting differences. pp means percentage points.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stats(from start: Date, to end: Date) -> PeriodStats? {
        GlucoseAnalytics.periodStats(samples: service.historyStore.samples, from: start, to: end,
                                     lowMgDl: service.effectiveLowMgDl, highMgDl: service.effectiveHighMgDl)
    }

    private func comparisonRow(_ title: String, current: Double?, previous: Double?, unit: String, differenceUnit: String) -> some View {
        GridRow {
            Text(title)
            Text(current.map { String(format: "%.1f %@", $0, unit) } ?? "—")
            Text(previous.map { String(format: "%.1f %@", $0, unit) } ?? "—")
            Text(current.flatMap { a in previous.map { String(format: "%+.1f %@", a - $0, differenceUnit) } } ?? "—")
                .foregroundStyle(.secondary)
        }
    }

    private struct TypicalPoint: Identifiable {
        let id: Int
        let minute: Double
        let median: Double
        let lower: Double
        let upper: Double
        let segment: Int
    }

    private var typicalDay: some View {
        let samples = service.historyStore.samples(since: service.statusTick.addingTimeInterval(-Double(min(typicalDays, service.historyRetentionDays)) * 86_400))
        let profile = GlucoseAnalytics.typicalDay(samples: samples)
        let points = typicalPoints(profile)
        return VStack(alignment: .leading, spacing: 16) {
            Picker("Lookback", selection: $typicalDays) {
                ForEach(LibreLinkUpService.typicalDayLookbackOptions.filter { $0 <= service.historyRetentionDays }, id: \.self) { Text("\($0) days").tag($0) }
            }.pickerStyle(.segmented)
            if points.isEmpty {
                ContentUnavailableView("More history needed", systemImage: "clock", description: Text("The typical-day view appears as readings accumulate across days."))
            } else {
                Chart(points) { point in
                    AreaMark(x: .value("Minute", point.minute), yStart: .value("Lower quartile", point.lower), yEnd: .value("Upper quartile", point.upper), series: .value("Segment", point.segment))
                        .foregroundStyle(Color.accentColor.opacity(0.15))
                    LineMark(x: .value("Minute", point.minute), y: .value("Median", point.median), series: .value("Segment", point.segment))
                        .foregroundStyle(Color.accentColor)
                }
                .chartXScale(domain: 0...1440)
                .chartXAxis {
                    AxisMarks(values: [0, 360, 720, 1080, 1440]) { value in
                        AxisGridLine()
                        AxisValueLabel { if let minute = value.as(Int.self) { Text(String(format: "%02d:00", minute / 60)) } }
                    }
                }
                .chartYAxisLabel(service.displayUnitLabel)
                .frame(height: 330)
                .accessibilityLabel("Typical daily glucose, median and middle 50 percent of readings")
                Text("\(profile?.dayCount ?? 0) days represented · line: median · shaded area: middle 50% of readings")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Clock times use your Mac’s current time zone. Empty intervals have too little history. The band describes previous readings, not a forecast.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func typicalPoints(_ profile: TypicalDayProfile?) -> [TypicalPoint] {
        guard let profile else { return [] }
        var segment = 0
        return profile.bins.enumerated().compactMap { index, bin in
            guard let bin else { segment += 1; return nil }
            let divisor = service.useMmolPerL ? 18.0 : 1.0
            return TypicalPoint(id: index, minute: (Double(index) + 0.5) * Double(profile.binMinutes),
                                median: bin.median / divisor, lower: bin.lower / divisor, upper: bin.upper / divisor, segment: segment)
        }
    }
}
