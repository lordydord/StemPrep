import Foundation

enum StemJobStatus: Equatable {
    case idle
    case ready(URL)
    case checking
    case preparing
    case uploading(Double)
    case queued(String)
    case processing(String)
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
        case .queued(let detail):
            return detail
        case .processing(let detail):
            return detail
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
        case .queued(let detail), .processing(let detail):
            return detail
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
        case .downloading(let completed, let total):
            guard total > 0 else { return nil }
            return Double(completed) / Double(total)
        default:
            return nil
        }
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
    let algorithmFields: [Field]?
    let algorithmGroup: Group?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case renderID = "render_id"
        case orderID = "order_id"
        case isActive = "is_active"
        case audioUploadDisabled = "audio_upload_disabled"
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

    static let fallback = MvsepAlgorithm(
        // `id` is MVSEP's mutable catalogue-row ID. Never use it as the
        // persisted picker value or the submitted separation type.
        id: -28,
        name: "Ensemble (vocals, instrum, bass, drums, other)",
        renderID: 28,
        orderID: 20,
        isActive: 1,
        audioUploadDisabled: 0,
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
}

struct RecentStemJob: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let folder: URL
    let stemCount: Int
    let completedAt: Date
}
