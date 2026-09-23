import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject var service: LibreLinkUpService
    @Environment(\.openWindow) private var openWindow
    @AppStorage("GlucoBarTrendsExpanded") private var trendsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if service.privacyMode {
                Label("Privacy mode is on", systemImage: "eye.slash").font(.headline)
                Text("Glucose readings are hidden while you share your screen.").font(.caption).foregroundStyle(.secondary)
                Toggle("Privacy mode", isOn: $service.privacyMode)
            } else {
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
            .accessibilityValue("\(service.menuBarValueText) \(service.displayUnitLabel), trend \(service.trendDescription)")

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
                if service.predictionEnabled {
                    Text(service.forecastStatusText).font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(2).help(service.forecastStatusText)
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
                .help(statusText)
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
            return "\(updated) • \(service.activePersonName ?? service.sourceDisplayName)"
        case .stale:
            let updated = service.lastUpdatedText ?? "Stale"
            return "Stale • \(updated)"
        default:
            if let detail = service.statusDetail, !detail.isEmpty {
                return [service.connectionIssue ?? service.statusHeadline, detail, service.retryText].compactMap { $0 }.joined(separator: " • ")
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
                typicalDay: service.typicalDayOverlayProfile
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
        if service.typicalDayOverlayProfile != nil {
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
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            } label: { Label("History", systemImage: "chart.xyaxis.line") }
            .help("Open larger graph, comparisons and typical day")

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
