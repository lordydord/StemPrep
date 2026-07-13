import Foundation
import Darwin

struct OutputStore {
    let root: URL

    init(root: URL = FileManager.default.temporaryDirectory) {
        self.root = root
    }

    func prepareFolder(for source: URL) throws -> URL {
        let manager = FileManager.default
        let parent = source.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = try FileNaming.uniqueFolder(in: parent, named: "\(FileNaming.safeTrackName(from: source)) Stems")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let original = folder.appendingPathComponent("original").appendingPathExtension(source.pathExtension)
        try Self.cloneOrCopy(from: source, to: original)

        return folder
    }

    func writeManifest(
        to folder: URL,
        source: URL,
        jobHash: String,
        algorithm: MvsepAlgorithm,
        outputFormat: MvsepOutputFormat,
        sourceFingerprint: String?,
        separationKey: String?,
        stems: [CompletedStem]
    ) throws {
        let payload: [String: Any] = [
            "source": source.path,
            "job_hash": jobHash,
            "output_format": outputFormat.rawValue,
            "source_fingerprint": sourceFingerprint ?? NSNull(),
            "separation_key": separationKey ?? NSNull(),
            "mvsep_algorithm": [
                "id": algorithm.id,
                "sep_type": algorithm.renderID,
                "name": algorithm.name,
                "group": algorithm.groupName,
                "defaults": algorithm.defaults
            ],
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "stems": Dictionary(uniqueKeysWithValues: stems.map { ($0.name, $0.url.path) })
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("stem-split-manifest.json"))
    }

    static func cloneOrCopy(from source: URL, to destination: URL) throws {
        let cloneResult = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                clonefile(sourcePath, destinationPath, 0)
            }
        }
        if cloneResult != 0 {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }
}
