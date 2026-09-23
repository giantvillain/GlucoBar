import Foundation
import Network
import AppKit

@MainActor
final class GlucoseConnectionManager {
    struct Result {
        let profileID: String
        let readings: [GlucoseReading]
        let connections: [LibreLinkConnection]
        let selected: LibreLinkConnection?
    }

    enum ConnectionError: LocalizedError {
        case choosePerson, personUnavailable
        var errorDescription: String? {
            switch self {
            case .choosePerson: return "Choose a person in Connection settings."
            case .personUnavailable: return "The selected person is no longer shared. Choose a person in Connection settings."
            }
        }
    }

    private var api: LibreLinkUpAPIClient
    private let nightscout: NightscoutAPIClient
    private var generation = UUID()
    private var session: LoginSession?
    private var sessionAccount: String?
    private let monitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var reachable: Bool?
    var onNetworkChange: ((Bool) -> Void)?
    var onWake: (() -> Void)?
    var onConnections: (([LibreLinkConnection]) -> Void)?

    init(api: LibreLinkUpAPIClient? = nil, nightscout: NightscoutAPIClient? = nil) {
        self.api = api ?? LibreLinkUpAPIClient()
        self.nightscout = nightscout ?? NightscoutAPIClient()
    }

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.reachable != online else { return }
                self.reachable = online
                self.onNetworkChange?(online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "GlucoBar.network"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onWake?() }
        }
    }

    deinit {
        monitor.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func reset() {
        generation = UUID()
        session = nil
        sessionAccount = nil
        api = LibreLinkUpAPIClient()
    }

    func fetch(source: DataSource, email: String, password: String, url: String, token: String,
               personID: String?, forceLogin: Bool) async throws -> Result {
        let tokenGeneration = generation
        if source == .nightscout {
            let entries = try await nightscout.fetchEntries(baseURL: url, token: token.isEmpty ? nil : token, count: 1500)
            guard tokenGeneration == generation else { throw CancellationError() }
            let readings = entries.compactMap { entry -> GlucoseReading? in
                guard let date = entry.date, let value = entry.sgv, value.isFinite, value > 0,
                      date <= Date().addingTimeInterval(60) else { return nil }
                return GlucoseReading(timestamp: date, valueMgDl: value, trendArrow: ReadingSupport.nightscoutArrow(entry.direction))
            }
            return Result(profileID: ProfileIdentity.key(source: "nightscout", account: ProfileIdentity.nightscoutAccount(url)),
                          readings: readings, connections: [], selected: nil)
        }

        // Capture the client: resetting during an await cannot redirect the old request to a new session.
        let client = api
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var login = sessionAccount == account && !forceLogin ? session : nil
        if login == nil {
            login = try await client.authenticate(email: email, password: password)
        }
        guard var login else { throw LibreLinkUpError.missingAuthToken }
        let connections: [LibreLinkConnection]
        do {
            connections = try await client.fetchConnections(authToken: login.authToken, accountId: login.accountId)
        } catch let error as LibreLinkUpError where error.isAuthenticationRelated {
            login = try await client.authenticate(email: email, password: password)
            connections = try await client.fetchConnections(authToken: login.authToken, accountId: login.accountId)
        }
        guard client === api else { throw CancellationError() }
        session = login
        sessionAccount = account
        onConnections?(connections)
        guard !connections.isEmpty else { throw LibreLinkUpError.noConnections }
        let selected: LibreLinkConnection
        if let personID, !personID.isEmpty {
            guard let match = connections.first(where: { ($0.patientId ?? $0.id) == personID }) else {
                throw ConnectionError.personUnavailable
            }
            selected = match
        } else {
            guard connections.count == 1, let only = connections.first else { throw ConnectionError.choosePerson }
            selected = only
        }
        let patient = selected.patientId ?? selected.id
        guard !patient.isEmpty else { throw LibreLinkUpError.missingPatientId }
        let graph: GraphResponse
        do {
            graph = try await client.fetchGraph(patientId: patient, authToken: login.authToken, accountId: login.accountId)
        } catch let error as LibreLinkUpError where error.isAuthenticationRelated {
            login = try await client.authenticate(email: email, password: password)
            graph = try await client.fetchGraph(patientId: patient, authToken: login.authToken, accountId: login.accountId)
        }
        guard client === api else { throw CancellationError() }
        session = login
        var readings = graph.graphReadings
        if let latest = graph.data.connection?.currentReading ?? selected.currentReading { readings.append(latest) }
        readings = readings.filter { $0.valueMgDl.isFinite && $0.valueMgDl > 0 && $0.timestamp <= Date().addingTimeInterval(60) }
        return Result(profileID: ProfileIdentity.key(source: "libreLinkUp", account: account, person: patient),
                      readings: readings, connections: connections, selected: selected)
    }
}
