import XCTest
import Foundation

@MainActor
final class ForecastTests: XCTestCase {
    func testCooldownSurvivesRestartAndSnoozeDoesNotConsumeIt() {
        let suite = "GlucoBarTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let first = AlertSchedule(profile: "a", defaults: defaults)
        XCTAssertFalse(first.allows(kind: "low", cooldown: 1800, now: now, snoozedUntil: now.addingTimeInterval(60)))
        XCTAssertTrue(first.allows(kind: "low", cooldown: 1800, now: now, snoozedUntil: nil))
        first.record(kind: "low", now: now)
        let restarted = AlertSchedule(profile: "a", defaults: defaults)
        XCTAssertFalse(restarted.allows(kind: "low", cooldown: 1800, now: now.addingTimeInterval(1799), snoozedUntil: nil))
        XCTAssertTrue(restarted.allows(kind: "low", cooldown: 1800, now: now.addingTimeInterval(1800), snoozedUntil: nil))
        XCTAssertTrue(restarted.allows(kind: "high", cooldown: 1800, now: now, snoozedUntil: nil))
        XCTAssertTrue(AlertSchedule(profile: "b", defaults: defaults).allows(kind: "low", cooldown: 1800, now: now, snoozedUntil: nil))
    }

    private func forecast(at start: Date, low: Bool) -> GlucosePrediction {
        GlucosePrediction(madeAt: start, startValueMgDl: 100,
            points: [5, 10, 15].map { PredictedPoint(date: start.addingTimeInterval(Double($0) * 60), valueMgDl: low ? 60 : 100, lowerMgDl: 50, upperMgDl: 140) },
            modelWeights: [:], regime: "stable")
    }

    func testCrossingEvaluationCountsHitsMissesAndFalseWarnings() throws {
        let start = Date()
        let evaluation = ForecastEvaluation()
        for (index, predicted, actual) in [(0, true, true), (1, false, true), (2, true, false)] {
            let date = start.addingTimeInterval(Double(index) * 3600)
            evaluation.record(forecast(at: date, low: predicted), low: 70, high: 180)
            let readings = [0, 5, 10, 15].map { minute in
                GlucoseReading(timestamp: date.addingTimeInterval(Double(minute) * 60), valueMgDl: minute == 0 || !actual ? 100 : 60)
            }
            evaluation.learn(readings: readings, now: date.addingTimeInterval(900))
        }
        let summary = try XCTUnwrap(evaluation.summaries(now: start.addingTimeInterval(3 * 3600)).first { $0.kind == "Low" })
        XCTAssertEqual(summary.windows, 3)
        XCTAssertEqual(summary.detected, 1)
        XCTAssertEqual(summary.missed, 1)
        XCTAssertEqual(summary.falseWarnings, 1)
        XCTAssertEqual(summary.meanLeadMinutes, 5)
    }

    func testMissingDataIsExcludedFromCrossingAccuracy() {
        let now = Date()
        let evaluation = ForecastEvaluation()
        evaluation.record(forecast(at: now, low: true), low: 70, high: 180)
        evaluation.learn(readings: [GlucoseReading(timestamp: now, valueMgDl: 100), GlucoseReading(timestamp: now.addingTimeInterval(900), valueMgDl: 100)], now: now.addingTimeInterval(900))
        XCTAssertTrue(evaluation.summaries(now: now.addingTimeInterval(900)).isEmpty)
    }

    func testEvaluationPersistsAndResetRemovesResults() {
        let suite = "GlucoBarTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let evaluation = ForecastEvaluation(key: "evaluation", defaults: defaults)
        evaluation.record(forecast(at: now, low: true), low: 70, high: nil)
        let restored = ForecastEvaluation(key: "evaluation", defaults: defaults)
        restored.learn(readings: [0, 5, 10, 15].map { GlucoseReading(timestamp: now.addingTimeInterval(Double($0) * 60), valueMgDl: 100) }, now: now.addingTimeInterval(900))
        XCTAssertEqual(restored.summaries(now: now.addingTimeInterval(900)).first?.falseWarnings, 1)
        restored.reset()
        XCTAssertTrue(ForecastEvaluation(key: "evaluation", defaults: defaults).summaries().isEmpty)
    }

    func testForecastAccuracyReportsPerHorizonSampleCounts() {
        let predictor = GlucosePredictor(persists: false)
        let origin = Date().addingTimeInterval(-4 * 3600)
        var readings: [GlucoseReading] = []
        for minute in stride(from: 0, through: 180, by: 5) {
            let date = origin.addingTimeInterval(Double(minute) * 60)
            readings.append(GlucoseReading(timestamp: date, valueMgDl: 100, trendArrow: 3))
            predictor.learn(from: readings)
            _ = predictor.predict(recent: readings, history: [], typicalDay: nil, now: date)
        }
        let row = predictor.accuracyRows(days: 7).first { $0.model == "ensemble" }
        XCTAssertNotNil(row)
        XCTAssertGreaterThan(row?.countsByHorizon[15] ?? 0, row?.countsByHorizon[60] ?? 0)
        XCTAssertEqual(row?.maeByHorizon[30] ?? .infinity, 0, accuracy: 0.000001)
    }
    func testLearningIsPersistedSeparatelyForEachProfile() {
        let firstKey = "GlucoBarTests.learning." + UUID().uuidString
        let secondKey = "GlucoBarTests.learning." + UUID().uuidString
        defer {
            UserDefaults.standard.removeObject(forKey: firstKey)
            UserDefaults.standard.removeObject(forKey: secondKey)
        }
        let predictor = GlucosePredictor(defaultsKey: firstKey)
        let origin = Date().addingTimeInterval(-3600)
        let readings = stride(from: 0, through: 30, by: 5).map {
            GlucoseReading(timestamp: origin.addingTimeInterval(Double($0) * 60), valueMgDl: 100, trendArrow: 3)
        }
        _ = predictor.predict(recent: Array(readings.prefix(4)), history: [], typicalDay: nil, now: readings[3].timestamp)
        predictor.learn(from: readings)
        predictor.saveNow()
        XCTAssertGreaterThan(GlucosePredictor(defaultsKey: firstKey).learnedForecastCount, 0)
        XCTAssertEqual(GlucosePredictor(defaultsKey: secondKey).learnedForecastCount, 0)
        predictor.resetLearning()
        XCTAssertEqual(GlucosePredictor(defaultsKey: firstKey).learnedForecastCount, 0)
    }

}
