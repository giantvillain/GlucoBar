import SwiftUI
import Foundation
import Combine
import AppKit
import ServiceManagement

@MainActor
final class LibreLinkUpService: ObservableObject {
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var useMmolPerL: Bool = false {
        didSet { persistPreferences() }
    }
    @Published var launchAtLoginEnabled: Bool = false
    @Published var graphRange: GraphRange = .hours4 {
        didSet { persistPreferences() }
    }
    @Published var isLoading: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var errorMessage: String?
    @Published var currentReading: GlucoseReading?
    @Published var readingHistory: [GlucoseReading] = []
    @Published var lastUpdated: Date?
    @Published private(set) var statusTick: Date = .now

    private let apiClient: LibreLinkUpAPIClient
    private var authToken: String?
    private var accountId: String?
    private var selectedConnection: LibreLinkConnection?
    private var statusTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    private let preferencesKey = "GlucoBarLibreLinkUpPreferences"
    private static let graphCacheKey = "GlucoBarLibreLinkUpGraphCache"
    private static let cachedHistoryWindow: TimeInterval = 12 * 60 * 60
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
    private static let emailKeyCandidates = [
        "GlucoBarLibreLinkUp.email",
        "LibreLinkUp.email",
        "LibreLinkUpEmail",
        "librelinkup.email",
        "email"
    ]
    private static let passwordKeyCandidates = [
        "GlucoBarLibreLinkUp.password",
        "LibreLinkUp.password",
        "LibreLinkUpPassword",
        "librelinkup.password",
        "password"
    ]

    init(apiClient: LibreLinkUpAPIClient? = nil) {
        self.apiClient = apiClient ?? LibreLinkUpAPIClient()
        restorePreferences()
        restoreCachedHistory()
        launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        startStatusTimer()
        startRefreshLoop()

        if hasStoredCredentials {
            Task { await authenticate() }
        }
    }

    deinit {
        statusTimer?.invalidate()
        refreshTask?.cancel()
    }

    var hasStoredCredentials: Bool {
        !email.isEmpty && !password.isEmpty
    }

    var displayUnitLabel: String {
        useMmolPerL ? "mmol/L" : "mg/dL"
    }

    var graphReadings: [ReadingSample] {
        let sorted = readingHistory.sorted(by: { $0.timestamp < $1.timestamp })
        guard !sorted.isEmpty else { return [] }

        let cutoff = statusTick.addingTimeInterval(-graphRange.windowInterval)
        let filtered = sorted.filter { $0.timestamp >= cutoff }
        if !filtered.isEmpty {
            return filtered
        }

        return Array(sorted.suffix(min(sorted.count, 24)))
    }

    var graphBounds: (min: Double, max: Double) {
        fixedGraphBounds
    }

    var graphYAxisLabels: (top: String, middle: String, bottom: String) {
        return (
            top: formattedValue(for: fixedGraphBounds.max),
            middle: "",
            bottom: formattedValue(for: fixedGraphBounds.min)
        )
    }

    var graphTargetLabels: (high: String?, low: String?) {
        (
            high: targetHighMgDl.map { formattedValue(for: $0) },
            low: targetLowMgDl.map { formattedValue(for: $0) }
        )
    }

    var graphXAxisLabels: (left: String, middle: String, right: String) {
        let readings = graphReadings
        guard let first = readings.first, let last = readings.last else {
            return ("--", "--", "--")
        }

        let calendar = Calendar.current
        let roundedFirst = calendar.dateInterval(of: .hour, for: first.timestamp)?.start ?? first.timestamp
        let roundedLast = calendar.dateInterval(of: .hour, for: last.timestamp)?.end ?? last.timestamp
        let middleDate = roundedFirst.addingTimeInterval(roundedLast.timeIntervalSince(roundedFirst) / 2.0)

        return (
            left: Self.timeFormatter.string(from: roundedFirst),
            middle: Self.timeFormatter.string(from: middleDate),
            right: Self.timeFormatter.string(from: roundedLast)
        )
    }

    var targetLowMgDl: Double? {
        selectedConnection?.targetLow
    }

    var targetHighMgDl: Double? {
        selectedConnection?.targetHigh
    }

    var connectionState: ConnectionState {
        if let errorMessage {
            return .error(errorMessage)
        }
        if isLoading {
            return isAuthenticated ? .refreshing : .signingIn
        }
        guard hasStoredCredentials else {
            return .signedOut
        }
        if !isAuthenticated {
            return .signingIn
        }
        if isDataStale {
            return .stale
        }
        return .connected
    }

    var statusHeadline: String {
        switch connectionState {
        case .signedOut:
            return "Sign in to LibreLinkUp"
        case .signingIn:
            return "Signing in..."
        case .refreshing:
            return "Refreshing glucose data..."
        case .connected:
            if let selectedConnection {
                return "Connected to \(selectedConnection.displayName)"
            }
            return "Connected"
        case .stale:
            if let selectedConnection {
                return "Connected to \(selectedConnection.displayName)"
            }
            return "Data is stale"
        case .error:
            return "Connection problem"
        }
    }

    var statusDetail: String? {
        switch connectionState {
        case .signedOut:
            return "Open Settings and enter your LibreLinkUp credentials."
        case .signingIn:
            return "Checking your account and loading the latest glucose data."
        case .refreshing:
            return "Updating the graph from LibreLinkUp."
        case .connected:
            return lastUpdatedText
        case .stale:
            return lastUpdatedText ?? "The last reading is older than expected."
        case .error(let message):
            return message
        }
    }

    var primaryActionTitle: String {
        switch connectionState {
        case .signedOut, .signingIn, .error:
            return "Reconnect"
        case .refreshing:
            return "Refreshing"
        case .connected, .stale:
            return "Refresh"
        }
    }

    var primaryActionSymbol: String {
        switch connectionState {
        case .signedOut, .signingIn, .error:
            return "arrow.triangle.2.circlepath"
        case .refreshing:
            return "hourglass"
        case .connected, .stale:
            return "arrow.clockwise"
        }
    }

    var shouldReconnect: Bool {
        switch connectionState {
        case .signedOut, .signingIn, .error:
            return true
        case .refreshing, .connected, .stale:
            return false
        }
    }

    var canRefresh: Bool {
        !isLoading && hasStoredCredentials
    }

    var menuStatusText: String {
        if let errorMessage {
            return errorMessage
        }

        if isLoading {
            if isAuthenticated {
                return "Refreshing glucose data..."
            }
            return hasStoredCredentials ? "Signing in..." : "Open Settings to sign in."
        }

        if !hasStoredCredentials {
            return "Open Settings to sign in."
        }

        if isAuthenticated {
            if currentReading != nil {
                if let selectedConnection {
                    return "Connected to \(selectedConnection.displayName)"
                }
                return "Connected"
            }
            return "Waiting for the first live reading."
        }

        return "Open Settings to sign in."
    }

    var menuStatusColor: Color {
        if errorMessage != nil { return .red }
        if isLoading { return .orange }
        if isDataStale { return .orange }
        if isAuthenticated { return .secondary }
        return .secondary
    }

    var menuBarValueText: String {
        guard let reading = currentReading else { return "--" }
        return formattedValue(for: reading.valueMgDl)
    }

    var menuBarTrendSymbol: String {
        trendSymbol(for: displayTrendArrow) ?? "→"
    }

    var menuBarTrendColor: Color {
        trendColor(for: displayTrendArrow)
    }

    var menuBarBadgeText: String {
        isDataStale ? "⚠" : ""
    }

    var menuBarDisplayText: String {
        var text = menuBarValueText
        text += " \(menuBarTrendSymbol)"
        if isDataStale {
            text += " \(menuBarBadgeText)"
        }
        return text
    }

    var lastUpdatedText: String? {
        guard let referenceDate = lastKnownReadingDate else { return nil }
        let elapsed = max(0, Int(statusTick.timeIntervalSince(referenceDate) / 60.0))
        if elapsed < 60 {
            return "Updated \(elapsed)m ago"
        }
        let hours = elapsed / 60
        let minutes = elapsed % 60
        if hours < 24 {
            return minutes == 0 ? "Updated \(hours)h ago" : "Updated \(hours)h \(minutes)m ago"
        }
        let days = hours / 24
        return "Updated \(days)d ago"
    }

    var isDataStale: Bool {
        guard let referenceDate = lastKnownReadingDate else { return false }
        return statusTick.timeIntervalSince(referenceDate) > 15 * 60
    }

    func formattedValue(for valueMgDl: Double) -> String {
        if useMmolPerL {
            return String(format: "%.1f", valueMgDl / 18.0)
        }
        return String(format: "%.0f", valueMgDl.rounded())
    }

    func trendSymbol(for trendArrow: Int?) -> String? {
        guard let trendArrow else { return nil }
        switch trendArrow {
        case ..<1:
            return nil
        case 1:
            return "↓"
        case 2:
            return "↘"
        case 3:
            return "→"
        case 4:
            return "↗"
        case 5:
            return "↑"
        case 6...:
            return "↑↑"
        default:
            return nil
        }
    }

    func trendColor(for trendArrow: Int?) -> Color {
        guard let trendArrow else { return .secondary }
        switch trendArrow {
        case 1, 2:
            return .red
        case 3:
            return .secondary
        case 4, 5, 6...:
            return .green
        default:
            return .secondary
        }
    }

    func authenticate() async {
        guard hasStoredCredentials else {
            errorMessage = "Open Settings to sign in."
            isAuthenticated = false
            return
        }

        await runRefreshFlow(forceLogin: true)
    }

    func fetchGlucose() async {
        await runRefreshFlow(forceLogin: false)
    }

    func reconnect() async {
        await runRefreshFlow(forceLogin: true)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) async {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        } catch {
            errorMessage = error.localizedDescription
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func runRefreshFlow(forceLogin: Bool) async {
        guard hasStoredCredentials else {
            errorMessage = "Open Settings to sign in."
            isAuthenticated = false
            currentReading = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            if forceLogin || authToken == nil || accountId == nil {
                let session = try await apiClient.authenticate(email: email, password: password)
                authToken = session.authToken
                accountId = session.accountId
            }

            try await refreshConnectionData(retryAfterRelogin: true)
            isAuthenticated = true
            errorMessage = nil
            persistCredentials()
            persistGraphCache()
            updateLastKnownReading()
        } catch {
            isAuthenticated = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func refreshConnectionData(retryAfterRelogin: Bool) async throws {
        guard let authToken, let accountId else {
            throw LibreLinkUpError.missingCredentials
        }

        let connections = try await apiClient.fetchConnections(authToken: authToken, accountId: accountId)
        guard let connection = connections.first(where: { $0.patientId?.isEmpty == false }) ?? connections.first else {
            selectedConnection = nil
            readingHistory = []
            currentReading = nil
            throw LibreLinkUpError.noConnections
        }

        selectedConnection = connection

        let patientId = connection.patientId ?? connection.id
        guard !patientId.isEmpty else {
            throw LibreLinkUpError.missingPatientId
        }

        let graph = try await apiClient.fetchGraph(
            patientId: patientId,
            authToken: authToken,
            accountId: accountId
        )

        let graphReadings = graph.graphReadings.sorted(by: { $0.timestamp < $1.timestamp })
        let connectionReading = graph.data.connection?.currentReading ?? connection.currentReading
        let merged = Self.merge(readings: graphReadings, with: connectionReading)

        readingHistory = Self.trimmedHistory(merged)
        currentReading = readingHistory.last
        lastUpdated = currentReading?.timestamp ?? readingHistory.last?.timestamp
    }

    private func restorePreferences() {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey) else {
            loadStoredCredentials()
            return
        }

        do {
            let preferences = try JSONDecoder.libreLinkUp.decode(StoredPreferences.self, from: data)
            useMmolPerL = preferences.useMmolPerL
            graphRange = preferences.graphRange
        } catch {
            // Fall back to defaults if preferences become unreadable.
        }

        loadStoredCredentials()
    }

    private func persistPreferences() {
        let preferences = StoredPreferences(useMmolPerL: useMmolPerL, graphRange: graphRange)
        do {
            let data = try JSONEncoder.libreLinkUp.encode(preferences)
            UserDefaults.standard.set(data, forKey: preferencesKey)
        } catch {
            // Ignore preference write failures.
        }
    }

    private func loadStoredCredentials() {
        for key in Self.emailKeyCandidates {
            if let value = KeychainHelper.load(key: key) {
                email = value
                break
            }
        }

        for key in Self.passwordKeyCandidates {
            if let value = KeychainHelper.load(key: key) {
                password = value
                break
            }
        }
    }

    private func persistCredentials() {
        guard !email.isEmpty, !password.isEmpty else { return }
        KeychainHelper.save(key: Self.emailKeyCandidates[0], value: email)
        KeychainHelper.save(key: Self.passwordKeyCandidates[0], value: password)
    }

    private func restoreCachedHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.graphCacheKey) else {
            return
        }

        do {
            let cache = try JSONDecoder.libreLinkUp.decode(GraphCache.self, from: data)
            readingHistory = Self.trimmedHistory(cache.readings)
            currentReading = readingHistory.last
            lastUpdated = currentReading?.timestamp
        } catch {
            // Ignore unreadable cache and continue fresh.
        }
    }

    private func persistGraphCache() {
        let cache = GraphCache(readings: Self.trimmedHistory(readingHistory))
        do {
            let data = try JSONEncoder.libreLinkUp.encode(cache)
            UserDefaults.standard.set(data, forKey: Self.graphCacheKey)
        } catch {
            // Ignore cache write failures.
        }
    }

    private func updateLastKnownReading() {
        currentReading = readingHistory.last ?? currentReading
        lastUpdated = currentReading?.timestamp
    }

    func copyCurrentReadingToClipboard() {
        guard let currentReading else { return }
        let text = "\(formattedValue(for: currentReading.valueMgDl)) \(menuBarTrendSymbol)"
            .trimmingCharacters(in: .whitespaces)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openLibreLinkUpPortal() {
        guard let url = URL(string: "https://www.libreview.com/") else { return }
        NSWorkspace.shared.open(url)
    }

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.statusTick = .now
            }
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let interval = self.autoRefreshInterval

                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }

                if Task.isCancelled {
                    break
                }

                await self.refreshIfNeeded()
            }
        }
    }

    private func refreshIfNeeded() async {
        guard hasStoredCredentials, !isLoading else { return }
        await fetchGlucose()
    }

    private var autoRefreshInterval: TimeInterval {
        if !hasStoredCredentials {
            return 15 * 60
        }
        if errorMessage != nil {
            return ProcessInfo.processInfo.isLowPowerModeEnabled ? 15 * 60 : 5 * 60
        }
        if !isAuthenticated {
            return 5 * 60
        }
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? 300 : 60
    }

    private func isAuthenticationError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .userAuthenticationRequired
        }
        if let libError = error as? LibreLinkUpError {
            return libError.isAuthenticationRelated
        }
        return false
    }

    private var lastKnownReadingDate: Date? {
        currentReading?.timestamp ?? readingHistory.last?.timestamp ?? lastUpdated
    }

    private var displayTrendArrow: Int? {
        currentReading?.trendArrow ?? readingHistory.last(where: { $0.trendArrow != nil })?.trendArrow
    }

    private var fixedGraphBounds: (min: Double, max: Double) {
        if useMmolPerL {
            return (0, 20 * 18.0)
        }
        return (0, 200)
    }

    private static func merge(readings: [GlucoseReading], with current: GlucoseReading?) -> [GlucoseReading] {
        var merged = readings
        if let current, merged.last?.timestamp != current.timestamp {
            merged.append(current)
        }

        var unique: [String: GlucoseReading] = [:]
        for reading in merged {
            unique[reading.identityKey] = reading
        }
        return unique.values.sorted(by: { $0.timestamp < $1.timestamp })
    }

    private static func trimmedHistory(_ readings: [GlucoseReading]) -> [GlucoseReading] {
        let sorted = readings.sorted(by: { $0.timestamp < $1.timestamp })
        guard let latestTimestamp = sorted.last?.timestamp else { return [] }

        let cutoff = latestTimestamp.addingTimeInterval(-cachedHistoryWindow)
        let trimmed = sorted.filter { $0.timestamp >= cutoff }
        return trimmed.isEmpty ? Array(sorted.suffix(1)) : trimmed
    }

}

enum ConnectionState: Equatable {
    case signedOut
    case signingIn
    case refreshing
    case connected
    case stale
    case error(String)
}
