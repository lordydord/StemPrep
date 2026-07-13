import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: StemPrepStore
    @Environment(\.openSettings) private var openSettings
    @AppStorage("hasCompletedOnboardingV1") private var hasCompletedOnboarding = false
    @State private var showsOnboarding = false

    var body: some View {
        ZStack {
            StudioPalette.background
                .ignoresSafeArea()

            AmbientBackdrop()

            VStack(spacing: 0) {
                StudioHeader {
                    openSettings()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        HeroHeader()
                        WorkflowRail()

                        HStack(alignment: .top, spacing: 18) {
                            SourceDeck()
                                .frame(maxWidth: .infinity)

                            EngineRack()
                                .frame(width: 330)
                        }

                        OutputRack()
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 28)
                    .padding(.bottom, 38)
                    .frame(maxWidth: 1380)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(StudioPalette.text)
        .preferredColorScheme(.dark)
        .onAppear {
            store.refreshPreferences()
            store.loadAlgorithms()
            store.recoverInterruptedJobIfNeeded()
            showsOnboarding = !hasCompletedOnboarding
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView {
                hasCompletedOnboarding = true
                showsOnboarding = false
            }
            .environmentObject(store)
            .interactiveDismissDisabled()
        }
    }
}

private struct AmbientBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .fill(StudioPalette.accent.opacity(0.08))
                    .frame(width: 520, height: 520)
                    .blur(radius: 120)
                    .offset(x: proxy.size.width * 0.34, y: -proxy.size.height * 0.42)

                Circle()
                    .fill(StudioPalette.signalBlue.opacity(0.045))
                    .frame(width: 420, height: 420)
                    .blur(radius: 140)
                    .offset(x: -proxy.size.width * 0.42, y: proxy.size.height * 0.32)

                Canvas { context, size in
                    var path = Path()
                    let step: CGFloat = 48
                    stride(from: CGFloat.zero, through: size.width, by: step).forEach { x in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    stride(from: CGFloat.zero, through: size.height, by: step).forEach { y in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(path, with: .color(Color.white.opacity(0.018)), lineWidth: 0.5)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct StudioHeader: View {
    @EnvironmentObject private var store: StemPrepStore
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 12) {
                BrandMark()

                VStack(alignment: .leading, spacing: 2) {
                    Text("STEM / PREP")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .tracking(1.9)
                    Text("MVSEP desktop instrument")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioPalette.muted)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(engineIndicator)
                    .frame(width: 7, height: 7)
                    .shadow(color: engineIndicator.opacity(0.7), radius: 6)

                Text(engineLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(StudioPalette.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(StudioPalette.surfaceSoft, in: Capsule())

            Divider()
                .frame(height: 22)
                .overlay(StudioPalette.line)

            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(UtilityButtonStyle())
            .help("Settings")
        }
        .padding(.horizontal, 24)
        .frame(height: 68)
        .background(StudioPalette.header.opacity(0.94))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(StudioPalette.line)
                .frame(height: 1)
        }
    }

    private var engineLabel: String {
        if store.algorithmLoadStatus != nil {
            return "SYNCING MODELS"
        }
        return "ENGINE READY"
    }

    private var engineIndicator: Color {
        store.algorithmLoadStatus == nil ? StudioPalette.accent : StudioPalette.signalAmber
    }
}

private struct BrandMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StudioPalette.accent)

            HStack(alignment: .center, spacing: 2) {
                ForEach([8, 17, 25, 13, 21, 10], id: \.self) { height in
                    Capsule()
                        .fill(StudioPalette.ink)
                        .frame(width: 2.5, height: CGFloat(height))
                }
            }
        }
        .frame(width: 38, height: 38)
        .shadow(color: StudioPalette.accent.opacity(0.2), radius: 12, y: 5)
    }
}

private struct HeroHeader: View {
    @EnvironmentObject private var store: StemPrepStore

    var body: some View {
        HStack(alignment: .bottom, spacing: 30) {
            VStack(alignment: .leading, spacing: 9) {
                Text("STUDIO UTILITY  /  01")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(StudioPalette.accent)

                Text("Unmix the record.")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .tracking(-1.8)
                    .textSelection(.enabled)

                Text("Drop in a WAV, choose the separation engine, and collect every part beside the original track.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(StudioPalette.muted)
                    .frame(maxWidth: 650, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 5) {
                Text(statusEyebrow)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(StudioPalette.subtle)
                Text(store.status.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 300, alignment: .trailing)
        }
    }

    private var statusEyebrow: String {
        switch store.status {
        case .idle: return "WAITING FOR SOURCE"
        case .ready: return "SOURCE LOCKED"
        case .paused: return "RENDER PAUSED"
        case .complete: return "EXPORT COMPLETE"
        case .failed: return "ACTION REQUIRED"
        default: return "RENDER IN PROGRESS"
        }
    }
}

private struct WorkflowRail: View {
    @EnvironmentObject private var store: StemPrepStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(WorkflowStep.allCases.enumerated()), id: \.element.id) { index, step in
                WorkflowNode(step: step, state: state(for: step))

                if index < WorkflowStep.allCases.count - 1 {
                    Rectangle()
                        .fill(index < activeIndex ? StudioPalette.accent.opacity(0.75) : StudioPalette.line)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func state(for step: WorkflowStep) -> WorkflowNodeState {
        if step.index < activeIndex { return .complete }
        if step.index == activeIndex { return .active }
        return .upcoming
    }

    private var activeIndex: Int {
        switch store.status {
        case .idle, .failed: return 0
        case .ready: return 1
        case .paused: return 2
        case .checking: return 1
        case .preparing, .uploading, .queued, .processing, .downloading: return 2
        case .complete: return 3
        }
    }
}

private struct WorkflowNode: View {
    let step: WorkflowStep
    let state: WorkflowNodeState

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(circleFill)
                    .frame(width: 28, height: 28)
                Image(systemName: state == .complete ? "checkmark" : step.icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("0\(step.index + 1)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(state == .active ? StudioPalette.accent : StudioPalette.subtle)
                Text(step.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state == .upcoming ? StudioPalette.subtle : StudioPalette.text)
            }
        }
        .fixedSize()
    }

    private var circleFill: Color {
        switch state {
        case .complete: return StudioPalette.accent
        case .active: return StudioPalette.accent.opacity(0.16)
        case .upcoming: return StudioPalette.surfaceSoft
        }
    }

    private var iconColor: Color {
        switch state {
        case .complete: return StudioPalette.ink
        case .active: return StudioPalette.accent
        case .upcoming: return StudioPalette.subtle
        }
    }
}

private struct SourceDeck: View {
    @EnvironmentObject private var store: StemPrepStore
    @State private var isTargeted = false
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("SOURCE DECK", systemImage: "waveform")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.7)
                    .foregroundStyle(StudioPalette.muted)

                Spacer()

                Text(sourceBadge)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(store.selectedFile == nil ? StudioPalette.subtle : StudioPalette.accent)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 17)

            Rectangle()
                .fill(StudioPalette.line)
                .frame(height: 1)

            VStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(isTargeted ? StudioPalette.accent.opacity(0.10) : StudioPalette.deck)
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .strokeBorder(
                                    isTargeted ? StudioPalette.accent : StudioPalette.lineStrong,
                                    style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 1, dash: isTargeted ? [] : [7, 7])
                                )
                        }

                    VStack(spacing: 20) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(StudioPalette.accent.opacity(0.14))
                                Image(systemName: store.selectedFile == nil ? "waveform.badge.plus" : "waveform")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(StudioPalette.accent)
                            }
                            .frame(width: 52, height: 52)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(sourceTitle)
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .tracking(-0.4)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(sourceSubtitle)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(StudioPalette.muted)
                                    .lineLimit(2)
                            }

                            Spacer()

                            Button(store.selectedFile == nil ? "Browse" : "Replace") {
                                store.chooseFile()
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .disabled(store.status.isRunning || store.hasResumableJob)
                        }

                        SignalWaveform(isActive: store.selectedFile != nil || store.status.isRunning)
                            .frame(height: 112)

                        HStack(spacing: 10) {
                            if let info = store.selectedFileInfo {
                                DeckMetadata(label: "SIZE", value: info.fileSize)
                                DeckMetadata(label: "LENGTH", value: info.duration ?? "READING")
                                DeckMetadata(label: "LOCATION", value: info.folder, expands: true)
                            } else {
                                DeckMetadata(label: "FORMAT", value: "WAV")
                                DeckMetadata(label: "INPUT", value: "DRAG OR BROWSE")
                                DeckMetadata(label: "OUTPUT", value: "BESIDE SOURCE", expands: true)
                            }
                        }
                    }
                    .padding(24)
                }
                .scaleEffect(isHovering && !store.status.isRunning ? 1.004 : 1)
                .animation(.easeOut(duration: 0.2), value: isHovering)
                .onHover { isHovering = $0 }
                .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted, perform: handleDrop)

                RenderStatusBar()
            }
            .padding(20)
        }
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(StudioPalette.line, lineWidth: 1)
        }
        .shadow(color: StudioPalette.shadow, radius: 28, y: 18)
    }

    private var sourceTitle: String {
        store.selectedFileInfo?.name ?? "Drop your master here"
    }

    private var sourceSubtitle: String {
        if store.selectedFile == nil {
            return isTargeted ? "Release to load this WAV" : "One clean WAV. We’ll handle the rest."
        }
        return "Ready for \(store.selectedAlgorithm.groupName)"
    }

    private var sourceBadge: String {
        store.selectedFile == nil ? "NO SOURCE" : "SOURCE LOCKED"
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard
                let data,
                let string = String(data: data, encoding: .utf8),
                let url = URL(string: string)
            else { return }

            Task { @MainActor in
                store.select(file: url)
            }
        }
        return true
    }
}

private struct DeckMetadata: View {
    let label: String
    let value: String
    var expands = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(StudioPalette.subtle)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(StudioPalette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
        .background(StudioPalette.surfaceSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SignalWaveform: View {
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<84, id: \.self) { index in
                    Capsule()
                        .fill(barColor(for: index))
                        .frame(maxWidth: .infinity)
                        .frame(height: height(for: index, maximum: proxy.size.height))
                }
            }
        }
        .overlay(alignment: .center) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    private func height(for index: Int, maximum: CGFloat) -> CGFloat {
        let a = abs(sin(Double(index) * 0.31))
        let b = abs(cos(Double(index) * 0.13))
        let envelope = 0.28 + sin(Double(index) / 83 * .pi) * 0.72
        return max(8, CGFloat((0.18 + a * b * 0.82) * envelope) * maximum)
    }

    private func barColor(for index: Int) -> Color {
        guard isActive else { return StudioPalette.subtle.opacity(0.20) }
        let emphasis = 0.42 + abs(sin(Double(index) * 0.11)) * 0.48
        return StudioPalette.accent.opacity(emphasis)
    }
}

private struct RenderStatusBar: View {
    @EnvironmentObject private var store: StemPrepStore

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.14))
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusColor.opacity(0.6), radius: 5)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(store.status.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusDetail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioPalette.muted)
                        .lineLimit(2)
                }

                Spacer()

                if store.status.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedText(now: context.date))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(StudioPalette.accent)
                    }
                }
            }

            if store.status.isRunning {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StudioPalette.surfaceSoft)
                        Capsule()
                            .fill(StudioPalette.accent)
                            .frame(width: proxy.size.width * CGFloat(store.status.progress ?? 0.34))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 2)
    }

    private var statusDetail: String {
        switch store.status {
        case .idle: return "Choose a WAV to start a new separation."
        case .ready: return "Source is loaded. Review the engine and render."
        case .checking: return "Checking whether these exact stems already exist."
        case .uploading: return "Sending the original WAV to MVSEP."
        case .queued, .processing: return "The remote engine is separating your track."
        case .downloading: return "Saving returned stems in parallel without duplicate raw copies."
        case .paused(let message): return message
        case .complete: return "All files are ready beside the source track."
        case .failed(let message): return message
        case .preparing: return "Creating the output folder beside the source."
        }
    }

    private var statusColor: Color {
        switch store.status {
        case .complete: return StudioPalette.success
        case .failed: return StudioPalette.danger
        case .paused: return StudioPalette.signalAmber
        case .idle, .ready: return StudioPalette.subtle
        default: return StudioPalette.accent
        }
    }

    private func elapsedText(now: Date) -> String {
        guard let start = store.runStartedAt else { return "00:00" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct EngineRack: View {
    @EnvironmentObject private var store: StemPrepStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("SEPARATION ENGINE", systemImage: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(StudioPalette.muted)
                Spacer()
                Text("MVSEP")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(StudioPalette.accent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 17)

            Rectangle().fill(StudioPalette.line).frame(height: 1)

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    RackLabel(number: "01", title: "MODEL")

                    Picker("Model", selection: $store.selectedRenderID) {
                        ForEach(store.algorithms) { algorithm in
                            Text(algorithm.displayName).tag(algorithm.renderID)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(store.status.isRunning || store.hasResumableJob)

                    Text(store.selectedAlgorithm.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioPalette.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Rectangle().fill(StudioPalette.line).frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    RackLabel(number: "02", title: "DELIVERY FORMAT")

                    Picker("Format", selection: $store.outputFormat) {
                        ForEach(MvsepOutputFormat.allCases) { format in
                            Text(format.shortName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(store.status.isRunning || store.hasResumableJob)

                    Text(store.outputFormat.technicalDetail)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(StudioPalette.subtle)
                }

                Rectangle().fill(StudioPalette.line).frame(height: 1)

                VStack(spacing: 10) {
                    Button(action: primaryAction) {
                        HStack {
                            Image(systemName: primaryIcon)
                                .font(.system(size: 13, weight: .bold))
                            Text(primaryTitle)
                                .font(.system(size: 13, weight: .bold))
                            Spacer()
                            Text("⌘↵")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .opacity(store.selectedFile == nil && !store.hasResumableJob ? 0 : 0.55)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(store.status.isRunning)
                    .keyboardShortcut(.return, modifiers: [.command])

                    if store.status.isRunning {
                        Button("Stop tracking") {
                            store.cancelCurrentJob()
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .frame(maxWidth: .infinity)
                    } else if store.hasResumableJob {
                        Button("Forget paused job") {
                            store.forgetPausedJob()
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .frame(maxWidth: .infinity)
                    }

                    if case .complete = store.status {
                        Button("Reveal output folder") {
                            store.revealOutputFolder()
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .frame(maxWidth: .infinity)
                    }
                }

                RecentSessions()
            }
            .padding(20)
        }
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(StudioPalette.line, lineWidth: 1)
        }
        .shadow(color: StudioPalette.shadow, radius: 28, y: 18)
    }

    private var primaryTitle: String {
        if store.status.isRunning { return "Rendering…" }
        if store.hasResumableJob { return "Resume tracking" }
        if store.selectedFile == nil { return "Choose source WAV" }
        if case .complete = store.status { return "Render again" }
        return "Split into stems"
    }

    private var primaryIcon: String {
        if store.hasResumableJob { return "arrow.clockwise" }
        return store.selectedFile == nil ? "waveform.badge.plus" : "bolt.fill"
    }

    private func primaryAction() {
        if store.hasResumableJob {
            store.resumeInterruptedJob()
        } else if store.selectedFile == nil {
            store.chooseFile()
        } else {
            store.splitSelectedFile()
        }
    }
}

private struct RackLabel: View {
    let number: String
    let title: String

    var body: some View {
        HStack(spacing: 7) {
            Text(number)
                .foregroundStyle(StudioPalette.accent)
            Text(title)
                .foregroundStyle(StudioPalette.subtle)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .tracking(1.3)
    }
}

private struct RecentSessions: View {
    @EnvironmentObject private var store: StemPrepStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RackLabel(number: "03", title: "RECENT SESSIONS")

            if store.recentJobs.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(StudioPalette.subtle)
                    Text("Finished renders appear here.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioPalette.muted)
                }
                .padding(.vertical, 3)
            } else {
                ForEach(store.recentJobs.prefix(3)) { job in
                    Button {
                        store.reveal(folder: job.folder)
                    } label: {
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(StudioPalette.accent.opacity(0.14))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(StudioPalette.accent)
                                }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                Text("\(job.stemCount) files · \(job.completedAt, style: .time)")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(StudioPalette.subtle)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct OutputRack: View {
    @EnvironmentObject private var store: StemPrepStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OUTPUT CHANNELS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.7)
                        .foregroundStyle(StudioPalette.muted)
                    Text("Every file returned by the selected model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StudioPalette.subtle)
                }

                Spacer()

                Text(outputCountLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(store.completedStems.isEmpty ? StudioPalette.subtle : StudioPalette.success)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Rectangle().fill(StudioPalette.line).frame(height: 1)

            VStack(spacing: 0) {
                if store.completedStems.isEmpty {
                    ForEach(Array(StemKind.allCases.enumerated()), id: \.element.id) { index, kind in
                        ChannelStrip(index: index, name: kind.displayName, stem: nil)
                        if index < StemKind.allCases.count - 1 {
                            Rectangle().fill(StudioPalette.line).frame(height: 1)
                        }
                    }
                } else {
                    ForEach(Array(store.completedStems.enumerated()), id: \.element.id) { index, stem in
                        ChannelStrip(index: index, name: stem.name, stem: stem)
                        if index < store.completedStems.count - 1 {
                            Rectangle().fill(StudioPalette.line).frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(StudioPalette.line, lineWidth: 1)
        }
        .shadow(color: StudioPalette.shadow, radius: 28, y: 18)
    }

    private var outputCountLabel: String {
        store.completedStems.isEmpty ? "STANDBY" : "\(store.completedStems.count) FILES READY"
    }
}

private struct ChannelStrip: View {
    @EnvironmentObject private var store: StemPrepStore
    let index: Int
    let name: String
    let stem: CompletedStem?

    var body: some View {
        HStack(spacing: 16) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(StudioPalette.subtle)
                .frame(width: 22)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(channelColor.opacity(0.13))
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(channelColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(name.capitalized)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(stem?.url.lastPathComponent ?? "Awaiting render")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioPalette.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 190, alignment: .leading)

            MiniWaveform(color: channelColor, isReady: stem != nil, seed: index)
                .frame(maxWidth: .infinity)
                .frame(height: 34)

            HStack(spacing: 6) {
                Circle()
                    .fill(stem == nil ? StudioPalette.subtle : StudioPalette.success)
                    .frame(width: 6, height: 6)
                Text(stem == nil ? "WAITING" : "READY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(stem == nil ? StudioPalette.subtle : StudioPalette.success)
            }
            .frame(width: 74, alignment: .leading)

            if let stem {
                HStack(spacing: 4) {
                    Button {
                        store.open(stem: stem)
                    } label: {
                        Image(systemName: "play.fill")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(UtilityButtonStyle())
                    .help("Play")

                    Button {
                        store.reveal(stem: stem)
                    } label: {
                        Image(systemName: "folder")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(UtilityButtonStyle())
                    .help("Reveal in Finder")
                }
            } else {
                Color.clear.frame(width: 68, height: 30)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 76)
        .background(Color.white.opacity(stem == nil ? 0 : 0.012))
    }

    private var channelColor: Color {
        let lower = name.lowercased()
        if lower.contains("vocal") || lower.contains("lead") || lower.contains("back") { return StudioPalette.signalCyan }
        if lower.contains("drum") || lower.contains("kick") || lower.contains("snare") || lower.contains("tom") { return StudioPalette.signalCoral }
        if lower.contains("bass") { return StudioPalette.signalAmber }
        return StudioPalette.signalBlue
    }

    private var iconName: String {
        let lower = name.lowercased()
        if lower.contains("vocal") || lower.contains("lead") || lower.contains("back") { return "music.mic" }
        if lower.contains("drum") || lower.contains("kick") || lower.contains("snare") || lower.contains("tom") { return "circle.grid.cross" }
        if lower.contains("bass") { return "speaker.wave.2" }
        if lower.contains("guitar") { return "guitars" }
        if lower.contains("piano") { return "pianokeys" }
        return "square.stack.3d.up"
    }
}

private struct MiniWaveform: View {
    let color: Color
    let isReady: Bool
    let seed: Int

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<38, id: \.self) { index in
                Capsule()
                    .fill(isReady ? color.opacity(0.62) : StudioPalette.subtle.opacity(0.14))
                    .frame(maxWidth: .infinity)
                    .frame(height: height(for: index))
            }
        }
    }

    private func height(for index: Int) -> CGFloat {
        let value = abs(sin(Double(index + seed * 7) * 0.41) * cos(Double(index) * 0.17))
        return 4 + CGFloat(value) * 27
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(StudioPalette.ink)
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(isEnabled ? StudioPalette.accent : StudioPalette.subtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: isEnabled ? StudioPalette.accent.opacity(configuration.isPressed ? 0.10 : 0.22) : .clear, radius: 14, y: 7)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isEnabled ? StudioPalette.text : StudioPalette.subtle)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(configuration.isPressed ? StudioPalette.surfaceRaised : StudioPalette.surfaceSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(StudioPalette.lineStrong, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct UtilityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? StudioPalette.accent : StudioPalette.muted)
            .background(configuration.isPressed ? StudioPalette.surfaceRaised : StudioPalette.surfaceSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(StudioPalette.line, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private enum WorkflowStep: Int, CaseIterable, Identifiable {
    case source
    case engine
    case render
    case collect

    var id: Int { rawValue }
    var index: Int { rawValue }

    var title: String {
        switch self {
        case .source: return "Source"
        case .engine: return "Engine"
        case .render: return "Separate"
        case .collect: return "Collect"
        }
    }

    var icon: String {
        switch self {
        case .source: return "waveform"
        case .engine: return "slider.horizontal.3"
        case .render: return "bolt.fill"
        case .collect: return "folder"
        }
    }
}

private enum WorkflowNodeState {
    case complete
    case active
    case upcoming
}

private enum StudioPalette {
    static let background = Color(red: 0.035, green: 0.040, blue: 0.045)
    static let header = Color(red: 0.045, green: 0.050, blue: 0.056)
    static let surface = Color(red: 0.067, green: 0.074, blue: 0.082)
    static let surfaceSoft = Color(red: 0.091, green: 0.099, blue: 0.108)
    static let surfaceRaised = Color(red: 0.115, green: 0.124, blue: 0.134)
    static let deck = Color(red: 0.046, green: 0.052, blue: 0.058)
    static let line = Color.white.opacity(0.075)
    static let lineStrong = Color.white.opacity(0.12)
    static let text = Color(red: 0.925, green: 0.940, blue: 0.932)
    static let muted = Color(red: 0.605, green: 0.642, blue: 0.628)
    static let subtle = Color(red: 0.355, green: 0.390, blue: 0.382)
    static let accent = Color(red: 1.000, green: 0.315, blue: 0.235)
    static let ink = Color(red: 0.080, green: 0.035, blue: 0.030)
    static let success = Color(red: 0.420, green: 0.880, blue: 0.540)
    static let danger = Color(red: 0.940, green: 0.350, blue: 0.330)
    static let signalCyan = Color(red: 0.280, green: 0.875, blue: 0.850)
    static let signalCoral = Color(red: 0.970, green: 0.390, blue: 0.300)
    static let signalAmber = Color(red: 0.990, green: 0.705, blue: 0.220)
    static let signalBlue = Color(red: 0.285, green: 0.570, blue: 0.990)
    static let shadow = Color(red: 0.010, green: 0.018, blue: 0.022).opacity(0.72)
}
