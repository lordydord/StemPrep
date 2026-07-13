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
    @Published private(set) var algorithmOptions: [String: String] = [:]
    @Published var algorithmLoadStatus: String?
    @Published private(set) var accountState: MvsepAccountState = .notConfigured
    @Published private(set) var remoteHistory: [MvsepHistoryItem] = []
    @Published private(set) var remoteHistoryLoadStatus: String?
    @Published private(set) var isCancellingRemoteJob = false
    @Published var remoteActionError: String?
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
        synchronizeAlgorithmOptions()
    }

    var selectedAlgorithm: MvsepAlgorithm {
        algorithms.first { $0.renderID == selectedRenderID } ?? .fallback
    }

    var hasResumableJob: Bool {
        resumableJob != nil
    }

    var effectiveAlgorithmOptions: [String: String] {
        var values = selectedAlgorithm.defaults
        values.merge(algorithmOptions) { _, selected in selected }
        return values
    }

    var estimatedCredits: Int? {
        selectedAlgorithm.estimatedCredits(for: selectedFileInfo?.durationSeconds)
    }

    var canCancelRemoteJob: Bool {
        guard !isCancellingRemoteJob, resumableJob != nil else { return false }
        guard case .queued(let progress) = status else { return false }
        return progress.stage == .waiting
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
        refreshMVSEPData()
    }

    func refreshMVSEPData() {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            accountState = .notConfigured
            remoteHistory = []
            remoteHistoryLoadStatus = nil
            return
        }

        accountState = .checking
        remoteHistoryLoadStatus = "SYNCING"
        Task { [weak self] in
            guard let self else { return }

            do {
                let account = try await mvsep.fetchAccount(apiToken: token)
                guard apiToken == token else { return }
                accountState = .connected(account)
            } catch {
                guard apiToken == token else { return }
                if case .mvsepRejected = error as? StemPrepError {
                    accountState = .invalid("Check the saved MVSEP token.")
                } else {
                    accountState = .unavailable("MVSEP account data is temporarily unavailable.")
                }
            }

            do {
                let history = try await mvsep.fetchSeparationHistory(apiToken: token, limit: 10)
                guard apiToken == token else { return }
                remoteHistory = history
                remoteHistoryLoadStatus = nil
            } catch {
                guard apiToken == token else { return }
                remoteHistoryLoadStatus = "UNAVAILABLE"
            }
        }
    }

    func modelSelectionDidChange() {
        UserDefaults.standard.set(selectedRenderID, forKey: "mvsepRenderID")
        synchronizeAlgorithmOptions()
    }

    func algorithmOptionValue(for field: MvsepAlgorithm.Field) -> String {
        algorithmOptions[field.name] ?? field.defaultValue ?? field.choices.first?.key ?? ""
    }

    func setAlgorithmOption(_ value: String, for field: MvsepAlgorithm.Field) {
        guard field.choices.contains(where: { $0.key == value }) else { return }
        algorithmOptions[field.name] = value
        UserDefaults.standard.set(
            algorithmOptions,
            forKey: "mvsepAlgorithmOptions.\(selectedRenderID)"
        )
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
                synchronizeAlgorithmOptions()
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
        let submittedOptions = effectiveAlgorithmOptions
        let startedAt = runStartedAt ?? Date()

        startTrackedTask { [weak self] in
            guard let self else { return }
            do {
                status = .checking
                let sourceFingerprint = try await AudioFingerprint.sha256(of: source)
                let separationKey = AudioFingerprint.separationKey(
                    sourceFingerprint: sourceFingerprint,
                    renderID: algorithm.renderID,
                    outputFormat: selectedFormat,
                    algorithmOptions: submittedOptions == algorithm.defaults ? [:] : submittedOptions
                )
                if restoreExistingResult(for: separationKey) {
                    return
                }

                status = .preparing
                let folder = try outputStore.prepareFolder(for: source)
                let sourceName = FileNaming.safeTrackName(from: source)

                status = .uploading(0)
                let created = try await mvsep.createSeparation(
                    audioURL: source,
                    apiToken: token,
                    algorithm: algorithm,
                    outputFormat: selectedFormat,
                    algorithmOptions: submittedOptions
                ) { [weak self] progress in
                    self?.status = .uploading(progress)
                }

                let job = ResumableStemJob(
                    jobHash: created.hash,
                    resultURL: created.resultURL,
                    sourcePath: source.path,
                    folderPath: folder.path,
                    sourceName: sourceName,
                    algorithm: algorithm,
                    outputFormat: selectedFormat,
                    algorithmOptions: submittedOptions,
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
        status = .queued(MvsepRemoteProgress(stage: .reconnecting))

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

    func cancelRemoteJob() {
        guard canCancelRemoteJob, let job = resumableJob else { return }
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            remoteActionError = StemPrepError.missingToken.localizedDescription
            return
        }

        isCancellingRemoteJob = true
        remoteActionError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await mvsep.cancelSeparation(
                    jobHash: job.jobHash,
                    apiToken: token,
                    resultURL: job.resultURL
                )
                activeTask?.cancel()
                activeTask = nil
                activeTaskID = nil
                clearResumableJob()
                runStartedAt = nil
                status = selectedFile.map(StemJobStatus.ready) ?? .idle
                isCancellingRemoteJob = false
                refreshMVSEPData()
            } catch {
                isCancellingRemoteJob = false
                remoteActionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
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

    func chooseDestinationForRemoteHistory(_ item: MvsepHistoryItem) {
        guard item.jobExists, activeTask == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose where to save the recovered stems"
        panel.prompt = "Save here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                self?.downloadRemoteHistory(item, to: destination)
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

    private func downloadRemoteHistory(_ item: MvsepHistoryItem, to parent: URL) {
        guard activeTask == nil else { return }
        completedStems = []
        runStartedAt = Date()
        status = .processing(MvsepRemoteProgress(
            stage: .reconnecting,
            message: "Retrieving this saved render from MVSEP."
        ))

        startTrackedTask { [weak self] in
            guard let self else { return }
            do {
                let result = try await mvsep.pollResult(jobHash: item.hash) { [weak self] nextStatus in
                    self?.status = nextStatus
                }
                guard !result.files.isEmpty else {
                    throw StemPrepError.remoteJobEnded("MVSEP returned no downloadable files for this render.")
                }

                let sourceName = FileNaming.sanitizedComponent(item.displayTitle, fallback: "Recovered MVSEP Render")
                let folder = try outputStore.prepareRemoteFolder(in: parent, named: sourceName)
                status = .downloading(0, result.files.count)
                let stems = try await mvsep.download(
                    remoteFiles: result.files,
                    to: folder,
                    sourceName: sourceName,
                    maxConcurrent: 3
                ) { [weak self] completed, total in
                    self?.status = .downloading(completed, total)
                }
                try outputStore.writeRemoteManifest(
                    to: folder,
                    jobHash: item.hash,
                    historyItem: item,
                    serverMetadata: result.metadata,
                    stems: stems
                )
                completedStems = stems
                status = .complete(folder)
                runStartedAt = nil
                recordRecoveredRemoteJob(
                    item: item,
                    folder: folder,
                    stems: stems,
                    metadata: result.metadata
                )
                CompletionNotifier.notify(folder: folder, stemCount: stems.count)
                refreshMVSEPData()
            } catch {
                handleJobError(error)
            }
        }
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
        let result = try await mvsep.pollResult(
            jobHash: job.jobHash,
            resultURL: job.resultURL
        ) { [weak self] nextStatus in
            self?.status = nextStatus
        }
        try Task.checkCancellation()

        status = .downloading(0, result.files.count)
        let stems = try await mvsep.download(
            remoteFiles: result.files,
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
                    outputFormat: job.outputFormat,
                    algorithmOptions: (job.algorithmOptions ?? job.algorithm.defaults) == job.algorithm.defaults
                        ? [:]
                        : (job.algorithmOptions ?? [:])
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
            stems: stems,
            algorithmOptions: job.algorithmOptions ?? job.algorithm.defaults,
            serverMetadata: result.metadata
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
            jobHash: job.jobHash,
            serverMetadata: result.metadata
        )
        clearResumableJob()
        CompletionNotifier.notify(folder: job.folderURL, stemCount: stems.count)
        refreshMVSEPData()
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
        algorithmOptions = job.algorithmOptions ?? job.algorithm.defaults
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
        jobHash: String,
        serverMetadata: MvsepCompletionMetadata?
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
            jobHash: jobHash,
            serverMetadata: serverMetadata,
            stems: stems.map { PersistedStem(name: $0.name, path: $0.url.path) },
            completedAt: Date()
        )
        completedJobRecords.removeAll { $0.id == record.id }
        completedJobRecords.insert(record, at: 0)
        completedJobRecords = Array(completedJobRecords.prefix(100))
        recentJobs = Array(completedJobRecords.prefix(8)).map(\.recentJob)
        try? historyStore.save(completedJobRecords)
    }

    private func recordRecoveredRemoteJob(
        item: MvsepHistoryItem,
        folder: URL,
        stems: [CompletedStem],
        metadata: MvsepCompletionMetadata
    ) {
        let record = CompletedJobRecord(
            id: AudioFingerprint.stableIdentifier(for: item.hash),
            separationKey: nil,
            sourceFingerprint: nil,
            sourcePath: "",
            folderPath: folder.path,
            title: item.displayTitle,
            detail: "MVSEP history - \(stems.count) file\(stems.count == 1 ? "" : "s")",
            renderID: item.algorithm?.renderID,
            outputFormat: nil,
            jobHash: item.hash,
            serverMetadata: metadata,
            stems: stems.map { PersistedStem(name: $0.name, path: $0.url.path) },
            completedAt: Date()
        )
        completedJobRecords.removeAll { $0.id == record.id }
        completedJobRecords.insert(record, at: 0)
        completedJobRecords = Array(completedJobRecords.prefix(100))
        recentJobs = Array(completedJobRecords.prefix(8)).map(\.recentJob)
        try? historyStore.save(completedJobRecords)
    }

    private func synchronizeAlgorithmOptions() {
        let algorithm = selectedAlgorithm
        let saved = UserDefaults.standard.dictionary(
            forKey: "mvsepAlgorithmOptions.\(algorithm.renderID)"
        ) as? [String: String]
        var values = algorithm.defaults
        for field in algorithm.configurableFields {
            if let savedValue = saved?[field.name],
               field.choices.contains(where: { $0.key == savedValue }) {
                values[field.name] = savedValue
            } else if let defaultValue = field.defaultValue {
                values[field.name] = defaultValue
            }
        }
        algorithmOptions = values
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
            selectedFileInfo = makeFileInfo(
                for: url,
                duration: Self.formatDuration(seconds),
                durationSeconds: seconds
            )
        }
    }

    private func makeFileInfo(
        for url: URL,
        duration: String?,
        durationSeconds: Double? = nil
    ) -> AudioFileInfo {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values?.fileSize.map { size in
            ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } ?? "WAV"

        return AudioFileInfo(
            name: url.lastPathComponent,
            folder: url.deletingLastPathComponent().path,
            fileSize: fileSize,
            duration: duration,
            durationSeconds: durationSeconds
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
