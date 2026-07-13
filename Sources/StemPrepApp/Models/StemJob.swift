import Foundation

enum MvsepRemoteStage: String, Equatable, Sendable {
    case waiting
    case distributing
    case processing
    case merging
    case reconnecting
    case offline
    case retrying

    var title: String {
        switch self {
        case .waiting: return "Waiting in queue"
        case .distributing: return "Processing large file"
        case .processing: return "Separating audio"
        case .merging: return "Merging sections"
        case .reconnecting: return "Reconnecting to MVSEP"
        case .offline: return "Waiting for connection"
        case .retrying: return "Retrying MVSEP"
        }
    }

    var phaseLabel: String {
        switch self {
        case .waiting: return "QUEUE"
        case .distributing: return "CHUNKS"
        case .processing: return "SEPARATE"
        case .merging: return "MERGE"
        case .reconnecting, .offline, .retrying: return "CONNECT"
        }
    }
}

struct MvsepRemoteProgress: Equatable, Sendable {
    let stage: MvsepRemoteStage
    let message: String?
    let queueCount: Int?
    let currentOrder: Int?
    let finishedChunks: Int?
    let allChunks: Int?

    init(
        stage: MvsepRemoteStage,
        message: String? = nil,
        queueCount: Int? = nil,
        currentOrder: Int? = nil,
        finishedChunks: Int? = nil,
        allChunks: Int? = nil
    ) {
        self.stage = stage
        self.message = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.queueCount = queueCount
        self.currentOrder = currentOrder
        self.finishedChunks = finishedChunks
        self.allChunks = allChunks
    }

    var title: String { stage.title }

    var detail: String {
        if let message, !message.isEmpty {
            return message
        }
        switch stage {
        case .waiting: return "MVSEP will start this render when a worker is ready."
        case .distributing: return "MVSEP split this large file across several workers."
        case .processing: return "MVSEP is separating the selected stems."
        case .merging: return "MVSEP is joining the processed sections."
        case .reconnecting: return "Checking the saved job on its original MVSEP host."
        case .offline: return "StemPrep will continue automatically when the network returns."
        case .retrying: return "The service is temporarily unavailable; StemPrep is retrying."
        }
    }

    var progress: Double? {
        guard
            stage == .distributing,
            let finishedChunks,
            let allChunks,
            allChunks > 0
        else { return nil }
        return min(1, max(0, Double(finishedChunks) / Double(allChunks)))
    }

    var metric: String {
        if let progress {
            return "\(Int((progress * 100).rounded()))%"
        }
        if let currentOrder, let queueCount, queueCount > 0 {
            return "#\(currentOrder) OF \(queueCount)"
        }
        if let currentOrder {
            return "POSITION #\(currentOrder)"
        }
        return "IN PROGRESS"
    }
}

enum StemJobStatus: Equatable {
    case idle
    case ready(URL)
    case checking
    case preparing
    case uploading(Double)
    case queued(MvsepRemoteProgress)
    case processing(MvsepRemoteProgress)
    case downloading(Int, Int)
    case paused(String)
    case complete(URL)
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Drop a WAV to begin"
        case .ready(let url):
            return url.lastPathComponent
        case .checking:
            return "Checking previous renders"
        case .preparing:
            return "Preparing output folder"
        case .uploading(let progress):
            return "Uploading to MVSEP \(Int(progress * 100))%"
        case .queued(let progress), .processing(let progress):
            return progress.title
        case .downloading(let completed, let total):
            return total > 0 ? "Downloading stems \(completed)/\(total)" : "Downloading stems"
        case .paused:
            return "Tracking paused"
        case .complete:
            return "Stems ready"
        case .failed:
            return "Something needs attention"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "Choose an MVSEP model, then drop a WAV."
        case .ready:
            return "Ready to send this track to the selected MVSEP model."
        case .checking:
            return "Fingerprinting the WAV before creating a new MVSEP job."
        case .preparing:
            return "Creating the track folder and copying the original file."
        case .uploading:
            return "Large WAV files can take a little while to upload."
        case .queued(let progress), .processing(let progress):
            return progress.detail
        case .downloading:
            return "Saving each MVSEP file directly into the final stem folder."
        case .paused(let message):
            return message
        case .complete(let folder):
            return folder.path
        case .failed(let message):
            return message
        }
    }

    var isRunning: Bool {
        switch self {
        case .checking, .preparing, .uploading, .queued, .processing, .downloading:
            return true
        default:
            return false
        }
    }

    var progress: Double? {
        switch self {
        case .uploading(let progress):
            return progress
        case .queued(let progress), .processing(let progress):
            return progress.progress
        case .downloading(let completed, let total):
            guard total > 0 else { return nil }
            return Double(completed) / Double(total)
        case .complete:
            return 1
        default:
            return nil
        }
    }

    var phaseLabel: String {
        switch self {
        case .idle: return "SOURCE"
        case .ready: return "READY"
        case .checking: return "CHECK"
        case .preparing: return "PREPARE"
        case .uploading: return "UPLOAD"
        case .queued(let progress), .processing(let progress): return progress.stage.phaseLabel
        case .downloading: return "DOWNLOAD"
        case .paused: return "PAUSED"
        case .complete: return "COMPLETE"
        case .failed: return "ATTENTION"
        }
    }

    var metric: String {
        switch self {
        case .uploading(let progress):
            return "\(Int((min(1, max(0, progress)) * 100).rounded()))%"
        case .queued(let progress), .processing(let progress):
            return progress.metric
        case .downloading(let completed, let total):
            return total > 0 ? "\(completed) OF \(total)" : "STARTING"
        case .complete:
            return "100%"
        case .checking, .preparing:
            return "IN PROGRESS"
        default:
            return "—"
        }
    }

    var usesIndeterminateProgress: Bool {
        isRunning && progress == nil
    }
}

enum StemKind: String, CaseIterable, Identifiable {
    case vocals
    case drums
    case bass
    case other

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }
}

struct MvsepAlgorithm: Identifiable, Codable, Hashable {
    struct Description: Codable, Hashable {
        let shortDescription: String?
        let longDescription: String?
        let lang: String?

        enum CodingKeys: String, CodingKey {
            case shortDescription = "short_description"
            case longDescription = "long_description"
            case lang
        }
    }

    struct Rating: Codable, Hashable {
        let average: String?
        let total: Int?
    }

    struct Field: Codable, Hashable {
        let name: String
        let text: String
        let defaultKey: String?
        let options: String?

        enum CodingKeys: String, CodingKey {
            case name
            case text
            case defaultKey = "default_key"
            case options
        }

        var defaultValue: String? {
            if let defaultKey, !defaultKey.isEmpty {
                return defaultKey
            }

            guard
                let options,
                let data = options.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else {
                return nil
            }

            return decoded.keys.sorted { lhs, rhs in
                (Int(lhs) ?? .max, lhs) < (Int(rhs) ?? .max, rhs)
            }.first
        }

        var choices: [(key: String, label: String)] {
            guard
                let options,
                let data = options.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return [] }

            return decoded.map { ($0.key, $0.value) }.sorted { lhs, rhs in
                let leftNumber = Int(lhs.key)
                let rightNumber = Int(rhs.key)
                if let leftNumber, let rightNumber, leftNumber != rightNumber {
                    return leftNumber < rightNumber
                }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
        }
    }

    struct Group: Codable, Hashable {
        let name: String
    }

    let id: Int
    let name: String
    let renderID: Int
    let orderID: Int
    let isActive: Int
    let audioUploadDisabled: Int
    let orientation: Int?
    let priceCoefficient: Double?
    let usage: Int?
    let rating: Rating?
    let descriptions: [Description]?
    let outputStems: String?
    let algorithmFields: [Field]?
    let algorithmGroup: Group?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case renderID = "render_id"
        case orderID = "order_id"
        case isActive = "is_active"
        case audioUploadDisabled = "audio_upload_disabled"
        case orientation
        case priceCoefficient = "price_coefficient"
        case usage
        case rating
        case descriptions = "algorithm_descriptions"
        case outputStems = "output_stems"
        case algorithmFields = "algorithm_fields"
        case algorithmGroup = "algorithm_group"
    }

    var groupName: String {
        algorithmGroup?.name ?? "MVSEP"
    }

    var displayName: String {
        "\(groupName) - \(name)"
    }

    var defaults: [String: String] {
        Dictionary(uniqueKeysWithValues: (algorithmFields ?? []).compactMap { field in
            guard field.name.hasPrefix("add_opt"), let value = field.defaultValue else {
                return nil
            }
            return (field.name, value)
        })
    }

    var configurableFields: [Field] {
        (algorithmFields ?? [])
            .filter { $0.name.hasPrefix("add_opt") && !$0.choices.isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var availabilityLabel: String {
        switch orientation {
        case 2: return "PREMIUM"
        case 1: return "REGISTERED"
        default: return "ALL USERS"
        }
    }

    var shortDescription: String? {
        let candidate = descriptions?.first { $0.lang?.lowercased() == "en" }
            ?? descriptions?.first
        return candidate?.shortDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var outputStemNames: [String] {
        guard
            let outputStems,
            let data = outputStems.data(using: .utf8),
            let stems = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return stems
    }

    func estimatedCredits(for duration: Double?) -> Int? {
        guard let duration, duration > 0, let priceCoefficient, priceCoefficient > 0 else { return nil }
        return max(1, Int(floor(duration * priceCoefficient / 60)))
    }

    static let fallback = MvsepAlgorithm(
        // `id` is MVSEP's mutable catalogue-row ID. Never use it as the
        // persisted picker value or the submitted separation type.
        id: -28,
        name: "Ensemble (vocals, instrum, bass, drums, other)",
        renderID: 28,
        orderID: 20,
        isActive: 1,
        audioUploadDisabled: 0,
        orientation: 2,
        priceCoefficient: 2,
        usage: nil,
        rating: nil,
        descriptions: nil,
        outputStems: "[\"vocals\",\"instrum\",\"bass\",\"drums\",\"other\"]",
        algorithmFields: [
            Field(name: "add_opt1", text: "Output files", defaultKey: "0", options: nil),
            Field(name: "add_opt2", text: "Model Type", defaultKey: "11", options: nil)
        ],
        algorithmGroup: Group(name: "Best Quality Models")
    )
}

enum MvsepOutputFormat: String, CaseIterable, Identifiable, Codable {
    case wav16 = "1"
    case flac24 = "5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wav16:
            return "WAV 16-bit"
        case .flac24:
            return "FLAC 24-bit"
        }
    }

    var shortName: String {
        switch self {
        case .wav16:
            return "WAV 16"
        case .flac24:
            return "FLAC 24"
        }
    }

    var technicalDetail: String {
        switch self {
        case .wav16:
            return "PCM · 16-BIT · UNIVERSAL"
        case .flac24:
            return "LOSSLESS · 24-BIT · ARCHIVE"
        }
    }
}

struct CompletedStem: Identifiable, Sendable {
    let name: String
    let url: URL

    var id: URL { url }
}

struct AudioFileInfo: Equatable {
    let name: String
    let folder: String
    let fileSize: String
    let duration: String?
    let durationSeconds: Double?
}

struct MvsepAccountSummary: Equatable, Sendable {
    let premiumMinutes: Double
    let premiumEnabled: Bool
    let longFilenamesEnabled: Bool
    let activeSeparations: Int
}

enum MvsepAccountState: Equatable, Sendable {
    case notConfigured
    case checking
    case connected(MvsepAccountSummary)
    case invalid(String)
    case unavailable(String)
}

struct MvsepHistoryAlgorithm: Decodable, Equatable, Sendable {
    struct Group: Decodable, Equatable, Sendable {
        let name: String?
    }

    let name: String?
    let renderID: Int?
    let algorithmGroup: Group?

    enum CodingKeys: String, CodingKey {
        case name
        case renderID = "render_id"
        case algorithmGroup = "algorithm_group"
    }
}

struct MvsepHistoryItem: Identifiable, Decodable, Equatable, Sendable {
    let hash: String
    let createdAt: String?
    let jobExists: Bool
    let credits: Int?
    let timeLeft: Int?
    let algorithm: MvsepHistoryAlgorithm?

    var id: String { hash }

    enum CodingKeys: String, CodingKey {
        case hash
        case createdAt = "created_at"
        case jobExists = "job_exists"
        case credits
        case timeLeft = "time_left"
        case algorithm
    }

    var displayTitle: String {
        let stem = URL(fileURLWithPath: hash).deletingPathExtension().lastPathComponent
        let pieces = stem.split(separator: "-", omittingEmptySubsequences: false)
        if pieces.count > 3,
           pieces[0].count >= 12,
           pieces[0].allSatisfy(\.isNumber) {
            return pieces.dropFirst(3).joined(separator: " ").replacingOccurrences(of: "_", with: " ")
        }
        return algorithm?.name ?? "MVSEP separation"
    }

    var algorithmLabel: String {
        let group = algorithm?.algorithmGroup?.name
        let name = algorithm?.name
        return [group, name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct CreatedSeparation: Equatable, Sendable {
    let hash: String
    let resultURL: URL?
}

struct MvsepCompletionMetadata: Codable, Equatable, Sendable {
    let algorithmName: String?
    let algorithmDescription: String?
    let outputFormat: String?
    let inputFilename: String?
    let processedAt: String?
}

struct MvsepCompletedResult: Equatable, Sendable {
    let files: [RemoteStemFile]
    let metadata: MvsepCompletionMetadata
}

struct RecentStemJob: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let folder: URL
    let stemCount: Int
    let completedAt: Date
}
