import SwiftUI
import Foundation
import Combine
import AppKit
import ServiceManagement
import Security

@MainActor
final class LibreLinkUpService: ObservableObject {
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var useMmolPerL: Bool = false {
        didSet { persistPreferences() }
    }
    @Published var launchAtLoginEnabled: Bool = false
    @Published var graphWindowHours: Int = 4 {
        didSet {
            let clamped = Self.clampedGraphWindowHours(graphWindowHours)
            if graphWindowHours != clamped {
                graphWindowHours = clamped
                return
            }
            persistPreferences()
        }
    }
    @Published var showTargetBands: Bool = true {
        didSet { persistPreferences() }
    }
    @Published var graphAxisMode: GraphAxisMode = .fixed {
        didSet { persistPreferences() }
    }

    // MARK: Insight preferences

    @Published var predictionEnabled: Bool = true {
        didSet { persistPreferences(); updatePrediction() }
    }
    @Published var predictionHorizonMinutes: Int = 30 {
        didSet {
            let clamped = Self.clamp(predictionHorizonMinutes, to: Self.predictionHorizonOptions)
            if predictionHorizonMinutes != clamped { predictionHorizonMinutes = clamped; return }
            persistPreferences()
        }
    }
    @Published var predictionBandEnabled: Bool = true {
        didSet { persistPreferences() }
    }
    @Published var rollingAverageEnabled: Bool = true {
        didSet { persistPreferences() }
    }
    @Published var rollingAverageMinutes: Int = 60 {
        didSet {
            let clamped = Self.clamp(rollingAverageMinutes, to: Self.rollingAverageOptions)
            if rollingAverageMinutes != clamped { rollingAverageMinutes = clamped; return }
            persistPreferences()
        }
    }
    @Published var typicalDayEnabled: Bool = true {
        didSet { persistPreferences() }
    }
    @Published var typicalDayLookbackDays: Int = 30 {
        didSet {
            let clamped = Self.clamp(typicalDayLookbackDays, to: Self.typicalDayLookbackOptions)
            if typicalDayLookbackDays != clamped { typicalDayLookbackDays = clamped; return }
            persistPreferences()
        }
    }
    @Published var trendsEnabled: Bool = true {
        didSet { persistPreferences() }
    }
    @Published var trendsPeriodDays: Int = 7 {
        didSet {
            let clamped = Self.clamp(trendsPeriodDays, to: Self.trendsPeriodOptions)
            if trendsPeriodDays != clamped { trendsPeriodDays = clamped; return }
            persistPreferences()
        }
    }
    @Published var historyRetentionDays: Int = 90 {
        didSet {
            let clamped = Self.clamp(historyRetentionDays, to: Self.historyRetentionOptions)
            if historyRetentionDays != clamped { historyRetentionDays = clamped; return }
            persistPreferences()
            historyStore.prune(retentionDays: historyRetentionDays)
            if typicalDayLookbackDays > historyRetentionDays {
                typicalDayLookbackDays = historyRetentionDays
            }
        }
    }

    static let predictionHorizonOptions: [Int] = [15, 30, 45, 60]
    static let rollingAverageOptions: [Int] = [30, 60, 120]
    static let typicalDayLookbackOptions: [Int] = [7, 14, 30, 60, 90]
    static let trendsPeriodOptions: [Int] = [0, 7, 14, 30, 90]
    static let historyRetentionOptions: [Int] = [30, 60, 90]

    let historyStore = GlucoseHistoryStore()
    private let predictor = GlucosePredictor()
    @Published private(set) var prediction: GlucosePrediction?
    private var typicalDayCache: (version: Int, lookback: Int, profile: TypicalDayProfile?)?
    @Published var lowThresholdEnabled: Bool = true {
        didSet { persistPreferences() }
    }
    @Published var highThresholdEnabled: Bool = true {
        didSet { persistPreferences() }
    }
    @Published var customTargetsEnabled: Bool = false {
        didSet { persistPreferences() }
    }
    @Published var customLowMgDl: Double = 70 {
        didSet { persistPreferences() }
    }
    @Published var customHighMgDl: Double = 180 {
        didSet { persistPreferences() }
    }
    @Published var isLoading: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var errorMessage: String?
    @Published var currentReading: GlucoseReading? {
        didSet {
            guard currentReading?.identityKey != oldValue?.identityKey else { return }
            triggerReadingUpdateAnimation()
        }
    }
    @Published var readingHistory: [GlucoseReading] = [] {
        didSet { historyDidChange() }
    }
    @Published var lastUpdated: Date?
    @Published private(set) var readingUpdateAnimationID = 0
    @Published private(set) var statusTick: Date = .now

    @Published var dataSource: DataSource = .libreLinkUp {
        didSet { persistPreferences() }
    }
    @Published var nightscoutBaseURL: String = "" {
        didSet { persistPreferences() }
    }
    @Published var nightscoutToken: String = ""

    private let apiClient: LibreLinkUpAPIClient
    private let nightscoutAPI = NightscoutAPIClient()
    private var authToken: String?
    private var accountId: String?
    private var selectedConnection: LibreLinkConnection?
    private var statusTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    private let preferencesKey = "GlucoBarLibreLinkUpPreferences"
    private static let graphCacheKey = "GlucoBarLibreLinkUpGraphCache"
    private static let cachedHistoryWindow: TimeInterval = 24 * 60 * 60
    static let graphWindowPresets: [Int] = [3, 6, 12, 24]
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
    private static let nightscoutTokenKeyCandidates = [
        "GlucoBarNightscout.token",
        "Nightscout.token",
        "nightscout.token",
        "NS.token",
        "token"
    ]

    init(apiClient: LibreLinkUpAPIClient? = nil) {
        self.apiClient = apiClient ?? LibreLinkUpAPIClient()
        restorePreferences()
        restoreCachedHistory()
        loadNightscoutTokenFromKeychain()
        launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        startStatusTimer()
        startRefreshLoop()

        if hasStoredCredentials {
            Task { await authenticate() }
        } else if dataSource == .nightscout, !nightscoutBaseURL.isEmpty {
            Task { await fetchGlucose() }
        }
    }

    deinit {
        statusTimer?.invalidate()
        refreshTask?.cancel()
    }

    var hasStoredCredentials: Bool {
        switch dataSource {
        case .libreLinkUp:
            return !email.isEmpty && !password.isEmpty
        case .nightscout:
            return !nightscoutBaseURL.isEmpty
        }
    }

    var displayUnitLabel: String {
        useMmolPerL ? "mmol/L" : "mg/dL"
    }

    var sourceDisplayName: String {
        switch dataSource {
        case .libreLinkUp: return "LibreLinkUp"
        case .nightscout: return "Nightscout"
        }
    }

    var graphReadings: [ReadingSample] {
        let sorted = readingHistory.sorted(by: { $0.timestamp < $1.timestamp })
        guard !sorted.isEmpty else { return [] }

        let cutoff = statusTick.addingTimeInterval(-graphWindowInterval)
        let filtered = sorted.filter { $0.timestamp >= cutoff }
        if !filtered.isEmpty {
            return filtered
        }

        return Array(sorted.suffix(min(sorted.count, 24)))
    }

    var graphWindowInterval: TimeInterval {
        TimeInterval(Self.clampedGraphWindowHours(graphWindowHours) * 60 * 60)
    }

    var graphBounds: (min: Double, max: Double) {
        switch graphAxisMode {
        case .fixed:
            return fixedGraphBounds
        case .auto:
            return autoGraphBounds
        }
    }

    var graphWindowLabel: String {
        "Last \(Self.clampedGraphWindowHours(graphWindowHours))h"
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
        guard showTargetBands else { return nil }
        return effectiveLowMgDl
    }

    var targetHighMgDl: Double? {
        guard showTargetBands else { return nil }
        return effectiveHighMgDl
    }

    /// Low threshold used for range colouring, independent of whether bands are drawn.
    var effectiveLowMgDl: Double? {
        guard lowThresholdEnabled else { return nil }
        if customTargetsEnabled || dataSource == .nightscout {
            return customLowMgDl
        }
        return selectedConnection?.targetLow
    }

    /// High threshold used for range colouring, independent of whether bands are drawn.
    var effectiveHighMgDl: Double? {
        guard highThresholdEnabled else { return nil }
        if customTargetsEnabled || dataSource == .nightscout {
            return customHighMgDl
        }
        return selectedConnection?.targetHigh
    }

    var hasAnyThreshold: Bool {
        effectiveLowMgDl != nil || effectiveHighMgDl != nil
    }

    func rangeStatus(for valueMgDl: Double) -> GlucoseRangeStatus {
        let low = effectiveLowMgDl
        let high = effectiveHighMgDl
        guard low != nil || high != nil else { return .unknown }
        if let low, valueMgDl < low { return .low }
        if let high, valueMgDl > high { return .high }
        return .inRange
    }

    func rangeColor(for status: GlucoseRangeStatus) -> Color {
        switch status {
        case .low: return Self.lowColor
        case .inRange: return Self.inRangeColor
        case .high: return Self.highColor
        case .unknown: return .accentColor
        }
    }

    static let inRangeColor = Color(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0)
    static let highColor = Color(red: 0xFF / 255.0, green: 0x95 / 255.0, blue: 0x00 / 255.0)
    static let lowColor = Color(red: 0xFF / 255.0, green: 0x3B / 255.0, blue: 0x30 / 255.0)

    var currentRangeStatus: GlucoseRangeStatus {
        guard let reading = currentReading else { return .unknown }
        return rangeStatus(for: reading.valueMgDl)
    }

    /// Colour for the headline value: range status when data is fresh, otherwise the connection state.
    var headlineColor: Color {
        if errorMessage != nil { return .red }
        if isDataStale { return .orange }
        return rangeColor(for: currentRangeStatus)
    }

    /// The reading used as the baseline for the delta shown next to the current value.
    /// Prefers the most recent reading at least five minutes older than the current one so that
    /// one-minute LibreLinkUp samples do not produce a meaningless delta.
    var deltaBaselineReading: GlucoseReading? {
        guard let current = currentReading else { return nil }
        let sorted = readingHistory
            .filter { $0.timestamp < current.timestamp }
            .sorted(by: { $0.timestamp < $1.timestamp })
        guard !sorted.isEmpty else { return nil }

        let minimumGap: TimeInterval = 5 * 60
        let maximumGap: TimeInterval = 20 * 60
        if let candidate = sorted.last(where: { current.timestamp.timeIntervalSince($0.timestamp) >= minimumGap }),
           current.timestamp.timeIntervalSince(candidate.timestamp) <= maximumGap {
            return candidate
        }
        if let last = sorted.last, current.timestamp.timeIntervalSince(last.timestamp) <= maximumGap {
            return last
        }
        return nil
    }

    var deltaText: String? {
        guard let current = currentReading, let baseline = deltaBaselineReading else { return nil }
        let diffMgDl = current.valueMgDl - baseline.valueMgDl
        let magnitude = formattedValue(for: abs(diffMgDl))
        // Decide "no change" from the digits actually shown, so "+0" or "+0.0" can never appear.
        let isZero = (Double(magnitude) ?? 0) == 0
        if isZero {
            return "±\(magnitude)"
        }
        return diffMgDl > 0 ? "+\(magnitude)" : "−\(magnitude)"
    }

    var deltaIntervalText: String? {
        guard let current = currentReading, let baseline = deltaBaselineReading else { return nil }
        let minutes = max(1, Int((current.timestamp.timeIntervalSince(baseline.timestamp) / 60).rounded()))
        return "\(minutes)m"
    }

    struct WindowStats {
        let timeInRangePercent: Int?
        let lowMgDl: Double
        let highMgDl: Double
        let averageMgDl: Double
    }

    var windowStats: WindowStats? {
        let readings = graphReadings
        guard !readings.isEmpty else { return nil }
        let values = readings.map(\.valueMgDl)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let average = values.reduce(0, +) / Double(values.count)

        var timeInRange: Int?
        if hasAnyThreshold {
            let inRange = values.filter { rangeStatus(for: $0) == .inRange }.count
            timeInRange = Int((Double(inRange) / Double(values.count) * 100).rounded())
        }
        return WindowStats(timeInRangePercent: timeInRange, lowMgDl: low, highMgDl: high, averageMgDl: average)
    }

    // MARK: - Insights

    /// The forecast to draw: only while the latest reading is fresh, trimmed to the chosen horizon.
    var activePrediction: GlucosePrediction? {
        guard predictionEnabled, let prediction, currentReading != nil else { return nil }
        guard statusTick.timeIntervalSince(prediction.madeAt) <= 12 * 60 else { return nil }
        return prediction.trimmed(toMinutes: predictionHorizonMinutes)
    }

    struct PredictionSummary {
        let text: String
        let status: GlucoseRangeStatus
    }

    /// One line for the popover, such as "Low in ~20 min" or "~6.8 in 30m".
    var predictionSummary: PredictionSummary? {
        guard let forecast = activePrediction else { return nil }
        if let crossing = forecast.firstCrossing(lowMgDl: effectiveLowMgDl, highMgDl: effectiveHighMgDl) {
            let word = crossing.status == .low ? "Low" : "High"
            return PredictionSummary(text: "\(word) in ~\(crossing.minutes) min", status: crossing.status)
        }
        guard let point = forecast.points.last else { return nil }
        let minutes = Int((point.date.timeIntervalSince(forecast.madeAt) / 60).rounded())
        return PredictionSummary(
            text: "~\(formattedValue(for: point.valueMgDl)) in \(minutes)m",
            status: rangeStatus(for: point.valueMgDl)
        )
    }

    var forecastLearnedCount: Int { predictor.learnedForecastCount }

    func resetForecastLearning() {
        predictor.resetLearning()
        updatePrediction()
    }

    /// Rolling average over the visible window, computed from the full cache so the start of the window is complete.
    var rollingAverageSeries: [AveragedPoint] {
        guard rollingAverageEnabled else { return [] }
        let cutoff = statusTick.addingTimeInterval(-graphWindowInterval)
        return GlucoseAnalytics.movingAverage(readingHistory, window: TimeInterval(rollingAverageMinutes) * 60)
            .filter { $0.date >= cutoff }
    }

    var typicalDayProfile: TypicalDayProfile? {
        guard typicalDayEnabled else { return nil }
        let lookback = min(typicalDayLookbackDays, historyRetentionDays)
        if let cache = typicalDayCache, cache.version == historyStore.version, cache.lookback == lookback {
            return cache.profile
        }
        let since = statusTick.addingTimeInterval(-TimeInterval(lookback) * 86_400)
        let profile = GlucoseAnalytics.typicalDay(samples: historyStore.samples(since: since))
        typicalDayCache = (historyStore.version, lookback, profile)
        return profile
    }

    /// Number of distinct days with stored history, for Settings.
    var storedHistoryDays: Int {
        guard let earliest = historyStore.earliestDate else { return 0 }
        return max(1, Int((statusTick.timeIntervalSince(earliest) / 86_400).rounded(.up)))
    }

    func periodStats(days: Int) -> PeriodStats? {
        let start: Date
        if days <= 0 {
            start = Calendar.current.startOfDay(for: statusTick)
        } else {
            start = statusTick.addingTimeInterval(-TimeInterval(days) * 86_400)
        }
        return GlucoseAnalytics.periodStats(
            samples: historyStore.samples(since: start),
            from: start,
            to: statusTick,
            lowMgDl: effectiveLowMgDl,
            highMgDl: effectiveHighMgDl
        )
    }

    static func periodTitle(days: Int) -> String {
        days <= 0 ? "Today" : "\(days)d"
    }

    /// Explains a partially filled window, for example when LibreLinkUp only returned 12 of 24 hours.
    var graphCoverageText: String? {
        guard let first = graphReadings.first else { return nil }
        let loadedHours = statusTick.timeIntervalSince(first.timestamp) / 3600
        let windowHours = Double(Self.clampedGraphWindowHours(graphWindowHours))
        guard windowHours - loadedHours > 0.75 else { return nil }
        let shown = max(1, Int(loadedHours.rounded()))
        return "\(shown)h of \(Int(windowHours))h loaded · history fills in while GlucoBar runs"
    }

    private func historyDidChange() {
        historyStore.merge(readingHistory)
        historyStore.prune(retentionDays: historyRetentionDays)
        predictor.learn(from: readingHistory)
        updatePrediction()
    }

    private func updatePrediction() {
        guard predictionEnabled, !readingHistory.isEmpty else {
            prediction = nil
            return
        }
        let recent = Array(readingHistory.suffix(120))
        prediction = predictor.predict(recent: recent, history: historyStore.samples, now: .now)
    }

    private static func clamp(_ value: Int, to options: [Int]) -> Int {
        guard !options.isEmpty else { return value }
        if options.contains(value) { return value }
        return options.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }

    var connectionState: ConnectionState {
        let authenticated = (dataSource == .nightscout && !nightscoutBaseURL.isEmpty) || isAuthenticated
        if let errorMessage {
            return .error(errorMessage)
        }
        if isLoading {
            return authenticated ? .refreshing : .signingIn
        }
        guard hasStoredCredentials else {
            return .signedOut
        }
        if !authenticated {
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
            return "Not connected"
        case .signingIn:
            return "Signing in"
        case .refreshing:
            return "Refreshing"
        case .connected:
            return "Connected"
        case .stale:
            return "Stale"
        case .error:
            return "Connection problem"
        }
    }

    var statusDetail: String? {
        switch connectionState {
        case .signedOut:
            return sourceDisplayName
        case .signingIn:
            return sourceDisplayName
        case .refreshing:
            return sourceDisplayName
        case .connected:
            return lastUpdatedText ?? sourceDisplayName
        case .stale:
            return lastUpdatedText ?? sourceDisplayName
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
        let authenticated = (dataSource == .nightscout && !nightscoutBaseURL.isEmpty) || isAuthenticated

        if let errorMessage {
            return errorMessage
        }

        if isLoading {
            return authenticated ? "Refreshing" : "Signing in"
        }

        if !hasStoredCredentials {
            return "Not connected"
        }

        if authenticated {
            if currentReading != nil {
                return "Connected"
            }
            return "Waiting for data"
        }

        return "Not connected"
    }

    var menuStatusColor: Color {
        if errorMessage != nil { return .red }
        if isLoading { return .orange }
        if isDataStale { return .orange }
        if isAuthenticated { return .secondary }
        return .secondary
    }

    /// Colour of the small dot in the menu bar: red on error, orange when stale, otherwise the range status.
    var menuBarIndicatorColor: Color {
        if errorMessage != nil { return .red }
        if isDataStale { return .orange }
        guard currentReading != nil else { return .secondary }
        switch currentRangeStatus {
        case .low: return Self.lowColor
        case .high: return Self.highColor
        case .inRange: return Self.inRangeColor
        case .unknown: return .secondary
        }
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

    func triggerReadingUpdateAnimation() {
        readingUpdateAnimationID += 1
    }

    func authenticate() async {
        switch dataSource {
        case .libreLinkUp:
            guard hasStoredCredentials else {
                errorMessage = "Open Settings to sign in."
                isAuthenticated = false
                return
            }
            await runRefreshFlow(forceLogin: true)
        case .nightscout:
            isAuthenticated = true
            errorMessage = nil
            await fetchNightscout()
        }
    }

    func fetchGlucose() async {
        switch dataSource {
        case .libreLinkUp:
            await runRefreshFlow(forceLogin: false)
        case .nightscout:
            await fetchNightscout()
        }
    }

    func reconnect() async {
        switch dataSource {
        case .libreLinkUp:
            await runRefreshFlow(forceLogin: true)
        case .nightscout:
            await fetchNightscout()
        }
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

            try await refreshConnectionData(retryAfterRelogin: !forceLogin)
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

    /// Fetches connections and graph data. When the stored session token has expired, signs in
    /// again once and retries, so an expired token recovers without the user pressing Reconnect.
    private func refreshConnectionData(retryAfterRelogin: Bool) async throws {
        do {
            try await performConnectionRefresh()
        } catch where retryAfterRelogin && isAuthenticationError(error) {
            let session = try await apiClient.authenticate(email: email, password: password)
            authToken = session.authToken
            accountId = session.accountId
            try await performConnectionRefresh()
        }
    }

    private func performConnectionRefresh() async throws {
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
        // Keep what was already cached so the history grows past the 12 hours the API returns.
        let merged = Self.merge(readings: readingHistory + graphReadings, with: connectionReading)

        readingHistory = Self.trimmedHistory(merged)
        currentReading = readingHistory.last
        lastUpdated = currentReading?.timestamp ?? readingHistory.last?.timestamp
    }

    private func restorePreferences() {
        if let data = UserDefaults.standard.data(forKey: preferencesKey) {
            do {
                let preferences = try JSONDecoder.libreLinkUp.decode(StoredPreferences.self, from: data)
                useMmolPerL = preferences.useMmolPerL
                graphWindowHours = Self.clampedGraphWindowHours(
                    preferences.graphWindowHours ?? preferences.graphRange?.rawValue ?? graphWindowHours
                )
                dataSource = preferences.dataSource ?? .libreLinkUp
                nightscoutBaseURL = preferences.nightscoutBaseURL ?? ""
                showTargetBands = preferences.showTargetBands ?? true
                lowThresholdEnabled = preferences.lowThresholdEnabled ?? true
                highThresholdEnabled = preferences.highThresholdEnabled ?? true
                customTargetsEnabled = preferences.customTargetsEnabled ?? false
                customLowMgDl = preferences.customLowMgDl ?? 70
                customHighMgDl = preferences.customHighMgDl ?? 180
                graphAxisMode = preferences.graphAxisMode ?? .fixed
                predictionEnabled = preferences.predictionEnabled ?? true
                predictionHorizonMinutes = preferences.predictionHorizonMinutes ?? 30
                predictionBandEnabled = preferences.predictionBandEnabled ?? true
                rollingAverageEnabled = preferences.rollingAverageEnabled ?? true
                rollingAverageMinutes = preferences.rollingAverageMinutes ?? 60
                typicalDayEnabled = preferences.typicalDayEnabled ?? true
                typicalDayLookbackDays = preferences.typicalDayLookbackDays ?? 30
                trendsEnabled = preferences.trendsEnabled ?? true
                trendsPeriodDays = preferences.trendsPeriodDays ?? 7
                historyRetentionDays = preferences.historyRetentionDays ?? 90
                if let token = preferences.nightscoutToken, !token.isEmpty {
                    nightscoutToken = token
                    persistNightscoutToken()
                }
            } catch {
                // Fall back to defaults if preferences become unreadable.
                useMmolPerL = useMmolPerL
                graphWindowHours = graphWindowHours
                dataSource = .libreLinkUp
                nightscoutBaseURL = ""
            }
        }

        loadStoredCredentials()
    }

    private func persistPreferences() {
        let preferences = StoredPreferences(
            useMmolPerL: useMmolPerL,
            graphRange: nil,
            graphWindowHours: graphWindowHours,
            dataSource: dataSource,
            nightscoutBaseURL: nightscoutBaseURL.isEmpty ? nil : nightscoutBaseURL,
            nightscoutToken: nil,
            showTargetBands: showTargetBands,
            lowThresholdEnabled: lowThresholdEnabled,
            highThresholdEnabled: highThresholdEnabled,
            customTargetsEnabled: customTargetsEnabled,
            customLowMgDl: customLowMgDl,
            customHighMgDl: customHighMgDl,
            graphAxisMode: graphAxisMode,
            predictionEnabled: predictionEnabled,
            predictionHorizonMinutes: predictionHorizonMinutes,
            predictionBandEnabled: predictionBandEnabled,
            rollingAverageEnabled: rollingAverageEnabled,
            rollingAverageMinutes: rollingAverageMinutes,
            typicalDayEnabled: typicalDayEnabled,
            typicalDayLookbackDays: typicalDayLookbackDays,
            trendsEnabled: trendsEnabled,
            trendsPeriodDays: trendsPeriodDays,
            historyRetentionDays: historyRetentionDays
        )
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
        // Treat Nightscout as always authenticated when URL is present
        if dataSource == .nightscout || isAuthenticated == false {
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
        return (0, 400)
    }

    /// Bounds that fit the visible readings and thresholds, rounded outward to tidy values.
    private var autoGraphBounds: (min: Double, max: Double) {
        let values = graphReadings.map(\.valueMgDl)
        var low = values.min() ?? (useMmolPerL ? 4 * 18.0 : 70)
        var high = values.max() ?? (useMmolPerL ? 10 * 18.0 : 180)

        if let target = effectiveLowMgDl { low = min(low, target) }
        if let target = effectiveHighMgDl { high = max(high, target) }

        let step = useMmolPerL ? 18.0 : 20.0
        let padding = useMmolPerL ? 1.0 * 18.0 : 20.0
        let floorLimit = useMmolPerL ? 2.0 * 18.0 : 40.0
        let minimumSpan = useMmolPerL ? 8.0 * 18.0 : 140.0

        var minValue = max(floorLimit, floor((low - padding) / step) * step)
        var maxValue = ceil((high + padding) / step) * step
        if maxValue - minValue < minimumSpan {
            maxValue = minValue + minimumSpan
        }
        if minValue >= maxValue {
            minValue = max(0, maxValue - minimumSpan)
        }
        return (minValue, maxValue)
    }

    private static func merge(readings: [GlucoseReading], with current: GlucoseReading?) -> [GlucoseReading] {
        var merged = readings
        if let current, merged.last?.timestamp != current.timestamp {
            merged.append(current)
        }

        // One reading per timestamp. The live connection reading carries a trend arrow while graph
        // points usually do not, so prefer the entry that has one when both describe the same minute.
        var unique: [Int: GlucoseReading] = [:]
        for reading in merged {
            let key = Int(reading.timestamp.timeIntervalSince1970)
            if let existing = unique[key], existing.trendArrow != nil, reading.trendArrow == nil {
                continue
            }
            unique[key] = reading
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

    private static func clampedGraphWindowHours(_ hours: Int) -> Int {
        min(max(hours, 1), 24)
    }

    private func loadNightscoutTokenFromKeychain() {
        for key in Self.nightscoutTokenKeyCandidates {
            if let value = KeychainHelper.load(key: key) {
                nightscoutToken = value
                break
            }
        }
    }

    private func persistNightscoutToken() {
        guard !nightscoutToken.isEmpty else { return }
        KeychainHelper.save(key: Self.nightscoutTokenKeyCandidates[0], value: nightscoutToken)
    }

    private func fetchNightscout() async {
        guard !nightscoutBaseURL.isEmpty else {
            errorMessage = "Open Settings and enter your Nightscout URL."
            currentReading = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let sampleInterval: TimeInterval = 5 * 60 // 5 minutes typical NS interval
            let desiredCount = max(24, Int(graphWindowInterval / sampleInterval) + 12) // pad a bit
            let entries = try await nightscoutAPI.fetchEntries(
                baseURL: nightscoutBaseURL,
                token: nightscoutToken.isEmpty ? nil : nightscoutToken,
                count: desiredCount
            )
            let readings = entries.compactMap { entry -> GlucoseReading? in
                guard let date = entry.date, let sgv = entry.sgv else { return nil }
                return GlucoseReading(
                    timestamp: date,
                    valueMgDl: sgv,
                    trendArrow: mapNightscoutDirection(entry.direction),
                    factoryTimestamp: nil
                )
            }
            readingHistory = Self.trimmedHistory(Self.merge(readings: readingHistory + readings, with: nil))
            currentReading = readingHistory.last
            lastUpdated = currentReading?.timestamp ?? readingHistory.last?.timestamp
            errorMessage = nil
            isAuthenticated = true
            persistGraphCache()
            persistNightscoutToken()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func mapNightscoutDirection(_ direction: String?) -> Int? {
        guard let d = direction?.lowercased() else { return nil }
        switch d {
        case "doubledown": return 1
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

enum ConnectionState: Equatable {
    case signedOut
    case signingIn
    case refreshing
    case connected
    case stale
    case error(String)
}
