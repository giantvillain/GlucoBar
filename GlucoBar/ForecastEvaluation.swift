import Foundation

/// Scores complete forecast windows. Overlapping windows are not independent glucose events.
nonisolated final class ForecastEvaluation {
    struct Window: Codable {
        let start: Date
        let minutes: Int
        let low: Double?
        let high: Double?
        let predictedLow: Bool
        let predictedHigh: Bool
    }
    struct Outcome: Codable {
        let start: Date
        let kind: String
        let predicted: Bool
        let actual: Bool
        let leadMinutes: Double?
    }
    struct Summary {
        let kind: String
        let windows: Int
        let missed: Int
        let falseWarnings: Int
        let detected: Int
        let meanLeadMinutes: Double?
    }
    private struct Saved: Codable {
        let pending: [Window]
        let outcomes: [Outcome]
    }
    private var pending: [Window] = []
    private var outcomes: [Outcome] = []
    private let key: String?
    private let defaults: UserDefaults

    init(key: String? = nil, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        if let key, let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            pending = saved.pending
            outcomes = saved.outcomes
        }
    }

    func record(_ forecast: GlucosePrediction, low: Double?, high: Double?) {
        guard low != nil || high != nil,
              low.map({ forecast.startValueMgDl >= $0 }) ?? true,
              high.map({ forecast.startValueMgDl <= $0 }) ?? true,
              let end = forecast.points.last?.date,
              !pending.contains(where: { $0.start == forecast.madeAt }),
              !outcomes.contains(where: { $0.start == forecast.madeAt }) else { return }
        pending.append(Window(start: forecast.madeAt, minutes: Int(end.timeIntervalSince(forecast.madeAt) / 60),
                              low: low, high: high,
                              predictedLow: low.map { threshold in forecast.points.contains { $0.valueMgDl < threshold } } ?? false,
                              predictedHigh: high.map { threshold in forecast.points.contains { $0.valueMgDl > threshold } } ?? false))
        save()
    }

    func learn(readings: [GlucoseReading], now: Date) {
        guard !pending.isEmpty else { return }
        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        var remaining: [Window] = []
        for window in pending {
            let end = window.start.addingTimeInterval(Double(window.minutes) * 60)
            guard let latest = sorted.last?.timestamp, latest >= end else {
                if now.timeIntervalSince(end) < 24 * 3600 { remaining.append(window) }
                continue
            }
            let samples = sorted.filter { $0.timestamp >= window.start && $0.timestamp <= end.addingTimeInterval(150) }
            // Do not count absent data as a successful or failed prediction.
            guard let first = samples.first, let last = samples.last,
                  first.timestamp.timeIntervalSince(window.start) <= 150,
                  abs(last.timestamp.timeIntervalSince(end)) <= 150,
                  ReadingSupport.segments(samples).count == 1 else { continue }
            for kind in ["Low", "High"] {
                guard let threshold = kind == "Low" ? window.low : window.high else { continue }
                let crossing = samples.first { kind == "Low" ? $0.valueMgDl < threshold : $0.valueMgDl > threshold }
                let predicted = kind == "Low" ? window.predictedLow : window.predictedHigh
                outcomes.append(Outcome(start: window.start, kind: kind, predicted: predicted, actual: crossing != nil,
                                        leadMinutes: predicted ? crossing.map { $0.timestamp.timeIntervalSince(window.start) / 60 } : nil))
            }
        }
        pending = remaining
        outcomes.removeAll { now.timeIntervalSince($0.start) > 7 * 86_400 }
        save()
    }

    func summaries(now: Date = .now) -> [Summary] {
        ["Low", "High"].compactMap { kind in
            let rows = outcomes.filter { $0.kind == kind && now.timeIntervalSince($0.start) <= 7 * 86_400 }
            guard !rows.isEmpty else { return nil }
            let lead = rows.compactMap(\.leadMinutes)
            return Summary(kind: kind, windows: rows.count,
                           missed: rows.filter { !$0.predicted && $0.actual }.count,
                           falseWarnings: rows.filter { $0.predicted && !$0.actual }.count,
                           detected: rows.filter { $0.predicted && $0.actual }.count,
                           meanLeadMinutes: lead.isEmpty ? nil : lead.reduce(0, +) / Double(lead.count))
        }
    }

    func reset() {
        pending = []
        outcomes = []
        if let key { defaults.removeObject(forKey: key) }
    }

    private func save() {
        guard let key, let data = try? JSONEncoder().encode(Saved(pending: pending, outcomes: outcomes)) else { return }
        defaults.set(data, forKey: key)
    }
}
