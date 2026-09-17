import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject var service: LibreLinkUpService
    @Environment(\.openWindow) private var openWindow
    @AppStorage("GlucoBarTrendsExpanded") private var trendsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heroSection
            statusRow

            if service.currentReading != nil || !service.graphReadings.isEmpty {
                readingCard
            } else {
                emptyStateCard
            }

            if service.trendsEnabled, !service.historyStore.isEmpty {
                trendsCard
            }

            footerRow
        }
        .padding(12)
        .frame(width: 344)
        .background {
            // The menu bar panel is glass on recent macOS releases, which makes the
            // desktop bleed through. A material layer keeps the content legible.
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(service.menuBarValueText)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: service.menuBarValueText)

                AnimatedTrendArrow(
                    symbol: service.menuBarTrendSymbol,
                    animationID: service.readingUpdateAnimationID
                )
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(service.headlineColor)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current glucose")
            .accessibilityValue("\(service.menuBarValueText) \(service.displayUnitLabel), trend \(service.menuBarTrendSymbol)")

            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayUnitLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let delta = service.deltaText {
                    HStack(spacing: 3) {
                        Text(delta)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        if let interval = service.deltaIntervalText {
                            Text("in \(interval)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityLabel("Change \(delta) in \(service.deltaIntervalText ?? "")")
                }

                if let summary = service.predictionSummary {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8, weight: .semibold))
                        Text(summary.text)
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(predictionColor(for: summary.status))
                    .help("Forecast from your recent readings and history. An estimate, not medical advice.")
                    .accessibilityLabel("Forecast: \(summary.text)")
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)

            refreshControl
        }
        .padding(.horizontal, 2)
    }

    private func predictionColor(for status: GlucoseRangeStatus) -> Color {
        switch status {
        case .low: return LibreLinkUpService.lowColor
        case .high: return LibreLinkUpService.highColor
        case .inRange, .unknown: return .secondary
        }
    }

    @ViewBuilder
    private var refreshControl: some View {
        if service.shouldReconnect {
            Button {
                Task { await service.reconnect() }
            } label: {
                Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(service.isLoading)
        } else {
            Button {
                Task { await service.fetchGlucose() }
            } label: {
                Group {
                    if service.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(!service.canRefresh)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh now (⌘R)")
            .accessibilityLabel("Refresh")
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: 5) {
            Image(systemName: stateIconName)
                .font(.caption2.weight(.semibold))
                .frame(width: 12)

            Text(statusText)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(statusForegroundStyle)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch service.connectionState {
        case .connected:
            let updated = service.lastUpdatedText ?? "Connected"
            return "\(updated) • \(service.sourceDisplayName)"
        case .stale:
            let updated = service.lastUpdatedText ?? "Stale"
            return "Stale • \(updated)"
        default:
            if let detail = service.statusDetail, !detail.isEmpty {
                return "\(service.statusHeadline) • \(detail)"
            }
            return service.statusHeadline
        }
    }

    private var statusForegroundStyle: AnyShapeStyle {
        switch service.connectionState {
        case .connected:
            return AnyShapeStyle(.secondary)
        default:
            return AnyShapeStyle(service.menuStatusColor)
        }
    }

    private var stateIconName: String {
        switch service.connectionState {
        case .signedOut:
            return "person.crop.circle"
        case .signingIn, .refreshing:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return "checkmark.circle"
        case .stale:
            return "exclamationmark.triangle"
        case .error:
            return "exclamationmark.octagon"
        }
    }

    // MARK: - Reading card

    private var readingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("Glucose")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                windowPicker
            }

            ReadingChartView(
                readings: service.graphReadings,
                windowEnd: service.statusTick,
                windowInterval: service.graphWindowInterval,
                formatValue: { service.formattedValue(for: $0) },
                yLabels: service.graphYAxisLabels,
                targetLabels: service.graphTargetLabels,
                bounds: service.graphBounds,
                bandLow: service.targetLowMgDl,
                bandHigh: service.targetHighMgDl,
                rangeLow: service.effectiveLowMgDl,
                rangeHigh: service.effectiveHighMgDl,
                isStale: service.isDataStale,
                prediction: service.activePrediction,
                showPredictionBand: service.predictionBandEnabled,
                rollingAverage: service.rollingAverageSeries,
                typicalDay: service.typicalDayProfile
            )
            .frame(height: 148)

            statsRow

            chartFootnotes
        }
        .padding(12)
        .background(cardBackground)
    }

    @ViewBuilder
    private var chartFootnotes: some View {
        let legend = legendItems
        if legend.isEmpty == false || service.graphCoverageText != nil {
            VStack(alignment: .leading, spacing: 3) {
                if !legend.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(legend, id: \.self) { item in
                            Text(item)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }

                if let coverage = service.graphCoverageText {
                    Label(coverage, systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help("LibreLinkUp only returns the last 12 hours. GlucoBar keeps what it has seen, so the window fills in as it keeps running.")
                }
            }
            .padding(.top, 2)
        }
    }

    private var legendItems: [String] {
        var items: [String] = []
        if service.typicalDayProfile != nil {
            items.append("⋯ Typical day")
        }
        if service.rollingAverageEnabled, !service.rollingAverageSeries.isEmpty {
            let minutes = service.rollingAverageMinutes
            let label = minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
            items.append("— \(label) avg")
        }
        if service.activePrediction != nil {
            items.append("– – Forecast")
        }
        return items
    }

    // MARK: - Trends

    private var trendsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        trendsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(trendsExpanded ? 90 : 0))
                        Text("Trends")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(trendsExpanded ? "Collapse trends" : "Expand trends")

                Spacer(minLength: 0)

                if trendsExpanded {
                    Picker("Period", selection: Binding(
                        get: { service.trendsPeriodDays },
                        set: { service.trendsPeriodDays = $0 }
                    )) {
                        ForEach(LibreLinkUpService.trendsPeriodOptions, id: \.self) { days in
                            Text(LibreLinkUpService.periodTitle(days: days)).tag(days)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if trendsExpanded {
                trendsContent
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    @ViewBuilder
    private var trendsContent: some View {
        if let stats = service.periodStats(days: service.trendsPeriodDays) {
            let tiles = trendTiles(for: stats)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(tiles, id: \.title) { tile in
                    StatTile(title: tile.title, value: tile.value, tint: tile.tint)
                }
            }

            HStack(spacing: 4) {
                Text("\(stats.sampleCount) readings · \(Int((stats.coverage * 100).rounded()))% coverage")
                if stats.coverage < 0.5 {
                    Text("· limited data")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        } else {
            Text("No history for this period yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private struct TrendTile {
        let title: String
        let value: String
        let tint: Color
    }

    private func trendTiles(for stats: PeriodStats) -> [TrendTile] {
        var tiles: [TrendTile] = []
        if let inRange = stats.timeInRangePercent {
            tiles.append(TrendTile(
                title: "In range",
                value: "\(Int(inRange.rounded()))%",
                tint: inRange >= 70 ? LibreLinkUpService.inRangeColor : LibreLinkUpService.highColor
            ))
        }
        if let below = stats.timeBelowPercent {
            tiles.append(TrendTile(
                title: "Below",
                value: "\(Int(below.rounded()))%",
                tint: below > 4 ? LibreLinkUpService.lowColor : .primary
            ))
        }
        if let above = stats.timeAbovePercent {
            tiles.append(TrendTile(
                title: "Above",
                value: "\(Int(above.rounded()))%",
                tint: above > 25 ? LibreLinkUpService.highColor : .primary
            ))
        }
        tiles.append(TrendTile(
            title: "Average",
            value: service.formattedValue(for: stats.meanMgDl),
            tint: chipTint(for: stats.meanMgDl)
        ))
        tiles.append(TrendTile(
            title: "Variability",
            value: "\(Int(stats.variabilityPercent.rounded()))%",
            tint: stats.variabilityPercent > 36 ? LibreLinkUpService.highColor : .primary
        ))
        tiles.append(TrendTile(
            title: "GMI",
            value: String(format: "%.1f%%", stats.gmiPercent),
            tint: .primary
        ))
        if tiles.count < 6 {
            tiles.append(TrendTile(title: "Lowest", value: service.formattedValue(for: stats.minMgDl), tint: chipTint(for: stats.minMgDl)))
            tiles.append(TrendTile(title: "Highest", value: service.formattedValue(for: stats.maxMgDl), tint: chipTint(for: stats.maxMgDl)))
            tiles.append(TrendTile(title: "Readings", value: "\(stats.sampleCount)", tint: .primary))
        }
        return Array(tiles.prefix(6))
    }

    private var windowOptions: [Int] {
        var options = LibreLinkUpService.graphWindowPresets
        if !options.contains(service.graphWindowHours) {
            options.append(service.graphWindowHours)
            options.sort()
        }
        return options
    }

    private var windowPicker: some View {
        Picker("Graph window", selection: Binding(
            get: { service.graphWindowHours },
            set: { service.graphWindowHours = $0 }
        )) {
            ForEach(windowOptions, id: \.self) { hours in
                Text("\(hours)h").tag(hours)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .labelsHidden()
        .fixedSize()
        .help("Hours of history shown in the graph")
    }

    @ViewBuilder
    private var statsRow: some View {
        if let stats = service.windowStats {
            HStack(spacing: 6) {
                if let inRange = stats.timeInRangePercent {
                    StatChip(
                        title: "In range",
                        value: "\(inRange)%",
                        tint: inRange >= 70 ? LibreLinkUpService.inRangeColor : LibreLinkUpService.highColor
                    )
                } else {
                    StatChip(
                        title: "Avg",
                        value: service.formattedValue(for: stats.averageMgDl),
                        tint: .secondary
                    )
                }

                StatChip(
                    title: "Low",
                    value: service.formattedValue(for: stats.lowMgDl),
                    tint: chipTint(for: stats.lowMgDl)
                )

                StatChip(
                    title: "High",
                    value: service.formattedValue(for: stats.highMgDl),
                    tint: chipTint(for: stats.highMgDl)
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Statistics for the \(service.graphWindowLabel.lowercased())")
        }
    }

    private func chipTint(for valueMgDl: Double) -> Color {
        switch service.rangeStatus(for: valueMgDl) {
        case .low, .high, .inRange:
            return service.rangeColor(for: service.rangeStatus(for: valueMgDl))
        case .unknown:
            return .secondary
        }
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No glucose data yet")
                .font(.headline)
            Text(emptyStateMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBackground)
    }

    private var emptyStateMessage: String {
        switch service.connectionState {
        case .signedOut:
            return service.dataSource == .libreLinkUp ? "Sign in through Settings to load your LibreLinkUp readings." : "Enter your Nightscout URL in Settings to load readings."
        case .signingIn:
            return "Waiting for \(service.sourceDisplayName) to return your first reading."
        case .refreshing:
            return "Updating the graph from \(service.sourceDisplayName)."
        case .connected, .stale:
            return "\(service.sourceDisplayName) is connected, but there is no reading to show yet."
        case .error(let message):
            return message
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 0) {
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Open Settings (⌘,)")

            Spacer(minLength: 0)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit GlucoBar (⌘Q)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 2)
    }
}

// MARK: - Stat chip

private struct StatChip: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(tint)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption2)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}

// MARK: - Chart

private struct ReadingChartView: View {
    let readings: [ReadingSample]
    let windowEnd: Date
    let windowInterval: TimeInterval
    let formatValue: (Double) -> String
    let yLabels: (top: String, middle: String, bottom: String)
    let targetLabels: (high: String?, low: String?)
    let bounds: (min: Double, max: Double)
    let bandLow: Double?
    let bandHigh: Double?
    let rangeLow: Double?
    let rangeHigh: Double?
    let isStale: Bool
    let prediction: GlucosePrediction?
    let showPredictionBand: Bool
    let rollingAverage: [AveragedPoint]
    let typicalDay: TypicalDayProfile?

    @State private var hoverPoint: CGPoint?

    private let xAxisHeight: CGFloat = 16
    private let xAxisLabelFontSize: CGFloat = 10.5
    private let xAxisLabelPadding: CGFloat = 6
    private let plotCornerRadius: CGFloat = 10
    private let chartHeight: CGFloat = 126
    private let thresholdGreen = LibreLinkUpService.inRangeColor
    private let thresholdOrange = LibreLinkUpService.highColor
    private let thresholdRed = LibreLinkUpService.lowColor
    private let staleColor = Color.secondary

    private static let hourStyle = Date.FormatStyle(date: .omitted, time: .omitted)
        .hour(.defaultDigits(amPM: .abbreviated))
    private static let clockStyle = Date.FormatStyle(date: .omitted, time: .shortened)

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    RoundedRectangle(cornerRadius: plotCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.primary.opacity(0.06), Color.primary.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    targetBands(in: size)
                    chartGrid(in: size)

                    if let typical = typicalDayPaths(in: size) {
                        typical.band
                            .fill(Color.primary.opacity(0.06))
                        typical.median
                            .stroke(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1.5, 3.5]))
                    }

                    if let fillPath = chartFillPath(in: size) {
                        fillPath
                            .fill(lineGradient(in: size))
                            .opacity(0.18)
                            .mask(verticalFadeMask)
                            .mask(leftEdgeFadeMask)
                    }

                    if let averagePath = rollingAveragePath(in: size) {
                        averagePath
                            .stroke(Color.primary.opacity(0.38), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                            .mask(leftEdgeFadeMask)
                    }

                    if let path = chartPath(in: size) {
                        path
                            .stroke(lineGradient(in: size), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                            .shadow(color: Color.black.opacity(0.12), radius: 2, y: 1)
                            .mask(leftEdgeFadeMask)
                    }

                    if let forecast = predictionPaths(in: size) {
                        if showPredictionBand {
                            forecast.band
                                .fill(Color.secondary.opacity(0.12))
                        }
                        forecast.divider
                            .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        forecast.line
                            .stroke(lineGradient(in: size), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 4]))
                            .opacity(0.9)
                    }

                    if hoverPoint == nil, let last = readings.last {
                        let point = point(for: last, in: size)
                        let color = color(for: last)
                        Circle()
                            .fill(color)
                            .frame(width: 7, height: 7)
                            .shadow(color: color.opacity(0.55), radius: 4)
                            .position(point)
                            .accessibilityLabel("Latest glucose")
                            .accessibilityValue(formatValue(last.valueMgDl))
                    }

                    if let hoverPoint, let sample = nearestReading(toX: hoverPoint.x, in: size) {
                        scrubOverlay(for: sample, in: size)
                    }

                    yAxisLabelsOverlay(in: size)
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        hoverPoint = location
                    case .ended:
                        hoverPoint = nil
                    }
                }
            }
            .frame(height: chartHeight)

            xAxisLabelsView
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Glucose graph")
    }

    // MARK: Colours

    private func color(for reading: ReadingSample) -> Color {
        if isStale { return staleColor }
        if let low = rangeLow, reading.valueMgDl < low { return thresholdRed }
        if let high = rangeHigh, reading.valueMgDl > high { return thresholdOrange }
        if rangeLow == nil && rangeHigh == nil { return .accentColor }
        return thresholdGreen
    }

    /// A vertical gradient that paints the trace orange above the high threshold, green in range,
    /// and red below the low threshold. Falls back to a single colour when no thresholds exist.
    private func lineGradient(in size: CGSize) -> LinearGradient {
        if isStale {
            return LinearGradient(colors: [staleColor, staleColor], startPoint: .top, endPoint: .bottom)
        }
        guard rangeLow != nil || rangeHigh != nil else {
            return LinearGradient(colors: [.accentColor, .accentColor], startPoint: .top, endPoint: .bottom)
        }

        let blend = 0.015
        var stops: [Gradient.Stop] = []

        if let high = rangeHigh {
            let fraction = yFraction(for: high)
            stops.append(.init(color: thresholdOrange, location: 0))
            stops.append(.init(color: thresholdOrange, location: max(0, fraction - blend)))
            stops.append(.init(color: thresholdGreen, location: min(1, fraction + blend)))
        } else {
            stops.append(.init(color: thresholdGreen, location: 0))
        }

        if let low = rangeLow {
            let fraction = yFraction(for: low)
            stops.append(.init(color: thresholdGreen, location: max(0, fraction - blend)))
            stops.append(.init(color: thresholdRed, location: min(1, fraction + blend)))
            stops.append(.init(color: thresholdRed, location: 1))
        } else {
            stops.append(.init(color: thresholdGreen, location: 1))
        }

        let sorted = stops.enumerated().sorted { lhs, rhs in
            lhs.element.location == rhs.element.location ? lhs.offset < rhs.offset : lhs.element.location < rhs.element.location
        }.map(\.element)

        return LinearGradient(stops: sorted, startPoint: .top, endPoint: .bottom)
    }

    /// 0 at the top of the plot, 1 at the bottom.
    private func yFraction(for value: Double) -> Double {
        let range = max(bounds.max - bounds.min, 1)
        let fraction = (bounds.max - value) / range
        return min(max(fraction, 0), 1)
    }

    // MARK: Scrubbing

    private func nearestReading(toX x: CGFloat, in size: CGSize) -> ReadingSample? {
        guard !readings.isEmpty else { return nil }
        var best: ReadingSample?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for reading in readings {
            let distance = abs(xPosition(for: reading.timestamp, in: size.width) - x)
            if distance < bestDistance {
                bestDistance = distance
                best = reading
            }
        }
        return best
    }

    @ViewBuilder
    private func scrubOverlay(for sample: ReadingSample, in size: CGSize) -> some View {
        let point = point(for: sample, in: size)
        let color = color(for: sample)
        let timeText = sample.timestamp.formatted(Self.clockStyle)

        Path { path in
            path.move(to: CGPoint(x: point.x, y: 0))
            path.addLine(to: CGPoint(x: point.x, y: size.height))
        }
        .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: color.opacity(0.5), radius: 3)
            .position(point)

        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text(formatValue(sample.valueMgDl))
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
                Text(timeText)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
            TrianglePointer()
                .fill(.ultraThinMaterial)
                .frame(width: 8, height: 4)
        }
        .position(badgePosition(for: point, in: size))
        .allowsHitTesting(false)
        .accessibilityLabel("Glucose at \(timeText)")
        .accessibilityValue(formatValue(sample.valueMgDl))
    }

    // MARK: Axes

    @ViewBuilder
    private func yAxisLabelsOverlay(in size: CGSize) -> some View {
        let xPosition: CGFloat = 18
        let collisionDistance: CGFloat = 12
        let highY = bandHigh.map { yPosition(for: $0, in: size.height) }
        let lowY = bandLow.map { yPosition(for: $0, in: size.height) }
        let topY: CGFloat = 10
        let bottomY = max(size.height - 10, 10)
        let showTop = !(highY.map { abs($0 - topY) < collisionDistance } ?? false)
            && !(lowY.map { abs($0 - topY) < collisionDistance } ?? false)
        let showBottom = !(lowY.map { abs($0 - bottomY) < collisionDistance } ?? false)
            && !(highY.map { abs($0 - bottomY) < collisionDistance } ?? false)

        ZStack {
            if showTop {
                Text(yLabels.top)
                    .position(x: xPosition, y: topY)
            }

            if showBottom {
                Text(yLabels.bottom)
                    .position(x: xPosition, y: bottomY)
            }

            if let highY, let highLabel = targetLabels.high {
                Text(highLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(thresholdOrange.opacity(0.95))
                    .position(x: xPosition, y: highY)
            }

            if let lowY, let lowLabel = targetLabels.low {
                Text(lowLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(thresholdRed.opacity(0.95))
                    .position(x: xPosition, y: lowY)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
    }

    private var xAxisLabelsView: some View {
        GeometryReader { geometry in
            let labels = xAxisLabels(in: geometry.size.width)

            ZStack(alignment: .topLeading) {
                ForEach(labels) { label in
                    Text(label.text)
                        .font(.system(size: xAxisLabelFontSize, weight: .semibold, design: .default))
                        .lineLimit(1)
                        .position(x: label.x, y: xAxisHeight / 2)
                }
            }
            .foregroundStyle(.secondary)
        }
        .frame(height: xAxisHeight)
    }

    /// Hour boundaries inside the visible window, spaced at a tidy stride (1, 2, 3, 4, 6 or 12 hours)
    /// and aligned to clock hours so that labels read like 6 pm, 9 pm, 12 am rather than odd offsets.
    private var hourTicks: [Date] {
        guard let domain = timeDomain else { return [] }
        let calendar = Calendar.current
        let spanHours = domain.end.timeIntervalSince(domain.start) / 3600
        let strideHours = [1, 2, 3, 4, 6, 12].first(where: { spanHours / Double($0) <= 6.5 }) ?? 12

        guard var current = calendar.dateInterval(of: .hour, for: domain.start)?.start else { return [] }
        if current < domain.start {
            current = calendar.date(byAdding: .hour, value: 1, to: current) ?? current
        }
        // Advance until the hour of day is a multiple of the stride.
        var guardCount = 0
        while calendar.component(.hour, from: current) % strideHours != 0, guardCount < 24 {
            current = calendar.date(byAdding: .hour, value: 1, to: current) ?? current
            guardCount += 1
        }

        var ticks: [Date] = []
        while current <= domain.end {
            ticks.append(current)
            guard let next = calendar.date(byAdding: .hour, value: strideHours, to: current) else { break }
            current = next
        }
        return ticks
    }

    private func xAxisLabels(in width: CGFloat) -> [XAxisLabel] {
        guard width > 0 else { return [] }
        var labels: [XAxisLabel] = []
        var previousMaxX = -CGFloat.greatestFiniteMagnitude

        for tick in hourTicks {
            let text = timeLabel(for: tick)
            let labelWidth = measuredXAxisLabelWidth(text)
            let x = xPosition(for: tick, in: width)
            let minX = x - labelWidth / 2
            let maxX = x + labelWidth / 2
            guard minX >= 0, maxX <= width, minX >= previousMaxX else { continue }
            labels.append(XAxisLabel(date: tick, text: text, x: x, width: labelWidth))
            previousMaxX = maxX
        }
        return labels
    }

    private func measuredXAxisLabelWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: xAxisLabelFontSize, weight: .semibold)
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        return ceil(measured + xAxisLabelPadding)
    }

    private func timeLabel(for date: Date) -> String {
        date.formatted(Self.hourStyle).lowercased()
    }

    // MARK: Masks and backgrounds

    private var leftEdgeFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var verticalFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0.0),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func chartGrid(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let gridColor = Color.secondary.opacity(0.10)
            let lineWidth: CGFloat = 1

            for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
                let y = canvasSize.height * fraction
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y))
                context.stroke(path, with: .color(gridColor), lineWidth: lineWidth)
            }

            for tick in hourTicks {
                let x = xPosition(for: tick, in: canvasSize.width)
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))
                context.stroke(path, with: .color(gridColor), lineWidth: lineWidth)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func targetBands(in size: CGSize) -> some View {
        if bandLow != nil || bandHigh != nil {
            ZStack(alignment: .top) {
                if let high = bandHigh {
                    let highY = clampedYPosition(for: high, in: size.height)

                    Rectangle()
                        .fill(thresholdOrange.opacity(0.08))
                        .frame(height: max(0, min(size.height, highY)))

                    RuleLine(y: highY, color: thresholdOrange.opacity(0.28))
                }

                if let low = bandLow {
                    let lowY = clampedYPosition(for: low, in: size.height)

                    Rectangle()
                        .fill(thresholdRed.opacity(0.08))
                        .frame(height: max(0, size.height - lowY))
                        .padding(.top, max(0, min(size.height, lowY)))

                    RuleLine(y: lowY, color: thresholdRed.opacity(0.28))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: plotCornerRadius, style: .continuous))
            .allowsHitTesting(false)
        }
    }

    // MARK: Overlays

    private func rollingAveragePath(in size: CGSize) -> Path? {
        guard rollingAverage.count >= 2 else { return nil }
        var path = Path()
        for (index, point) in rollingAverage.enumerated() {
            let position = CGPoint(
                x: xPosition(for: point.date, in: max(size.width, 1)),
                y: clampedYPosition(for: point.valueMgDl, in: max(size.height, 1))
            )
            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        return path
    }

    /// The typical-day band and median for every clock time visible in the window.
    private func typicalDayPaths(in size: CGSize) -> (band: Path, median: Path)? {
        guard let typicalDay, let domain = timeDomain else { return nil }
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let step: TimeInterval = 5 * 60

        var band = Path()
        var median = Path()
        var upperSegment: [CGPoint] = []
        var lowerSegment: [CGPoint] = []
        var medianSegment: [CGPoint] = []
        var drewAnything = false

        func flush() {
            if upperSegment.count >= 2 {
                band.move(to: upperSegment[0])
                for point in upperSegment.dropFirst() { band.addLine(to: point) }
                for point in lowerSegment.reversed() { band.addLine(to: point) }
                band.closeSubpath()
                median.move(to: medianSegment[0])
                for point in medianSegment.dropFirst() { median.addLine(to: point) }
                drewAnything = true
            }
            upperSegment.removeAll(keepingCapacity: true)
            lowerSegment.removeAll(keepingCapacity: true)
            medianSegment.removeAll(keepingCapacity: true)
        }

        var date = domain.start
        while date <= domain.end {
            if let values = typicalDay.values(at: date) {
                let x = xPosition(for: date, in: width)
                upperSegment.append(CGPoint(x: x, y: clampedYPosition(for: values.upper, in: height)))
                lowerSegment.append(CGPoint(x: x, y: clampedYPosition(for: values.lower, in: height)))
                medianSegment.append(CGPoint(x: x, y: clampedYPosition(for: values.median, in: height)))
            } else {
                flush()
            }
            date = date.addingTimeInterval(step)
        }
        flush()

        return drewAnything ? (band, median) : nil
    }

    /// The dashed forecast line, its uncertainty band, and the divider between actual and forecast.
    private func predictionPaths(in size: CGSize) -> (line: Path, band: Path, divider: Path)? {
        guard let prediction, !prediction.points.isEmpty else { return nil }
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let startX = xPosition(for: prediction.madeAt, in: width)
        let start = CGPoint(x: startX, y: clampedYPosition(for: prediction.startValueMgDl, in: height))

        var line = Path()
        line.move(to: start)
        for point in prediction.points {
            line.addLine(to: CGPoint(
                x: xPosition(for: point.date, in: width),
                y: clampedYPosition(for: point.valueMgDl, in: height)
            ))
        }

        var band = Path()
        band.move(to: start)
        for point in prediction.points {
            band.addLine(to: CGPoint(
                x: xPosition(for: point.date, in: width),
                y: clampedYPosition(for: point.upperMgDl, in: height)
            ))
        }
        for point in prediction.points.reversed() {
            band.addLine(to: CGPoint(
                x: xPosition(for: point.date, in: width),
                y: clampedYPosition(for: point.lowerMgDl, in: height)
            ))
        }
        band.closeSubpath()

        var divider = Path()
        divider.move(to: CGPoint(x: startX, y: 0))
        divider.addLine(to: CGPoint(x: startX, y: height))

        return (line, band, divider)
    }

    // MARK: Geometry

    private func chartPath(in size: CGSize) -> Path? {
        smoothedPath(in: size, closeToBottom: false)
    }

    private func chartFillPath(in size: CGSize) -> Path? {
        smoothedPath(in: size, closeToBottom: true)
    }

    private func smoothedPath(in size: CGSize, closeToBottom: Bool) -> Path? {
        guard readings.count > 1 else { return nil }

        let plotWidth = max(size.width, 1)
        let plotHeight = max(size.height, 1)
        let pts: [CGPoint] = readings.map { point(for: $0, in: size) }

        var path = Path()
        path.move(to: pts[0])

        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = (i + 2 < pts.count) ? pts[i + 2] : p2

            let tension: CGFloat = 0.5
            let d1 = CGPoint(x: (p2.x - p0.x) * tension, y: (p2.y - p0.y) * tension)
            let d2 = CGPoint(x: (p3.x - p1.x) * tension, y: (p3.y - p1.y) * tension)

            let cp1 = CGPoint(x: p1.x + d1.x / 3.0, y: p1.y + d1.y / 3.0)
            let cp2 = CGPoint(x: p2.x - d2.x / 3.0, y: p2.y - d2.y / 3.0)

            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }

        if closeToBottom, let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: min(last.x, plotWidth), y: plotHeight))
            path.addLine(to: CGPoint(x: max(first.x, 0), y: plotHeight))
            path.closeSubpath()
        }

        return path
    }

    private func point(for reading: ReadingSample, in size: CGSize) -> CGPoint {
        CGPoint(
            x: xPosition(for: reading.timestamp, in: max(size.width, 1)),
            y: yPosition(for: reading.valueMgDl, in: max(size.height, 1))
        )
    }

    private func badgePosition(for point: CGPoint, in size: CGSize) -> CGPoint {
        let x = min(max(44, point.x), size.width - 44)
        let hasRoomAbove = point.y > 34
        let y = hasRoomAbove ? point.y - 20 : point.y + 22
        return CGPoint(x: x, y: min(max(14, y), size.height - 14))
    }

    private func xPosition(for date: Date, in width: CGFloat) -> CGFloat {
        guard let domain = timeDomain else { return 0 }
        let span = max(domain.end.timeIntervalSince(domain.start), 60)
        let progress = date.timeIntervalSince(domain.start) / span
        return CGFloat(progress) * width
    }

    private func yPosition(for value: Double, in height: CGFloat) -> CGFloat {
        let range = max(bounds.max - bounds.min, 1)
        let normalizedValue = (value - bounds.min) / range
        return height - (CGFloat(normalizedValue) * height)
    }

    private func clampedYPosition(for value: Double, in height: CGFloat) -> CGFloat {
        min(max(0, yPosition(for: value, in: height)), height)
    }

    /// The visible time span. It is anchored to the selected window ending now, so the axis stays
    /// stable between refreshes and the latest reading sits just inside the right edge.
    private var timeDomain: (start: Date, end: Date)? {
        guard !readings.isEmpty else { return nil }
        var start = windowEnd.addingTimeInterval(-max(windowInterval, 3600))
        if let first = readings.first?.timestamp, first < start {
            start = first
        }
        var visibleEnd = windowEnd
        if let lastForecast = prediction?.points.last?.date, lastForecast > visibleEnd {
            visibleEnd = lastForecast
        }
        let span = visibleEnd.timeIntervalSince(start)
        let end = visibleEnd.addingTimeInterval(max(span * 0.03, 120))
        return (start, end)
    }

    private struct TrianglePointer: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.closeSubpath()
            return p
        }
    }

    private struct XAxisLabel: Identifiable {
        let date: Date
        let text: String
        let x: CGFloat
        let width: CGFloat

        var id: Date { date }
    }
}

private struct RuleLine: View {
    let y: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: proxy.size.width, y: y))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}
