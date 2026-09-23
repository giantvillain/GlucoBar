import XCTest
import Foundation

@MainActor
final class GlucoseDataTests: XCTestCase {
    func testUnknownAndRapidTrendsStayDistinct() {
        XCTAssertEqual(ReadingSupport.trendSymbol(nil), "?")
        XCTAssertEqual(ReadingSupport.trendSymbol(ReadingSupport.nightscoutArrow("DoubleDown")), "↓↓")
        XCTAssertEqual(ReadingSupport.trendSymbol(ReadingSupport.nightscoutArrow("SingleDown")), "↓")
        XCTAssertNil(ReadingSupport.nightscoutArrow("NOT COMPUTABLE"))
        XCTAssertEqual(ReadingSupport.trendDescription(nil), "unavailable")
    }

    func testUnitConversionAndRounding() {
        XCTAssertEqual(ReadingSupport.formatted(180, mmol: true), "10.0")
        XCTAssertEqual(ReadingSupport.formatted(99, mmol: true), "5.5")
        XCTAssertEqual(ReadingSupport.formatted(100.6, mmol: false), "101")
    }

    func testProfilesSeparateSourcesAccountsAndPeople() {
        let a = ProfileIdentity.key(source: "libreLinkUp", account: " Person@Example.com ", person: "one")
        XCTAssertEqual(a, ProfileIdentity.key(source: "libreLinkUp", account: "person@example.com", person: "one"))
        XCTAssertNotEqual(a, ProfileIdentity.key(source: "libreLinkUp", account: "person@example.com", person: "two"))
        XCTAssertNotEqual(a, ProfileIdentity.key(source: "libreLinkUp", account: "other@example.com", person: "one"))
        XCTAssertNotEqual(a, ProfileIdentity.key(source: "nightscout", account: "person@example.com", person: "one"))
        XCTAssertNotEqual(ProfileIdentity.key(source: "nightscout", account: "https://example.com/A"), ProfileIdentity.key(source: "nightscout", account: "https://example.com/a"))
        XCTAssertEqual(ProfileIdentity.nightscoutAccount("Example.com/site/"), "https://example.com/site")
    }

    func testSwitchingProfilesReloadsOnlyTheirOwnHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = GlucoseHistoryRepository(directory: directory)
        let reading = GlucoseReading(timestamp: Date(timeIntervalSince1970: 1_800_000_000), valueMgDl: 123)
        repository.select("person-a")
        repository.store.merge([reading])
        repository.saveGraph([reading])
        XCTAssertTrue(repository.select("person-b").isEmpty)
        XCTAssertTrue(repository.store.isEmpty)
        XCTAssertEqual(repository.select("person-a"), [reading])
        XCTAssertEqual(repository.store.samples.first?.v, 123)
        repository.deleteCurrent()
        XCTAssertTrue(repository.select("person-a").isEmpty)
        XCTAssertTrue(repository.store.isEmpty)
    }

    func testGapsSplitChartAndStopRollingAverage() {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let readings = [0, 5, 10, 15, 60, 65, 70, 75].map { minute in
            GlucoseReading(timestamp: origin.addingTimeInterval(Double(minute) * 60), valueMgDl: minute < 60 ? 100 : 200)
        }
        XCTAssertEqual(ReadingSupport.segments(readings).map(\.count), [4, 4])
        let averages = GlucoseAnalytics.movingAverage(readings, window: 1800)
        XCTAssertNil(averages.first { $0.date == origin.addingTimeInterval(60 * 60) })
        XCTAssertEqual(averages.last?.valueMgDl, 200)
        XCTAssertEqual(ReadingSupport.segments([readings[0]]).count, 1)
    }

    func testNoForecastAcrossGap() {
        let origin = Date()
        let readings = [0, 5, 10, 60].map {
            GlucoseReading(timestamp: origin.addingTimeInterval(Double($0) * 60), valueMgDl: 100, trendArrow: 3)
        }
        XCTAssertNil(GlucosePredictor(persists: false).predict(recent: readings, history: [], typicalDay: nil, now: origin.addingTimeInterval(3600)))
    }

    func testNightscoutTimestampFormatsAgree() throws {
        let variants = [
            "{\"sgv\":123,\"date\":1704067200000}",
            "{\"sgv\":123.0,\"date\":1704067200000.0}",
            "{\"sgv\":123,\"dateString\":\"2024-01-01T00:00:00Z\"}",
            "{\"sgv\":123,\"dateString\":\"2024-01-01T00:00:00.000Z\"}"
        ]
        for json in variants {
            let entry = try JSONDecoder().decode(NightscoutEntry.self, from: Data(json.utf8))
            XCTAssertEqual(entry.date?.timeIntervalSince1970, 1704067200)
            XCTAssertEqual(entry.sgv, 123)
        }
    }

    func testLibrePayloadAcceptsNumericTimestampAndStringValues() throws {
        let json = #"{"Timestamp":1704067200,"ValueInMgPerDl":"123.5","TrendArrow":"3"}"#
        let payload = try JSONDecoder().decode(MeasurementPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.timestamp?.timeIntervalSince1970, 1704067200)
        XCTAssertEqual(payload.valueMgDl, 123.5)
        XCTAssertEqual(payload.trendArrow, 3)
    }

    func testCSVHasExplicitUnitsAndUTC() {
        let csv = GlucoseHistoryRepository.csv(samples: [HistorySample(t: 1704067200, v: 180)])
        XCTAssertTrue(csv.contains("timestamp_utc,glucose_mg_dL,glucose_mmol_L"))
        XCTAssertTrue(csv.contains("2024-01-01T00:00:00Z,180.0,10.00"))
    }

    func testComparisonCoverageAndBoundaryAreNotDoubleCounted() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ranges = GlucoseAnalytics.comparisonRanges(days: 7, now: now)
        XCTAssertEqual(ranges.currentStart, ranges.previousEnd)
        let sample = HistorySample(t: Int(ranges.currentStart.timeIntervalSince1970), v: 100)
        XCTAssertNil(GlucoseAnalytics.periodStats(samples: [sample], from: ranges.previousStart, to: ranges.previousEnd, lowMgDl: 70, highMgDl: 180))
        let stats = try XCTUnwrap(GlucoseAnalytics.periodStats(samples: [sample], from: ranges.currentStart, to: ranges.currentEnd, lowMgDl: 70, highMgDl: 180))
        XCTAssertEqual(stats.sampleCount, 1)
        XCTAssertLessThan(stats.coverage, 0.001)
    }

    func testTodayComparisonUsesYesterdaySameLocalClockAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 14))!
        let ranges = GlucoseAnalytics.comparisonRanges(days: 0, now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: ranges.previousEnd), 14)
        XCTAssertEqual(calendar.component(.day, from: ranges.previousStart), 7)
        XCTAssertEqual(calendar.component(.hour, from: ranges.currentStart), 0)
    }
}
