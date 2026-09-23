import Foundation

/// Result of replaying stored history through a fresh predictor.
nonisolated struct ForecastBacktestResult: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let model: String
        let title: String
        /// Mean absolute error in mg/dL by horizon.
        let maeByHorizon: [Int: Double]
        let count: Int
        let countsByHorizon: [Int: Int]
    }

    let rows: [Row]
    let bandCoverageByHorizon: [Int: Double]
    let forecastCount: Int
    let evaluationDays: Int
    let completedAt: Date
}

/// Replays the stored five-minute history chronologically through a fresh predictor, retraining the
/// regression and typical-day profile at each day boundary from the data before it, so every forecast is
/// made with only what would have been known at the time. Learning runs online exactly as it does live.
nonisolated enum ForecastBacktest {
    static func run(
        samples: [HistorySample],
        evaluationDays: Int,
        progress: (Double) -> Void
    ) -> ForecastBacktestResult? {
        let sorted = samples.sorted { $0.t < $1.t }
        guard let first = sorted.first, let last = sorted.last else { return nil }

        var evaluationStart = last.t - max(1, evaluationDays) * 86_400
        evaluationStart = max(evaluationStart, first.t + 12 * 3600)
        guard evaluationStart < last.t - 2 * 3600 else { return nil }

        let calendar = Calendar.current
        let predictor = GlucosePredictor(persists: false, dailyLogLimit: Int.max)
        var currentDay: Int?
        var typical: TypicalDayProfile?
        let startIndex = sorted.firstIndex { $0.t >= evaluationStart } ?? sorted.count
        let total = max(1, sorted.count - startIndex)
        var recentStart = 0

        for position in startIndex..<sorted.count {
            if Task.isCancelled { return nil }
            let sample = sorted[position]
            let dayStart = Int(calendar.startOfDay(for: sample.date).timeIntervalSince1970)
            if currentDay != dayStart {
                currentDay = dayStart
                let training = Array(sorted[..<position])
                let lookback = training.filter { $0.t >= dayStart - 30 * 86_400 }
                typical = GlucoseAnalytics.typicalDay(samples: lookback, calendar: calendar)
                predictor.ridgeModel = RidgeForecastModel.train(samples: training, typical: typical, now: sample.date, calendar: calendar)
            }

            while sorted[recentStart].t < sample.t - 70 * 60 { recentStart += 1 }
            let recent = sorted[recentStart...position].map { GlucoseReading(timestamp: $0.date, valueMgDl: $0.v) }
            predictor.learn(from: recent)
            _ = predictor.predict(recent: recent, history: sorted, typicalDay: typical, now: sample.date)

            if (position - startIndex) % 25 == 0 {
                progress(Double(position - startIndex) / Double(total))
            }
        }
        progress(1)

        let rows = predictor.accuracyRows(days: 10_000).map {
            ForecastBacktestResult.Row(model: $0.model, title: $0.title, maeByHorizon: $0.maeByHorizon, count: $0.count, countsByHorizon: $0.countsByHorizon)
        }
        guard !rows.isEmpty else { return nil }
        let count = rows.first { $0.model == "ensemble" }?.count ?? 0
        return ForecastBacktestResult(
            rows: rows,
            bandCoverageByHorizon: predictor.bandCoverage(days: 10_000),
            forecastCount: count,
            evaluationDays: max(1, Int((Double(last.t - evaluationStart) / 86_400).rounded())),
            completedAt: .now
        )
    }
}
