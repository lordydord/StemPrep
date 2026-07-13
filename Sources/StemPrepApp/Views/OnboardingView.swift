import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: StemPrepStore
    @State private var apiToken = ""
    @State private var errorMessage: String?
    @FocusState private var tokenIsFocused: Bool

    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 74, height: 74)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Connect StemPrep to MVSEP")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("StemPrep uses your own MVSEP account to separate tracks into stems.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OnboardingPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                OnboardingStep(
                    symbol: "person.crop.circle.badge.plus",
                    title: "Create or sign in to your account",
                    detail: "Open MVSEP and register if you do not already have an account."
                )
                OnboardingStep(
                    symbol: "key.horizontal",
                    title: "Copy your API token",
                    detail: "The Full API page displays your token after you sign in."
                )
                OnboardingStep(
                    symbol: "lock.shield",
                    title: "Paste it below",
                    detail: "StemPrep stores it in macOS Keychain and sends it only to MVSEP."
                )
            }
            .padding(.vertical, 24)

            HStack(spacing: 10) {
                Link(destination: AppIdentity.mvsepAPIHelpURL) {
                    Label("Open MVSEP", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)

                SecureField("Paste your MVSEP API token", text: $apiToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .focused($tokenIsFocused)
                    .onSubmit(saveAndContinue)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }

            HStack {
                Button("Set up later") {
                    onComplete()
                }
                .buttonStyle(.plain)
                .foregroundStyle(OnboardingPalette.muted)

                Spacer()

                Button("Save and continue", action: saveAndContinue)
                    .buttonStyle(.borderedProminent)
                    .tint(OnboardingPalette.accent)
                    .foregroundStyle(OnboardingPalette.ink)
                    .disabled(apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 22)
        }
        .padding(28)
        .frame(width: 590)
        .background(OnboardingPalette.background)
        .foregroundStyle(OnboardingPalette.text)
        .preferredColorScheme(.dark)
        .onAppear {
            apiToken = store.apiToken
            tokenIsFocused = apiToken.isEmpty
        }
    }

    private func saveAndContinue() {
        do {
            try store.saveAPIToken(apiToken)
            onComplete()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct OnboardingStep: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OnboardingPalette.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OnboardingPalette.muted)
            }
        }
    }
}

private enum OnboardingPalette {
    static let background = Color(red: 0.045, green: 0.050, blue: 0.056)
    static let text = Color(red: 0.925, green: 0.940, blue: 0.932)
    static let muted = Color(red: 0.590, green: 0.625, blue: 0.612)
    static let accent = Color(red: 1.000, green: 0.315, blue: 0.235)
    static let ink = Color(red: 0.080, green: 0.035, blue: 0.030)
}
