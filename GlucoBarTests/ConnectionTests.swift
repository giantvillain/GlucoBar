import XCTest
import Foundation

nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@MainActor
final class ConnectionTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    private let login = #"{"status":0,"data":{"user":{"id":"account"},"authTicket":{"token":"test-token"}}}"#
    private let connections = #"{"status":0,"data":[{"id":"a","patientId":"one","firstName":"One"},{"id":"b","patientId":"two","firstName":"Two"}]}"#
    private let graph = #"{"status":0,"data":{"graphData":[{"Timestamp":"2024-01-01T00:00:00Z","ValueInMgPerDl":123}]}}"#

    func testMultiplePeopleRequireExplicitSelection() async throws {
        let login = login, connections = connections
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("login") { return (200, login) }
            return (200, connections)
        }
        defer { StubURLProtocol.handler = nil }
        let manager = GlucoseConnectionManager(api: LibreLinkUpAPIClient(session: session()))
        var people = 0
        manager.onConnections = { people = $0.count }
        do {
            _ = try await manager.fetch(source: .libreLinkUp, email: "test@example.com", password: "test", url: "", token: "", personID: nil, forceLogin: false)
            XCTFail("Must not silently select the first person")
        } catch let error as GlucoseConnectionManager.ConnectionError {
            if case .choosePerson = error { } else { XCTFail("Wrong selection error") }
        }
        XCTAssertEqual(people, 2)
    }

    func testExplicitPersonDeterminesRequestAndProfile() async throws {
        let login = login, connections = connections, graph = graph
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("login") { return (200, login) }
            if request.url!.path.hasSuffix("connections") { return (200, connections) }
            XCTAssertTrue(request.url!.path.contains("/two/graph"))
            return (200, graph)
        }
        defer { StubURLProtocol.handler = nil }
        let manager = GlucoseConnectionManager(api: LibreLinkUpAPIClient(session: session()))
        let result = try await manager.fetch(source: .libreLinkUp, email: "test@example.com", password: "test", url: "", token: "", personID: "two", forceLogin: false)
        XCTAssertEqual(result.selected?.patientId, "two")
        XCTAssertEqual(result.profileID, ProfileIdentity.key(source: "libreLinkUp", account: "test@example.com", person: "two"))
        XCTAssertEqual(result.readings.first?.valueMgDl, 123)
    }

    func testMissingPersonDoesNotFallBackToAnother() async throws {
        let login = login, connections = connections
        StubURLProtocol.handler = { request in (200, request.url!.path.hasSuffix("login") ? login : connections) }
        defer { StubURLProtocol.handler = nil }
        let manager = GlucoseConnectionManager(api: LibreLinkUpAPIClient(session: session()))
        do {
            _ = try await manager.fetch(source: .libreLinkUp, email: "test@example.com", password: "test", url: "", token: "", personID: "removed", forceLogin: false)
            XCTFail("Missing person must not fall back")
        } catch let error as GlucoseConnectionManager.ConnectionError {
            if case .personUnavailable = error { } else { XCTFail("Wrong selection error") }
        }
    }

    func testExpiredTokenRetriesLoginOnce() async throws {
        let login = login, connections = connections, graph = graph
        nonisolated(unsafe) var logins = 0
        nonisolated(unsafe) var connectionRequests = 0
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("login") { logins += 1; return (200, login) }
            if request.url!.path.hasSuffix("connections") {
                connectionRequests += 1
                return connectionRequests == 1 ? (401, "{}") : (200, connections)
            }
            return (200, graph)
        }
        defer { StubURLProtocol.handler = nil }
        let manager = GlucoseConnectionManager(api: LibreLinkUpAPIClient(session: session()))
        _ = try await manager.fetch(source: .libreLinkUp, email: "test@example.com", password: "test", url: "", token: "", personID: "one", forceLogin: false)
        XCTAssertEqual(logins, 2)
        XCTAssertEqual(connectionRequests, 2)
    }

    func testNightscoutPreservesDoubleDownAndRejectsInvalidValues() async throws {
        StubURLProtocol.handler = { _ in (200, #"[{"sgv":110,"direction":"DoubleDown","date":1704067200000},{"sgv":-1,"date":1704067200000}]"#) }
        defer { StubURLProtocol.handler = nil }
        let manager = GlucoseConnectionManager(nightscout: NightscoutAPIClient(session: session()))
        let result = try await manager.fetch(source: .nightscout, email: "", password: "", url: "example.com", token: "", personID: nil, forceLogin: false)
        XCTAssertEqual(result.readings.count, 1)
        XCTAssertEqual(result.readings.first?.trendArrow, 7)
    }
    func testResetDiscardsNightscoutResponseAlreadyInFlight() async throws {
        let entered = XCTestExpectation(description: "Request started")
        let gate = DispatchSemaphore(value: 0)
        StubURLProtocol.handler = { _ in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return (200, #"[{"sgv":110,"date":1704067200000}]"#)
        }
        defer { StubURLProtocol.handler = nil; gate.signal() }
        let manager = GlucoseConnectionManager(nightscout: NightscoutAPIClient(session: session()))
        let task = Task {
            try await manager.fetch(source: .nightscout, email: "", password: "", url: "example.com", token: "", personID: nil, forceLogin: false)
        }
        await fulfillment(of: [entered], timeout: 2)
        manager.reset()
        gate.signal()
        do {
            _ = try await task.value
            XCTFail("The previous profile's response must be discarded")
        } catch is CancellationError { }
    }

}
