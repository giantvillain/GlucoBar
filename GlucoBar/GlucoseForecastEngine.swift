import Foundation

/// Owns all learning and background work for one active history profile.
@MainActor
final class GlucoseForecastEngine {
    private(set) var predictor = GlucosePredictor(persists: false)
    private(set) var evaluation = ForecastEvaluation()
    private var trainingTask: Task<Void, Never>?
    private var backtestTask: Task<Void, Never>?
    private var backtestRun: UUID?
    private var generation = UUID()
    private var trainedVersion = -1
    private var trainedAt: Date?

    func select(learningKey: String?) {
        predictor.saveNow()
        trainingTask?.cancel()
        backtestTask?.cancel()
        trainingTask = nil
        backtestTask = nil
        backtestRun = nil
        generation = UUID()
        trainedVersion = -1
        trainedAt = nil
        predictor = GlucosePredictor(persists: learningKey != nil, defaultsKey: learningKey ?? "unused")
        evaluation = ForecastEvaluation(key: learningKey.map { $0 + ".evaluation" })
    }

    func reset() {
        predictor.resetLearning()
        predictor.ridgeModel = nil
        evaluation.reset()
        generation = UUID()
        trainingTask?.cancel()
        backtestTask?.cancel()
        trainingTask = nil
        backtestTask = nil
        backtestRun = nil
        trainedVersion = -1
        trainedAt = nil
    }

    func train(samples: [HistorySample], version: Int, typical: TypicalDayProfile?, completion: @escaping () -> Void) {
        guard trainingTask == nil, version != trainedVersion,
              trainedAt.map({ Date().timeIntervalSince($0) >= 6 * 3600 }) ?? true else { return }
        trainedVersion = version
        let token = generation
        trainingTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            let model = RidgeForecastModel.train(samples: samples, typical: typical, now: .now)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == token else { return }
                self.trainingTask = nil
                if let model {
                    self.trainedAt = .now
                    self.predictor.ridgeModel = model
                    completion()
                }
            }
        }
    }

    func backtest(samples: [HistorySample], days: Int, progress: @escaping (Double) -> Void,
                  completion: @escaping (ForecastBacktestResult?) -> Void) {
        guard backtestTask == nil else { return }
        let token = generation
        let run = UUID()
        backtestRun = run
        backtestTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = ForecastBacktest.run(samples: samples, evaluationDays: days) { fraction in
                Task { @MainActor [weak self] in
                    guard self?.generation == token, self?.backtestRun == run else { return }
                    progress(fraction)
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == token else { return }
                self.backtestTask = nil
                self.backtestRun = nil
                completion(result)
            }
        }
    }
}
