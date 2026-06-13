import Foundation

public struct NightscoutEntry: Decodable {
    public let sgv: Double?
    public let direction: String?
    public let date: Date?
    
    enum CodingKeys: String, CodingKey {
        case sgv, direction, date, dateString
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Decode sgv as Double? from Int or Double
        if let intSgv = try? container.decode(Int.self, forKey: .sgv) {
            self.sgv = Double(intSgv)
        } else if let doubleSgv = try? container.decode(Double.self, forKey: .sgv) {
            self.sgv = doubleSgv
        } else {
            self.sgv = nil
        }
        
        self.direction = try? container.decode(String.self, forKey: .direction)
        
        // Decode date from "date" key (Int or Double ms since 1970)
        // or from "dateString" key (ISO8601 string)
        if let intMs = try? container.decode(Int64.self, forKey: .date) {
            self.date = Date(timeIntervalSince1970: TimeInterval(intMs) / 1000)
        } else if let doubleMs = try? container.decode(Double.self, forKey: .date) {
            self.date = Date(timeIntervalSince1970: doubleMs / 1000)
        } else if let dateString = try? container.decode(String.self, forKey: .dateString) {
            let formatter = ISO8601DateFormatter()
            self.date = formatter.date(from: dateString)
        } else {
            self.date = nil
        }
    }
}

public enum NightscoutAPIError: Error, LocalizedError {
    case invalidBaseURL
    case httpStatus(Int)
    case invalidResponse
    case decodingFailed(Error)
    
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The base URL provided is invalid."
        case .httpStatus(let code):
            return "HTTP request failed with status code \(code)."
        case .invalidResponse:
            return "The response from the server was invalid."
        case .decodingFailed(let error):
            return "Decoding of response failed: \(error.localizedDescription)"
        }
    }
}

public final class NightscoutAPIClient {
    private let session: URLSession
    
    public init(session: URLSession = .shared) {
        self.session = session
    }
    
    public func fetchEntries(baseURL: String, token: String?, count: Int) async throws -> [NightscoutEntry] {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString: String
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            urlString = trimmed
        } else {
            urlString = "https://" + trimmed
        }
        
        guard var components = URLComponents(string: urlString) else {
            throw NightscoutAPIError.invalidBaseURL
        }
        
        // Append path /api/v1/entries.json
        var path = components.path
        if !path.hasSuffix("/") {
            path += "/"
        }
        path += "api/v1/entries.json"
        components.path = path
        
        // Query items
        var queryItems = [URLQueryItem(name: "count", value: String(count))]
        if let token = token, !token.isEmpty {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = queryItems
        
        guard let url = components.url else {
            throw NightscoutAPIError.invalidBaseURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NightscoutAPIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NightscoutAPIError.httpStatus(httpResponse.statusCode)
        }
        
        do {
            let decoder = JSONDecoder()
            let entries = try decoder.decode([NightscoutEntry].self, from: data)
            let sorted = entries.sorted { lhs, rhs in
                switch (lhs.date, rhs.date) {
                case (nil, nil):
                    return false
                case (nil, _):
                    return true
                case (_, nil):
                    return false
                case (let l?, let r?):
                    return l < r
                }
            }
            return sorted
        } catch {
            throw NightscoutAPIError.decodingFailed(error)
        }
    }
}
