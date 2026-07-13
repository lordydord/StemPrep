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

    func prepareRemoteFolder(in parent: URL, named trackName: String) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let safeName = FileNaming.sanitizedComponent(trackName, fallback: "Recovered MVSEP Render")
        let folder = try FileNaming.uniqueFolder(in: parent, named: "\(safeName) Stems")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
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
        stems: [CompletedStem],
        algorithmOptions: [String: String] = [:],
        serverMetadata: MvsepCompletionMetadata? = nil
    ) throws {
        var algorithmPayload: [String: Any] = [
            "id": algorithm.id,
            "sep_type": algorithm.renderID,
            "name": algorithm.name,
            "group": algorithm.groupName,
            "defaults": algorithm.defaults,
            "submitted_options": algorithmOptions
        ]
        if let serverMetadata {
            algorithmPayload["server_confirmed_name"] = serverMetadata.algorithmName ?? NSNull()
            algorithmPayload["server_description"] = serverMetadata.algorithmDescription ?? NSNull()
        }

        var payload: [String: Any] = [
            "source": source.path,
            "job_hash": jobHash,
            "output_format": outputFormat.rawValue,
            "source_fingerprint": sourceFingerprint ?? NSNull(),
            "separation_key": separationKey ?? NSNull(),
            "mvsep_algorithm": algorithmPayload,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "stems": Dictionary(uniqueKeysWithValues: stems.map { ($0.name, $0.url.path) })
        ]
        if let serverMetadata {
            payload["mvsep_result"] = [
                "algorithm": Self.jsonValue(serverMetadata.algorithmName),
                "algorithm_description": Self.jsonValue(serverMetadata.algorithmDescription),
                "output_format": Self.jsonValue(serverMetadata.outputFormat),
                "input_filename": Self.jsonValue(serverMetadata.inputFilename),
                "processed_at": Self.jsonValue(serverMetadata.processedAt)
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("stem-split-manifest.json"))
    }

    func writeRemoteManifest(
        to folder: URL,
        jobHash: String,
        historyItem: MvsepHistoryItem,
        serverMetadata: MvsepCompletionMetadata,
        stems: [CompletedStem]
    ) throws {
        let algorithmPayload: [String: Any] = [
            "sep_type": Self.jsonValue(historyItem.algorithm?.renderID),
            "name": Self.jsonValue(historyItem.algorithm?.name ?? serverMetadata.algorithmName),
            "group": Self.jsonValue(historyItem.algorithm?.algorithmGroup?.name)
        ]
        let resultPayload: [String: Any] = [
            "algorithm": Self.jsonValue(serverMetadata.algorithmName),
            "algorithm_description": Self.jsonValue(serverMetadata.algorithmDescription),
            "output_format": Self.jsonValue(serverMetadata.outputFormat),
            "input_filename": Self.jsonValue(serverMetadata.inputFilename),
            "processed_at": Self.jsonValue(serverMetadata.processedAt)
        ]
        let payload: [String: Any] = [
            "source": NSNull(),
            "job_hash": jobHash,
            "recovered_from_mvsep_history": true,
            "mvsep_algorithm": algorithmPayload,
            "mvsep_result": resultPayload,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "stems": Dictionary(uniqueKeysWithValues: stems.map { ($0.name, $0.url.path) })
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("stem-split-manifest.json"))
    }

    private static func jsonValue(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private static func jsonValue(_ value: Int?) -> Any {
        if let value { return value }
        return NSNull()
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
