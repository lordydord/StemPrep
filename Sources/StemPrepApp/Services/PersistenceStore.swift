import Foundation

struct ResumableStemJob: Codable, Equatable {
    let jobHash: String
    let sourcePath: String
    let folderPath: String
    let sourceName: String
    let algorithm: MvsepAlgorithm
    let outputFormat: MvsepOutputFormat
    let startedAt: Date
    let sourceFingerprint: String?
    let separationKey: String?
    var isPaused: Bool

    var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    var folderURL: URL {
        URL(fileURLWithPath: folderPath, isDirectory: true)
    }
}

struct PersistedStem: Codable, Equatable {
    let name: String
    let path: String

    var completedStem: CompletedStem {
        CompletedStem(name: name, url: URL(fileURLWithPath: path))
    }
}

struct CompletedJobRecord: Codable, Equatable, Identifiable {
    let id: String
    let separationKey: String?
    let sourceFingerprint: String?
    let sourcePath: String
    let folderPath: String
    let title: String
    let detail: String
    let renderID: Int?
    let outputFormat: MvsepOutputFormat?
    let stems: [PersistedStem]
    let completedAt: Date

    var folderURL: URL {
        URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    var completedStems: [CompletedStem] {
        stems.map(\.completedStem)
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: folderPath)
            && !stems.isEmpty
            && stems.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    var recentJob: RecentStemJob {
        RecentStemJob(
            title: title,
            detail: detail,
            folder: folderURL,
            stemCount: stems.count,
            completedAt: completedAt
        )
    }
}

struct StemJobRecoveryStore {
    private let defaults: UserDefaults
    private let key = "activeMvsepStemJob"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ResumableStemJob? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ResumableStemJob.self, from: data)
    }

    func save(_ job: ResumableStemJob) {
        guard let data = try? JSONEncoder().encode(job) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

struct AlgorithmCatalogueCache {
    private struct Envelope: Codable {
        let savedAt: Date
        let algorithms: [MvsepAlgorithm]
    }

    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.fileURL = cacheRoot
            .appendingPathComponent(AppIdentity.cacheDirectoryName, isDirectory: true)
            .appendingPathComponent("mvsep-algorithms.json", isDirectory: false)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> [MvsepAlgorithm]? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            !envelope.algorithms.isEmpty
        else {
            return nil
        }
        return envelope.algorithms
    }

    func save(_ algorithms: [MvsepAlgorithm]) throws {
        guard !algorithms.isEmpty else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Envelope(savedAt: Date(), algorithms: algorithms))
        try data.write(to: fileURL, options: .atomic)
    }
}

struct CompletedJobHistoryStore {
    private struct Envelope: Codable {
        let jobs: [CompletedJobRecord]
    }

    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.fileURL = applicationSupport
            .appendingPathComponent("StemPrep", isDirectory: true)
            .appendingPathComponent("completed-jobs.json", isDirectory: false)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> [CompletedJobRecord] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else {
            return []
        }
        return envelope.jobs
    }

    func save(_ jobs: [CompletedJobRecord]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Envelope(jobs: Array(jobs.prefix(100))))
        try data.write(to: fileURL, options: .atomic)
    }

    func importedManifests(below root: URL) -> [CompletedJobRecord] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var records: [CompletedJobRecord] = []
        for case let url as URL in enumerator where url.lastPathComponent == "stem-split-manifest.json" {
            if let record = Self.record(fromManifest: url) {
                records.append(record)
            }
        }
        return records
    }

    private static func record(fromManifest url: URL) -> CompletedJobRecord? {
        guard
            let data = try? Data(contentsOf: url),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sourcePath = payload["source"] as? String,
            let stemMap = payload["stems"] as? [String: String],
            !stemMap.isEmpty
        else {
            return nil
        }

        let folder = url.deletingLastPathComponent()
        let algorithm = payload["mvsep_algorithm"] as? [String: Any]
        let renderID = algorithm?["sep_type"] as? Int
        let group = algorithm?["group"] as? String ?? "MVSEP"
        let name = algorithm?["name"] as? String ?? "Recovered manifest"
        let format = (payload["output_format"] as? String).flatMap(MvsepOutputFormat.init(rawValue:))
        let sourceFingerprint = payload["source_fingerprint"] as? String
        let separationKey = payload["separation_key"] as? String
        let date = (payload["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date.distantPast
        let title = FileNaming.safeTrackName(from: URL(fileURLWithPath: sourcePath))
        let stems = stemMap
            .map { PersistedStem(name: $0.key, path: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let identifier = separationKey
            ?? AudioFingerprint.stableIdentifier(for: url.path)

        return CompletedJobRecord(
            id: identifier,
            separationKey: separationKey,
            sourceFingerprint: sourceFingerprint,
            sourcePath: sourcePath,
            folderPath: folder.path,
            title: title,
            detail: "\(group) - \(name)",
            renderID: renderID,
            outputFormat: format,
            stems: stems,
            completedAt: date
        )
    }
}
