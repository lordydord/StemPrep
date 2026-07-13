import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: StemPrepStore
    @AppStorage("mvsepOutputFormat") private var outputFormatRaw = MvsepOutputFormat.wav16.rawValue
    @State private var apiToken = ""
    @State private var saveMessage: String?
    @State private var saveFailed = false
    @FocusState private var tokenIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SettingsPalette.accent)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(SettingsPalette.ink)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Engine settings")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Connection and default delivery format")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SettingsPalette.muted)
                }
            }
            .padding(24)

            Rectangle()
                .fill(SettingsPalette.line)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsLabel(number: "01", title: "MVSEP API TOKEN")

                    SecureField("Paste your token", text: $apiToken)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .focused($tokenIsFocused)
                        .padding(.horizontal, 13)
                        .frame(height: 40)
                        .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(tokenIsFocused ? SettingsPalette.accent.opacity(0.7) : SettingsPalette.line, lineWidth: 1)
                        }

                    HStack {
                        Link(destination: AppIdentity.mvsepAPIHelpURL) {
                            Label("Get an API token", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.link)

                        Spacer()

                        if !store.apiToken.isEmpty {
                            Button("Remove", role: .destructive, action: removeToken)
                                .buttonStyle(.bordered)
                        }

                        Button("Save token", action: saveToken)
                            .buttonStyle(.borderedProminent)
                            .tint(SettingsPalette.accent)
                            .foregroundStyle(SettingsPalette.ink)
                            .disabled(apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text("Stored in macOS Keychain and sent only to MVSEP when you start a separation.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SettingsPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let saveMessage {
                        Text(saveMessage)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(saveFailed ? Color.red : SettingsPalette.accent)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SettingsLabel(number: "02", title: "DEFAULT DELIVERY")

                    Picker("Output format", selection: $outputFormatRaw) {
                        ForEach(MvsepOutputFormat.allCases) { format in
                            Text(format.displayName).tag(format.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    Text(selectedFormatDetail)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(SettingsPalette.muted)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SettingsLabel(number: "03", title: "MVSEP ACCOUNT")
                        Spacer()
                        Button {
                            store.refreshMVSEPData()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10, weight: .semibold))
                        .disabled(store.apiToken.isEmpty)
                    }

                    accountPanel
                }
            }
            .padding(24)
        }
        .frame(width: 480)
        .background(SettingsPalette.background)
        .foregroundStyle(SettingsPalette.text)
        .preferredColorScheme(.dark)
        .onAppear {
            store.refreshPreferences()
            apiToken = store.apiToken
            store.refreshMVSEPData()
        }
        .onChange(of: outputFormatRaw) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "mvsepOutputFormat")
            store.outputFormat = MvsepOutputFormat(rawValue: newValue) ?? .wav16
        }
    }

    private var selectedFormatDetail: String {
        MvsepOutputFormat(rawValue: outputFormatRaw)?.technicalDetail ?? MvsepOutputFormat.wav16.technicalDetail
    }

    @ViewBuilder
    private var accountPanel: some View {
        switch store.accountState {
        case .notConfigured:
            accountMessage(icon: "key", title: "Not connected", detail: "Save an API token to check your MVSEP account.")
        case .checking:
            accountMessage(icon: "arrow.triangle.2.circlepath", title: "Checking account", detail: "Requesting the latest account status from MVSEP…")
        case let .invalid(message):
            accountMessage(icon: "exclamationmark.triangle", title: "Token needs attention", detail: message)
        case let .unavailable(message):
            accountMessage(icon: "wifi.exclamationmark", title: "Account unavailable", detail: message)
        case let .connected(account):
            HStack(spacing: 8) {
                accountMetric(value: formattedBalance(account.premiumMinutes), label: "PREMIUM BALANCE")
                accountMetric(value: account.premiumEnabled ? "ON" : "OFF", label: "PREMIUM USE")
                accountMetric(value: String(account.activeSeparations), label: "ACTIVE JOBS")
                accountMetric(value: account.longFilenamesEnabled ? "ON" : "OFF", label: "LONG NAMES")
            }
        }
    }

    private func accountMessage(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsPalette.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(SettingsPalette.muted)
            }
            Spacer()
        }
        .padding(11)
        .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func accountMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(SettingsPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(SettingsPalette.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func formattedBalance(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value.rounded() == value ? 0 : 1)))
    }

    private func saveToken() {
        do {
            try store.saveAPIToken(apiToken)
            apiToken = store.apiToken
            saveFailed = false
            saveMessage = "Saved securely in Keychain."
        } catch {
            saveFailed = true
            saveMessage = error.localizedDescription
        }
    }

    private func removeToken() {
        do {
            try store.saveAPIToken("")
            apiToken = ""
            saveFailed = false
            saveMessage = "Token removed from Keychain."
        } catch {
            saveFailed = true
            saveMessage = error.localizedDescription
        }
    }
}

private struct SettingsLabel: View {
    let number: String
    let title: String

    var body: some View {
        HStack(spacing: 7) {
            Text(number).foregroundStyle(SettingsPalette.accent)
            Text(title).foregroundStyle(SettingsPalette.muted)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .tracking(1.3)
    }
}

private enum SettingsPalette {
    static let background = Color(red: 0.045, green: 0.050, blue: 0.056)
    static let field = Color(red: 0.075, green: 0.082, blue: 0.090)
    static let line = Color.white.opacity(0.09)
    static let text = Color(red: 0.925, green: 0.940, blue: 0.932)
    static let muted = Color(red: 0.590, green: 0.625, blue: 0.612)
    static let accent = Color(red: 1.000, green: 0.315, blue: 0.235)
    static let ink = Color(red: 0.080, green: 0.035, blue: 0.030)
}
