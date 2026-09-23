import Foundation

@MainActor
final class GlucoseHistoryRepository {
    private(set) var profileID: String?
    private(set) var store = GlucoseHistoryStore(fileURL: nil)
    private let directory: URL
    private let defaults: UserDefaults

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlucoBar/Profiles", isDirectory: true)
        self.defaults = defaults
    }

    var learningKey: String { "GlucoBar.learning." + (profileID ?? "unconnected") }
    private var graphURL: URL? { profileID.map { directory.appendingPathComponent($0 + "-graph.json") } }

    @discardableResult
    func select(_ profileID: String?) -> [GlucoseReading] {
        store.saveNow()
        self.profileID = profileID
        store = GlucoseHistoryStore(fileURL: profileID.map { directory.appendingPathComponent($0 + "-history.json") })
        guard let url = graphURL, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(GraphCache.self, from: data) else { return [] }
        return cache.readings
    }

    func saveGraph(_ readings: [GlucoseReading]) {
        guard let url = graphURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(GraphCache(readings: readings)).write(to: url, options: .atomic)
        } catch { /* A network refresh can repopulate this short-term cache. */ }
    }

    func deleteCurrent() {
        store.removeAll()
        store.saveNow()
        if let url = graphURL { try? FileManager.default.removeItem(at: url) }
        defaults.removeObject(forKey: learningKey)
    }

    private static var legacyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlucoBar/glucose-history-v1.json")
    }

    static var legacySamples: [HistorySample] {
        guard let data = try? Data(contentsOf: legacyURL),
              let samples = try? JSONDecoder().decode([HistorySample].self, from: data) else { return [] }
        return samples.filter { $0.v.isFinite && $0.v > 0 }.sorted { $0.t < $1.t }
    }

    static func deleteLegacy() throws {
        if FileManager.default.fileExists(atPath: legacyURL.path) { try FileManager.default.removeItem(at: legacyURL) }
        UserDefaults.standard.removeObject(forKey: "GlucoBarLibreLinkUpGraphCache")
        UserDefaults.standard.removeObject(forKey: "GlucoBarPredictorLearningV2")
    }

    static func csv(samples: [HistorySample]) -> String {
        let formatter = ISO8601DateFormatter()
        var rows = ["timestamp_utc,glucose_mg_dL,glucose_mmol_L"]
        rows += samples.map {
            "\(formatter.string(from: $0.date)),\(String(format: "%.1f", $0.v)),\(String(format: "%.2f", $0.v / 18))"
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
