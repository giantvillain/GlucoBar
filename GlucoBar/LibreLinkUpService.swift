import SwiftUI
import Foundation
import Combine
import AppKit
import ServiceManagement
import Security
import UniformTypeIdentifiers

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

    @Published var notifyPredictedLow: Bool = false {
        didSet {
            persistPreferences()
            if notifyPredictedLow && !restoring { notifier.requestAuthorizationIfNeeded() }
        }
    }
    @Published var notifyPredictedHigh: Bool = false {
        didSet {
            persistPreferences()
            if notifyPredictedHigh && !restoring { notifier.requestAuthorizationIfNeeded() }
        }
    }
    @Published var notificationCooldownMinutes: Int = 30 {
        didSet {
            let clamped = Self.clamp(notificationCooldownMinutes, to: Self.notificationCooldownOptions)
            if notificationCooldownMinutes != clamped { notificationCooldownMinutes = clamped; return }
            persistPreferences()
        }
    }

    static let notificationCooldownOptions: [Int] = [15, 30, 60]
    static let predictionHorizonOptions: [Int] = [15, 30, 45, 60]
    static let rollingAverageOptions: [Int] = [30, 60, 120]
    static let typicalDayLookbackOptions: [Int] = [7, 14, 30, 60, 90]
    static let trendsPeriodOptions: [Int] = [0, 7, 14, 30, 90]
    static let historyRetentionOptions: [Int] = [30, 60, 90]

    private let historyRepository = GlucoseHistoryRepository()
    var historyStore: GlucoseHistoryStore { historyRepository.store }
    private let forecastEngine = GlucoseForecastEngine()
    private var predictor: GlucosePredictor { forecastEngine.predictor }
    let notifier = ForecastNotifier()
    @Published private(set) var availableConnections: [LibreLinkConnection] = []
    @Published private(set) var selectedPersonID: String?
    @Published private(set) var isOnline = true
    @Published private(set) var nextRefreshAt: Date?
    @Published private(set) var connectionIssue: String?
    @Published var dataMessage: String?
    @Published var notifyMissingData = false { didSet { saveExtraPreferences(); if notifyMissingData && !restoring { notifier.requestAuthorizationIfNeeded() } } }
    @Published var menuShowsDelta = false { didSet { saveExtraPreferences() } }
    @Published var menuShowsAge = false { didSet { saveExtraPreferences() } }
    @Published var privacyMode = false { didSet { saveExtraPreferences(); if privacyMode { notifier.hideDeliveredReadings() } } }
    private var restoring = true
    private var switchingProfile = false
    private var requestGeneration = UUID()
    private var notifierSubscription: AnyCancellable?
    private var failureCount = 0
    private var recoveryRequested = false
    @Published private(set) var prediction: GlucosePrediction?
    @Published private(set) var backtestResult: ForecastBacktestResult?
    /// Fraction complete while a backtest runs, nil otherwise.
    @Published private(set) var backtestProgress: Double?
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
        didSet { persistPreferences(); if !restoring && oldValue != dataSource { resetConnection() } }
    }
    @Published var nightscoutBaseURL: String = "" {
        didSet { persistPreferences() }
    }
    @Published var nightscoutToken: String = ""

    private let connectionManager: GlucoseConnectionManager
    private var selectedConnection: LibreLinkConnection?
    private var statusTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    private let preferencesKey = "GlucoBarLibreLinkUpPreferences"
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

    init(apiClient: LibreLinkUpAPIClient? = nil, startAutomatically: Bool = true) {
        self.connectionManager = GlucoseConnectionManager(api: apiClient ?? LibreLinkUpAPIClient())
        notifierSubscription = notifier.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        guard startAutomatically else { return }
        restorePreferences()
        loadNightscoutTokenFromKeychain()
        launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        restoreExtraPreferences()
        restoring = false
        selectedPersonID = UserDefaults.standard.string(forKey: personPreferenceKey)
        restoreActiveProfile()
        connectionManager.onConnections = { [weak self] in self?.availableConnections = $0 }
        connectionManager.onNetworkChange = { [weak self] online in
            guard let self else { return }
            let recovered = !self.isOnline && online
            self.isOnline = online
            if !online { self.connectionIssue = "Offline" }
            if recovered { self.connectionIssue = nil; self.recoverConnection() }
        }
        connectionManager.onWake = { [weak self] in
            guard let self else { return }
            self.recoverConnection()
        }
        connectionManager.startMonitoring()
        startStatusTimer()
        startRefreshLoop()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.predictor.saveNow()
            }
        }

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
        return filtered
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
            top: formattedValue(for: graphBounds.max),
            middle: "",
            bottom: formattedValue(for: graphBounds.min)
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
        if errorMessage != nil || !isOnline { return .red }
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
        let binned = GlucoseHistoryStore(fileURL: nil)
        binned.merge(readings)
        let values = binned.samples.map(\.v)
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

    /// Live accuracy over the last seven days, blend first.
    var forecastAccuracyRows: [GlucosePredictor.AccuracyRow] { predictor.accuracyRows(days: 7) }

    var forecastBandCoverage: [Int: Double] { predictor.bandCoverage(days: 7) }

    /// A short description of the regression's training state, for Settings.
    var forecastRegressionSummary: String {
        if let model = predictor.ridgeModel {
            return "Regression trained on \(model.rowCount) history rows."
        }
        return storedHistoryDays >= 3
            ? "Regression not trained yet."
            : "Regression needs about three days of history before it trains."
    }

    /// The current blend, for Settings, such as "trend 40%, history match 25%".
    var forecastBlendSummary: String? {
        guard let forecast = activePrediction else { return nil }
        let parts = forecast.modelWeights
            .filter { $0.value >= 0.05 }
            .sorted { $0.value > $1.value }
            .map { "\(GlucosePredictor.title(forModel: $0.key).lowercased()) \(Int(($0.value * 100).rounded()))%" }
        guard !parts.isEmpty else { return nil }
        return "Current blend (\(forecast.regime)): " + parts.joined(separator: ", ") + "."
    }

    func resetForecastLearning() {
        forecastEngine.reset()
        backtestProgress = nil
        backtestResult = nil
        scheduleRegressionTrainingIfNeeded()
        updatePrediction()
    }

    /// Replays stored history through a fresh predictor in the background.
    func runBacktest(days: Int = 7) {
        guard backtestProgress == nil else { return }
        let samples = historyStore.samples
        backtestProgress = 0
        forecastEngine.backtest(samples: samples, days: days, progress: { [weak self] in
            self?.backtestProgress = $0
        }, completion: { [weak self] in
            self?.backtestResult = $0
            self?.backtestProgress = nil
            if $0 == nil { self?.dataMessage = "Not enough continuous history to complete the backtest." }
        })
    }

    /// Rolling average over the visible window, computed from the full cache so the start of the window is complete.
    var rollingAverageSeries: [AveragedPoint] {
        guard rollingAverageEnabled else { return [] }
        let cutoff = statusTick.addingTimeInterval(-graphWindowInterval)
        return GlucoseAnalytics.movingAverage(readingHistory, window: TimeInterval(rollingAverageMinutes) * 60)
            .filter { $0.date >= cutoff }
    }

    /// The typical-day profile drawn on the chart, when that overlay is enabled.
    var typicalDayOverlayProfile: TypicalDayProfile? {
        typicalDayEnabled ? typicalDayProfile : nil
    }

    /// The typical-day profile, always available to the forecast regardless of the overlay setting.
    var typicalDayProfile: TypicalDayProfile? {
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
        guard !restoring, !switchingProfile, historyRepository.profileID != nil else { return }
        historyStore.merge(readingHistory)
        if !historyRepository.legacyWasImported { migrateLegacyHistory(onlyIfMatching: true) }
        historyStore.prune(retentionDays: historyRetentionDays)
        predictor.learn(from: readingHistory)
        forecastEngine.evaluation.learn(readings: readingHistory, now: .now)
        scheduleRegressionTrainingIfNeeded()
        updatePrediction()
    }

    private func updatePrediction() {
        guard predictionEnabled, !readingHistory.isEmpty else {
            prediction = nil
            return
        }
        let recent = Array(readingHistory.suffix(120))
        prediction = predictor.predict(
            recent: recent,
            history: historyStore.samples,
            typicalDay: typicalDayProfile,
            now: .now
        )
        if let forecast = activePrediction {
            forecastEngine.evaluation.record(forecast, low: effectiveLowMgDl, high: effectiveHighMgDl)
        }
        evaluateForecastNotifications()
    }

    /// Retrains the regression in the background at startup and then at most every six hours.
    private func scheduleRegressionTrainingIfNeeded() {
        guard predictionEnabled, historyRepository.profileID != nil else { return }
        forecastEngine.train(samples: historyStore.samples, version: historyStore.version, typical: typicalDayProfile) { [weak self] in
            self?.updatePrediction()
        }
    }

    private func evaluateForecastNotifications() {
        guard notifyPredictedLow || notifyPredictedHigh, !isDataStale else { return }
        guard let forecast = activePrediction,
              let crossing = forecast.firstCrossing(lowMgDl: notifyPredictedLow ? effectiveLowMgDl : nil, highMgDl: notifyPredictedHigh ? effectiveHighMgDl : nil)
        else { return }
        let threshold = crossing.status == .low ? effectiveLowMgDl : effectiveHighMgDl
        guard let threshold else { return }
        notifier.evaluate(
            event: ForecastNotifier.Event(
                status: crossing.status,
                minutes: crossing.minutes,
                thresholdText: formattedValue(for: threshold),
                currentText: "\(menuBarValueText) \(menuBarTrendSymbol)",
                unitLabel: displayUnitLabel
            ),
            notifyLow: notifyPredictedLow,
            notifyHigh: notifyPredictedHigh,
            cooldown: TimeInterval(notificationCooldownMinutes) * 60, privacy: privacyMode
        )
    }

    private static func clamp(_ value: Int, to options: [Int]) -> Int {
        guard !options.isEmpty else { return value }
        if options.contains(value) { return value }
        return options.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }

    var connectionState: ConnectionState {
        let authenticated = (dataSource == .nightscout && !nightscoutBaseURL.isEmpty) || isAuthenticated
        if !isOnline && hasStoredCredentials { return .error("Offline — waiting for a network connection") }
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
            return "Sensor data delayed"
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
        if errorMessage != nil || !isOnline { return .red }
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
        ReadingSupport.trendSymbol(displayTrendArrow)
    }

    var menuBarTrendColor: Color {
        trendColor(for: displayTrendArrow)
    }

    var menuBarBadgeText: String {
        isDataStale ? "⚠" : ""
    }

    var menuBarDisplayText: String {
        if privacyMode { return "GlucoBar" }
        var text = menuBarValueText + " " + menuBarTrendSymbol
        if menuShowsDelta, let deltaText { text += " " + deltaText }
        if menuShowsAge, let age = lastKnownReadingDate { text += " \(max(0, Int(statusTick.timeIntervalSince(age) / 60)))m" }
        if errorMessage != nil || !isOnline { text += " ⨯" }
        else if isDataStale { text += " ◷" }
        else if currentRangeStatus == .low { text += " !↓" }
        else if currentRangeStatus == .high { text += " !↑" }
        return text
    }

    var trendDescription: String { ReadingSupport.trendDescription(displayTrendArrow) }

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
        ReadingSupport.formatted(valueMgDl, mmol: useMmolPerL)
    }

    func trendSymbol(for trendArrow: Int?) -> String? {
        trendArrow == nil ? nil : ReadingSupport.trendSymbol(trendArrow)
    }

    func trendColor(for trendArrow: Int?) -> Color {
        guard let trendArrow else { return .secondary }
        switch trendArrow {
        case 1, 2, 7:
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

    func authenticate() async { await fetchGlucose(forceLogin: true) }
    func reconnect() async { await fetchGlucose(forceLogin: true) }

    func fetchGlucose(forceLogin: Bool = false) async {
        guard !restoring, !isLoading, hasStoredCredentials, isOnline else { return }
        let generation = requestGeneration
        isLoading = true
        nextRefreshAt = nil
        defer {
            if generation == requestGeneration {
                isLoading = false
                if recoveryRequested {
                    recoveryRequested = false
                    Task { await self.fetchGlucose() }
                } else { startRefreshLoop() }
            }
        }
        do {
            let result = try await connectionManager.fetch(source: dataSource, email: email, password: password,
                url: nightscoutBaseURL, token: nightscoutToken, personID: selectedPersonID, forceLogin: forceLogin)
            guard generation == requestGeneration else { return }
            if historyRepository.profileID != result.profileID { activateProfile(result.profileID) }
            selectedConnection = result.selected
            availableConnections = result.connections
            if let selected = result.selected {
                selectedPersonID = selected.patientId ?? selected.id
                UserDefaults.standard.set(selectedPersonID, forKey: personPreferenceKey)
            }
            statusTick = .now
            let merged = Self.trimmedHistory(Self.merge(readings: readingHistory + result.readings, with: nil))
            currentReading = merged.last
            lastUpdated = currentReading?.timestamp
            readingHistory = merged
            isAuthenticated = true
            errorMessage = nil
            connectionIssue = nil
            failureCount = 0
            persistCredentials()
            persistNightscoutToken()
            persistGraphCache()
            updatePrediction()
        } catch {
            guard generation == requestGeneration, !(error is CancellationError) else { return }
            isAuthenticated = false
            failureCount += 1
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let error = error as? LibreLinkUpError, error.isAuthenticationRelated {
                connectionIssue = "Login expired — check your credentials"
            } else if let error = error as? NightscoutAPIError, case .httpStatus(let code) = error, code == 401 || code == 403 {
                connectionIssue = "Access denied — check your API token"
            } else if let error = error as? URLError, [.notConnectedToInternet, .networkConnectionLost].contains(error.code) {
                connectionIssue = "Network unavailable"
            } else { connectionIssue = "Connection problem" }
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
                notifyPredictedLow = preferences.notifyPredictedLow ?? false
                notifyPredictedHigh = preferences.notifyPredictedHigh ?? false
                notificationCooldownMinutes = preferences.notificationCooldownMinutes ?? 30
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
        guard !restoring else { return }
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
            historyRetentionDays: historyRetentionDays,
            notifyPredictedLow: notifyPredictedLow,
            notifyPredictedHigh: notifyPredictedHigh,
            notificationCooldownMinutes: notificationCooldownMinutes
        )
        do {
            let data = try JSONEncoder.libreLinkUp.encode(preferences)
            UserDefaults.standard.set(data, forKey: preferencesKey)
        } catch {
            // Ignore preference write failures.
        }
    }

    private func loadStoredCredentials() {
        for key in (UserDefaults.standard.bool(forKey: "GlucoBar.ignoreLegacyCredentials") ? Array(Self.emailKeyCandidates.prefix(1)) : Self.emailKeyCandidates) {
            if let value = KeychainHelper.load(key: key) {
                email = value
                break
            }
        }

        for key in (UserDefaults.standard.bool(forKey: "GlucoBar.ignoreLegacyCredentials") ? Array(Self.passwordKeyCandidates.prefix(1)) : Self.passwordKeyCandidates) {
            if let value = KeychainHelper.load(key: key) {
                password = value
                break
            }
        }
    }

    private func persistCredentials() {
        guard dataSource == .libreLinkUp, !email.isEmpty, !password.isEmpty else { return }
        KeychainHelper.save(key: Self.emailKeyCandidates[0], value: email)
        KeychainHelper.save(key: Self.passwordKeyCandidates[0], value: password)
    }

    private func persistGraphCache() {
        historyRepository.saveGraph(Self.trimmedHistory(readingHistory))
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
                self?.checkMissingData()
            }
        }
    }

    private func recoverConnection() {
        statusTick = .now
        if isLoading { recoveryRequested = true }
        else { Task { await self.fetchGlucose() } }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        let interval = autoRefreshInterval
        nextRefreshAt = hasStoredCredentials && isOnline ? Date().addingTimeInterval(interval) : nil
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            if self.hasStoredCredentials && self.isOnline { await self.fetchGlucose() }
            else { self.startRefreshLoop() }
        }
    }

    private var autoRefreshInterval: TimeInterval {
        if !hasStoredCredentials || !isOnline { return 60 }
        if failureCount > 0 { return min(900, 30 * pow(2, Double(min(failureCount - 1, 5)))) }
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? 300 : (dataSource == .nightscout ? 300 : 60)
    }

    private var lastKnownReadingDate: Date? {
        currentReading?.timestamp ?? readingHistory.last?.timestamp ?? lastUpdated
    }

    private var displayTrendArrow: Int? {
        currentReading?.trendArrow
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
        for key in (UserDefaults.standard.bool(forKey: "GlucoBar.ignoreLegacyCredentials") ? Array(Self.nightscoutTokenKeyCandidates.prefix(1)) : Self.nightscoutTokenKeyCandidates) {
            if let value = KeychainHelper.load(key: key) {
                nightscoutToken = value
                break
            }
        }
    }

    private func persistNightscoutToken() {
        guard dataSource == .nightscout else { return }
        guard !nightscoutToken.isEmpty else {
            KeychainHelper.delete(key: Self.nightscoutTokenKeyCandidates[0])
            return
        }
        KeychainHelper.save(key: Self.nightscoutTokenKeyCandidates[0], value: nightscoutToken)
    }

    private var personPreferenceKey: String { "GlucoBar.person." + ProfileIdentity.key(source: "libreLinkUp", account: email) }
    var activePersonName: String? { selectedConnection?.displayName }
    var hasActiveProfile: Bool { historyRepository.profileID != nil }
    var crossingSummaries: [ForecastEvaluation.Summary] { forecastEngine.evaluation.summaries(now: statusTick) }

    var forecastStatusText: String {
        if !predictionEnabled { return "Forecast is turned off" }
        if currentReading == nil { return "Forecast waiting for readings" }
        if let date = currentReading?.timestamp, statusTick.timeIntervalSince(date) > 12 * 60 {
            return "Forecast paused — readings are delayed"
        }
        if activePrediction == nil { return "Forecast needs more continuous recent readings" }
        let count = forecastAccuracyRows.first(where: { $0.model == "ensemble" })?.countsByHorizon[30] ?? 0
        if count < 30 { return "Learning · limited forecast history" }
        if let error = forecastAccuracyRows.first(where: { $0.model == "ensemble" })?.maeByHorizon[30] {
            return "30m mean error \(formattedValue(for: error)) \(displayUnitLabel) · \(count) checks"
        }
        return "Learning · limited forecast history"
    }

    var retryText: String? {
        guard isOnline, let nextRefreshAt, errorMessage != nil else { return nil }
        return "Retry in \(max(0, Int(ceil(nextRefreshAt.timeIntervalSince(statusTick)))))s"
    }

    private func activateProfile(_ id: String?) {
        switchingProfile = true
        defer { switchingProfile = false }
        prediction = nil
        backtestResult = nil
        backtestProgress = nil
        typicalDayCache = nil
        let cached = historyRepository.select(id)
        forecastEngine.select(learningKey: id == nil ? nil : historyRepository.learningKey)
        notifier.selectProfile(id)
        currentReading = nil
        readingHistory = Self.trimmedHistory(cached)
        currentReading = readingHistory.last
        lastUpdated = currentReading?.timestamp
        if id != nil { migrateLegacyHistory(onlyIfMatching: true) }
        historyStore.prune(retentionDays: historyRetentionDays)
    }

    private func restoreActiveProfile() {
        if dataSource == .nightscout, !nightscoutBaseURL.isEmpty {
            activateProfile(ProfileIdentity.key(source: "nightscout", account: ProfileIdentity.nightscoutAccount(nightscoutBaseURL)))
        } else if dataSource == .libreLinkUp, !email.isEmpty, let selectedPersonID {
            activateProfile(ProfileIdentity.key(source: "libreLinkUp", account: email, person: selectedPersonID))
        }
    }

    private func resetConnection() {
        requestGeneration = UUID()
        connectionManager.reset()
        isLoading = false
        isAuthenticated = false
        selectedConnection = nil
        availableConnections = []
        errorMessage = nil
        connectionIssue = nil
        failureCount = 0
        recoveryRequested = false
        activateProfile(nil)
        selectedPersonID = UserDefaults.standard.string(forKey: personPreferenceKey)
        startRefreshLoop()
    }

    func connect(source: DataSource, email: String, password: String, url: String, token: String) async {
        guard !restoring else { return }
        dataSource = source
        if source == .nightscout { customTargetsEnabled = true }
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        nightscoutBaseURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        nightscoutToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        resetConnection()
        restoreActiveProfile()
        await authenticate()
    }

    func selectPerson(_ id: String) async {
        guard !id.isEmpty else { return }
        let connections = availableConnections
        resetConnection()
        availableConnections = connections
        selectedPersonID = id
        UserDefaults.standard.set(id, forKey: personPreferenceKey)
        restoreActiveProfile()
        await fetchGlucose()
    }

    #if DEBUG
    /// In-memory fixture for visual QA. No account, local history, or network is accessed.
    static func preview() -> LibreLinkUpService {
        let service = LibreLinkUpService(startAutomatically: false)
        service.email = "demo@example.com"
        service.password = "demo"
        service.useMmolPerL = true
        service.isAuthenticated = true
        service.customTargetsEnabled = true
        let end = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 300) * 300)
        let readings = (0..<(28 * 288)).compactMap { i -> GlucoseReading? in
            let ago = 28 * 288 - 1 - i
            // Include a visible recent missing-data interval.
            if (34...39).contains(ago) { return nil }
            let date = end.addingTimeInterval(-Double(ago) * 300)
            let phase = Double(i % 288) / 288 * 2 * Double.pi
            let value = 115 + 28 * sin(phase) + 20 * sin(phase * 3) + 8 * sin(Double(i) / 5)
            return GlucoseReading(timestamp: date, valueMgDl: value, trendArrow: ago == 0 ? 4 : nil)
        }
        service.historyStore.merge(readings)
        service.readingHistory = Array(readings.suffix(288))
        service.currentReading = readings.last
        service.lastUpdated = end
        service.prediction = service.predictor.predict(recent: service.readingHistory, history: service.historyStore.samples,
                                                       typicalDay: service.typicalDayProfile, now: .now)
        return service
    }
    #endif

    private func checkMissingData() {
        guard hasStoredCredentials, notifyMissingData, isDataStale, let date = lastKnownReadingDate else { return }
        notifier.missingData(lastReading: date, cooldown: Double(notificationCooldownMinutes) * 60)
    }

    private func restoreExtraPreferences() {
        let d = UserDefaults.standard
        notifyMissingData = d.bool(forKey: "GlucoBar.notifyMissing")
        menuShowsDelta = d.bool(forKey: "GlucoBar.menuDelta")
        menuShowsAge = d.bool(forKey: "GlucoBar.menuAge")
        privacyMode = d.bool(forKey: "GlucoBar.privacyMode")
    }

    private func saveExtraPreferences() {
        guard !restoring else { return }
        let d = UserDefaults.standard
        d.set(notifyMissingData, forKey: "GlucoBar.notifyMissing")
        d.set(menuShowsDelta, forKey: "GlucoBar.menuDelta")
        d.set(menuShowsAge, forKey: "GlucoBar.menuAge")
        d.set(privacyMode, forKey: "GlucoBar.privacyMode")
    }

    func deleteStoredHistory() {
        // Invalidating in-flight work prevents deleted data from being written back by an old response.
        requestGeneration = UUID()
        connectionManager.reset()
        isLoading = false
        forecastEngine.reset()
        historyRepository.deleteCurrent()
        prediction = nil
        backtestResult = nil
        backtestProgress = nil
        typicalDayCache = nil
        readingHistory = []
        currentReading = nil
        lastUpdated = nil
        startRefreshLoop()
        dataMessage = "History and forecast learning deleted for this profile. New readings will be stored on the next refresh."
    }

    func forgetCredentials() {
        // Only remove GlucoBar's keys; generic legacy aliases may belong to another application.
        let keys = [Self.emailKeyCandidates[0], Self.passwordKeyCandidates[0], Self.nightscoutTokenKeyCandidates[0]]
        let deleted = keys.map { KeychainHelper.delete(key: $0) }.allSatisfy { $0 }
        UserDefaults.standard.set(true, forKey: "GlucoBar.ignoreLegacyCredentials")
        email = ""
        password = ""
        nightscoutBaseURL = ""
        nightscoutToken = ""
        resetConnection()
        dataMessage = deleted ? "Credentials removed. Stored history is retained separately." : "Some Keychain items could not be removed. Check Keychain Access."
    }

    var hasLegacyHistory: Bool { !restoring && !GlucoseHistoryRepository.legacySamples.isEmpty }
    var legacyHistoryWasImported: Bool { historyRepository.legacyWasImported }

    func importLegacyHistory() {
        migrateLegacyHistory(onlyIfMatching: false)
    }

    private func migrateLegacyHistory(onlyIfMatching: Bool) {
        guard hasActiveProfile, !onlyIfMatching || !historyRepository.legacyWasImported else { return }
        do {
            predictor.saveNow()
            guard try historyRepository.importLegacy(onlyIfMatching: onlyIfMatching) else { return }
            // Do not let the old in-memory predictor overwrite the imported learning.
            forecastEngine.select(learningKey: historyRepository.learningKey, savingCurrent: false)
            let wasSwitching = switchingProfile
            switchingProfile = true
            readingHistory = Self.trimmedHistory(Self.merge(readings: historyRepository.cachedGraph + readingHistory, with: nil))
            currentReading = readingHistory.last
            lastUpdated = currentReading?.timestamp
            switchingProfile = wasSwitching
            historyStore.prune(retentionDays: historyRetentionDays)
            try historyStore.saveNowThrowing()
            typicalDayCache = nil
            backtestResult = nil
            backtestProgress = nil
            scheduleRegressionTrainingIfNeeded()
            updatePrediction()
            objectWillChange.send()
            dataMessage = "Older history and forecast learning restored to this profile. The original copy is kept as a backup."
        } catch { dataMessage = "Could not restore older history: " + error.localizedDescription }
    }

    func deleteLegacyHistory() {
        do {
            try GlucoseHistoryRepository.deleteLegacy()
            dataMessage = "Unassigned history and old forecast learning deleted."
        } catch { dataMessage = "Could not delete unassigned history: " + error.localizedDescription }
    }

    func exportHistory(legacy: Bool = false) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = legacy ? "GlucoBar-unassigned-history.csv" : "GlucoBar-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try GlucoseHistoryRepository.csv(samples: legacy ? GlucoseHistoryRepository.legacySamples : historyStore.samples).write(to: url, atomically: true, encoding: .utf8)
            dataMessage = "History exported with UTC timestamps and both glucose units."
        } catch { dataMessage = "Export failed: " + error.localizedDescription }
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
