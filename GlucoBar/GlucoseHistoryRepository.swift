import Foundation

@MainActor
final class GlucoseHistoryRepository {
    private(set) var profileID: String?
    private(set) var store = GlucoseHistoryStore(fileURL: nil)
    private let directory: URL
    private let defaults: UserDefaults
    private let legacyFileURL: URL
    private let legacyOwnerKey = "GlucoBar.legacyHistoryOwner"

    init(directory: URL? = nil, defaults: UserDefaults = .standard, legacyURL: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlucoBar/Profiles", isDirectory: true)
        self.defaults = defaults
        self.legacyFileURL = legacyURL ?? Self.legacyURL
    }

    var learningKey: String { "GlucoBar.learning." + (profileID ?? "unconnected") }
    private var graphURL: URL? { profileID.map { directory.appendingPathComponent($0 + "-graph.json") } }

    @discardableResult
    func select(_ profileID: String?) -> [GlucoseReading] {
        store.saveNow()
        self.profileID = profileID
        store = GlucoseHistoryStore(fileURL: profileID.map { directory.appendingPathComponent($0 + "-history.json") })
        return cachedGraph
    }

    var cachedGraph: [GlucoseReading] {
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
        readLegacySamples(at: legacyURL)
    }

    private static func readLegacySamples(at url: URL) -> [HistorySample] {
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([HistorySample].self, from: data) else { return [] }
        return samples.filter { $0.v.isFinite && $0.v > 0 }.sorted { $0.t < $1.t }
    }

    var legacyWasImported: Bool { defaults.string(forKey: legacyOwnerKey) != nil }

    /// Old versions did not record identity. Require a substantial, exact overlap before
    /// assigning their data automatically; otherwise leave the explicit import available.
    @discardableResult
    func importLegacy(onlyIfMatching: Bool = true) throws -> Bool {
        guard let profileID, !onlyIfMatching || !legacyWasImported else { return false }
        let samples = Self.readLegacySamples(at: legacyFileURL)
        guard !samples.isEmpty else { return false }
        if onlyIfMatching {
            let old = Dictionary(samples.map { ($0.t, $0.v) }, uniquingKeysWith: { first, _ in first })
            let overlap = store.samples.filter { old[$0.t] != nil }
            guard overlap.count >= 12,
                  let first = overlap.first, let last = overlap.last, last.t - first.t >= 3600,
                  overlap.allSatisfy({ abs($0.v - old[$0.t]!) < 0.11 }) else { return false }
        }

        store.merge(samples.map { GlucoseReading(timestamp: $0.date, valueMgDl: $0.v) })
        try store.saveNowThrowing()
        if let data = defaults.data(forKey: "GlucoBarLibreLinkUpGraphCache"),
           let legacyGraph = try? JSONDecoder().decode(GraphCache.self, from: data), let graphURL {
            var byDate: [Date: GlucoseReading] = [:]
            for reading in legacyGraph.readings + cachedGraph where reading.valueMgDl.isFinite && reading.valueMgDl > 0 {
                byDate[reading.timestamp] = reading
            }
            let graph = GraphCache(readings: byDate.values.sorted { $0.timestamp < $1.timestamp })
            try JSONEncoder().encode(graph).write(to: graphURL, options: .atomic)
        }
        GlucosePredictor.copyLegacyLearning(to: learningKey, defaults: defaults)
        // Keep this marker even if the profile or legacy backup is deleted. An upgrade must
        // never silently reimport deleted data or give it to the next account selected.
        defaults.set(profileID, forKey: legacyOwnerKey)
        return true
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
