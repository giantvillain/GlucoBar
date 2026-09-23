import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var service: LibreLinkUpService
    @State private var email = ""
    @State private var password = ""
    @State private var launchAtStartup = false
    @State private var useMmolPerL = false
    @State private var graphWindowHours = 4.0
    @State private var graphAxisMode: GraphAxisMode = .fixed
    @State private var selectedSource: DataSource = .libreLinkUp
    @State private var nightscoutBaseURL = ""
    @State private var nightscoutToken = ""
    @State private var showTargetBands = true
    @State private var customTargetsEnabled = false
    @State private var lowThresholdEnabled = true
    @State private var highThresholdEnabled = true
    @State private var customLowThreshold = 70.0
    @State private var customHighThreshold = 180.0

    @State private var confirmDelete = false
    @State private var confirmForget = false
    @State private var confirmLegacyImport = false
    @State private var confirmLegacyDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusStrip
            if service.privacyMode {
                VStack(spacing: 16) {
                    Label("Readings hidden", systemImage: "eye.slash").font(.title2)
                    Text("Turn off privacy mode to view settings and glucose details.")
                    Toggle("Privacy mode", isOn: $service.privacyMode).fixedSize()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TabView {
                    settingsPage {
                        sourceSection
                        if selectedSource == .libreLinkUp, !service.availableConnections.isEmpty {
                            SettingsPanel("Person") {
                                Picker("Show readings for", selection: Binding(
                                    get: { service.selectedPersonID ?? "" },
                                    set: { id in Task { await service.selectPerson(id) } }
                                )) {
                                    Text("Choose a person…").tag("")
                                    ForEach(service.availableConnections, id: \.id) { connection in
                                        Text(connection.displayName).tag(connection.patientId ?? connection.id)
                                    }
                                }
                                .disabled(service.isLoading)
                                Text("Each person has separate history and forecast learning.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        actionRow
                        startupSection
                    }.tabItem { Label("Connection", systemImage: "network") }
                    settingsPage {
                        menuAppearanceSection
                        displaySection
                        thresholdsSection
                        insightsSection
                    }.tabItem { Label("Appearance", systemImage: "menubar.rectangle") }
                    settingsPage { alertsSection }
                        .tabItem { Label("Alerts", systemImage: "bell") }
                    settingsPage {
                        SettingsPanel("Forecast learning") {
                            Text(service.forecastStatusText).font(.headline)
                            Text(forecastDescription).font(.caption).foregroundStyle(.secondary)
                            Button("Reset forecast learning") { service.resetForecastLearning() }
                            forecastAccuracySection
                            crossingAccuracySection
                            backtestSection
                        }
                    }.tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                    settingsPage { dataSection }
                        .tabItem { Label("Data", systemImage: "externaldrive") }
                }
            }
            Text("Appearance and alert preferences save automatically. Use Connect after changing account details.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 700, height: 610)
        .alert("Delete this profile’s history?", isPresented: $confirmDelete) {
            Button("Delete history", role: .destructive) { service.deleteStoredHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes local readings and forecast learning for the active profile. New readings will be stored after the next refresh.")
        }
        .alert("Forget saved credentials?", isPresented: $confirmForget) {
            Button("Forget credentials", role: .destructive) { service.forgetCredentials(); loadSettings() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("GlucoBar will disconnect and remove its saved login and token. Stored history remains on this Mac.")
        }
        .alert("Assign older history to this profile?", isPresented: $confirmLegacyImport) {
            Button("Import history") { service.importLegacyHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only continue if the unassigned readings belong to the currently selected person and account. Older versions did not record that identity.")
        }
        .alert("Delete unassigned history?", isPresented: $confirmLegacyDelete) {
            Button("Delete", role: .destructive) { service.deleteLegacyHistory() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes the older unassigned copy and its old forecast learning. Current profile history is kept.") }
        .task { await service.notifier.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await service.notifier.refreshAuthorization() }
        }
        .onAppear(perform: loadSettings)
        .onChange(of: service.graphWindowHours) { _, newValue in
            if Int(graphWindowHours.rounded()) != newValue {
                graphWindowHours = Double(newValue)
            }
        }
        .onChange(of: service.graphAxisMode) { _, newValue in
            if graphAxisMode != newValue {
                graphAxisMode = newValue
            }
        }
    }

    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
    }

    private var menuAppearanceSection: some View {
        SettingsPanel("Menu bar") {
            Toggle("Show change since the previous reading", isOn: $service.menuShowsDelta)
            Toggle("Show reading age", isOn: $service.menuShowsAge)
            Toggle("Privacy mode", isOn: $service.privacyMode)
            Text("Privacy mode hides glucose values in the menu bar, app windows and new notifications while sharing your screen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPanel("macOS permission") {
                Label(service.notifier.permissionText, systemImage: service.notifier.authorized ? "bell.badge" : "bell.slash")
                HStack {
                    Button("Allow notifications") { service.notifier.requestAuthorizationIfNeeded() }
                    Button("Test notification") { service.notifier.testNotification() }
                        .disabled(!service.notifier.authorized)
                    Button("macOS settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
                if let error = service.notifier.lastError { Text(error).foregroundStyle(.red) }
            }
            SettingsPanel("Alerts") {
                Toggle("Notify on predicted low", isOn: $service.notifyPredictedLow)
                Toggle("Notify on predicted high", isOn: $service.notifyPredictedHigh)
                Toggle("Notify when readings are more than 15 minutes old", isOn: $service.notifyMissingData)
                if !service.predictionEnabled && (service.notifyPredictedLow || service.notifyPredictedHigh) {
                    Text("Turn on Show forecast in Appearance to receive predicted glucose alerts.").font(.caption).foregroundStyle(.orange)
                }
                Picker("Repeat each alert type at most every", selection: $service.notificationCooldownMinutes) {
                    ForEach(LibreLinkUpService.notificationCooldownOptions, id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Text("Forecast alerts use your selected horizon and thresholds. Alerts require GlucoBar to be running and your Mac to be awake.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsPanel("Snooze all alerts") {
                HStack {
                    ForEach([15, 30, 60], id: \.self) { minutes in
                        Button("\(minutes) minutes") { service.notifier.snooze(minutes: minutes) }
                    }
                    Button("Resume now") { service.notifier.snooze(minutes: 0) }
                }
                if let until = service.notifier.snoozedUntil, until > service.statusTick {
                    Text("Snoozed until \(until.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                } else { Text("Alerts are not snoozed").foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var crossingAccuracySection: some View {
        Divider()
        Text("Crossing predictions · last 7 days").font(.caption.weight(.semibold))
        if service.crossingSummaries.isEmpty {
            Text("Waiting for complete forecast windows to evaluate crossings.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(service.crossingSummaries, id: \.kind) { summary in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(summary.kind): \(summary.detected) detected · \(summary.missed) missed · \(summary.falseWarnings) false warnings")
                Text("\(summary.windows) evaluated windows · mean lead \(summary.meanLeadMinutes.map { String(format: "%.0f min", $0) } ?? "—")")
                    .foregroundStyle(.secondary)
            }.font(.caption)
        }
        Text("Counts describe overlapping forecast windows starting in range, not independent events or delivered notifications. Windows with missing readings are excluded. Thresholds and horizons are captured when each forecast is made.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var dataSection: some View {
        SettingsPanel("Local history") {
            Text("\(service.storedHistoryDays) days stored for the active profile")
            Picker("Keep history", selection: $service.historyRetentionDays) {
                ForEach(LibreLinkUpService.historyRetentionOptions, id: \.self) { Text("\($0) days").tag($0) }
            }
            Text("Readings are stored in five-minute bins on this Mac. Each source, account and selected person has separate history and forecast learning. Credentials are stored in Keychain. Exports contain health data.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Export CSV…") { service.exportHistory() }.disabled(service.historyStore.isEmpty)
                Button("Delete stored history…", role: .destructive) { confirmDelete = true }.disabled(!service.hasActiveProfile)
            }
            if service.hasLegacyHistory {
                Divider()
                Text(service.legacyHistoryWasImported ? "Older history backup" : "Unassigned history from an older version").font(.headline)
                Text(service.legacyHistoryWasImported ? "The older data has been imported. Its original copy is still available here as a backup." : "Older readings are restored automatically when they match this profile. Otherwise, import them only after checking who they belong to.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Export older history…") { service.exportHistory(legacy: true) }
                    Button("Import into this profile…") { confirmLegacyImport = true }.disabled(!service.hasActiveProfile)
                    Button("Delete older history…", role: .destructive) { confirmLegacyDelete = true }
                }
            }
            Divider()
            Button("Forget credentials…", role: .destructive) { confirmForget = true }
            if let message = service.dataMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings")
                .font(.title2.weight(.semibold))
        }
    }

    private var statusStrip: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: statusIconName)
                .foregroundStyle(statusColor)
                .frame(width: 16)

            Text(statusLine)
                .help(statusLine)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.10))
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsPanel("Data Source") {
                Picker("Source", selection: $selectedSource) {
                    ForEach(DataSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)

            }

            if selectedSource == .libreLinkUp {
                SettingsPanel("LibreLinkUp") {
                    TextField("Email address", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { connect() }

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { connect() }
                }
            } else {
                SettingsPanel("Nightscout") {
                    TextField("Base URL", text: $nightscoutBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { connect() }

                    SecureField("API token", text: $nightscoutToken)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { connect() }
                }
            }
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsPanel("Display") {
                Toggle("Show values in mmol/L", isOn: $useMmolPerL)
                    .onChange(of: useMmolPerL) { _, newValue in
                        service.useMmolPerL = newValue
                        loadThresholdSettings()
                    }

                Divider()

                HStack(spacing: 10) {
                    Text("Graph history")
                        .frame(width: 92, alignment: .leading)

                    Slider(value: $graphWindowHours, in: 1...24, step: 1)
                        .onChange(of: graphWindowHours) { _, newValue in
                            service.graphWindowHours = Int(newValue.rounded())
                        }

                    Text("\(Int(graphWindowHours))h")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }

                Divider()

                HStack(spacing: 10) {
                    Text("Graph scale")
                        .frame(width: 92, alignment: .leading)

                    Picker("Graph scale", selection: $graphAxisMode) {
                        ForEach(GraphAxisMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: graphAxisMode) { _, newValue in
                        service.graphAxisMode = newValue
                    }
                }

                Text(graphAxisDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var thresholdsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsPanel("Threshold Bands") {
                Toggle("Show threshold bands", isOn: $showTargetBands)
                    .onChange(of: showTargetBands) { _, newValue in
                        service.showTargetBands = newValue
                    }

                if showTargetBands {
                    if selectedSource == .libreLinkUp {
                        Toggle("Set thresholds manually", isOn: $customTargetsEnabled)
                            .onChange(of: customTargetsEnabled) { _, newValue in
                                service.customTargetsEnabled = newValue
                                commitThresholdValues()
                            }
                    } else {
                        Label("Nightscout uses manual thresholds.", systemImage: "slider.horizontal.3")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if showTargetBands {
                SettingsPanel("Values") {
                    thresholdRow(
                        title: "Low",
                        isEnabled: $lowThresholdEnabled,
                        value: $customLowThreshold,
                        range: thresholdRange,
                        tint: .red
                    )

                    thresholdRow(
                        title: "High",
                        isEnabled: $highThresholdEnabled,
                        value: $customHighThreshold,
                        range: thresholdRange,
                        tint: .orange
                    )

                    if !thresholdValuesAreEditable {
                        Label("Using thresholds from LibreLinkUp.", systemImage: "waveform.path.ecg")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Label("Using manual thresholds.", systemImage: "slider.horizontal.3")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }

    }

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsPanel("Startup") {
                Toggle("Open GlucoBar when you log in", isOn: $launchAtStartup)
                    .onChange(of: launchAtStartup) { _, newValue in
                        Task { @MainActor in
                            await service.setLaunchAtLoginEnabled(newValue)
                            launchAtStartup = service.launchAtLoginEnabled
                        }
                    }
            }
        }
    }

    private var insightsSection: some View {
        SettingsPanel("Insights") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Toggle("Show forecast", isOn: $service.predictionEnabled)
                    Picker("Horizon", selection: $service.predictionHorizonMinutes) {
                        ForEach(LibreLinkUpService.predictionHorizonOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)
                    .disabled(!service.predictionEnabled)
                    Toggle("Uncertainty band", isOn: $service.predictionBandEnabled)
                        .disabled(!service.predictionEnabled)
                }

                GridRow {
                    Toggle("Show rolling average", isOn: $service.rollingAverageEnabled)
                    Picker("Average window", selection: $service.rollingAverageMinutes) {
                        ForEach(LibreLinkUpService.rollingAverageOptions, id: \.self) { minutes in
                            Text(minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes) min").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)
                    .disabled(!service.rollingAverageEnabled)
                    Color.clear.frame(height: 1)
                }

                GridRow {
                    Toggle("Show typical day", isOn: $service.typicalDayEnabled)
                    Picker("Lookback", selection: $service.typicalDayLookbackDays) {
                        ForEach(LibreLinkUpService.typicalDayLookbackOptions.filter { $0 <= service.historyRetentionDays }, id: \.self) { days in
                            Text("\(days) days").tag(days)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)
                    .disabled(!service.typicalDayEnabled)
                    Text(service.storedHistoryDays == 0 ? "No history stored yet" : "\(service.storedHistoryDays) days of history stored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GridRow {
                    Toggle("Show trends in menu", isOn: $service.trendsEnabled)
                }

            }

        }
    }

    private struct AccuracyDisplayRow: Identifiable {
        let title: String
        let maeByHorizon: [Int: Double]
        let counts: [Int: Int]
        var id: String { title }
    }

    @ViewBuilder
    private var forecastAccuracySection: some View {
        let rows = service.forecastAccuracyRows.map { AccuracyDisplayRow(title: $0.title, maeByHorizon: $0.maeByHorizon, counts: $0.countsByHorizon) }
        if !rows.isEmpty {
            Divider()
            Text("Forecast accuracy over the last 7 days, mean error in \(service.displayUnitLabel) · n = checks")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            accuracyTable(rows: rows, coverage: service.forecastBandCoverage)
        }
    }

    @ViewBuilder
    private var backtestSection: some View {
        Divider()
        HStack(spacing: 10) {
            Button("Run backtest on stored history") {
                service.runBacktest(days: 7)
            }
            .controlSize(.small)
            .disabled(service.backtestProgress != nil || service.storedHistoryDays < 2)

            if let progress = service.backtestProgress {
                ProgressView(value: progress)
                    .frame(width: 120)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if service.storedHistoryDays < 2 {
                Text("Needs at least two days of stored history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Replays the last week of history through a fresh forecaster, retraining daily on only what was known at the time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let result = service.backtestResult {
            Text("Backtest over the last \(result.evaluationDays) days, \(result.forecastCount) forecasts, mean error in \(service.displayUnitLabel) · n = checks")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            accuracyTable(
                rows: result.rows.map { AccuracyDisplayRow(title: $0.title, maeByHorizon: $0.maeByHorizon, counts: $0.countsByHorizon) },
                coverage: result.bandCoverageByHorizon
            )
        }
    }

    private func accuracyTable(rows: [AccuracyDisplayRow], coverage: [Int: Double]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                Text("Model")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                accuracyHeader(15)
                accuracyHeader(30)
                accuracyHeader(60)
            }
            ForEach(rows) { row in
                GridRow {
                    Text(row.title)
                        .font(.caption)
                        .fontWeight(row.title.hasPrefix("Forecast") ? .semibold : .regular)
                    accuracyCell(row.maeByHorizon[15].map { service.formattedValue(for: $0) + " · n=\(row.counts[15] ?? 0)" })
                    accuracyCell(row.maeByHorizon[30].map { service.formattedValue(for: $0) + " · n=\(row.counts[30] ?? 0)" })
                    accuracyCell(row.maeByHorizon[60].map { service.formattedValue(for: $0) + " · n=\(row.counts[60] ?? 0)" })
                }
            }
            if !coverage.isEmpty {
                GridRow {
                    Text("Band coverage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    accuracyCell(coverage[15].map { "\(Int(($0 * 100).rounded()))%" })
                    accuracyCell(coverage[30].map { "\(Int(($0 * 100).rounded()))%" })
                    accuracyCell(coverage[60].map { "\(Int(($0 * 100).rounded()))%" })
                }
            }
        }
    }

    private func accuracyHeader(_ minutes: Int) -> some View {
        Text("\(minutes) min")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .gridColumnAlignment(.trailing)
    }

    private func accuracyCell(_ text: String?) -> some View {
        Text(text ?? "—")
            .font(.caption)
            .monospacedDigit()
            .gridColumnAlignment(.trailing)
    }

    private var forecastDescription: String {
        let learned = service.forecastLearnedCount
        let learning = learned == 0
            ? "It has not scored any forecasts yet."
            : "It has checked \(learned) predicted horizon values against real readings so far."
        var text = "The forecast blends a trend fit, a momentum fit, the sensor's trend arrow, matches against your own history, a regression trained on that history and your typical-day drift. It scores every forecast against what actually happened, learns each model's error and bias by regime, and adapts the blend and the band. \(learning) \(service.forecastRegressionSummary)"
        if let blend = service.forecastBlendSummary {
            text += " \(blend)"
        }
        return text + " Forecasts are estimates, not medical advice."
    }

    private func thresholdRow(
        title: String,
        isEnabled: Binding<Bool>,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .onChange(of: isEnabled.wrappedValue) { _, _ in
                    commitThresholdValues()
                }

            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)

            Text(title)
                .frame(width: 36, alignment: .leading)

            TextField(title, value: value, format: thresholdFormat)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .disabled(!thresholdValuesAreEditable || !isEnabled.wrappedValue)
                .onSubmit { commitThresholdValues() }
                .onChange(of: value.wrappedValue) { _, _ in
                    commitThresholdValues()
                }

            Stepper(title, value: value, in: range, step: thresholdStep)
                .labelsHidden()
                .disabled(!thresholdValuesAreEditable || !isEnabled.wrappedValue)

            Text(thresholdUnitLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Spacer()

            if service.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Connect") { connect() }
                .buttonStyle(.borderedProminent)
                .disabled(!canConnect)
        }
    }

    private var statusIconName: String {
        if service.errorMessage != nil {
            return "exclamationmark.triangle.fill"
        }
        if service.isAuthenticated {
            return "checkmark.circle.fill"
        }
        return "person.crop.circle"
    }

    private var statusColor: Color {
        if service.errorMessage != nil { return .red }
        if service.isAuthenticated { return .green }
        return .secondary
    }

    private var statusTitle: String {
        if service.errorMessage != nil {
            return "Connection problem"
        }
        if service.isAuthenticated {
            return "Connected"
        }
        return "Not connected"
    }

    private var statusDetail: String? {
        if let error = service.errorMessage {
            return error
        }
        if service.isAuthenticated {
            return service.lastUpdatedText
        }
        return service.sourceDisplayName
    }

    private var statusLine: String {
        if let statusDetail, !statusDetail.isEmpty {
            return [service.connectionIssue ?? statusTitle, statusDetail, service.retryText].compactMap { $0 }.joined(separator: " • ")
        }
        return statusTitle
    }

    private var canConnect: Bool {
        if selectedSource == .libreLinkUp {
            return !email.isEmpty && !password.isEmpty && !service.isLoading
        } else {
            return !nightscoutBaseURL.isEmpty && !service.isLoading
        }
    }

    private var graphAxisDescription: String {
        switch graphAxisMode {
        case .fixed:
            return useMmolPerL
                ? "Always shows 0–20 mmol/L so the graph looks the same every time."
                : "Always shows 0–400 mg/dL so the graph looks the same every time."
        case .auto:
            return "Zooms the axis to your readings and thresholds for the selected window."
        }
    }

    private var thresholdStep: Double {
        useMmolPerL ? 0.1 : 1
    }

    private var thresholdRange: ClosedRange<Double> {
        useMmolPerL ? 2.0...25.0 : 36.0...450.0
    }

    private var thresholdUnitLabel: String {
        useMmolPerL ? "mmol/L" : "mg/dL"
    }

    private var thresholdFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(useMmolPerL ? 1 : 0))
    }

    private var thresholdValuesAreEditable: Bool {
        customTargetsEnabled || selectedSource == .nightscout
    }

    private func loadSettings() {
        email = service.email
        password = service.password
        launchAtStartup = service.launchAtLoginEnabled
        useMmolPerL = service.useMmolPerL
        graphWindowHours = Double(service.graphWindowHours)
        graphAxisMode = service.graphAxisMode
        selectedSource = service.dataSource
        nightscoutBaseURL = service.nightscoutBaseURL
        nightscoutToken = service.nightscoutToken
        loadThresholdSettings()
    }

    private func connect() {
        guard canConnect else { return }
        Task {
            await service.connect(source: selectedSource, email: email, password: password,
                                  url: nightscoutBaseURL, token: nightscoutToken)
        }
    }

    private func loadThresholdSettings() {
        showTargetBands = service.showTargetBands
        customTargetsEnabled = service.customTargetsEnabled
        lowThresholdEnabled = service.lowThresholdEnabled
        highThresholdEnabled = service.highThresholdEnabled
        customLowThreshold = displayThreshold(fromMgDl: service.customLowMgDl)
        customHighThreshold = displayThreshold(fromMgDl: service.customHighMgDl)
    }

    private func commitThresholdValues() {
        service.showTargetBands = showTargetBands
        service.customTargetsEnabled = thresholdValuesAreEditable
        service.lowThresholdEnabled = lowThresholdEnabled
        service.highThresholdEnabled = highThresholdEnabled
        service.customLowMgDl = mgDlThreshold(fromDisplayValue: customLowThreshold)
        service.customHighMgDl = mgDlThreshold(fromDisplayValue: customHighThreshold)
    }

    private func displayThreshold(fromMgDl value: Double) -> Double {
        useMmolPerL ? value / 18.0 : value.rounded()
    }

    private func mgDlThreshold(fromDisplayValue value: Double) -> Double {
        useMmolPerL ? value * 18.0 : value
    }
}

private struct SettingsPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            content
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.10))
        }
    }
}
