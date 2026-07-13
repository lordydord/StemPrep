import Foundation
import CryptoKit

enum AudioFingerprint {
    static func sha256(of fileURL: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var hasher = SHA256()

            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: 2 * 1024 * 1024), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }

            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    static func separationKey(
        sourceFingerprint: String,
        renderID: Int,
        outputFormat: MvsepOutputFormat,
        algorithmOptions: [String: String] = [:]
    ) -> String {
        let optionsIdentity = algorithmOptions.keys.sorted().map { key in
            "\(key)=\(algorithmOptions[key] ?? "")"
        }.joined(separator: "&")
        let baseIdentity = "\(sourceFingerprint)|\(renderID)|\(outputFormat.rawValue)"
        let identity = optionsIdentity.isEmpty ? baseIdentity : "\(baseIdentity)|\(optionsIdentity)"
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func stableIdentifier(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
