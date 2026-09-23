import Foundation
import XCTest

@MainActor
final class LegacyMigrationTests: XCTestCase {
    private func withFixture(_ body: (GlucoseHistoryRepository, UserDefaults, URL, [GlucoseReading]) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "GlucoBarTests.migration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("legacy.json")
        let readings = (0..<24).map {
            GlucoseReading(timestamp: Date(timeIntervalSince1970: Double(1_800_000_000 + $0 * 300)), valueMgDl: Double(100 + $0))
        }
        try JSONEncoder().encode(readings.map { HistorySample(t: Int($0.timestamp.timeIntervalSince1970), v: $0.valueMgDl) }).write(to: legacy)
        let repository = GlucoseHistoryRepository(directory: directory.appendingPathComponent("Profiles"), defaults: defaults, legacyURL: legacy)
        try body(repository, defaults, legacy, readings)
    }

    private func learning(_ count: Int) -> Data {
        Data("{\"errorStats\":{},\"stacks\":{},\"bands\":{},\"daily\":{},\"scoredCount\":\(count)}".utf8)
    }

    func testMatchingUpgradeRestoresHistoryGraphAndLearningWithoutChangingOriginal() throws {
        try withFixture { repository, defaults, legacy, readings in
            let original = try Data(contentsOf: legacy)
            repository.select("one")
            let newer = GlucoseReading(timestamp: readings.last!.timestamp.addingTimeInterval(300), valueMgDl: 140)
            repository.store.merge(Array(readings.suffix(13)) + [newer])
            repository.saveGraph([newer])
            defaults.set(try JSONEncoder().encode(GraphCache(readings: readings)), forKey: "GlucoBarLibreLinkUpGraphCache")
            defaults.set(learning(1000), forKey: "GlucoBarPredictorLearningV2")
            defaults.set(learning(2), forKey: repository.learningKey)

            XCTAssertTrue(try repository.importLegacy())
            XCTAssertEqual(repository.store.samples.count, 25)
            XCTAssertEqual(repository.cachedGraph.last, newer)
            XCTAssertEqual(repository.cachedGraph.count, 25)
            XCTAssertEqual(defaults.data(forKey: repository.learningKey), learning(1000))
            XCTAssertEqual(try Data(contentsOf: legacy), original)
            repository.select("one")
            XCTAssertEqual(repository.store.samples.count, 25)
        }
    }

    func testAutomaticImportRequiresSubstantialMatchingOverlap() throws {
        try withFixture { repository, _, _, readings in
            XCTAssertFalse(try repository.importLegacy())
            repository.select("one")
            XCTAssertFalse(try repository.importLegacy())
            repository.store.merge(Array(readings.prefix(12)))
            XCTAssertFalse(try repository.importLegacy()) // Twelve bins span only 55 minutes.
            repository.store.merge([GlucoseReading(timestamp: readings[12].timestamp, valueMgDl: 999)])
            XCTAssertFalse(try repository.importLegacy()) // A conflicting value prevents assignment.
            XCTAssertFalse(repository.legacyWasImported)
        }
    }

    func testMigrationDoesNotRepeatAfterDeletionOrProfileSwitch() throws {
        try withFixture { repository, defaults, legacy, readings in
            repository.select("one")
            repository.store.merge(readings)
            XCTAssertTrue(try repository.importLegacy())
            repository.deleteCurrent()
            XCTAssertFalse(try repository.importLegacy())
            XCTAssertTrue(repository.store.isEmpty)
            let reopened = GlucoseHistoryRepository(directory: legacy.deletingLastPathComponent().appendingPathComponent("Profiles"), defaults: defaults, legacyURL: legacy)
            reopened.select("two")
            reopened.store.merge(Array(readings.suffix(13)))
            XCTAssertFalse(try reopened.importLegacy())
            XCTAssertEqual(reopened.store.samples.count, 13)
        }
    }

    func testExplicitImportPreservesExistingBinsAndMoreTrainedLearning() throws {
        try withFixture { repository, defaults, _, readings in
            repository.select("one")
            repository.store.merge([GlucoseReading(timestamp: readings[0].timestamp, valueMgDl: 150)])
            defaults.set(learning(1000), forKey: repository.learningKey)
            defaults.set(learning(10), forKey: "GlucoBarPredictorLearningV2")
            XCTAssertTrue(try repository.importLegacy(onlyIfMatching: false))
            XCTAssertEqual(repository.store.samples.first?.v, 150)
            XCTAssertEqual(repository.store.samples.count, 24)
            XCTAssertEqual(defaults.data(forKey: repository.learningKey), learning(1000))
        }
    }

    func testFailedSaveDoesNotMarkLegacyAsImported() throws {
        try withFixture { _, defaults, legacy, readings in
            let blockedDirectory = legacy.deletingLastPathComponent().appendingPathComponent("file-not-directory")
            try Data().write(to: blockedDirectory)
            let repository = GlucoseHistoryRepository(directory: blockedDirectory, defaults: defaults, legacyURL: legacy)
            repository.select("one")
            repository.store.merge(Array(readings.suffix(13)))
            XCTAssertThrowsError(try repository.importLegacy())
            XCTAssertFalse(repository.legacyWasImported)
        }
    }

    func testCorruptLegacyLearningDoesNotReplaceProfileLearning() throws {
        try withFixture { repository, defaults, _, readings in
            repository.select("one")
            repository.store.merge(readings)
            defaults.set(learning(1000), forKey: repository.learningKey)
            defaults.set(Data("invalid".utf8), forKey: "GlucoBarPredictorLearningV2")
            XCTAssertTrue(try repository.importLegacy())
            XCTAssertEqual(defaults.data(forKey: repository.learningKey), learning(1000))
        }
    }
}
