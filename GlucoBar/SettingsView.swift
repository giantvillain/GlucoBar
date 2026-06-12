import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var service: LibreLinkUpService
    @State private var email = ""
    @State private var password = ""
    @State private var launchAtStartup = false
    @State private var useMmolPerL = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statusCard
            accountCard
            preferencesCard
            actionRow
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            email = service.email
            password = service.password
            launchAtStartup = service.launchAtLoginEnabled
            useMmolPerL = service.useMmolPerL
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.title2.weight(.semibold))
            Text("Connect GlucoBar to your LibreLinkUp account, choose how values are shown, and control whether it starts automatically.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current Status")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: statusIconName)
                    .foregroundStyle(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(service.statusHeadline)
                        .font(.headline)

                    if let statusDetail {
                        Text(statusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.12))
        }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LibreLinkUp Account")
                .font(.headline)

            Text("Use the same email and password you use in LibreLinkUp. The password is stored securely in Keychain on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                TextField("Email address", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { connect() }

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { connect() }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.12))
        }
    }

    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display")
                .font(.headline)

            Toggle(isOn: $useMmolPerL) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show values in mmol/L")
                    Text("Turn this off to display values in mg/dL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: useMmolPerL) { _, newValue in
                service.useMmolPerL = newValue
            }

            Divider()

            Text("Startup")
                .font(.headline)

            Toggle(isOn: $launchAtStartup) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open GlucoBar when you log in")
                    Text("Launch the app automatically after you sign in to macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: launchAtStartup) { _, newValue in
                Task { @MainActor in
                    await service.setLaunchAtLoginEnabled(newValue)
                    launchAtStartup = service.launchAtLoginEnabled
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.12))
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

    private var statusDetail: String? {
        if let error = service.errorMessage {
            return error
        }
        if service.isAuthenticated {
            return "Your account is connected and GlucoBar can refresh readings automatically."
        }
        return "Sign in to start showing your current glucose readings."
    }

    private var canConnect: Bool {
        !email.isEmpty && !password.isEmpty && !service.isLoading
    }

    private func connect() {
        guard canConnect else { return }
        service.email = email
        service.password = password
        Task { await service.authenticate() }
    }
}
