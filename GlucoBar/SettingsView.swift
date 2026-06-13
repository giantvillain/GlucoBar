import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var service: LibreLinkUpService
    @State private var email = ""
    @State private var password = ""
    @State private var launchAtStartup = false
    @State private var useMmolPerL = false
    @State private var graphWindowHours = 4.0
    @State private var selectedSource: DataSource = .libreLinkUp
    @State private var nightscoutBaseURL = ""
    @State private var nightscoutToken = ""
    @State private var showTargetBands = true
    @State private var customTargetsEnabled = false
    @State private var lowThresholdEnabled = true
    @State private var highThresholdEnabled = true
    @State private var customLowThreshold = 70.0
    @State private var customHighThreshold = 180.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusStrip

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    sourceSection
                    displaySection
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(alignment: .leading, spacing: 12) {
                    thresholdsSection
                    startupSection
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }

            actionRow
        }
        .padding(20)
        .frame(width: 660, alignment: .topLeading)
        .onAppear(perform: loadSettings)
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
                .onChange(of: selectedSource) { _, newValue in
                    service.dataSource = newValue
                    if newValue == .nightscout {
                        service.customTargetsEnabled = true
                        customTargetsEnabled = true
                    }
                }
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
        .frame(height: 214, alignment: .top)
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

            Button("Save and Connect") { connect() }
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
            return "\(statusTitle) • \(statusDetail)"
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
        selectedSource = service.dataSource
        nightscoutBaseURL = service.nightscoutBaseURL
        nightscoutToken = service.nightscoutToken
        loadThresholdSettings()
    }

    private func connect() {
        guard canConnect else { return }
        service.dataSource = selectedSource
        if selectedSource == .libreLinkUp {
            service.email = email
            service.password = password
            Task { await service.authenticate() }
        } else {
            service.nightscoutBaseURL = nightscoutBaseURL
            service.nightscoutToken = nightscoutToken
            Task { await service.fetchGlucose() }
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
