import Foundation
import SwiftUI

typealias ReadingSample = GlucoseReading

enum GraphRange: Int, CaseIterable, Identifiable, Codable, Hashable {
    case hours2 = 2
    case hours4 = 4
    case hours8 = 8
    case hours12 = 12

    var id: Int { rawValue }

    var title: String {
        "\(rawValue)h"
    }

    var windowInterval: TimeInterval {
        TimeInterval(rawValue * 60 * 60)
    }
}

enum DataSource: String, CaseIterable, Identifiable, Codable, Hashable {
    case libreLinkUp
    case nightscout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .libreLinkUp: return "LibreLinkUp"
        case .nightscout: return "Nightscout"
        }
    }
}

struct GlucoseReading: Identifiable, Codable, Equatable {
    let id: String
    let timestamp: Date
    let valueMgDl: Double
    let trendArrow: Int?
    let factoryTimestamp: Date?

    var identityKey: String {
        "\(Int(timestamp.timeIntervalSince1970))-\(Int(valueMgDl.rounded()))-\(trendArrow ?? -1)"
    }

    init(
        id: String? = nil,
        timestamp: Date,
        valueMgDl: Double,
        trendArrow: Int? = nil,
        factoryTimestamp: Date? = nil
    ) {
        self.id = id ?? "\(Int(timestamp.timeIntervalSince1970))-\(Int(valueMgDl.rounded()))-\(trendArrow ?? -1)"
        self.timestamp = timestamp
        self.valueMgDl = valueMgDl
        self.trendArrow = trendArrow
        self.factoryTimestamp = factoryTimestamp
    }

    init?(payload: MeasurementPayload) {
        guard let timestamp = payload.timestamp ?? payload.factoryTimestamp,
              let valueMgDl = payload.valueMgDl
        else { return nil }

        self.init(
            timestamp: timestamp,
            valueMgDl: valueMgDl,
            trendArrow: payload.trendArrow,
            factoryTimestamp: payload.factoryTimestamp
        )
    }
}

struct LibreLinkConnection: Decodable {
    let id: String
    let patientId: String?
    let firstName: String?
    let lastName: String?
    let targetLow: Double?
    let targetHigh: Double?
    let uom: Int?
    let glucoseMeasurement: MeasurementPayload?
    let glucoseItem: MeasurementPayload?

    var displayName: String {
        let nameParts = [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }
        return nameParts.isEmpty ? "LibreLinkUp" : nameParts.joined(separator: " ")
    }

    var currentReading: GlucoseReading? {
        if let glucoseMeasurement, let reading = GlucoseReading(payload: glucoseMeasurement) {
            return reading
        }
        if let glucoseItem, let reading = GlucoseReading(payload: glucoseItem) {
            return reading
        }
        return nil
    }
}

struct ConnectionsResponse: Decodable {
    let status: Int
    let data: [LibreLinkConnection]
    let minimumVersion: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Int.self, forKey: .status)

        var resolvedMinimumVersion: String?
        if let data = try? container.decode([LibreLinkConnection].self, forKey: .data) {
            self.data = data
        } else if let versionHint = try? container.decode(VersionHint.self, forKey: .data) {
            self.data = []
            resolvedMinimumVersion = versionHint.minimumVersion
        } else if let single = try? container.decode(LibreLinkConnection.self, forKey: .data) {
            self.data = [single]
        } else {
            self.data = []
        }
        minimumVersion = resolvedMinimumVersion
    }
}

struct GraphResponse: Decodable {
    let status: Int
    let data: GraphPayload
    let minimumVersion: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Int.self, forKey: .status)

        var resolvedMinimumVersion: String?
        if let payload = try? container.decode(GraphPayload.self, forKey: .data) {
            data = payload
        } else if let versionHint = try? container.decode(VersionHint.self, forKey: .data) {
            data = GraphPayload(connection: nil, graphData: [])
            resolvedMinimumVersion = versionHint.minimumVersion
        } else {
            data = GraphPayload(connection: nil, graphData: [])
        }
        minimumVersion = resolvedMinimumVersion
    }

    var graphReadings: [GlucoseReading] {
        data.graphData.compactMap { GlucoseReading(payload: $0) }
    }
}

struct GraphPayload: Decodable {
    let connection: LibreLinkConnection?
    let graphData: [MeasurementPayload]

    private enum CodingKeys: String, CodingKey {
        case connection
        case graphData
    }

    init(connection: LibreLinkConnection?, graphData: [MeasurementPayload]) {
        self.connection = connection
        self.graphData = graphData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connection = try container.decodeIfPresent(LibreLinkConnection.self, forKey: .connection)
        graphData = try container.decodeIfPresent([MeasurementPayload].self, forKey: .graphData) ?? []
    }
}

struct MeasurementPayload: Decodable {
    let timestamp: Date?
    let factoryTimestamp: Date?
    let valueMgDl: Double?
    let trendArrow: Int?
    let trendMessage: String?

    private enum CodingKeys: String, CodingKey {
        case timestamp = "Timestamp"
        case factoryTimestamp = "FactoryTimestamp"
        case valueMgDl = "ValueInMgPerDl"
        case value = "Value"
        case glucoseUnits = "GlucoseUnits"
        case trendArrow = "TrendArrow"
        case trendMessage = "TrendMessage"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decodeDateIfPresent(forKey: .timestamp)
        factoryTimestamp = try container.decodeDateIfPresent(forKey: .factoryTimestamp)
        trendArrow = try container.decodeIntIfPresent(forKey: .trendArrow)
        trendMessage = try container.decodeIfPresent(String.self, forKey: .trendMessage)

        if let mgDl = try container.decodeDoubleIfPresent(forKey: .valueMgDl) {
            valueMgDl = mgDl
        } else if let rawValue = try container.decodeDoubleIfPresent(forKey: .value) {
            let units = try container.decodeIntIfPresent(forKey: .glucoseUnits) ?? 1
            valueMgDl = units == 2 ? (rawValue * 18.0) : rawValue
        } else {
            valueMgDl = nil
        }
    }
}

struct LoginRequest: Encodable {
    let email: String
    let password: String
}

struct LoginResponse: Decodable {
    let status: Int
    let data: LoginData?
    let minimumVersion: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Int.self, forKey: .status)

        var resolvedMinimumVersion: String?
        if let loginData = try? container.decode(LoginData.self, forKey: .data) {
            data = loginData
        } else if let versionHint = try? container.decode(VersionHint.self, forKey: .data) {
            data = nil
            resolvedMinimumVersion = versionHint.minimumVersion
        } else {
            data = nil
        }
        minimumVersion = resolvedMinimumVersion
    }
}

struct LoginData: Decodable {
    let user: LoginUser
    let authTicket: AuthTicket?
}

struct LoginUser: Decodable {
    let id: String
}

struct AuthTicket: Decodable {
    let token: String
}

struct StoredPreferences: Codable {
    let useMmolPerL: Bool
    let graphRange: GraphRange?
    let graphWindowHours: Int?
    let dataSource: DataSource?
    let nightscoutBaseURL: String?
    let nightscoutToken: String?
    let showTargetBands: Bool?
    let lowThresholdEnabled: Bool?
    let highThresholdEnabled: Bool?
    let customTargetsEnabled: Bool?
    let customLowMgDl: Double?
    let customHighMgDl: Double?
}

struct GraphCache: Codable {
    let readings: [GlucoseReading]
}

struct VersionHint: Decodable {
    let minimumVersion: String
}

struct LoginSession {
    let authToken: String
    let accountId: String
}

enum LibreLinkUpError: LocalizedError {
    case missingCredentials
    case missingAuthToken
    case missingPatientId
    case noConnections
    case unauthorized
    case httpStatus(Int)
    case apiStatus(Int)
    case minimumVersion(String)
    case invalidResponse
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Open Settings to sign in."
        case .missingAuthToken:
            return "LibreLinkUp login did not return a token."
        case .missingPatientId:
            return "LibreLinkUp connection is missing a patient ID."
        case .noConnections:
            return "No shared LibreLinkUp connections found."
        case .unauthorized:
            return "LibreLinkUp session expired. Signing in again..."
        case .httpStatus(let status):
            return "LibreLinkUp request failed (\(status))."
        case .apiStatus(let status):
            return "LibreLinkUp returned status \(status)."
        case .minimumVersion(let version):
            return "LibreLinkUp requires app version \(version) or later."
        case .invalidResponse:
            return "LibreLinkUp returned an invalid response."
        case .decodingFailed:
            return "LibreLinkUp response format changed."
        }
    }

    var isAuthenticationRelated: Bool {
        switch self {
        case .missingCredentials, .missingAuthToken, .unauthorized:
            return true
        default:
            return false
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeDateIfPresent(forKey key: Key) throws -> Date? {
        if let string = try decodeIfPresent(String.self, forKey: key) {
            return LibreLinkUpDates.parse(string)
        }
        if let seconds = try decodeIfPresent(TimeInterval.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    func decodeIntIfPresent(forKey key: Key) throws -> Int? {
        if let value = try decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try decodeIfPresent(Double.self, forKey: key) {
            return Int(value.rounded())
        }
        if let string = try decodeIfPresent(String.self, forKey: key) {
            return Int(string)
        }
        return nil
    }

    func decodeDoubleIfPresent(forKey key: Key) throws -> Double? {
        if let value = try decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let string = try decodeIfPresent(String.self, forKey: key) {
            return Double(string)
        }
        return nil
    }
}

private enum LibreLinkUpDates {
    static func parse(_ string: String) -> Date? {
        let formats = [
            "M/d/yyyy h:mm:ss a",
            "MM/dd/yyyy h:mm:ss a",
            "M/d/yyyy h:mm a",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return date
            }
        }

        return nil
    }
}

extension JSONDecoder {
    static var libreLinkUp: JSONDecoder {
        JSONDecoder()
    }
}

extension JSONEncoder {
    static var libreLinkUp: JSONEncoder {
        JSONEncoder()
    }
}
