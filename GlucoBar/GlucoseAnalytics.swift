import Foundation

/// A point on the rolling-average line.
nonisolated struct AveragedPoint: Identifiable, Equatable {
    let date: Date
    let valueMgDl: Double

    var id: Date { date }
}

/// The median and interquartile band of glucose for each slot of the day, built from long-term history.
nonisolated struct TypicalDayProfile: Equatable, Sendable {
    struct Bin: Equatable, Sendable {
        let median: Double
        let lower: Double
        let upper: Double
        let count: Int
    }

    let binMinutes: Int
    let bins: [Bin?]
    let dayCount: Int

    var binCount: Int { bins.count }

    var hasData: Bool { bins.contains { $0 != nil } }

    /// Values at a given clock time, interpolated between neighbouring bin centres so the overlay
    /// reads as a smooth band rather than steps. Returns nil across gaps with too little history.
    func values(at date: Date, calendar: Calendar = .current) -> Bin? {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minuteOfDay = Double(components.hour ?? 0) * 60 + Double(components.minute ?? 0) + Double(components.second ?? 0) / 60
        return values(atMinuteOfDay: minuteOfDay)
    }

    /// Values at a minute of the day (0 ..< 1440), interpolated between neighbouring bin centres.
    func values(atMinuteOfDay minuteOfDay: Double) -> Bin? {
        guard !bins.isEmpty else { return nil }
        let slot = minuteOfDay / Double(binMinutes) - 0.5
        let lowerIndex = Int(floor(slot))
        let fraction = slot - Double(lowerIndex)
        let count = bins.count
        let first = bins[((lowerIndex % count) + count) % count]
        let second = bins[(((lowerIndex + 1) % count) + count) % count]

        switch (first, second) {
        case let (a?, b?):
            return Bin(
                median: a.median + (b.median - a.median) * fraction,
                lower: a.lower + (b.lower - a.lower) * fraction,
                upper: a.upper + (b.upper - a.upper) * fraction,
                count: min(a.count, b.count)
            )
        case let (a?, nil):
            return fraction < 0.5 ? a : nil
        case let (nil, b?):
            return fraction >= 0.5 ? b : nil
        default:
            return nil
        }
    }
}

/// Summary statistics for a period of history.
nonisolated struct PeriodStats: Equatable {
    let sampleCount: Int
    /// Fraction of the period's five-minute slots that have a reading, 0...1.
    let coverage: Double
    let meanMgDl: Double
    let standardDeviationMgDl: Double
    let minMgDl: Double
    let maxMgDl: Double
    let timeInRangePercent: Double?
    let timeBelowPercent: Double?
    let timeAbovePercent: Double?

    /// Coefficient of variation, the usual measure of glucose variability.
    var variabilityPercent: Double {
        meanMgDl > 0 ? standardDeviationMgDl / meanMgDl * 100 : 0
    }

    /// Glucose Management Indicator, an estimate of HbA1c from the mean glucose.
    var gmiPercent: Double {
        3.31 + 0.02392 * meanMgDl
    }
}

nonisolated enum GlucoseAnalytics {
    struct ComparisonRanges {
        let currentStart: Date
        let currentEnd: Date
        let previousStart: Date
        let previousEnd: Date
    }

    static func comparisonRanges(days: Int, now: Date, calendar: Calendar = .current) -> ComparisonRanges {
        let start = days == 0 ? calendar.startOfDay(for: now) : (calendar.date(byAdding: .day, value: -days, to: now) ?? now)
        let previousEnd = days == 0 ? (calendar.date(byAdding: .day, value: -1, to: now) ?? start) : start
        let previousStart = days == 0 ? calendar.startOfDay(for: previousEnd) : (calendar.date(byAdding: .day, value: -days, to: start) ?? start)
        return ComparisonRanges(currentStart: start, currentEnd: now, previousStart: previousStart, previousEnd: previousEnd)
    }

    /// A trailing moving average of the readings over `window` seconds.
    static func movingAverage(_ readings: [GlucoseReading], window: TimeInterval) -> [AveragedPoint] {
        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2, window > 0 else { return [] }

        var result: [AveragedPoint] = []
        result.reserveCapacity(sorted.count)
        var start = 0
        var sum = 0.0
        var count = 0

        for (index, reading) in sorted.enumerated() {
            if index > 0, reading.timestamp.timeIntervalSince(sorted[index - 1].timestamp) > ReadingSupport.maximumGap {
                start = index
                sum = 0
                count = 0
            }
            sum += reading.valueMgDl
            count += 1
            while start < index, sorted[start].timestamp < reading.timestamp.addingTimeInterval(-window) {
                sum -= sorted[start].valueMgDl
                count -= 1
                start += 1
            }
            // Skip the very first points where the window is mostly empty; they would just trace the raw line.
            let span = reading.timestamp.timeIntervalSince(sorted[start].timestamp)
            guard count >= 3, span >= window * 0.5 else { continue }
            result.append(AveragedPoint(date: reading.timestamp, valueMgDl: sum / Double(count)))
        }
        return result
    }

    /// Builds the typical-day profile from long-term samples.
    static func typicalDay(
        samples: [HistorySample],
        binMinutes: Int = 15,
        minimumCount: Int = 3,
        calendar: Calendar = .current
    ) -> TypicalDayProfile? {
        guard !samples.isEmpty, binMinutes > 0 else { return nil }
        let binCount = max(1, 24 * 60 / binMinutes)
        var buckets = Array(repeating: [Double](), count: binCount)
        var days = Set<Int>()

        for sample in samples {
            let date = sample.date
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            let index = min(binCount - 1, minuteOfDay / binMinutes)
            buckets[index].append(sample.v)
            days.insert((components.year ?? 0) * 10_000 + (components.month ?? 0) * 100 + (components.day ?? 0))
        }

        let bins: [TypicalDayProfile.Bin?] = buckets.map { values in
            guard values.count >= minimumCount else { return nil }
            let sorted = values.sorted()
            return TypicalDayProfile.Bin(
                median: percentile(sorted, 0.5),
                lower: percentile(sorted, 0.25),
                upper: percentile(sorted, 0.75),
                count: sorted.count
            )
        }

        let profile = TypicalDayProfile(binMinutes: binMinutes, bins: bins, dayCount: days.count)
        return profile.hasData ? profile : nil
    }

    /// Statistics for the samples between `start` and `end`.
    static func periodStats(
        samples: [HistorySample],
        from start: Date,
        to end: Date,
        lowMgDl: Double?,
        highMgDl: Double?
    ) -> PeriodStats? {
        let startKey = Int(start.timeIntervalSince1970)
        let endKey = Int(end.timeIntervalSince1970)
        let values = samples.lazy.filter { $0.t >= startKey && $0.t < endKey }.map(\.v)
        let count = values.count
        guard count > 0 else { return nil }

        let mean = values.reduce(0, +) / Double(count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(count - 1, 1))
        let expectedSlots = max(1.0, end.timeIntervalSince(start) / TimeInterval(GlucoseHistoryStore.binSeconds))
        let coverage = min(1.0, Double(count) / expectedSlots)

        var below: Double?
        var above: Double?
        var inRange: Double?
        if lowMgDl != nil || highMgDl != nil {
            let belowCount = lowMgDl.map { low in values.filter { $0 < low }.count } ?? 0
            let aboveCount = highMgDl.map { high in values.filter { $0 > high }.count } ?? 0
            below = lowMgDl == nil ? nil : Double(belowCount) / Double(count) * 100
            above = highMgDl == nil ? nil : Double(aboveCount) / Double(count) * 100
            inRange = Double(count - belowCount - aboveCount) / Double(count) * 100
        }

        return PeriodStats(
            sampleCount: count,
            coverage: coverage,
            meanMgDl: mean,
            standardDeviationMgDl: variance.squareRoot(),
            minMgDl: values.min() ?? mean,
            maxMgDl: values.max() ?? mean,
            timeInRangePercent: inRange,
            timeBelowPercent: below,
            timeAbovePercent: above
        )
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = p * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = min(sorted.count - 1, lower + 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}
