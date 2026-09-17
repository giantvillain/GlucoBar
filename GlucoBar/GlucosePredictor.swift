import Foundation

/// One step of a forecast.
nonisolated struct PredictedPoint: Identifiable, Equatable {
    let date: Date
    let valueMgDl: Double
    let lowerMgDl: Double
    let upperMgDl: Double

    var id: Date { date }
}

/// A forecast made from the latest reading.
nonisolated struct GlucosePrediction: Equatable {
    /// Timestamp of the reading the forecast starts from.
    let madeAt: Date
    let startValueMgDl: Double
    /// Points at five-minute steps, from five minutes after `madeAt`.
    let points: [PredictedPoint]
    /// Relative contribution of each model, averaged over the horizons, for display.
    let modelWeights: [String: Double]
    /// The regime the forecast was made in, for display.
    let regime: String

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
            modelWeights: modelWeights,
            regime: regime
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

/// Forecasts glucose for the next hour by blending several models and learning how to blend them.
///
/// Models, each producing a change from the current value at every five-minute horizon:
/// * `trend`: recency-weighted linear fit of the last 20 minutes with a decaying slope, sanity-checked
///   against the sensor's own trend arrow.
/// * `momentum`: damped quadratic fit of the last 30 minutes, which captures turning points.
/// * `arrow`: extrapolation of the sensor trend arrow's rate.
/// * `pattern`: analogue search over long-term history for moments whose preceding half hour looked
///   like now, at a similar level and time of day, averaging what happened next.
/// * `ridge`: a ridge regression trained on the user's own history (see `RidgeForecastModel`).
/// * `drift`: the expected change at this clock time from the typical-day profile, with mild reversion.
/// * `naive`: no change, the baseline every other model has to beat.
///
/// Learning. Every forecast is scored later against the readings that actually arrived, per regime
/// (rising, stable or falling, by day or night). Each model keeps an error and a signed bias per regime
/// and horizon; the bias is subtracted before blending. Blend weights come from an online least-squares
/// stack, regularised toward inverse-error weights until enough data has accumulated. The band around the
/// forecast tracks the empirical 5th and 95th percentiles of the blend's residuals per horizon, so it is
/// asymmetric and calibrated to about 90% coverage.
nonisolated final class GlucosePredictor {
    nonisolated static let stepMinutes = 5
    nonisolated static let maximumHorizonMinutes = 60
    /// Model order is fixed because the stacking matrices index by position.
    nonisolated static let modelNames = ["trend", "momentum", "arrow", "pattern", "ridge", "drift", "naive"]
    nonisolated static let displayHorizons = [15, 30, 60]
    nonisolated static let horizons = Array(stride(from: stepMinutes, through: maximumHorizonMinutes, by: stepMinutes))

    nonisolated static func title(forModel model: String) -> String {
        switch model {
        case "trend": return "Trend fit"
        case "momentum": return "Momentum fit"
        case "arrow": return "Trend arrow"
        case "pattern": return "History match"
        case "ridge": return "Learned regression"
        case "drift": return "Typical-day drift"
        case "naive": return "No change"
        case "ensemble": return "Forecast (blend)"
        default: return model
        }
    }

    enum Regime: String, CaseIterable, Codable {
        case risingDay, stableDay, fallingDay, risingNight, stableNight, fallingNight

        static func classify(slopePerMinute: Double, date: Date, calendar: Calendar) -> Regime {
            let hour = calendar.component(.hour, from: date)
            let night = hour >= 22 || hour < 6
            if slopePerMinute >= 0.6 { return night ? .risingNight : .risingDay }
            if slopePerMinute <= -0.6 { return night ? .fallingNight : .fallingDay }
            return night ? .stableNight : .stableDay
        }

        var title: String {
            switch self {
            case .risingDay: return "rising, daytime"
            case .stableDay: return "stable, daytime"
            case .fallingDay: return "falling, daytime"
            case .risingNight: return "rising, night"
            case .stableNight: return "stable, night"
            case .fallingNight: return "falling, night"
            }
        }
    }

    struct AccuracyRow: Equatable {
        let model: String
        let title: String
        /// Mean absolute error in mg/dL by horizon.
        let maeByHorizon: [Int: Double]
        let count: Int
    }

    // MARK: Learned state

    private struct ErrorStats: Codable {
        var absError: Double
        var bias: Double
        /// Mean of the squared signed error, to estimate the noise around the bias.
        var squared: Double?
        var count: Int
    }

    private struct StackState: Codable {
        var a: [Double]
        var b: [Double]
        var n: Double
    }

    private struct BandState: Codable {
        var lower: Double
        var upper: Double
        var coverage: Double
        var count: Int
    }

    private struct AccuracyCell: Codable {
        var sum: Double
        var count: Int
    }

    private struct StoredLearning: Codable {
        var errorStats: [String: ErrorStats]
        var stacks: [String: StackState]
        var bands: [String: BandState]
        var daily: [String: [String: AccuracyCell]]
        var scoredCount: Int
    }

    private struct PendingForecast {
        let madeAt: Date
        let startValue: Double
        let regime: Regime
        let rawDeltas: [String: [Int: Double]]
        let correctedDeltas: [String: [Int: Double]]
        let ensembleDeltas: [Int: Double]
        let rawBlendDeltas: [Int: Double]
        let bandLower: [Int: Double]
        let bandUpper: [Int: Double]
        var scored: Set<Int> = []
    }

    private var errorStats: [String: ErrorStats] = [:]
    private var stacks: [String: StackState] = [:]
    private var bands: [String: BandState] = [:]
    private var daily: [String: [String: AccuracyCell]] = [:]
    private(set) var scoredCount = 0
    private var pending: [PendingForecast] = []

    /// Regression trained on the user's history. Set by whoever owns the predictor.
    var ridgeModel: RidgeForecastModel?

    private let persists: Bool
    private let dailyLogLimit: Int
    private let defaultsKey = "GlucoBarPredictorLearningV2"
    private var lastSave: Date = .distantPast
    private var dirty = false

    private static let defaultError: [String: Double] = [
        "trend": 9, "momentum": 11, "arrow": 10, "pattern": 12, "ridge": 9, "drift": 13, "naive": 12, "ensemble": 9
    ]
    private static let errorLearningRate = 0.15
    private static let stackForgetting = 0.9997
    private static let calendar = Calendar.current

    /// Knobs that the backtest harness sweeps. The defaults are the values that did best on replayed data.
    struct Tuning {
        /// Subtract each model's learned signed bias before blending.
        var biasCorrection = true
        /// Subtract the blend's own learned bias from the final forecast instead of, or as well as, per model.
        var ensembleBiasCorrection = false
        /// How quickly the signed bias follows recent errors once enough samples exist. Consecutive forecasts
        /// are highly correlated, so this must be slow or the "bias" just echoes the last few minutes' noise.
        /// Until 1/rate samples have been seen the estimate is a plain running mean.
        var biasLearningRate = 0.002
        /// A bias is only applied beyond this many standard errors, so noise is never "corrected".
        var biasSignificance = 2.0
        /// Force the stacked weights to sum to one. Off lets the stack scale up models that are too timid.
        var renormalizeStack = false
        /// Allowed range for the sum of stacked weights when not renormalising.
        var stackSumRange: ClosedRange<Double> = 0.5...1.5
        /// Ridge pull toward the inverse-error prior, as a fraction of the mean diagonal of the normal equations.
        var stackShrink = 0.02
    }
    nonisolated(unsafe) static var tuning = Tuning()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(persists: Bool = true, dailyLogLimit: Int = 8) {
        self.persists = persists
        self.dailyLogLimit = dailyLogLimit
        if persists {
            load()
        }
    }

    /// Number of forecast horizons scored so far.
    var learnedForecastCount: Int { scoredCount }

    func resetLearning() {
        errorStats = [:]
        stacks = [:]
        bands = [:]
        daily = [:]
        pending = []
        scoredCount = 0
        dirty = false
        if persists {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    // MARK: - Forecasting

    func predict(
        recent: [GlucoseReading],
        history: [HistorySample],
        typicalDay: TypicalDayProfile?,
        now: Date
    ) -> GlucosePrediction? {
        let readings = recent.sorted { $0.timestamp < $1.timestamp }
        guard let last = readings.last else { return nil }
        guard now.timeIntervalSince(last.timestamp) <= 12 * 60 else { return nil }

        let window = readings.filter { last.timestamp.timeIntervalSince($0.timestamp) <= 35 * 60 }
        guard window.count >= 3 else { return nil }

        let arrow = trendArrow(in: window, last: last)
        let regimeSlope = weightedSlope(
            window.filter { last.timestamp.timeIntervalSince($0.timestamp) <= 15 * 60 },
            last: last,
            decayMinutes: 8
        ) ?? arrow?.center ?? 0
        let regime = Regime.classify(slopePerMinute: regimeSlope, date: last.timestamp, calendar: Self.calendar)

        var raw: [String: [Int: Double]] = [:]
        if let trend = trendModel(window, last: last, arrow: arrow) { raw["trend"] = trend }
        if let momentum = momentumModel(window, last: last) { raw["momentum"] = momentum }
        if let arrowDeltas = arrowModel(arrow) { raw["arrow"] = arrowDeltas }
        if let pattern = patternModel(window, last: last, history: history) { raw["pattern"] = pattern }
        if let ridge = ridgeDeltas(window, last: last, typicalDay: typicalDay) { raw["ridge"] = ridge }
        if let drift = driftModel(last: last, typicalDay: typicalDay) { raw["drift"] = drift }
        raw["naive"] = Dictionary(uniqueKeysWithValues: Self.horizons.map { ($0, 0.0) })
        guard raw.count > 1 else { return nil }

        var corrected: [String: [Int: Double]] = [:]
        var ensembleDeltas: [Int: Double] = [:]
        var rawBlendDeltas: [Int: Double] = [:]
        var bandLower: [Int: Double] = [:]
        var bandUpper: [Int: Double] = [:]
        var weightTotals: [String: Double] = [:]
        var points: [PredictedPoint] = []

        for horizon in Self.horizons {
            var available: [String: Double] = [:]
            for (model, deltas) in raw {
                guard let delta = deltas[horizon] else { continue }
                let fixed = Self.tuning.biasCorrection ? delta - bias(model: model, regime: regime, horizon: horizon) : delta
                available[model] = fixed
                corrected[model, default: [:]][horizon] = fixed
            }
            guard !available.isEmpty else { continue }

            let weights = blendWeights(available: available, regime: regime, horizon: horizon)
            var delta = 0.0
            for (model, weight) in weights {
                delta += weight * (available[model] ?? 0)
                weightTotals[model, default: 0] += weight
            }
            rawBlendDeltas[horizon] = delta
            if Self.tuning.ensembleBiasCorrection {
                delta -= bias(model: "blendraw", regime: regime, horizon: horizon)
            }

            let value = clamp(last.valueMgDl + delta)
            let offsets = bandOffsets(regime: regime, horizon: horizon)
            let lower = clamp(value + offsets.lower)
            let upper = clamp(value + offsets.upper)
            ensembleDeltas[horizon] = delta
            bandLower[horizon] = lower
            bandUpper[horizon] = upper
            points.append(PredictedPoint(
                date: last.timestamp.addingTimeInterval(TimeInterval(horizon) * 60),
                valueMgDl: value,
                lowerMgDl: lower,
                upperMgDl: upper
            ))
        }
        guard !points.isEmpty else { return nil }

        let weightSum = weightTotals.values.reduce(0, +)
        let normalizedWeights = weightTotals.mapValues { weightSum > 0 ? $0 / weightSum : 0 }

        if !pending.contains(where: { $0.madeAt == last.timestamp }) {
            pending.append(PendingForecast(
                madeAt: last.timestamp,
                startValue: last.valueMgDl,
                regime: regime,
                rawDeltas: raw,
                correctedDeltas: corrected,
                ensembleDeltas: ensembleDeltas,
                rawBlendDeltas: rawBlendDeltas,
                bandLower: bandLower,
                bandUpper: bandUpper
            ))
            pending.removeAll { last.timestamp.timeIntervalSince($0.madeAt) > 75 * 60 }
        }

        return GlucosePrediction(
            madeAt: last.timestamp,
            startValueMgDl: last.valueMgDl,
            points: points,
            modelWeights: normalizedWeights,
            regime: regime.title
        )
    }

    // MARK: - Learning

    /// Scores earlier forecasts against the readings that have since arrived.
    func learn(from readings: [GlucoseReading]) {
        guard !pending.isEmpty, !readings.isEmpty else { return }
        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        var changed = false

        for index in pending.indices {
            let forecast = pending[index]
            let dayKey = Self.dayFormatter.string(from: forecast.madeAt)
            for horizon in Self.horizons where !forecast.scored.contains(horizon) {
                let target = forecast.madeAt.addingTimeInterval(TimeInterval(horizon) * 60)
                guard let actual = nearestReading(to: target, in: sorted, tolerance: 150) else { continue }
                let actualDelta = actual.valueMgDl - forecast.startValue
                let regimeKeys = [forecast.regime.rawValue, "all"]

                for (model, deltas) in forecast.rawDeltas {
                    guard let delta = deltas[horizon] else { continue }
                    let signed = delta - actualDelta
                    for regimeKey in regimeKeys {
                        updateErrorStats(model: model, regimeKey: regimeKey, horizon: horizon, signedError: signed)
                    }
                    logAccuracy(day: dayKey, model: model, horizon: horizon, value: abs(signed))
                }

                if let rawBlend = forecast.rawBlendDeltas[horizon] {
                    for regimeKey in regimeKeys {
                        updateErrorStats(model: "blendraw", regimeKey: regimeKey, horizon: horizon, signedError: rawBlend - actualDelta)
                    }
                }

                if let ensembleDelta = forecast.ensembleDeltas[horizon] {
                    let signed = ensembleDelta - actualDelta
                    for regimeKey in regimeKeys {
                        updateErrorStats(model: "ensemble", regimeKey: regimeKey, horizon: horizon, signedError: signed)
                    }
                    logAccuracy(day: dayKey, model: "ensemble", horizon: horizon, value: abs(signed))
                    updateBand(horizon: horizon, residual: actualDelta - ensembleDelta)
                    if let lower = forecast.bandLower[horizon], let upper = forecast.bandUpper[horizon] {
                        let inside = actual.valueMgDl >= lower && actual.valueMgDl <= upper
                        logAccuracy(day: dayKey, model: "band", horizon: horizon, value: inside ? 1 : 0)
                        if var band = bands[String(horizon)] {
                            band.coverage += ((inside ? 1.0 : 0.0) - band.coverage) * 0.05
                            bands[String(horizon)] = band
                        }
                    }
                    updateStack(
                        regime: forecast.regime,
                        horizon: horizon,
                        corrected: forecast.correctedDeltas,
                        ensembleDelta: ensembleDelta,
                        actualDelta: actualDelta
                    )
                }

                pending[index].scored.insert(horizon)
                scoredCount += 1
                changed = true
            }
        }

        pending.removeAll { $0.scored.count >= Self.horizons.count }
        if changed {
            dirty = true
            saveIfDue()
        }
    }

    // MARK: - Accuracy reporting

    /// Mean absolute error per model over the last `days` of scored forecasts, blend first.
    func accuracyRows(days: Int) -> [AccuracyRow] {
        let cells = aggregatedCells(days: days)
        let order = ["ensemble"] + Self.modelNames
        var rows: [AccuracyRow] = []
        for model in order {
            var mae: [Int: Double] = [:]
            var count = 0
            for horizon in Self.displayHorizons {
                guard let cell = cells["\(model)|\(horizon)"], cell.count >= 10 else { continue }
                mae[horizon] = cell.sum / Double(cell.count)
                count = max(count, cell.count)
            }
            guard !mae.isEmpty else { continue }
            rows.append(AccuracyRow(model: model, title: Self.title(forModel: model), maeByHorizon: mae, count: count))
        }
        return rows
    }

    /// Fraction of readings that fell inside the band, per display horizon, over the last `days`.
    func bandCoverage(days: Int) -> [Int: Double] {
        let cells = aggregatedCells(days: days)
        var coverage: [Int: Double] = [:]
        for horizon in Self.displayHorizons {
            guard let cell = cells["band|\(horizon)"], cell.count >= 10 else { continue }
            coverage[horizon] = cell.sum / Double(cell.count)
        }
        return coverage
    }

    private func aggregatedCells(days: Int) -> [String: AccuracyCell] {
        let cutoff = Self.calendar.date(byAdding: .day, value: -max(days, 1), to: .now) ?? .distantPast
        let cutoffKey = Self.dayFormatter.string(from: cutoff)
        var totals: [String: AccuracyCell] = [:]
        for (day, cells) in daily where day >= cutoffKey || days >= 10_000 {
            for (key, cell) in cells {
                var total = totals[key] ?? AccuracyCell(sum: 0, count: 0)
                total.sum += cell.sum
                total.count += cell.count
                totals[key] = total
            }
        }
        return totals
    }

    // MARK: - Blending and calibration

    private func blendWeights(available: [String: Double], regime: Regime, horizon: Int) -> [String: Double] {
        // Inverse-error prior over the available models.
        var prior: [String: Double] = [:]
        for model in available.keys {
            prior[model] = 1.0 / (expectedError(model: model, regime: regime, horizon: horizon) + 3.0)
        }
        let priorSum = prior.values.reduce(0, +)
        guard priorSum > 0 else { return [:] }
        prior = prior.mapValues { $0 / priorSum }

        let key = "\(regime.rawValue)|\(horizon)"
        guard let stack = stacks[key], stack.n >= 10 else { return prior }

        let count = Self.modelNames.count
        let priorVector = Self.modelNames.map { prior[$0] ?? 0 }
        let trace = (0..<count).map { stack.a[$0 * count + $0] }.reduce(0, +)
        let scale = max(trace / Double(count), 1.0)
        let kappa = scale * (30.0 / (30.0 + stack.n)) + Self.tuning.stackShrink * scale

        var matrix = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        var rhs = [Double](repeating: 0, count: count)
        for row in 0..<count {
            for column in 0..<count {
                matrix[row][column] = stack.a[row * count + column] + (row == column ? kappa : 0)
            }
            rhs[row] = stack.b[row] + kappa * priorVector[row]
        }
        guard let solved = LinearAlgebra.solve(matrix, rhs) else { return prior }

        var weights: [String: Double] = [:]
        var sum = 0.0
        for (position, model) in Self.modelNames.enumerated() where available[model] != nil {
            let weight = max(0, solved[position])
            weights[model] = weight
            sum += weight
        }
        guard sum > 1e-9 else { return prior }
        if Self.tuning.renormalizeStack {
            return weights.mapValues { $0 / sum }
        }
        // Keep the learned scale, within reason: models that are systematically too timid get amplified.
        let range = Self.tuning.stackSumRange
        let clampedSum = min(max(sum, range.lowerBound), range.upperBound)
        return weights.mapValues { $0 / sum * clampedSum }
    }

    private func updateStack(
        regime: Regime,
        horizon: Int,
        corrected: [String: [Int: Double]],
        ensembleDelta: Double,
        actualDelta: Double
    ) {
        let count = Self.modelNames.count
        let key = "\(regime.rawValue)|\(horizon)"
        var stack = stacks[key] ?? StackState(
            a: [Double](repeating: 0, count: count * count),
            b: [Double](repeating: 0, count: count),
            n: 0
        )
        // Models that were unavailable are imputed with the blend itself, which leaves their weight untouched.
        let x = Self.modelNames.map { corrected[$0]?[horizon] ?? ensembleDelta }
        let forget = Self.stackForgetting
        for row in 0..<count {
            for column in 0..<count {
                stack.a[row * count + column] = stack.a[row * count + column] * forget + x[row] * x[column]
            }
            stack.b[row] = stack.b[row] * forget + x[row] * actualDelta
        }
        stack.n = stack.n * forget + 1
        stacks[key] = stack
    }

    private func updateErrorStats(model: String, regimeKey: String, horizon: Int, signedError: Double) {
        let key = "\(model)|\(regimeKey)|\(horizon)"
        if var stats = errorStats[key] {
            stats.absError += (abs(signedError) - stats.absError) * Self.errorLearningRate
            // Running mean at first, then a slow exponential average.
            let rate = max(Self.tuning.biasLearningRate, 1.0 / Double(stats.count + 1))
            stats.bias += (signedError - stats.bias) * rate
            let squared = stats.squared ?? signedError * signedError
            stats.squared = squared + (signedError * signedError - squared) * rate
            stats.count += 1
            errorStats[key] = stats
        } else {
            errorStats[key] = ErrorStats(absError: abs(signedError), bias: signedError, squared: signedError * signedError, count: 1)
        }
    }

    /// The part of a bias estimate that stands clear of its own noise, using soft thresholding.
    /// Forecasts a few minutes apart are strongly correlated, so the effective sample size is reduced.
    private func significantBias(_ stats: ErrorStats) -> Double {
        guard stats.count >= 10 else { return 0 }
        let variance = max((stats.squared ?? 0) - stats.bias * stats.bias, 1)
        let effectiveCount = max(Double(stats.count) / 6, 1)
        let standardError = (variance / effectiveCount).squareRoot()
        let threshold = Self.tuning.biasSignificance * standardError
        let magnitude = abs(stats.bias) - threshold
        guard magnitude > 0 else { return 0 }
        return stats.bias > 0 ? magnitude : -magnitude
    }

    private func updateBand(horizon: Int, residual: Double) {
        let key = String(horizon)
        let baseline = 2.0 + 0.6 * Double(horizon)
        var band = bands[key] ?? BandState(lower: -baseline, upper: baseline, coverage: 0.9, count: 0)
        let scale = max(3.0, expectedError(model: "ensemble", regime: nil, horizon: horizon))
        // Large steps at first so the band converges within a few hours, then fine adjustments.
        let step = scale * max(0.05, 0.5 / (Double(band.count) + 1).squareRoot())
        // Stochastic quantile tracking of the 95th and 5th percentiles of the residual.
        band.upper += residual > band.upper ? step * 0.95 : -step * 0.05
        band.lower += residual > band.lower ? step * 0.05 : -step * 0.95
        band.count += 1
        bands[key] = band
    }

    /// Offsets from the forecast value to the band edges, in mg/dL.
    private func bandOffsets(regime: Regime, horizon: Int) -> (lower: Double, upper: Double) {
        let baseline = 2.0 + 0.6 * Double(horizon)
        var lower = -baseline
        var upper = baseline
        if let band = bands[String(horizon)], band.count >= 20 {
            lower = band.lower
            upper = band.upper
        }
        // Widen or narrow for how the blend has been doing in this regime versus overall.
        let regimeError = errorStats["ensemble|\(regime.rawValue)|\(horizon)"]
        let overallError = errorStats["ensemble|all|\(horizon)"]
        if let regimeError, let overallError,
           regimeError.count >= 20, overallError.count >= 20, overallError.absError > 0 {
            let ratio = min(1.6, max(0.6, regimeError.absError / overallError.absError))
            lower *= ratio
            upper *= ratio
        }
        let floor = 2.0 + 0.3 * Double(horizon)
        return (min(lower, -floor), max(upper, floor))
    }

    /// Expected absolute error in mg/dL, blending regime-specific and overall statistics by sample count.
    func expectedError(model: String, regime: Regime?, horizon: Int) -> Double {
        let overall = errorStats["\(model)|all|\(horizon)"]
        let specific = regime.flatMap { errorStats["\(model)|\($0.rawValue)|\(horizon)"] }
        let prior = (Self.defaultError[model] ?? 10) * Double(horizon) / 30.0

        var estimate = prior
        if let overall {
            let weight = 5.0
            estimate = (estimate * weight + overall.absError * Double(overall.count)) / (weight + Double(overall.count))
        }
        if let specific {
            let pull = min(Double(specific.count), 200)
            estimate = (estimate * 20 + specific.absError * pull) / (20 + pull)
        }
        return estimate
    }

    private func bias(model: String, regime: Regime, horizon: Int) -> Double {
        let overall = errorStats["\(model)|all|\(horizon)"].map(significantBias) ?? 0
        guard let specific = errorStats["\(model)|\(regime.rawValue)|\(horizon)"], specific.count >= 10 else {
            return overall
        }
        let regimeBias = significantBias(specific)
        let pull = min(Double(specific.count), 200)
        return (overall * 20 + regimeBias * pull) / (20 + pull)
    }

    // MARK: - Models

    private struct ArrowRate {
        let center: Double
        let lower: Double
        let upper: Double
    }

    private func trendArrow(in readings: [GlucoseReading], last: GlucoseReading) -> ArrowRate? {
        let source = readings.last(where: { $0.trendArrow != nil && last.timestamp.timeIntervalSince($0.timestamp) <= 5 * 60 })
        guard let arrow = source?.trendArrow else { return nil }
        switch arrow {
        case 1: return ArrowRate(center: -2.5, lower: -4, upper: -2)
        case 2: return ArrowRate(center: -1.5, lower: -2, upper: -1)
        case 3: return ArrowRate(center: 0, lower: -1, upper: 1)
        case 4: return ArrowRate(center: 1.5, lower: 1, upper: 2)
        case 5: return ArrowRate(center: 2.5, lower: 2, upper: 4)
        case 6...: return ArrowRate(center: 3.5, lower: 3, upper: 5)
        default: return nil
        }
    }

    /// Recency-weighted linear regression over the last 20 minutes with a decaying slope. The sensor's
    /// trend arrow, when present, bounds the fitted slope and nudges it toward the arrow's own rate.
    private func trendModel(_ readings: [GlucoseReading], last: GlucoseReading, arrow: ArrowRate?) -> [Int: Double]? {
        let window = readings.filter { last.timestamp.timeIntervalSince($0.timestamp) <= 20 * 60 }
        guard window.count >= 3,
              last.timestamp.timeIntervalSince(window[0].timestamp) >= 8 * 60,
              var slope = weightedSlope(window, last: last, decayMinutes: 10)
        else { return nil }

        if let arrow {
            slope = min(max(slope, arrow.lower - 0.5), arrow.upper + 0.5)
            slope = 0.75 * slope + 0.25 * arrow.center
        }

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
            deltas[horizon] = (b * h + 0.5 * c * h * h) * exp(-h / 30)
        }
        return deltas
    }

    /// The sensor's trend arrow extrapolated with a short decay.
    private func arrowModel(_ arrow: ArrowRate?) -> [Int: Double]? {
        guard let arrow else { return nil }
        let tau = 20.0
        var deltas: [Int: Double] = [:]
        for horizon in Self.horizons {
            deltas[horizon] = arrow.center * tau * (1 - exp(-Double(horizon) / tau))
        }
        return deltas
    }

    /// Cached lookup structures for the pattern model, rebuilt only when the history changes.
    private struct HistoryIndex {
        let count: Int
        let firstT: Int
        let lastT: Int
        let byTime: [Int: Double]
        let minuteOfDay: [Int]
    }
    private var historyIndex: HistoryIndex?

    private func lookup(for history: [HistorySample]) -> HistoryIndex {
        if let cached = historyIndex,
           cached.count == history.count,
           cached.firstT == history.first?.t,
           cached.lastT == history.last?.t {
            return cached
        }
        var byTime: [Int: Double] = [:]
        byTime.reserveCapacity(history.count)
        var minutes: [Int] = []
        minutes.reserveCapacity(history.count)
        for sample in history {
            byTime[sample.t] = sample.v
            minutes.append(RidgeForecastModel.minuteOfDay(for: sample.date, calendar: Self.calendar))
        }
        let built = HistoryIndex(
            count: history.count,
            firstT: history.first?.t ?? 0,
            lastT: history.last?.t ?? 0,
            byTime: byTime,
            minuteOfDay: minutes
        )
        historyIndex = built
        return built
    }

    /// Analogue forecast: past moments whose preceding half hour resembled the current one.
    private func patternModel(
        _ readings: [GlucoseReading],
        last: GlucoseReading,
        history: [HistorySample]
    ) -> [Int: Double]? {
        let lags = [0, 5, 10, 15, 20, 25, 30]
        guard history.count >= 12 * 24 * 2 else { return nil }

        var shape: [Double] = []
        for lag in lags {
            let target = last.timestamp.addingTimeInterval(-TimeInterval(lag) * 60)
            guard let value = interpolatedValue(at: target, in: readings, tolerance: 6 * 60) else { return nil }
            shape.append(value - last.valueMgDl)
        }

        let table = lookup(for: history)
        let bin = GlucoseHistoryStore.binSeconds
        let nowMinute = RidgeForecastModel.minuteOfDay(for: last.timestamp, calendar: Self.calendar)
        let lastKey = Int(last.timestamp.timeIntervalSince1970) / bin * bin
        let latestUsable = lastKey - Self.maximumHorizonMinutes * 60

        struct Candidate { let key: Int; let distance: Double }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(24)
        var worstKept = Double.greatestFiniteMagnitude
        let keep = 20

        for (position, sample) in history.enumerated() where sample.t <= latestUsable {
            var clock = abs(table.minuteOfDay[position] - nowMinute)
            clock = min(clock, 1440 - clock)
            guard clock <= 240 else { continue }

            let key = sample.t
            let base = sample.v
            guard table.byTime[key + Self.maximumHorizonMinutes * 60] != nil else { continue }

            var shapeDistance = 0.0
            var complete = true
            for (lagIndex, lag) in lags.enumerated() where lagIndex > 0 {
                guard let value = table.byTime[key - lag * 60] else { complete = false; break }
                let diff = (value - base) - shape[lagIndex]
                shapeDistance += diff * diff
            }
            guard complete else { continue }

            let level = (base - last.valueMgDl) / 35
            let clockFraction = Double(clock) / 240
            let distance = shapeDistance / (Double(lags.count - 1) * 120) + level * level + clockFraction * clockFraction

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
        for horizon in Self.horizons {
            var weightedSum = 0.0
            var weightSum = 0.0
            for candidate in usable {
                guard let base = table.byTime[candidate.key],
                      let future = table.byTime[candidate.key + horizon * 60]
                else { continue }
                let weight = exp(-candidate.distance)
                weightedSum += (future - base) * weight
                weightSum += weight
            }
            guard weightSum > 0 else { continue }
            deltas[horizon] = weightedSum / weightSum
        }
        return deltas.isEmpty ? nil : deltas
    }

    /// The ridge regression's forecast, when a model has been trained and the recent readings are complete.
    private func ridgeDeltas(_ readings: [GlucoseReading], last: GlucoseReading, typicalDay: TypicalDayProfile?) -> [Int: Double]? {
        guard let ridgeModel else { return nil }
        var values: [Double] = []
        for lag in 0...RidgeForecastModel.lagCount {
            let target = last.timestamp.addingTimeInterval(-TimeInterval(lag * Self.stepMinutes) * 60)
            guard let value = interpolatedValue(at: target, in: readings, tolerance: 6 * 60) else { return nil }
            values.append(value)
        }
        guard let base = RidgeForecastModel.baseFeatures(values: values, date: last.timestamp, typical: typicalDay, calendar: Self.calendar) else {
            return nil
        }
        var deltas: [Int: Double] = [:]
        for horizon in Self.horizons {
            if let delta = ridgeModel.predictDelta(base: base, date: last.timestamp, horizon: horizon, typical: typicalDay, calendar: Self.calendar) {
                deltas[horizon] = delta
            }
        }
        return deltas.isEmpty ? nil : deltas
    }

    /// The change the typical-day profile expects at this clock time, with mild reversion toward it.
    private func driftModel(last: GlucoseReading, typicalDay: TypicalDayProfile?) -> [Int: Double]? {
        guard let typicalDay, let now = typicalDay.values(at: last.timestamp, calendar: Self.calendar) else { return nil }
        var deltas: [Int: Double] = [:]
        for horizon in Self.horizons {
            let future = last.timestamp.addingTimeInterval(TimeInterval(horizon) * 60)
            guard let expected = typicalDay.values(at: future, calendar: Self.calendar) else { continue }
            let drift = expected.median - now.median
            let reversion = -(last.valueMgDl - now.median) * 0.25 * (1 - exp(-Double(horizon) / 45))
            deltas[horizon] = drift + reversion
        }
        return deltas.isEmpty ? nil : deltas
    }

    // MARK: - Numeric helpers

    private func weightedSlope(_ readings: [GlucoseReading], last: GlucoseReading, decayMinutes: Double) -> Double? {
        guard readings.count >= 2 else { return nil }
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
        let matrix: [[Double]] = [[n, sx, sx2], [sx, sx2, sx3], [sx2, sx3, sx4]]
        guard let solved = LinearAlgebra.solve(matrix, [sy, sxy, sx2y]) else { return nil }
        return (solved[1], solved[2])
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

    private func logAccuracy(day: String, model: String, horizon: Int, value: Double) {
        guard Self.displayHorizons.contains(horizon) else { return }
        var cells = daily[day] ?? [:]
        var cell = cells["\(model)|\(horizon)"] ?? AccuracyCell(sum: 0, count: 0)
        cell.sum += value
        cell.count += 1
        cells["\(model)|\(horizon)"] = cell
        daily[day] = cells
        if daily.count > dailyLogLimit {
            let stale = daily.keys.sorted().prefix(daily.count - dailyLogLimit)
            for key in stale { daily.removeValue(forKey: key) }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(StoredLearning.self, from: data)
        else { return }
        errorStats = stored.errorStats
        stacks = stored.stacks
        bands = stored.bands
        daily = stored.daily
        scoredCount = stored.scoredCount
    }

    private func saveIfDue() {
        guard persists, dirty, Date().timeIntervalSince(lastSave) >= 120 else { return }
        saveNow()
    }

    func saveNow() {
        guard persists, dirty else { return }
        let stored = StoredLearning(
            errorStats: errorStats,
            stacks: stacks,
            bands: bands,
            daily: daily,
            scoredCount: scoredCount
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            lastSave = .now
            dirty = false
        }
    }
}
