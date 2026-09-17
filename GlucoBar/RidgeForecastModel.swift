import Foundation

nonisolated enum LinearAlgebra {
    /// Solves a·x = b by Gaussian elimination with partial pivoting. Returns nil when the system is singular.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        guard n > 0, a.count == n, a.allSatisfy({ $0.count == n }) else { return nil }
        var m = a
        var r = b

        for column in 0..<n {
            var pivot = column
            var best = abs(m[column][column])
            for row in (column + 1)..<n where abs(m[row][column]) > best {
                best = abs(m[row][column])
                pivot = row
            }
            guard best > 1e-12 else { return nil }
            if pivot != column {
                m.swapAt(pivot, column)
                r.swapAt(pivot, column)
            }
            let p = m[column][column]
            for row in (column + 1)..<n {
                let factor = m[row][column] / p
                guard factor != 0 else { continue }
                for k in column..<n { m[row][k] -= factor * m[column][k] }
                r[row] -= factor * r[column]
            }
        }

        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = r[row]
            for k in (row + 1)..<n { sum -= m[row][k] * x[k] }
            x[row] = sum / m[row][row]
        }
        return x
    }
}

/// A ridge regression per forecast horizon, trained on the user's own long-term history.
///
/// Features: a constant, the six most recent five-minute changes, the current level, the time of day as
/// sine and cosine, the gap from the typical-day median with a flag for whether a profile existed, and
/// the change the typical-day profile expects over the horizon. The target is the change in mg/dL.
nonisolated struct RidgeForecastModel: Codable, Sendable, Equatable {
    static let lagCount = 6
    static let featureCount = 13

    let weightsByHorizon: [String: [Double]]
    let trainedAt: Date
    let rowCount: Int

    /// Horizon-independent features. `values` holds v(t), v(t−5), …, v(t−30), most recent first.
    static func baseFeatures(values: [Double], date: Date, typical: TypicalDayProfile?, calendar: Calendar) -> [Double]? {
        guard values.count == lagCount + 1 else { return nil }
        return baseFeatures(values: values, minuteOfDay: minuteOfDay(for: date, calendar: calendar), typical: typical)
    }

    static func baseFeatures(values: [Double], minuteOfDay: Int, typical: TypicalDayProfile?) -> [Double]? {
        guard values.count == lagCount + 1 else { return nil }
        var features: [Double] = [1]
        features.reserveCapacity(featureCount)
        for index in 0..<lagCount {
            features.append((values[index] - values[index + 1]) / 10)
        }
        features.append((values[0] - 120) / 50)
        let angle = Double(minuteOfDay) / 1440 * 2 * .pi
        features.append(sin(angle))
        features.append(cos(angle))
        if let typical, let bin = typical.values(atMinuteOfDay: Double(minuteOfDay)) {
            features.append((values[0] - bin.median) / 50)
            features.append(1)
        } else {
            features.append(0)
            features.append(0)
        }
        return features
    }

    /// The typical-day profile's expected change over the horizon, scaled.
    static func drift(minuteOfDay: Int, horizon: Int, typical: TypicalDayProfile?) -> Double {
        guard let typical,
              let now = typical.values(atMinuteOfDay: Double(minuteOfDay)),
              let future = typical.values(atMinuteOfDay: Double((minuteOfDay + horizon) % 1440))
        else { return 0 }
        return (future.median - now.median) / 20
    }

    static func minuteOfDay(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    func predictDelta(base: [Double], date: Date, horizon: Int, typical: TypicalDayProfile?, calendar: Calendar) -> Double? {
        guard let weights = weightsByHorizon[String(horizon)],
              weights.count == Self.featureCount,
              base.count == Self.featureCount - 1
        else { return nil }
        let minute = Self.minuteOfDay(for: date, calendar: calendar)
        let features = base + [Self.drift(minuteOfDay: minute, horizon: horizon, typical: typical)]
        var sum = 0.0
        for index in 0..<weights.count { sum += weights[index] * features[index] }
        return sum
    }

    /// Fits one ridge regression per horizon. Returns nil with too little contiguous history.
    static func train(
        samples: [HistorySample],
        typical: TypicalDayProfile?,
        now: Date,
        calendar: Calendar = .current
    ) -> RidgeForecastModel? {
        guard samples.count >= 800 else { return nil }
        let bin = GlucoseHistoryStore.binSeconds
        var byTime: [Int: Double] = [:]
        byTime.reserveCapacity(samples.count)
        for sample in samples { byTime[sample.t] = sample.v }

        let horizons = GlucosePredictor.horizons
        let n = featureCount
        var xtx = [Double](repeating: 0, count: horizons.count * n * n)
        var xty = [Double](repeating: 0, count: horizons.count * n)
        var rows = 0

        for sample in samples {
            var values: [Double] = [sample.v]
            var complete = true
            for lag in 1...lagCount {
                guard let value = byTime[sample.t - lag * bin] else { complete = false; break }
                values.append(value)
            }
            guard complete else { continue }
            let minute = minuteOfDay(for: sample.date, calendar: calendar)
            guard let base = baseFeatures(values: values, minuteOfDay: minute, typical: typical) else { continue }

            var used = false
            for (horizonIndex, horizon) in horizons.enumerated() {
                guard let future = byTime[sample.t + horizon * 60] else { continue }
                let features = base + [drift(minuteOfDay: minute, horizon: horizon, typical: typical)]
                let y = future - sample.v
                let matrixBase = horizonIndex * n * n
                let vectorBase = horizonIndex * n
                for i in 0..<n {
                    let fi = features[i]
                    guard fi != 0 else { continue }
                    xty[vectorBase + i] += fi * y
                    let rowBase = matrixBase + i * n
                    for j in 0..<n { xtx[rowBase + j] += fi * features[j] }
                }
                used = true
            }
            if used { rows += 1 }
        }
        guard rows >= 500 else { return nil }

        let lambda = max(1.0, 0.002 * Double(rows))
        var weights: [String: [Double]] = [:]
        for (horizonIndex, horizon) in horizons.enumerated() {
            var matrix = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var vector = [Double](repeating: 0, count: n)
            let matrixBase = horizonIndex * n * n
            for i in 0..<n {
                for j in 0..<n { matrix[i][j] = xtx[matrixBase + i * n + j] }
                matrix[i][i] += lambda
                vector[i] = xty[horizonIndex * n + i]
            }
            guard let solved = LinearAlgebra.solve(matrix, vector) else { continue }
            weights[String(horizon)] = solved
        }
        guard weights.count == horizons.count else { return nil }
        return RidgeForecastModel(weightsByHorizon: weights, trainedAt: now, rowCount: rows)
    }
}
