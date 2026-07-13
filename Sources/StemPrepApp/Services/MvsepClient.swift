import Foundation

struct MvsepClient {
    private let algorithmsURL = URL(string: "https://mvsep.com/api/app/algorithms")!
    private let createURL = URL(string: "https://mvsep.com/api/separation/create")!
    private let resultURL = URL(string: "https://mvsep.com/api/separation/get")!
    private let session: URLSession
    private let uploadConfiguration: URLSessionConfiguration
    private let downloadTransport: any DownloadTransport
    private let networkAvailability: any NetworkAvailabilityProviding
    private let pollingPolicy: PollingPolicy

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 2 * 60 * 60
        self.session = URLSession(configuration: configuration)
        self.uploadConfiguration = configuration
        self.downloadTransport = BackgroundDownloadCoordinator.shared
        self.networkAvailability = NetworkAvailability.shared
        self.pollingPolicy = .production
    }

    init(session: URLSession) {
        self.session = session
        self.uploadConfiguration = session.configuration
        self.downloadTransport = URLSessionDownloadTransport(session: session)
        self.networkAvailability = NetworkAvailability.shared
        self.pollingPolicy = .production
    }

    init(
        session: URLSession,
        downloadTransport: any DownloadTransport,
        networkAvailability: any NetworkAvailabilityProviding,
        pollingPolicy: PollingPolicy,
        uploadConfiguration: URLSessionConfiguration? = nil
    ) {
        self.session = session
        self.uploadConfiguration = uploadConfiguration ?? session.configuration
        self.downloadTransport = downloadTransport
        self.networkAvailability = networkAvailability
        self.pollingPolicy = pollingPolicy
    }

    func fetchAlgorithms() async throws -> [MvsepAlgorithm] {
        let (data, response) = try await session.data(from: algorithmsURL)
        try validate(response: response, data: data)
        let algorithms = try JSONDecoder().decode([MvsepAlgorithm].self, from: data)
        return algorithms
            .filter { $0.isActive == 1 && $0.audioUploadDisabled == 0 && $0.renderID > 0 }
            .sorted {
                if $0.groupName == $1.groupName {
                    if $0.orderID == $1.orderID {
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    return $0.orderID < $1.orderID
                }
                return $0.groupName.localizedStandardCompare($1.groupName) == .orderedAscending
            }
    }

    func createSeparation(
        audioURL: URL,
        apiToken: String,
        algorithm: MvsepAlgorithm,
        outputFormat: MvsepOutputFormat,
        onUploadProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> String {
        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"

        let boundary = "StemPrepBoundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var fields: [(String, String)] = [
            ("api_token", apiToken),
            ("sep_type", String(algorithm.renderID))
        ]
        fields.append(contentsOf: algorithm.defaults.keys.sorted().compactMap { key in
            algorithm.defaults[key].map { (key, $0) }
        })
        fields.append(("output_format", outputFormat.rawValue))
        fields.append(("is_demo", "0"))
        let descriptor = try MultipartBodyDescriptor(
            boundary: boundary,
            fileFieldName: "audiofile",
            fileURL: audioURL,
            mimeType: "audio/wav",
            fields: fields
        )
        let worker = StreamedUploadWorker(
            descriptor: descriptor,
            configuration: uploadConfiguration,
            onProgress: onUploadProgress
        )

        await onUploadProgress(0)
        let (data, response) = try await worker.upload(request: request)
        await onUploadProgress(1)
        try validate(response: response, data: data)
        let payload = try JSONDecoder().decode(CreateResponse.self, from: data)

        guard payload.success else {
            throw StemPrepError.mvsepRejected(payload.data?.message ?? "MVSEP rejected the job.")
        }

        guard let hash = payload.data?.hash, !hash.isEmpty else {
            throw StemPrepError.noJobHash
        }

        return hash
    }

    func pollResult(jobHash: String, onStatus: @escaping @MainActor (StemJobStatus) -> Void) async throws -> [RemoteStemFile] {
        let deadline = Date().addingTimeInterval(90 * 60)
        var retryAttempt = 0

        while Date() < deadline {
            try Task.checkCancellation()
            if !networkAvailability.isOnline {
                await onStatus(.queued("Offline - waiting for connection"))
                await networkAvailability.waitUntilOnline()
                retryAttempt = 0
            }
            var components = URLComponents(url: resultURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "hash", value: jobHash)]

            let result: ResultResponse
            do {
                let (data, response) = try await session.data(from: components.url!)
                try validate(response: response, data: data)
                result = try JSONDecoder().decode(ResultResponse.self, from: data)
                retryAttempt = 0
            } catch {
                try Task.checkCancellation()

                if Self.isConnectivityError(error) || !networkAvailability.isOnline {
                    await onStatus(.queued("Offline - waiting for connection"))
                    await networkAvailability.waitUntilOnline()
                    retryAttempt = 0
                    continue
                }

                if case .transientService = error as? StemPrepError {
                    let delays = pollingPolicy.retryDelays
                    let delay = delays[min(retryAttempt, delays.count - 1)]
                    retryAttempt += 1
                    await onStatus(.queued("MVSEP is temporarily unavailable - retrying"))
                    try await Task.sleep(for: delay)
                    continue
                }
                throw error
            }

            let nextPollDelay: Duration
            switch result.status {
            case "done":
                return result.data?.files ?? []
            case "failed", "not_found":
                throw StemPrepError.remoteJobEnded(result.data?.message ?? "MVSEP status: \(result.status)")
            case "waiting", "distributing":
                let queue = result.data?.queueCount.map { "Queue position: \($0)" } ?? result.data?.message ?? "Waiting in MVSEP queue"
                await onStatus(.queued(queue))
                nextPollDelay = pollingPolicy.queuedDelay
            case "processing", "merging":
                await onStatus(.processing(result.data?.message ?? "MVSEP is processing the track"))
                nextPollDelay = pollingPolicy.processingDelay
            default:
                await onStatus(.processing(result.data?.message ?? "MVSEP status: \(result.status)"))
                nextPollDelay = pollingPolicy.unknownDelay
            }

            try await Task.sleep(for: nextPollDelay)
        }

        throw StemPrepError.timeout
    }

    func download(
        remoteFiles: [RemoteStemFile],
        to folder: URL,
        sourceName: String,
        maxConcurrent: Int = 3,
        onProgress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> [CompletedStem] {
        try Task.checkCancellation()
        var downloads: [PreparedDownload] = []
        var usedNames: Set<String> = []

        for remoteFile in remoteFiles {
            guard let url = remoteFile.urlValue else { continue }
            let suppliedName = remoteFile.downloadName ?? url.lastPathComponent
            let filename = URL(fileURLWithPath: suppliedName).lastPathComponent
            guard !filename.isEmpty else { continue }

            let label = FileNaming.stemLabel(for: filename, fallbackIndex: downloads.count + 1)
            let uniqueLabel = FileNaming.uniqueStemLabel(label, usedLabels: &usedNames)
            let suppliedExtension = URL(fileURLWithPath: filename).pathExtension
            let fileExtension = suppliedExtension.isEmpty ? url.pathExtension : suppliedExtension
            let finalBaseURL = folder.appendingPathComponent("\(sourceName)_\(uniqueLabel)")
            let finalURL = fileExtension.isEmpty
                ? finalBaseURL
                : finalBaseURL.appendingPathExtension(fileExtension)
            downloads.append(
                PreparedDownload(
                    index: downloads.count,
                    remoteURL: url,
                    finalURL: finalURL,
                    displayName: uniqueLabel.capitalized
                )
            )
        }

        let total = downloads.count
        await onProgress(0, total)
        guard total > 0 else { return [] }

        let concurrencyLimit = max(1, min(maxConcurrent, total))
        return try await withThrowingTaskGroup(of: IndexedCompletedStem.self) { group in
            var nextDownload = 0
            var completed: [IndexedCompletedStem] = []

            while nextDownload < concurrencyLimit {
                let item = downloads[nextDownload]
                group.addTask {
                    try await downloadOne(item)
                }
                nextDownload += 1
            }

            while let stem = try await group.next() {
                completed.append(stem)
                await onProgress(completed.count, total)

                if nextDownload < total {
                    let item = downloads[nextDownload]
                    group.addTask {
                        try await downloadOne(item)
                    }
                    nextDownload += 1
                }
            }

            return completed
                .sorted { $0.index < $1.index }
                .map(\.stem)
        }
    }

    private func downloadOne(_ item: PreparedDownload) async throws -> IndexedCompletedStem {
        try Task.checkCancellation()
        let response = try await downloadTransport.download(from: item.remoteURL, to: item.finalURL)
        do {
            try validate(response: response, data: nil)
        } catch {
            try? FileManager.default.removeItem(at: item.finalURL)
            throw error
        }
        try Task.checkCancellation()
        return IndexedCompletedStem(
            index: item.index,
            stem: CompletedStem(name: item.displayName, url: item.finalURL)
        )
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            if http.statusCode == 408 || http.statusCode == 425 || http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                throw StemPrepError.transientService("MVSEP returned \(http.statusCode): \(message)")
            }
            throw StemPrepError.mvsepRejected("MVSEP returned \(http.statusCode): \(message)")
        }
    }

    private static func isConnectivityError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .timedOut
        ].contains(urlError.code)
    }
}

private struct PreparedDownload: Sendable {
    let index: Int
    let remoteURL: URL
    let finalURL: URL
    let displayName: String
}

private struct IndexedCompletedStem: Sendable {
    let index: Int
    let stem: CompletedStem
}

struct RemoteStemFile: Decodable {
    let url: String?
    let download: String?

    var urlValue: URL? {
        guard let url else { return nil }
        return URL(string: url.replacingOccurrences(of: "\\/", with: "/"))
    }

    var downloadName: String? {
        download
    }
}

private struct CreateResponse: Decodable {
    struct DataPayload: Decodable {
        let hash: String?
        let message: String?
    }

    let success: Bool
    let data: DataPayload?
}

private struct ResultResponse: Decodable {
    struct DataPayload: Decodable {
        let message: String?
        let queueCount: Int?
        let files: [RemoteStemFile]?

        enum CodingKeys: String, CodingKey {
            case message
            case queueCount = "queue_count"
            case files
        }
    }

    let success: Bool?
    let status: String
    let data: DataPayload?
}
