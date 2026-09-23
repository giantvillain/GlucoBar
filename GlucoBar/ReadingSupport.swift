import Foundation
import CryptoKit

nonisolated enum ReadingSupport {
    /// Longer intervals represent missing data, not a measured glucose trajectory.
    static let maximumGap: TimeInterval = 10 * 60

    static func segments(_ readings: [GlucoseReading]) -> [[GlucoseReading]] {
        var result: [[GlucoseReading]] = []
        for reading in readings.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let previous = result.last?.last,
               reading.timestamp.timeIntervalSince(previous.timestamp) <= maximumGap {
                result[result.count - 1].append(reading)
            } else {
                result.append([reading])
            }
        }
        return result
    }

    static func formatted(_ mgDl: Double, mmol: Bool) -> String {
        String(format: mmol ? "%.1f" : "%.0f", mmol ? mgDl / 18 : mgDl)
    }

    static func trendSymbol(_ arrow: Int?) -> String {
        switch arrow {
        case 1: return "↓"
        case 2: return "↘"
        case 3: return "→"
        case 4: return "↗"
        case 5: return "↑"
        case 6: return "↑↑"
        case 7: return "↓↓"
        default: return "?"
        }
    }

    static func trendDescription(_ arrow: Int?) -> String {
        switch arrow {
        case 1: return "falling"
        case 2: return "falling slowly"
        case 3: return "stable"
        case 4: return "rising slowly"
        case 5: return "rising"
        case 6: return "rising quickly"
        case 7: return "falling quickly"
        default: return "unavailable"
        }
    }

    static func nightscoutArrow(_ direction: String?) -> Int? {
        switch direction?.lowercased() {
        case "doubledown": return 7
        case "singledown": return 1
        case "fortyfivedown": return 2
        case "flat": return 3
        case "fortyfiveup": return 4
        case "singleup": return 5
        case "doubleup": return 6
        default: return nil
        }
    }
}

/// Opaque filenames keep account identifiers out of the history directory.
nonisolated enum ProfileIdentity {
    static func key(source: String, account: String, person: String = "") -> String {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = source == "libreLinkUp" ? trimmed.lowercased() : trimmed
        let parts = [source, normalized, person]
        let bytes = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func nightscoutAccount(_ address: String) -> String {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URLComponents(string: raw.contains("://") ? raw : "https://" + raw) else { return raw }
        url.host = url.host?.lowercased()
        url.query = nil
        url.fragment = nil
        while url.path.hasSuffix("/") { url.path.removeLast() }
        return url.string ?? raw
    }
}
