import Foundation

enum FileNaming {
    static func safeTrackName(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let scalars = base.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        let collapsed = String(scalars).split(separator: " ").joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? "Track" : trimmed
    }

    static func uniqueFolder(in parent: URL, named name: String) throws -> URL {
        let manager = FileManager.default
        let first = parent.appendingPathComponent(name, isDirectory: true)
        if !manager.fileExists(atPath: first.path) {
            return first
        }

        for index in 2..<1000 {
            let candidate = parent.appendingPathComponent("\(name) \(index)", isDirectory: true)
            if !manager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw StemPrepError.outputFolderUnavailable
    }

    static func stemKind(for filename: String) -> StemKind? {
        let lower = filename.lowercased()
        if lower.contains("vocal") { return .vocals }
        if lower.contains("drum") { return .drums }
        if lower.contains("bass") { return .bass }
        if lower.contains("other") { return .other }
        return nil
    }

    static func stemLabel(for filename: String, fallbackIndex: Int) -> String {
        if let kind = stemKind(for: filename) {
            return kind.rawValue
        }

        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let lower = base.lowercased()
        let knownLabels = [
            "instrumental", "instrum", "piano", "guitar", "strings", "wind",
            "lead", "back", "male", "female", "kick", "snare", "cymbals",
            "toms", "hihat", "speech", "music", "noise"
        ]

        if let known = knownLabels.first(where: { lower.contains($0) }) {
            return known == "instrum" ? "instrumental" : known
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = base.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        let label = String(cleaned)
            .split(separator: " ")
            .suffix(4)
            .joined(separator: "-")
            .lowercased()

        return label.isEmpty ? "stem-\(fallbackIndex)" : label
    }

    static func uniqueStemLabel(_ label: String, usedLabels: inout Set<String>) -> String {
        if usedLabels.insert(label).inserted {
            return label
        }

        for index in 2..<1000 {
            let candidate = "\(label)-\(index)"
            if usedLabels.insert(candidate).inserted {
                return candidate
            }
        }

        return "\(label)-\(UUID().uuidString.prefix(8))"
    }
}

enum StemPrepError: LocalizedError {
    case outputFolderUnavailable
    case unsupportedFile
    case missingToken
    case noJobHash
    case mvsepRejected(String)
    case remoteJobEnded(String)
    case transientService(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .outputFolderUnavailable:
            return "Could not create a unique output folder."
        case .unsupportedFile:
            return "Please drop a WAV file."
        case .missingToken:
            return "Add your MVSEP API token in Settings."
        case .noJobHash:
            return "MVSEP accepted the upload but did not return a job hash."
        case .mvsepRejected(let message):
            return message
        case .remoteJobEnded(let message):
            return message
        case .transientService(let message):
            return message
        case .timeout:
            return "MVSEP did not finish within the timeout window."
        }
    }
}
