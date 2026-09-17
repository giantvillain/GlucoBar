import Foundation

/// One step of a forecast.
struct PredictedPoint: Identifiable, Equatable {
    let date: Date
    let valueMgDl: Double
    let lowerMgDl: Double
    let upperMgDl: Double

    var id: Date { date }
}

/// A forecast made from the latest reading.
struct GlucosePrediction: Equatable {
    /// Timestamp of the reading the forecast starts from.
    let madeAt: Date
    let startValueMgDl: Double
    /// Points at five-minute steps, from five minutes after `madeAt`.
    let points: [PredictedPoint]
    /// Relative contribution of each model, for display.
    let modelWeights: [String: Double]

    func point(atMinutes minutes: Int) -> PredictedPoint? {
        points.first { Int(($0.date.timeIntervalSince(madeAt) / 60).rounded()) == minutes }
    }

    /// The forecast trimmed to a shorter horizon.
    func trimmed(toMinutes minutes: Int) -> GlucosePrediction {
        let cutoff = madeAt.addingTimeInterval(TimeInterval(minutes) * 60 + 1)
        return GlucosePrediction(
            madeAt: madeAt,
            startValueMgDl: startValueMgDl,
            points: points.filter { $0.date <= cutoff },
            modelWeights: modelWeights
        )
    }

    /// The first forecast step that leaves the target range, if any.
    func firstCrossing(lowMgDl: Double?, highMgDl: Double?) -> (status: GlucoseRangeStatus, minutes: Int)? {
        for point in points {
            let minutes = Int((point.date.timeIntervalSince(madeAt) / 60).rounded())
            if let low = lowMgDl, point.valueMgDl < low {
                return (.low, minutes)
            }
            if let high = highMgDl, point.valueMgDl > high {
                return (.high, minutes)
            }
        }
        return nil
    }
}

/// Forecasts glucose for the next hour by blending three models and learning which of them to trust.
///
/// * `trend`: a recency-weighted linear fit of the last 20 minutes with a decaying slope.
/// * `momentum`: a quadratic fit of the last 30 minutes, damped harder, which captures turning points.
/// * `pattern`: an analogue search over the long-term history. It finds past moments whose preceding
///   half hour looked like the current one, at a similar glucose level and time of day, and averages
///   what happened next. This is the part that learns from the user's own history.
///
/// Every forecast is scored later against the readings that actually arrived. Each model keeps an
/// exponentially weighted error per horizon, and the blend weights models by the inverse of that error,
/// so the mix adapts to whichever model has recently been right for this person.
@MainActor
final class GlucosePredictor {
    nonisolated static let stepMinutes = 5
    nonisolated static let maximumHorizonMinutes = 60
    nonisolated static let modelNames = ["trend", "momentum", "pattern"]

    private struct PendingForecast {
        let madeAt: Date
        let startValue: Double
        var perModel: [String: [Int: Double]]
        var scoredHorizons: Set<Int> = []
    }

    private struct StoredErrors: Codable {
        var errors: [String: [String: Double]]
        var scoredCount: Int
    }

    /// Exponentially weighted mean absolute error in mg/dL, per model and horizon.
    private var errors: [String: [Int: Double]] = [:]
    private(set) var scoredCount = 0
    private var pending: [PendingForecast] = []
    private let defaultsKey = "GlucoBarPredictorErrors"

    private static let horizons = Array(stride(from: stepMinutes, through: maximumHorizonMinutes, by: stepMinutes))
    private static let defaultError: [String: Double] = ["trend": 9, "momentum": 11, "pattern": 12]
    private static let learningRate = 0.15

    init() {
        load()
    }

    /// Number of forecasts scored so far, useful to show that learning is happening.
    var learnedForecastCount: Int { scoredCount }

    func resetLearning() {
        errors = [:]
        pending = []
        scoredCount = 0
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    // MARK: - Forecasting

    func predict(recent: [GlucoseReading], history: [HistorySample], now: Date) -> GlucosePrediction? {
        let readings = recent.sorted { $0.timestamp < $1.timestamp }
        guard let last = readings.last else { return nil }
        guard now.timeIntervalSince(last.timestamp) <= 12 * 60 else { return nil }

        let window = readings.filter { last.timestamp.timeIntervalSince($0.timestamp) <= 35 * 60 }
        guard window.count >= 3 else { return nil }

        var perModel: [String: [Int: Double]] = [:]
        var spreads: [Int: Double] = [:]

        if let trend = trendModel(window, last: last) { perModel["trend"] = trend }
        if let momentum = momentumModel(window, last: last) { perModel["momentum"] = momentum }
        if let pattern = patternModel(window, last: last, history: history) {
            perModel["pattern"] = pattern.deltas
            spreads = pattern.spread
        }
        guard !perModel.isEmpty else { return nil }

        var points: [PredictedPoint] = []
        var totalWeights: [String: Double] = [:]

        for horizon in Self.horizons {
            var weightedDelta = 0.0
            var weightedError = 0.0
            var weightSum = 0.0
            for (model, deltas) in perModel {
                guard let delta = deltas[horizon] else { continue }
                let error = expectedError(model: model, horizon: horizon)
                let weight = 1.0 / (error + 3.0)
                weightedDelta += delta * weight
                weightedError += error * weight
                weightSum += weight
                totalWeights[model, default: 0] += weight
            }
            guard weightSum > 0 else { continue }

            let delta = weightedDelta / weightSum
            let blendedError = weightedError / weightSum
            // Roughly a 90% band: twice the learned mean absolute error, never narrower than a floor
            // that grows with the horizon, and never narrower than the spread of matched history.
            let baseline = 2.0 + 0.6 * Double(horizon)
            let spread = spreads[horizon] ?? 0
            let halfWidth = max(baseline, blendedError * 2.0, spread)
            let value = clamp(last.valueMgDl + delta)
            points.append(PredictedPoint(
                date: last.timestamp.addingTimeInterval(TimeInterval(horizon) * 60),
                valueMgDl: value,
                lowerMgDl: clamp(value - halfWidth),
                upperMgDl: clamp(value + halfWidth)
            ))
        }
        guard !points.isEmpty else { return nil }

        let weightTotal = totalWeights.values.reduce(0, +)
        let normalizedWeights = totalWeights.mapValues { weightTotal > 0 ? $0 / weightTotal : 0 }

        if !pending.contains(where: { $0.madeAt == last.timestamp }) {
            pending.append(PendingForecast(madeAt: last.timestamp, startValue: last.valueMgDl, perModel: perModel))
            pending.removeAll { last.timestamp.timeIntervalSince($0.madeAt) > 75 * 60 }
        }

        return GlucosePrediction(
            madeAt: last.timestamp,
            startValueMgDl: last.valueMgDl,
            points: points,
            modelWeights: normalizedWeights
        )
    }

    // MARK: - Learning

    /// Scores earlier forecasts against the readings that have since arrived and updates the
    /// per-model error estimates.
    func learn(from readings: [GlucoseReading]) {
        guard !pending.isEmpty, !readings.isEmpty else { return }
        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        var changed = false

        for index in pending.indices {
            let forecast = pending[index]
            for horizon in Self.horizons where !forecast.scoredHorizons.contains(horizon) {
                let target = forecast.madeAt.addingTimeInterval(TimeInterval(horizon) * 60)
                guard let actual = nearestReading(to: target, in: sorted, tolerance: 150) else { continue }
                for (model, deltas) in forecast.perModel {
                    guard let delta = deltas[horizon] else { continue }
                    let predicted = forecast.startValue + delta
                    let error = abs(predicted - actual.valueMgDl)
                    let previous = errors[model]?[horizon] ?? Self.defaultError[model] ?? 10
                    errors[model, default: [:]][horizon] = previous + (error - previous) * Self.learningRate
                }
                pending[index].scoredHorizons.insert(horizon)
                scoredCount += 1
                changed = true
            }
        }

        pending.removeAll { $0.scoredHorizons.count >= Self.horizons.count }
        if changed { save() }
    }

    /// Current expected error for a model at a horizon, in mg/dL.
    func expectedError(model: String, horizon: Int) -> Double {
        if let learned = errors[model]?[horizon] { return learned }
        // Untrained horizons borrow from a neighbour, otherwise fall back to a prior that grows with time.
        if let neighbour = errors[model]?.min(by: { abs($0.key - horizon) < abs($1.key - horizon) }) {
            return neighbour.value * Double(horizon) / Double(max(neighbour.key, 1))
        }
        return (Self.defaultError[model] ?? 10) * Double(horizon) / 30.0
    }

    // MARK: - Models

    /// Recency-weighted linear regression over the last 20 minutes with a slope that decays over time.
    private func trendModel(_ readings: [GlucoseReading], last: GlucoseReading) -> [Int: Double]? {
        let window = readings.filter { last.timestamp.timeIntervalSince($0.timestamp) <= 20 * 60 }
        guard window.count >= 3,
              last.timestamp.timeIntervalSince(window[0].timestamp) >= 8 * 60,
              let slope = weightedSlope(window, last: last, decayMinutes: 10)
        else { return nil }

        let tau = 25.0
        var deltas: [Int: Double] = [:]
        for horizon in Self.horizons {
            deltas[horizon] = slope * tau * (1 - exp(-Double(horizon) / tau))
        }
        return deltas
    }

    /// Quadratic fit over the last 30 minutes, damped so acceleration only shapes the near term.
    private func momentumModel(_ readings: [GlucoseReading], last: GlucoseReading) -> [Int: Double]? {
        let window = readings.filter { last.timestamp.timeIntervalSince($0.timestamp) <= 30 * 60 }
        guard window.count >= 5, last.timestamp.timeIntervalSince(window[0].timestamp) >= 15 * 60 else { return nil }

        let xs = window.map { $0.timestamp.timeIntervalSince(last.timestamp) / 60 }
        let ys = window.map { $0.valueMgDl - last.valueMgDl }
        guard let (b, c) = quadraticFit(xs: xs, ys: ys) else { return nil }

        var deltas: [Int: Double] = [:]
        for horizon in Self.horizons {
            let h = Double(horizon)
            let damping = exp(-h / 30)
            let raw = b * h + 0.5 * c * h * h
            deltas[horizon] = raw * damping
        }
        return deltas
    }

    /// Analogue forecast: find past moments in the long-term history whose preceding half hour
    /// resembled the current one and average their subsequent path.
    private func patternModel(
        _ readings: [GlucoseReading],
        last: GlucoseReading,
        history: [HistorySample]
    ) -> (deltas: [Int: Double], spread: [Int: Double])? {
        let lags = [0, 5, 10, 15, 20, 25, 30]
        guard history.count >= 12 * 24 * 2 else { return nil }

        // Current shape relative to the latest value, sampled at five-minute lags.
        var shape: [Double] = []
        for lag in lags {
            let target = last.timestamp.addingTimeInterval(-TimeInterval(lag) * 60)
            guard let value = interpolatedValue(at: target, in: readings, tolerance: 6 * 60) else { return nil }
            shape.append(value - last.valueMgDl)
        }

        let bin = GlucoseHistoryStore.binSeconds
        var byTime: [Int: Double] = [:]
        byTime.reserveCapacity(history.count)
        for sample in history { byTime[sample.t] = sample.v }

        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.hour, .minute], from: last.timestamp)
        let nowMinute = Double((nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0))
        let lastKey = Int(last.timestamp.timeIntervalSince1970) / bin * bin
        let latestUsable = lastKey - Self.maximumHorizonMinutes * 60

        struct Candidate { let key: Int; let distance: Double }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(64)
        var worstKept = Double.greatestFiniteMagnitude
        let keep = 20

        for sample in history where sample.t <= latestUsable {
            let key = sample.t
            let base = sample.v
            var shapeDistance = 0.0
            var complete = true
            for (index, lag) in lags.enumerated() where index > 0 {
                guard let value = byTime[key - lag * 60] else { complete = false; break }
                let diff = (value - base) - shape[index]
                shapeDistance += diff * diff
            }
            guard complete, byTime[key + Self.maximumHorizonMinutes * 60] != nil else { continue }

            let candidateMinute = Double(calendar.component(.hour, from: sample.date) * 60 + calendar.component(.minute, from: sample.date))
            var clock = abs(candidateMinute - nowMinute)
            clock = min(clock, 1440 - clock)
            let levelDistance = ((base - last.valueMgDl) / 35).squared
            let clockDistance = (clock / 240).squared
            let distance = shapeDistance / (Double(lags.count - 1) * 120) + levelDistance + clockDistance

            if candidates.count < keep {
                candidates.append(Candidate(key: key, distance: distance))
                worstKept = candidates.map(\.distance).max() ?? distance
            } else if distance < worstKept {
                if let worstIndex = candidates.indices.max(by: { candidates[$0].distance < candidates[$1].distance }) {
                    candidates[worstIndex] = Candidate(key: key, distance: distance)
                }
                worstKept = candidates.map(\.distance).max() ?? distance
            }
        }

        let usable = candidates.filter { $0.distance < 3.5 }
        guard usable.count >= 5 else { return nil }

        var deltas: [Int: Double] = [:]
        var spread: [Int: Double] = [:]
        for horizon in Self.horizons {
            var weightedSum = 0.0
            var weightedSquares = 0.0
            var weightSum = 0.0
            for candidate in usable {
                guard let base = byTime[candidate.key], let future = byTime[candidate.key + horizon * 60] else { continue }
                let weight = exp(-candidate.distance)
                let delta = future - base
                weightedSum += delta * weight
                weightedSquares += delta * delta * weight
                weightSum += weight
            }
            guard weightSum > 0 else { continue }
            let mean = weightedSum / weightSum
            let variance = max(0, weightedSquares / weightSum - mean * mean)
            deltas[horizon] = mean
            spread[horizon] = variance.squareRoot()
        }
        return deltas.isEmpty ? nil : (deltas, spread)
    }

    // MARK: - Numeric helpers

    private func weightedSlope(_ readings: [GlucoseReading], last: GlucoseReading, decayMinutes: Double) -> Double? {
        var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for reading in readings {
            let x = reading.timestamp.timeIntervalSince(last.timestamp) / 60
            let y = reading.valueMgDl
            let w = exp(x / decayMinutes)
            sw += w; sx += w * x; sy += w * y; sxx += w * x * x; sxy += w * x * y
        }
        let denominator = sw * sxx - sx * sx
        guard abs(denominator) > 1e-9 else { return nil }
        return (sw * sxy - sx * sy) / denominator
    }

    /// Least-squares fit of y = a + b·x + c·x², returning (b, c).
    private func quadraticFit(xs: [Double], ys: [Double]) -> (Double, Double)? {
        let n = Double(xs.count)
        var sx = 0.0, sx2 = 0.0, sx3 = 0.0, sx4 = 0.0, sy = 0.0, sxy = 0.0, sx2y = 0.0
        for (x, y) in zip(xs, ys) {
            let x2 = x * x
            sx += x; sx2 += x2; sx3 += x2 * x; sx4 += x2 * x2
            sy += y; sxy += x * y; sx2y += x2 * y
        }
        // Solve the 3x3 normal equations with Cramer's rule.
        let m: [[Double]] = [[n, sx, sx2], [sx, sx2, sx3], [sx2, sx3, sx4]]
        let r: [Double] = [sy, sxy, sx2y]
        let det = determinant(m)
        guard abs(det) > 1e-9 else { return nil }
        var mb = m; for i in 0..<3 { mb[i][1] = r[i] }
        var mc = m; for i in 0..<3 { mc[i][2] = r[i] }
        return (determinant(mb) / det, determinant(mc) / det)
    }

    private func determinant(_ m: [[Double]]) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }

    private func interpolatedValue(at date: Date, in readings: [GlucoseReading], tolerance: TimeInterval) -> Double? {
        var before: GlucoseReading?
        var after: GlucoseReading?
        for reading in readings {
            if reading.timestamp <= date { before = reading } else { after = reading; break }
        }
        switch (before, after) {
        case let (b?, a?):
            let span = a.timestamp.timeIntervalSince(b.timestamp)
            guard span > 0 else { return b.valueMgDl }
            guard date.timeIntervalSince(b.timestamp) <= tolerance || a.timestamp.timeIntervalSince(date) <= tolerance else { return nil }
            let fraction = date.timeIntervalSince(b.timestamp) / span
            return b.valueMgDl + (a.valueMgDl - b.valueMgDl) * fraction
        case let (b?, nil):
            return date.timeIntervalSince(b.timestamp) <= tolerance ? b.valueMgDl : nil
        case let (nil, a?):
            return a.timestamp.timeIntervalSince(date) <= tolerance ? a.valueMgDl : nil
        default:
            return nil
        }
    }

    private func nearestReading(to date: Date, in sorted: [GlucoseReading], tolerance: TimeInterval) -> GlucoseReading? {
        var best: GlucoseReading?
        var bestDistance = tolerance
        for reading in sorted {
            let distance = abs(reading.timestamp.timeIntervalSince(date))
            if distance <= bestDistance {
                bestDistance = distance
                best = reading
            } else if reading.timestamp > date {
                break
            }
        }
        return best
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 40), 400)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(StoredErrors.self, from: data)
        else { return }
        for (model, byHorizon) in stored.errors {
            var converted: [Int: Double] = [:]
            for (key, value) in byHorizon {
                if let horizon = Int(key) { converted[horizon] = value }
            }
            errors[model] = converted
        }
        scoredCount = stored.scoredCount
    }

    private func save() {
        var encoded: [String: [String: Double]] = [:]
        for (model, byHorizon) in errors {
            encoded[model] = Dictionary(uniqueKeysWithValues: byHorizon.map { (String($0.key), $0.value) })
        }
        let stored = StoredErrors(errors: encoded, scoredCount: scoredCount)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

private extension Double {
    var squared: Double { self * self }
}
