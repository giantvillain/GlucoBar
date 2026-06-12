import Foundation
import CryptoKit

final class LibreLinkUpAPIClient {
    private let session: URLSession
    private let apiBaseURL = URL(string: "https://api.libreview.io")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func authenticate(email: String, password: String) async throws -> LoginSession {
        let loginURL = Self.url(baseURL: apiBaseURL, path: "llu/auth/login")
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("llu.ios", forHTTPHeaderField: "product")
        request.setValue("4.16.0", forHTTPHeaderField: "version")
        request.httpBody = try JSONEncoder.libreLinkUp.encode(LoginRequest(email: email, password: password))

        let response: LoginResponse = try await send(request)

        if let minimumVersion = response.minimumVersion {
            throw LibreLinkUpError.minimumVersion(minimumVersion)
        }

        guard let token = response.data?.authTicket?.token, !token.isEmpty else {
            throw LibreLinkUpError.missingAuthToken
        }

        let userId = response.data?.user.id ?? email
        return LoginSession(authToken: token, accountId: Self.accountId(from: userId))
    }

    func fetchConnections(authToken: String, accountId: String) async throws -> [LibreLinkConnection] {
        let request = try makeAuthenticatedRequest(
            path: "/llu/connections",
            authToken: authToken,
            accountId: accountId
        )

        let response: ConnectionsResponse = try await send(request)
        guard response.status == 0 else {
            if response.status == 920, let minimumVersion = response.minimumVersion {
                throw LibreLinkUpError.minimumVersion(minimumVersion)
            }
            throw LibreLinkUpError.apiStatus(response.status)
        }

        return response.data
    }

    func fetchGraph(patientId: String, authToken: String, accountId: String) async throws -> GraphResponse {
        let request = try makeAuthenticatedRequest(
            path: "/llu/connections/\(patientId)/graph?minutes=720",
            authToken: authToken,
            accountId: accountId
        )

        let response: GraphResponse = try await send(request)
        guard response.status == 0 else {
            if response.status == 920, let minimumVersion = response.minimumVersion {
                throw LibreLinkUpError.minimumVersion(minimumVersion)
            }
            throw LibreLinkUpError.apiStatus(response.status)
        }

        return response
    }

    private func makeAuthenticatedRequest(path: String, authToken: String, accountId: String) throws -> URLRequest {
        let url = Self.url(baseURL: apiBaseURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("llu.ios", forHTTPHeaderField: "product")
        request.setValue("4.16.0", forHTTPHeaderField: "version")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "Account-Id")
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibreLinkUpError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw LibreLinkUpError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw LibreLinkUpError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder.libreLinkUp.decode(Response.self, from: data)
        } catch {
            throw LibreLinkUpError.decodingFailed(error)
        }
    }

    private static func url(baseURL: URL, path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path

        if let questionMarkIndex = trimmedPath.firstIndex(of: "?") {
            let rawPath = String(trimmedPath[..<questionMarkIndex])
            let rawQuery = String(trimmedPath[trimmedPath.index(after: questionMarkIndex)...])
            components.path = "/\(rawPath)"
            components.percentEncodedQuery = rawQuery
        } else {
            components.path = "/\(trimmedPath)"
        }

        return components.url ?? baseURL
    }

    private static func accountId(from userId: String) -> String {
        let digest = SHA256.hash(data: Data(userId.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
