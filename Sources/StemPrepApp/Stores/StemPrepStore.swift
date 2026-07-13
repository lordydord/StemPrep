import Foundation
import AppKit
import AVFoundation
import UserNotifications

@MainActor
final class StemPrepStore: ObservableObject {
    @Published var selectedFile: URL?
    @Published var selectedFileInfo: AudioFileInfo?
    @Published var status: StemJobStatus = .idle
    @Published var completedStems: [CompletedStem] = []
    @Published var recentJobs: [RecentStemJob] = []
    @Published var apiToken: String
    @Published var outputFormat: MvsepOutputFormat
    @Published var algorithms: [MvsepAlgorithm] = [.fallback]
    @Published var selectedRenderID: Int
    @Published var algorithmLoadStatus: String?
    @Published var runStartedAt: Date?
    @Published private(set) var resumableJob: ResumableStemJob?

    private let mvsep = MvsepClient()
    private let outputStore = OutputStore()
    private let recoveryStore = StemJobRecoveryStore()
    private let algorithmCache = AlgorithmCatalogueCache()
    private let historyStore = CompletedJobHistoryStore()
    private let keychainStore = KeychainStore()
    private var completedJobRecords: [CompletedJobRecord] = []
    private var activeTask: Task<Void, Never>?
    private var activeTaskID: UUID?
    private var didAttemptRecovery = false

    init() {
        let defaults = UserDefaults.standard
        let keychainStore = KeychainStore()
        var savedToken = keychainStore.load() ?? ""
        if savedToken.isEmpty,
           let legacyToken = defaults.string(forKey: "mvsepApiToken"),
           !legacyToken.isEmpty {
            do {
                try keychainStore.save(legacyToken)
                savedToken = legacyToken
                defaults.removeObject(forKey: "mvsepApiToken")
            } catch {
                // Keep the legacy preference untouched if Keychain is unavailable.
            }
        }
        self.apiToken = savedToken
        let savedFormat = defaults.string(forKey: "mvsepOutputFormat").flatMap(MvsepOutputFormat.init(rawValue:))
        self.outputFormat = savedFormat ?? .wav16
        self.selectedRenderID = defaults.object(forKey: "mvsepRenderID") as? Int ?? MvsepAlgorithm.fallback.renderID

        if let cachedAlgorithms = algorithmCache.load() {
            self.algorithms = cachedAlgorithms
        }
        self.resumableJob = recoveryStore.load()

        var history = historyStore.load()
        history = history
            .filter(\.isAvailable)
            .sorted { $0.completedAt > $1.completedAt }
        self.completedJobRecords = history
        self.recentJobs = Array(history.prefix(8)).map(\.recentJob)
        try? historyStore.save(history)
    }

    var selectedAlgorithm: MvsepAlgorithm {
        algorithms.first { $0.renderID == selectedRenderID } ?? .fallback
    }

    var hasResumableJob: Bool {
        resumableJob != nil
    }

    func refreshPreferences(includeModelSelection: Bool = true) {
        let defaults = UserDefaults.standard
        apiToken = keychainStore.load() ?? ""

        if let savedFormat = defaults.string(forKey: "mvsepOutputFormat").flatMap(MvsepOutputFormat.init(rawValue:)) {
            outputFormat = savedFormat
        }

        if includeModelSelection,
           let savedRenderID = defaults.object(forKey: "mvsepRenderID") as? Int {
            selectedRenderID = savedRenderID
        }
    }

    func saveAPIToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychainStore.delete()
        } else {
            try keychainStore.save(trimmed)
        }
        UserDefaults.standard.removeObject(forKey: "mvsepApiToken")
        apiToken = trimmed
    }

    func loadAlgorithms() {
        algorithmLoadStatus = "Refreshing MVSEP models"
        Task { [weak self] in
            guard let self else { return }
            defer { algorithmLoadStatus = nil }

            do {
                let fetched = try await mvsep.fetchAlgorithms()
                guard !fetched.isEmpty else { return }
                algorithms = fetched
                try? algorithmCache.save(fetched)
                if !algorithms.contains(where: { $0.renderID == self.selectedRenderID }) {
                    selectedRenderID = algorithms.first { $0.renderID == MvsepAlgorithm.fallback.renderID }?.renderID
                        ?? algorithms[0].renderID
                }
            } catch {
                // The cached catalogue is already visible. If no cache exists,
                // the built-in ensemble model remains available.
            }
        }
    }

    func recoverInterruptedJobIfNeeded() {
        guard !didAttemptRecovery else { return }
        didAttemptRecovery = true
        guard let job = resumableJob else { return }

        hydrate(job)
        if job.isPaused {
            status = .paused("The MVSEP job is saved locally and ready to resume.")
        } else {
            resumeInterruptedJob()
        }
    }

    func select(file url: URL) {
        guard url.pathExtension.lowercased() == "wav" else {
            status = .failed(StemPrepError.unsupportedFile.localizedDescription)
            return
        }
        selectedFile = url
        selectedFileInfo = makeFileInfo(for: url, duration: nil)
        loadDuration(for: url)
        completedStems = []
        status = .ready(url)
    }

    func splitSelectedFile() {
        guard activeTask == nil else { return }
        if hasResumableJob {
            resumeInterruptedJob()
            return
        }

        // Refresh credentials and format without replacing the model currently
        // shown in the picker with an older saved selection.
        refreshPreferences(includeModelSelection: false)
        guard let source = selectedFile else { return }
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            status = .failed(StemPrepError.missingToken.localizedDescription)
            return
        }

        UserDefaults.standard.set(outputFormat.rawValue, forKey: "mvsepOutputFormat")
        UserDefaults.standard.set(selectedRenderID, forKey: "mvsepRenderID")
        completedStems = []
        runStartedAt = Date()
        let algorithm = selectedAlgorithm
        let selectedFormat = outputFormat
        let startedAt = runStartedAt ?? Date()

        startTrackedTask { [weak self] in
            guard let self else { return }
            do {
                status = .checking
                let sourceFingerprint = try await AudioFingerprint.sha256(of: source)
                let separationKey = AudioFingerprint.separationKey(
                    sourceFingerprint: sourceFingerprint,
                    renderID: algorithm.renderID,
                    outputFormat: selectedFormat
                )
                if restoreExistingResult(for: separationKey) {
                    return
                }

                status = .preparing
                let folder = try outputStore.prepareFolder(for: source)
                let sourceName = FileNaming.safeTrackName(from: source)

                status = .uploading(0)
                let hash = try await mvsep.createSeparation(
                    audioURL: source,
                    apiToken: token,
                    algorithm: algorithm,
                    outputFormat: selectedFormat
                ) { [weak self] progress in
                    self?.status = .uploading(progress)
                }

                let job = ResumableStemJob(
                    jobHash: hash,
                    sourcePath: source.path,
                    folderPath: folder.path,
                    sourceName: sourceName,
                    algorithm: algorithm,
                    outputFormat: selectedFormat,
                    startedAt: startedAt,
                    sourceFingerprint: sourceFingerprint,
                    separationKey: separationKey,
                    isPaused: Task.isCancelled
                )
                saveResumableJob(job)
                if Task.isCancelled {
                    status = .paused("Tracking stopped locally. The accepted MVSEP job can be resumed without uploading again.")
                    return
                }
                try await finish(job)
            } catch {
                handleJobError(error)
            }
        }
    }

    func resumeInterruptedJob() {
        guard activeTask == nil, var job = resumableJob else { return }
        job.isPaused = false
        saveResumableJob(job)
        hydrate(job)
        runStartedAt = job.startedAt
        status = .queued("Reconnecting to MVSEP")

        startTrackedTask { [weak self] in
            guard let self else { return }
            do {
                try await finish(job)
            } catch {
                handleJobError(error)
            }
        }
    }

    func cancelCurrentJob() {
        guard let task = activeTask else { return }
        activeTask = nil
        activeTaskID = nil
        task.cancel()
        runStartedAt = nil

        if var job = resumableJob {
            job.isPaused = true
            saveResumableJob(job)
            status = .paused("Tracking stopped locally. The MVSEP job can be resumed without uploading again.")
        } else if let source = selectedFile {
            status = .ready(source)
        } else {
            status = .idle
        }
    }

    func forgetPausedJob() {
        guard activeTask == nil, resumableJob != nil else { return }
        clearResumableJob()
        runStartedAt = nil
        if let source = selectedFile {
            status = .ready(source)
        } else {
            status = .idle
        }
    }

    func chooseFile() {
        guard !status.isRunning, !hasResumableJob else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.select(file: url)
            }
        }
    }

    func revealOutputFolder() {
        guard case .complete(let url) = status else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func reveal(folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func reveal(stem: CompletedStem) {
        NSWorkspace.shared.activateFileViewerSelecting([stem.url])
    }

    func open(stem: CompletedStem) {
        NSWorkspace.shared.open(stem.url)
    }

    private func startTrackedTask(operation: @escaping @MainActor () async -> Void) {
        let taskID = UUID()
        activeTaskID = taskID
        activeTask = Task { [weak self] in
            await operation()
            guard let self, activeTaskID == taskID else { return }
            activeTask = nil
            activeTaskID = nil
        }
    }

    private func finish(_ job: ResumableStemJob) async throws {
        let files = try await mvsep.pollResult(jobHash: job.jobHash) { [weak self] nextStatus in
            self?.status = nextStatus
        }
        try Task.checkCancellation()

        status = .downloading(0, files.count)
        let stems = try await mvsep.download(
            remoteFiles: files,
            to: job.folderURL,
            sourceName: job.sourceName,
            maxConcurrent: 3
        ) { [weak self] completed, total in
            self?.status = .downloading(completed, total)
        }

        let sourceFingerprint: String?
        if let existingFingerprint = job.sourceFingerprint {
            sourceFingerprint = existingFingerprint
        } else {
            sourceFingerprint = try? await AudioFingerprint.sha256(of: job.sourceURL)
        }
        let separationKey = job.separationKey
            ?? sourceFingerprint.map {
                AudioFingerprint.separationKey(
                    sourceFingerprint: $0,
                    renderID: job.algorithm.renderID,
                    outputFormat: job.outputFormat
                )
            }

        try outputStore.writeManifest(
            to: job.folderURL,
            source: job.sourceURL,
            jobHash: job.jobHash,
            algorithm: job.algorithm,
            outputFormat: job.outputFormat,
            sourceFingerprint: sourceFingerprint,
            separationKey: separationKey,
            stems: stems
        )
        completedStems = stems
        status = .complete(job.folderURL)
        runStartedAt = nil
        recordCompletedJob(
            source: job.sourceURL,
            folder: job.folderURL,
            algorithm: job.algorithm,
            outputFormat: job.outputFormat,
            sourceFingerprint: sourceFingerprint,
            separationKey: separationKey,
            stems: stems,
            jobHash: job.jobHash
        )
        clearResumableJob()
        CompletionNotifier.notify(folder: job.folderURL, stemCount: stems.count)
    }

    private func handleJobError(_ error: Error) {
        guard !Task.isCancelled else { return }
        runStartedAt = nil

        if case .remoteJobEnded = error as? StemPrepError {
            clearResumableJob()
        }
        status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func saveResumableJob(_ job: ResumableStemJob) {
        resumableJob = job
        recoveryStore.save(job)
    }

    private func clearResumableJob() {
        resumableJob = nil
        recoveryStore.clear()
    }

    private func hydrate(_ job: ResumableStemJob) {
        selectedFile = job.sourceURL
        selectedFileInfo = makeFileInfo(for: job.sourceURL, duration: nil)
        selectedRenderID = job.algorithm.renderID
        outputFormat = job.outputFormat
        completedStems = []
        loadDuration(for: job.sourceURL)
    }

    private func restoreExistingResult(for separationKey: String) -> Bool {
        guard
            let record = completedJobRecords.first(where: { $0.separationKey == separationKey }),
            record.isAvailable
        else {
            return false
        }

        completedStems = record.completedStems
        status = .complete(record.folderURL)
        runStartedAt = nil
        completedJobRecords.removeAll { $0.id == record.id }
        completedJobRecords.insert(record, at: 0)
        recentJobs = Array(completedJobRecords.prefix(8)).map(\.recentJob)
        try? historyStore.save(completedJobRecords)
        return true
    }

    private func recordCompletedJob(
        source: URL,
        folder: URL,
        algorithm: MvsepAlgorithm,
        outputFormat: MvsepOutputFormat,
        sourceFingerprint: String?,
        separationKey: String?,
        stems: [CompletedStem],
        jobHash: String
    ) {
        let record = CompletedJobRecord(
            id: separationKey ?? AudioFingerprint.stableIdentifier(for: jobHash),
            separationKey: separationKey,
            sourceFingerprint: sourceFingerprint,
            sourcePath: source.path,
            folderPath: folder.path,
            title: FileNaming.safeTrackName(from: source),
            detail: "\(algorithm.groupName) - \(stems.count) file\(stems.count == 1 ? "" : "s")",
            renderID: algorithm.renderID,
            outputFormat: outputFormat,
            stems: stems.map { PersistedStem(name: $0.name, path: $0.url.path) },
            completedAt: Date()
        )
        completedJobRecords.removeAll { $0.id == record.id }
        completedJobRecords.insert(record, at: 0)
        completedJobRecords = Array(completedJobRecords.prefix(100))
        recentJobs = Array(completedJobRecords.prefix(8)).map(\.recentJob)
        try? historyStore.save(completedJobRecords)
    }

    private func loadDuration(for url: URL) {
        Task {
            let asset = AVURLAsset(url: url)
            guard
                let duration = try? await asset.load(.duration),
                selectedFile == url
            else { return }

            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite && seconds > 0 else { return }
            selectedFileInfo = makeFileInfo(for: url, duration: Self.formatDuration(seconds))
        }
    }

    private func makeFileInfo(for url: URL, duration: String?) -> AudioFileInfo {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values?.fileSize.map { size in
            ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } ?? "WAV"

        return AudioFileInfo(
            name: url.lastPathComponent,
            folder: url.deletingLastPathComponent().path,
            fileSize: fileSize,
            duration: duration
        )
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        let minutes = rounded / 60
        let secondsPart = rounded % 60
        return "\(minutes):\(String(format: "%02d", secondsPart))"
    }
}

enum CompletionNotifier {
    static func notify(folder: URL, stemCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Stem Prep complete"
        content.body = "\(stemCount) MVSEP file\(stemCount == 1 ? "" : "s") ready in \(folder.lastPathComponent)."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "stem-prep-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
