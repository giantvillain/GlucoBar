import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject var service: LibreLinkUpService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection

            if service.currentReading != nil || !service.graphReadings.isEmpty {
                readingCard
            } else {
                emptyStateCard
            }

            actionRow
        }
        .padding(12)
        .frame(width: 356)
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: stateIconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(service.menuStatusColor)
                    .frame(width: 14)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(service.statusHeadline)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(service.menuStatusColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail = service.statusDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rangeGrid
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
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

    private var readingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Glucose")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text(summaryText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ReadingChartView(
                readings: service.graphReadings,
                yLabels: service.graphYAxisLabels,
                targetLabels: service.graphTargetLabels,
                bounds: service.graphBounds,
                targetLow: service.targetLowMgDl,
                targetHigh: service.targetHighMgDl,
                lineColor: service.isDataStale ? .orange : .accentColor
            )
            .frame(height: 150)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.16))
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
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.12))
        }
    }

    private var emptyStateMessage: String {
        switch service.connectionState {
        case .signedOut:
            return "Sign in in Settings to load your LibreLinkUp readings."
        case .signingIn:
            return "Waiting for LibreLinkUp to return your first reading."
        case .refreshing:
            return "Updating the graph from LibreLinkUp."
        case .connected, .stale:
            return "LibreLinkUp is connected, but there is no reading to show yet."
        case .error(let message):
            return message
        }
    }

    private var summaryText: String {
        "\(service.displayUnitLabel) • \(service.graphReadings.count) samples"
    }

    private var rangeGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 6),
                GridItem(.flexible(), spacing: 6)
            ],
            spacing: 6
        ) {
            ForEach(GraphRange.allCases) { range in
                Button {
                    service.graphRange = range
                } label: {
                    Text(range.title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GraphRangeButtonStyle(isSelected: service.graphRange == range))
            }
        }
        .frame(width: 156)
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    if service.shouldReconnect {
                        await service.reconnect()
                    } else {
                        await service.fetchGlucose()
                    }
                }
            } label: {
                Label(service.primaryActionTitle, systemImage: service.primaryActionSymbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(service.isLoading || !service.hasStoredCredentials)

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
    }
}

private struct GraphRangeButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.vertical, 6)
            .padding(.horizontal, 7)
            .foregroundStyle(isSelected ? .white : .primary)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.white.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(isSelected ? 0 : 0.08), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct ReadingChartView: View {
    let readings: [ReadingSample]
    let yLabels: (top: String, middle: String, bottom: String)
    let targetLabels: (high: String?, low: String?)
    let bounds: (min: Double, max: Double)
    let targetLow: Double?
    let targetHigh: Double?
    let lineColor: Color

    private let xAxisHeight: CGFloat = 18
    private let plotCornerRadius: CGFloat = 12
    private let chartHeight: CGFloat = 110

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .init(identifier: "en_US_POSIX")
        formatter.dateFormat = "h"
        return formatter
    }

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    ZStack {
                        RoundedRectangle(cornerRadius: plotCornerRadius, style: .continuous)
                            .fill(Color.black.opacity(0.08))

                        targetBands(in: geometry.size)

                        chartGrid(in: geometry.size)

                        if let fillPath = chartFillPath(in: geometry.size) {
                            fillPath
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            lineColor.opacity(0.18),
                                            lineColor.opacity(0.02)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }

                        if let path = chartPath(in: geometry.size) {
                            path
                                .stroke(lineColor, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        }

                        if let lastPoint = lastPoint(in: geometry.size) {
                            Circle()
                                .fill(lineColor)
                                .frame(width: 6, height: 6)
                                .position(lastPoint)
                        }

                        yAxisLabelsOverlay(in: geometry.size)
                    }
                }
                .frame(height: chartHeight)

                xAxisLabelsView
            }
        }
    }

    @ViewBuilder
    private func yAxisLabelsOverlay(in size: CGSize) -> some View {
        let xPosition: CGFloat = 18

        ZStack {
            Text(yLabels.top)
                .position(x: xPosition, y: 10)

            Text(yLabels.bottom)
                .position(x: xPosition, y: max(size.height - 10, 10))

            if let high = targetHigh, let highLabel = targetLabels.high {
                Text(highLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange.opacity(0.95))
                    .position(x: xPosition, y: yPosition(for: high, in: size.height))
            }

            if let low = targetLow, let lowLabel = targetLabels.low {
                Text(lowLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red.opacity(0.95))
                    .position(x: xPosition, y: yPosition(for: low, in: size.height))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var xAxisLabelsView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(hourTicks.dropFirst().enumerated()), id: \.offset) { index, tick in
                    Text(timeFormatter.string(from: tick))
                        .font(.system(size: 10.5, weight: .semibold, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .position(
                            x: xPosition(for: tick, in: geometry.size.width, labelCount: hourTicks.count, index: index),
                            y: xAxisHeight / 2
                        )
                }
            }
            .foregroundStyle(.secondary)
        }
        .frame(height: xAxisHeight)
    }

    private var hourTicks: [Date] {
        guard let first = readings.first, let last = readings.last else { return [] }
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .hour, for: first.timestamp)?.start ?? first.timestamp
        let end = calendar.dateInterval(of: .hour, for: last.timestamp)?.end ?? last.timestamp

        var ticks: [Date] = []
        var current = start
        while current <= end {
            ticks.append(current)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: current) else { break }
            current = next
        }

        return ticks
    }

    private func chartGrid(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let gridColor = Color.white.opacity(0.08)
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
    }

    @ViewBuilder
    private func targetBands(in size: CGSize) -> some View {
        if let low = targetLow, let high = targetHigh, high > low {
            let lowY = yPosition(for: low, in: size.height)
            let highY = yPosition(for: high, in: size.height)

            ZStack(alignment: .top) {
                if highY > 0 {
                    Rectangle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(height: max(0, min(size.height, highY)))
                }

                Rectangle()
                    .fill(Color.green.opacity(0.08))
                    .frame(height: max(0, min(size.height, lowY - highY)))
                    .padding(.top, max(0, min(size.height, highY)))

                if lowY < size.height {
                    Rectangle()
                        .fill(Color.red.opacity(0.12))
                        .frame(height: max(0, size.height - lowY))
                        .padding(.top, max(0, min(size.height, lowY)))
                }

                RuleLine(y: highY, color: .orange.opacity(0.35))
                RuleLine(y: lowY, color: .red.opacity(0.35))
            }
            .clipShape(RoundedRectangle(cornerRadius: plotCornerRadius, style: .continuous))
        }
    }

    private func chartPath(in size: CGSize) -> Path? {
        guard readings.count > 1 else { return nil }
        return path(in: size, closeToBottom: false)
    }

    private func chartFillPath(in size: CGSize) -> Path? {
        guard readings.count > 1 else { return nil }
        return path(in: size, closeToBottom: true)
    }

    private func path(in size: CGSize, closeToBottom: Bool) -> Path? {
        guard let domain = timeDomain else { return nil }

        let plotWidth = max(size.width, 1)
        let plotHeight = max(size.height, 1)
        let minValue = bounds.min
        let range = max(bounds.max - bounds.min, 1)
        let timeSpan = max(domain.end.timeIntervalSince(domain.start), 60)

        var path = Path()
        for (index, reading) in readings.enumerated() {
            let xProgress = reading.timestamp.timeIntervalSince(domain.start) / timeSpan
            let normalizedValue = (reading.valueMgDl - minValue) / range
            let x = CGFloat(xProgress) * plotWidth
            let y = plotHeight - (CGFloat(normalizedValue) * plotHeight)
            let point = CGPoint(x: x, y: y)

            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        if closeToBottom {
            path.addLine(to: CGPoint(x: plotWidth, y: plotHeight))
            path.addLine(to: CGPoint(x: 0, y: plotHeight))
            path.closeSubpath()
        }

        return path
    }

    private func lastPoint(in size: CGSize) -> CGPoint? {
        guard let domain = timeDomain, let reading = readings.last else { return nil }
        let plotWidth = max(size.width, 1)
        let plotHeight = max(size.height, 1)
        let range = max(bounds.max - bounds.min, 1)
        let normalizedValue = (reading.valueMgDl - bounds.min) / range
        let timeSpan = max(domain.end.timeIntervalSince(domain.start), 60)
        let xProgress = reading.timestamp.timeIntervalSince(domain.start) / timeSpan
        let x = CGFloat(xProgress) * plotWidth
        let y = plotHeight - (CGFloat(normalizedValue) * plotHeight)
        return CGPoint(x: x, y: y)
    }

    private func xPosition(for date: Date, in width: CGFloat, labelCount: Int? = nil, index: Int? = nil) -> CGFloat {
        guard let domain = timeDomain else { return 0 }
        let span = max(domain.end.timeIntervalSince(domain.start), 60)
        let progress = date.timeIntervalSince(domain.start) / span
        let rawX = CGFloat(progress) * width

        guard let labelCount, let index else { return rawX }

        let inset: CGFloat = 8
        if labelCount <= 1 {
            return width / 2
        }
        if index == 0 {
            return max(inset, rawX)
        }
        if index == labelCount - 1 {
            return min(width - inset, rawX)
        }
        return rawX
    }

    private func yPosition(for value: Double, in height: CGFloat) -> CGFloat {
        let range = max(bounds.max - bounds.min, 1)
        let normalizedValue = (value - bounds.min) / range
        return height - (CGFloat(normalizedValue) * height)
    }

    private var timeDomain: (start: Date, end: Date)? {
        guard let first = readings.first, let last = readings.last else { return nil }
        let start = first.timestamp
        var end = last.timestamp
        if end <= start {
            end = start.addingTimeInterval(3600)
        } else {
            let padding = max(end.timeIntervalSince(start) * 0.08, 300)
            end = end.addingTimeInterval(padding)
        }
        return (start, end)
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
