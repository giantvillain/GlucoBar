import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject var service: LibreLinkUpService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerSection

            if service.currentReading != nil || !service.graphReadings.isEmpty {
                readingCard
            } else {
                emptyStateCard
            }

            actionRow
        }
        .padding(10)
        .frame(width: 344)
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: stateIconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(service.menuStatusColor)
                .frame(width: 14)
                .padding(.top, 1)

            Text(headerStatusLine)
                .font(.callout.weight(.semibold))
                .foregroundStyle(service.menuStatusColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 1)
    }

    private var headerStatusLine: String {
        if let detail = service.statusDetail, !detail.isEmpty {
            return "\(service.statusHeadline) • \(detail)"
        }
        return service.statusHeadline
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
        VStack(alignment: .leading, spacing: 8) {
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
                formatValue: { service.formattedValue(for: $0) },
                trendSymbol: { service.trendSymbol(for: $0) },
                readingUpdateAnimationID: service.readingUpdateAnimationID,
                yLabels: service.graphYAxisLabels,
                targetLabels: service.graphTargetLabels,
                bounds: service.graphBounds,
                targetLow: service.targetLowMgDl,
                targetHigh: service.targetHighMgDl,
                lineColor: service.isDataStale ? .orange : .accentColor
            )
            .frame(height: 148)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.10))
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
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.10))
        }
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

    private var summaryText: String {
        "\(service.displayUnitLabel) • \(service.graphReadings.count) • \(service.sourceDisplayName)"
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            .buttonStyle(.bordered)
            .disabled(service.isLoading || !service.hasStoredCredentials)

            HStack(spacing: 6) {
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

private struct ReadingChartView: View {
    let readings: [ReadingSample]
    let formatValue: (Double) -> String
    let trendSymbol: (Int?) -> String?
    let readingUpdateAnimationID: Int
    let yLabels: (top: String, middle: String, bottom: String)
    let targetLabels: (high: String?, low: String?)
    let bounds: (min: Double, max: Double)
    let targetLow: Double?
    let targetHigh: Double?
    let lineColor: Color

    private let xAxisHeight: CGFloat = 16
    private let xAxisLabelFontSize: CGFloat = 10.5
    private let xAxisLabelPadding: CGFloat = 6
    private let plotCornerRadius: CGFloat = 10
    private let chartHeight: CGFloat = 126
    private let thresholdGreen = Color(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0)
    private let thresholdOrange = Color(red: 0xFF / 255.0, green: 0x95 / 255.0, blue: 0x00 / 255.0)
    private let thresholdRed = Color(red: 0xFF / 255.0, green: 0x3B / 255.0, blue: 0x30 / 255.0)

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .init(identifier: "en_US_POSIX")
        formatter.dateFormat = "h a"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    ZStack {
                        RoundedRectangle(cornerRadius: plotCornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.black.opacity(0.06), Color.black.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        targetBands(in: geometry.size)

                        chartGrid(in: geometry.size)

                        if let fillPath = chartFillPath(in: geometry.size) {
                            fillPath
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            lineColor.opacity(0.22),
                                            lineColor.opacity(0.0)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .mask(leftEdgeFadeMask)
                        }

                        if let path = chartPath(in: geometry.size) {
                            path
                                .stroke(lineColor, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                                .shadow(color: lineColor.opacity(0.25), radius: 3, y: 1)
                                .mask(leftEdgeFadeMask)
                        }

                        if let lastPoint = lastPoint(in: geometry.size) {
                            Circle()
                                .fill(lineColor)
                                .frame(width: 7, height: 7)
                                .shadow(color: lineColor.opacity(0.55), radius: 4)
                                .position(lastPoint)

                            if let last = readings.last {
                                let arrow = trendSymbol(last.trendArrow) ?? "→"
                                let label = "\(formatValue(last.valueMgDl)) \(arrow)"
                                VStack(spacing: 2) {
                                    HStack(spacing: 3) {
                                        Text(formatValue(last.valueMgDl))
                                        AnimatedTrendArrow(
                                            symbol: arrow,
                                            animationID: readingUpdateAnimationID
                                        )
                                    }
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                    TrianglePointer()
                                        .fill(.ultraThinMaterial)
                                        .frame(width: 8, height: 4)
                                }
                                .position(latestBadgePosition(for: lastPoint, in: geometry.size))
                                .accessibilityLabel("Latest glucose")
                                .accessibilityValue(label)
                            }
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
                    .foregroundStyle(thresholdOrange.opacity(0.95))
                    .position(x: xPosition, y: yPosition(for: high, in: size.height))
            }

            if let low = targetLow, let lowLabel = targetLabels.low {
                Text(lowLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(thresholdRed.opacity(0.95))
                    .position(x: xPosition, y: yPosition(for: low, in: size.height))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var xAxisLabelsView: some View {
        GeometryReader { geometry in
            let labels = xAxisLabels(in: geometry.size.width)

            ZStack(alignment: .topLeading) {
                ForEach(labels) { label in
                    Text(label.text)
                        .font(.system(size: xAxisLabelFontSize, weight: .semibold, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .position(
                            x: label.x,
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

    private func xAxisLabels(in width: CGFloat) -> [XAxisLabel] {
        let ticks = hourTicks
        guard width > 0, !ticks.isEmpty else { return [] }

        for hourStride in 1...max(ticks.count - 1, 1) {
            let labels = xAxisLabels(from: ticks, hourStride: hourStride, width: width)
            if labelsDoNotOverlap(labels) {
                return labels
            }
        }

        if let last = ticks.last {
            return xAxisLabels(from: [last], hourStride: 1, width: width)
        }

        return []
    }

    private func xAxisLabels(from ticks: [Date], hourStride: Int, width: CGFloat) -> [XAxisLabel] {
        guard !ticks.isEmpty else { return [] }

        var labelDates = ticks.enumerated().compactMap { index, tick in
            index % hourStride == 0 ? tick : nil
        }

        if let last = ticks.last, labelDates.last != last {
            labelDates.append(last)
        }

        return labelDates.map { date in
            let text = timeLabel(for: date)
            let labelWidth = measuredXAxisLabelWidth(text)
            return XAxisLabel(
                date: date,
                text: text,
                x: xAxisLabelPosition(for: date, labelWidth: labelWidth, in: width),
                width: labelWidth
            )
        }
    }

    private func labelsDoNotOverlap(_ labels: [XAxisLabel]) -> Bool {
        guard labels.count > 1 else { return true }

        var previousMaxX = -CGFloat.greatestFiniteMagnitude
        for label in labels.sorted(by: { $0.x < $1.x }) {
            let minX = label.x - label.width / 2
            if minX < previousMaxX {
                return false
            }
            previousMaxX = label.x + label.width / 2
        }

        return true
    }

    private func measuredXAxisLabelWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: xAxisLabelFontSize, weight: .semibold)
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        return ceil(measured + xAxisLabelPadding)
    }

    private func timeLabel(for date: Date) -> String {
        Self.timeFormatter.string(from: date).lowercased()
    }

    private var leftEdgeFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.07),
                .init(color: .black, location: 0.35),
                .init(color: .black, location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
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
    }

    @ViewBuilder
    private func targetBands(in size: CGSize) -> some View {
        if targetLow != nil || targetHigh != nil {
            ZStack(alignment: .top) {
                if let high = targetHigh {
                    let highY = clampedYPosition(for: high, in: size.height)

                    Rectangle()
                        .fill(thresholdOrange.opacity(0.08))
                        .blur(radius: 0.5)
                        .frame(height: max(0, min(size.height, highY)))

                    RuleLine(y: highY, color: thresholdOrange.opacity(0.28))
                }

                if let low = targetLow, let high = targetHigh, high > low {
                    let lowY = clampedYPosition(for: low, in: size.height)
                    let highY = clampedYPosition(for: high, in: size.height)

                    Rectangle()
                        .fill(thresholdGreen.opacity(0.05))
                        .blur(radius: 0.5)
                        .frame(height: max(0, min(size.height, lowY - highY)))
                        .padding(.top, max(0, min(size.height, highY)))
                }

                if let low = targetLow {
                    let lowY = clampedYPosition(for: low, in: size.height)

                    Rectangle()
                        .fill(thresholdRed.opacity(0.08))
                        .blur(radius: 0.5)
                        .frame(height: max(0, size.height - lowY))
                        .padding(.top, max(0, min(size.height, lowY)))

                    RuleLine(y: lowY, color: thresholdRed.opacity(0.28))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: plotCornerRadius, style: .continuous))
        }
    }

    private func chartPath(in size: CGSize) -> Path? {
        smoothedPath(in: size, closeToBottom: false)
    }

    private func chartFillPath(in size: CGSize) -> Path? {
        smoothedPath(in: size, closeToBottom: true)
    }

    private func smoothedPath(in size: CGSize, closeToBottom: Bool) -> Path? {
        guard let domain = timeDomain, readings.count > 1 else { return nil }

        let plotWidth = max(size.width, 1)
        let plotHeight = max(size.height, 1)
        let minValue = bounds.min
        let range = max(bounds.max - bounds.min, 1)
        let timeSpan = max(domain.end.timeIntervalSince(domain.start), 60)

        let pts: [CGPoint] = readings.map { r in
            let xProgress = r.timestamp.timeIntervalSince(domain.start) / timeSpan
            let normalized = (r.valueMgDl - minValue) / range
            let x = CGFloat(xProgress) * plotWidth
            let y = plotHeight - (CGFloat(normalized) * plotHeight)
            return CGPoint(x: x, y: y)
        }

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

    private func latestBadgePosition(for point: CGPoint, in size: CGSize) -> CGPoint {
        let x = min(max(24, point.x), size.width - 24)
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

    private func xAxisLabelPosition(for date: Date, labelWidth: CGFloat, in width: CGFloat) -> CGFloat {
        let rawX = xPosition(for: date, in: width)
        guard width > labelWidth else { return width / 2 }

        let halfWidth = labelWidth / 2
        return min(max(halfWidth, rawX), width - halfWidth)
    }

    private func yPosition(for value: Double, in height: CGFloat) -> CGFloat {
        let range = max(bounds.max - bounds.min, 1)
        let normalizedValue = (value - bounds.min) / range
        return height - (CGFloat(normalizedValue) * height)
    }

    private func clampedYPosition(for value: Double, in height: CGFloat) -> CGFloat {
        min(max(0, yPosition(for: value, in: height)), height)
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
