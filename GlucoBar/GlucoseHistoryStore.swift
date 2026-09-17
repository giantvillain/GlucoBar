import Foundation
import AppKit

/// A compact long-term sample: seconds since 1970 and the value in mg/dL.
struct HistorySample: Codable, Equatable, Sendable {
    let t: Int
    let v: Double

    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
}

/// Long-term glucose history used for the typical-day overlay, longer-term statistics and the
/// pattern-matching part of the forecast. Readings are binned to five-minute slots so that even
/// 90 days of one-minute LibreLinkUp samples stay small, and the store lives in Application Support.
@MainActor
final class GlucoseHistoryStore {
    nonisolated static let binSeconds = 300

    /// Increments whenever the stored samples change, so callers can cache derived work cheaply.
    private(set) var version = 0

    private var byBin: [Int: Double] = [:]
    private var sortedCache: [HistorySample]?
    private var saveTask: Task<Void, Never>?
    private let fileURL: URL?

    init(fileURL: URL? = GlucoseHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveNow()
            }
        }
    }

    /// All samples ordered by time, one per five-minute bin.
    var samples: [HistorySample] {
        if let sortedCache { return sortedCache }
        let sorted = byBin.map { HistorySample(t: $0.key, v: $0.value) }.sorted { $0.t < $1.t }
        sortedCache = sorted
        return sorted
    }

    var isEmpty: Bool { byBin.isEmpty }

    var earliestDate: Date? {
        byBin.keys.min().map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Samples with a timestamp at or after `start`.
    func samples(since start: Date) -> [HistorySample] {
        let all = samples
        let startKey = Int(start.timeIntervalSince1970)
        var low = 0
        var high = all.count
        while low < high {
            let mid = (low + high) / 2
            if all[mid].t < startKey { low = mid + 1 } else { high = mid }
        }
        return Array(all[low...])
    }

    /// Adds readings to the store. Existing bins are kept, so the first value seen for a slot wins.
    /// Returns true when anything changed.
    @discardableResult
    func merge(_ readings: [GlucoseReading]) -> Bool {
        var sums: [Int: (total: Double, count: Int)] = [:]
        for reading in readings {
            guard reading.valueMgDl.isFinite, reading.valueMgDl > 0 else { continue }
            let key = Int(reading.timestamp.timeIntervalSince1970) / Self.binSeconds * Self.binSeconds
            guard byBin[key] == nil else { continue }
            let entry = sums[key] ?? (0, 0)
            sums[key] = (entry.total + reading.valueMgDl, entry.count + 1)
        }
        guard !sums.isEmpty else { return false }
        for (key, entry) in sums {
            // One decimal place is plenty for mg/dL and keeps the JSON file compact.
            byBin[key] = (entry.total / Double(entry.count) * 10).rounded() / 10
        }
        didChange()
        return true
    }

    /// Removes samples older than the retention period. Returns true when anything changed.
    @discardableResult
    func prune(retentionDays: Int, now: Date = .now) -> Bool {
        let cutoff = Int(now.timeIntervalSince1970) - max(1, retentionDays) * 86_400
        let stale = byBin.keys.filter { $0 < cutoff }
        guard !stale.isEmpty else { return false }
        for key in stale { byBin.removeValue(forKey: key) }
        didChange()
        return true
    }

    func removeAll() {
        guard !byBin.isEmpty else { return }
        byBin.removeAll()
        didChange()
    }

    // MARK: - Persistence

    nonisolated private static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("GlucoBar", isDirectory: true)
            .appendingPathComponent("glucose-history-v1.json")
    }

    private func didChange() {
        version += 1
        sortedCache = nil
        scheduleSave()
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([HistorySample].self, from: data) else { return }
        for sample in decoded where sample.v.isFinite && sample.v > 0 {
            byBin[sample.t] = sample.v
        }
        sortedCache = nil
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(samples)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // History is a convenience cache; losing a save is not fatal.
        }
    }
}
