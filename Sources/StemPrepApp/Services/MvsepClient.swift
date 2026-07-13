import Foundation

struct MvsepClient {
    private let algorithmsURL = URL(string: "https://mvsep.com/api/app/algorithms")!
    private let accountURL = URL(string: "https://mvsep.com/api/app/user")!
    private let historyURL = URL(string: "https://mvsep.com/api/app/separation_history")!
    private let createURL = URL(string: "https://mvsep.com/api/separation/create")!
    private let resultURL = URL(string: "https://mvsep.com/api/separation/get")!
    private let cancelURL = URL(string: "https://mvsep.com/api/separation/cancel")!
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

    func fetchAccount(apiToken: String) async throws -> MvsepAccountSummary {
        let url = try authenticatedURL(accountURL, apiToken: apiToken)
        let (data, response) = try await session.data(from: url)
        try validate(response: response, data: data)
        let payload = try JSONDecoder().decode(AccountResponse.self, from: data)
        guard payload.success, let account = payload.data else {
            throw StemPrepError.mvsepRejected("The MVSEP API token is invalid.")
        }
        return MvsepAccountSummary(
            premiumMinutes: account.premiumMinutes?.doubleValue ?? 0,
            premiumEnabled: account.premiumEnabled?.boolValue ?? false,
            longFilenamesEnabled: account.longFilenamesEnabled?.boolValue ?? false,
            activeSeparations: account.currentQueue?.collectionCount ?? 0
        )
    }

    func fetchSeparationHistory(apiToken: String, limit: Int = 10) async throws -> [MvsepHistoryItem] {
        var components = URLComponents(url: historyURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api_token", value: apiToken),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "limit", value: String(max(1, min(20, limit))))
        ]
        let (data, response) = try await session.data(from: components.url!)
        try validate(response: response, data: data)
        let payload = try JSONDecoder().decode(HistoryResponse.self, from: data)
        guard payload.success else {
            throw StemPrepError.mvsepRejected("The MVSEP API token is invalid.")
        }
        return payload.data ?? []
    }

    func createSeparation(
        audioURL: URL,
        apiToken: String,
        algorithm: MvsepAlgorithm,
        outputFormat: MvsepOutputFormat,
        algorithmOptions: [String: String]? = nil,
        onUploadProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> CreatedSeparation {
        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"

        let boundary = "StemPrepBoundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var fields: [(String, String)] = [
            ("api_token", apiToken),
            ("sep_type", String(algorithm.renderID))
        ]
        let submittedOptions = algorithmOptions ?? algorithm.defaults
        fields.append(contentsOf: submittedOptions.keys.sorted().compactMap { key in
            submittedOptions[key].map { (key, $0) }
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
        let worker = FileBackedUploadWorker(
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

        return CreatedSeparation(
            hash: hash,
            resultURL: Self.safeResultURL(from: payload.data?.link)
        )
    }

    func pollResult(
        jobHash: String,
        resultURL preferredResultURL: URL? = nil,
        onStatus: @escaping @MainActor (StemJobStatus) -> Void
    ) async throws -> MvsepCompletedResult {
        let deadline = Date().addingTimeInterval(90 * 60)
        var retryAttempt = 0

        while Date() < deadline {
            try Task.checkCancellation()
            if !networkAvailability.isOnline {
                await onStatus(.queued(MvsepRemoteProgress(stage: .offline)))
                await networkAvailability.waitUntilOnline()
                retryAttempt = 0
            }
            let pollURL = Self.safeResultURL(preferredResultURL) ?? resultURL
            var components = URLComponents(url: pollURL, resolvingAgainstBaseURL: false)!
            var queryItems = (components.queryItems ?? []).filter { $0.name != "hash" }
            queryItems.append(URLQueryItem(name: "hash", value: jobHash))
            components.queryItems = queryItems

            let result: ResultResponse
            do {
                let (data, response) = try await session.data(from: components.url!)
                try validate(response: response, data: data)
                result = try JSONDecoder().decode(ResultResponse.self, from: data)
                retryAttempt = 0
            } catch {
                try Task.checkCancellation()

                if Self.isConnectivityError(error) || !networkAvailability.isOnline {
                    await onStatus(.queued(MvsepRemoteProgress(stage: .offline)))
                    await networkAvailability.waitUntilOnline()
                    retryAttempt = 0
                    continue
                }

                if case .transientService = error as? StemPrepError {
                    let delays = pollingPolicy.retryDelays
                    let delay = delays[min(retryAttempt, delays.count - 1)]
                    retryAttempt += 1
                    await onStatus(.queued(MvsepRemoteProgress(stage: .retrying)))
                    try await Task.sleep(for: delay)
                    continue
                }
                throw error
            }

            let nextPollDelay: Duration
            switch result.status {
            case "done":
                return MvsepCompletedResult(
                    files: result.data?.files ?? [],
                    metadata: result.data?.completionMetadata ?? MvsepCompletionMetadata(
                        algorithmName: nil,
                        algorithmDescription: nil,
                        outputFormat: nil,
                        inputFilename: nil,
                        processedAt: nil
                    )
                )
            case "failed", "not_found":
                throw StemPrepError.remoteJobEnded(result.data?.message ?? "MVSEP status: \(result.status)")
            case "waiting":
                await onStatus(.queued(result.remoteProgress(stage: .waiting)))
                nextPollDelay = pollingPolicy.queuedDelay
            case "distributing":
                await onStatus(.processing(result.remoteProgress(stage: .distributing)))
                nextPollDelay = pollingPolicy.processingDelay
            case "processing":
                await onStatus(.processing(result.remoteProgress(stage: .processing)))
                nextPollDelay = pollingPolicy.processingDelay
            case "merging":
                await onStatus(.processing(result.remoteProgress(stage: .merging)))
                nextPollDelay = pollingPolicy.processingDelay
            default:
                await onStatus(.processing(MvsepRemoteProgress(
                    stage: .processing,
                    message: result.data?.message ?? "MVSEP status: \(result.status)"
                )))
                nextPollDelay = pollingPolicy.unknownDelay
            }

            try await Task.sleep(for: nextPollDelay)
        }

        throw StemPrepError.timeout
    }

    func cancelSeparation(
        jobHash: String,
        apiToken: String,
        resultURL: URL? = nil
    ) async throws {
        let endpoint = Self.regionalEndpoint(for: resultURL, path: "/api/separation/cancel") ?? cancelURL
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "api_token", value: apiToken),
            URLQueryItem(name: "hash", value: jobHash)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let payload = try JSONDecoder().decode(ActionResponse.self, from: data)
        guard payload.success else {
            throw StemPrepError.mvsepRejected(payload.resolvedMessage ?? "MVSEP could not cancel this job.")
        }
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

    private func authenticatedURL(_ endpoint: URL, apiToken: String) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "api_token", value: apiToken)]
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private static func safeResultURL(from value: String?) -> URL? {
        guard let value, let url = URL(string: value) else { return nil }
        return safeResultURL(url)
    }

    private static func safeResultURL(_ url: URL?) -> URL? {
        guard
            let url,
            url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(),
            host == "mvsep.com" || host == "www.mvsep.com" || host.hasSuffix(".mvsep.com"),
            url.path.hasPrefix("/api/separation/get")
        else { return nil }
        return url
    }

    private static func regionalEndpoint(for resultURL: URL?, path: String) -> URL? {
        guard let safeURL = safeResultURL(resultURL), let host = safeURL.host else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        return components.url
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

struct RemoteStemFile: Decodable, Equatable, Sendable {
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
        let link: String?
        let message: String?
    }

    let success: Bool
    let data: DataPayload?
}

private struct ResultResponse: Decodable {
    struct DataPayload: Decodable {
        let message: String?
        let queueCount: Int?
        let currentOrder: Int?
        let finishedChunks: Int?
        let allChunks: Int?
        let files: [RemoteStemFile]?
        let algorithm: JSONValue?
        let algorithmDescription: JSONValue?
        let outputFormat: JSONValue?
        let inputFile: JSONValue?
        let date: JSONValue?

        enum CodingKeys: String, CodingKey {
            case message
            case queueCount = "queue_count"
            case currentOrder = "current_order"
            case finishedChunks = "finished_chunks"
            case allChunks = "all_chunks"
            case files
            case algorithm
            case algorithmDescription = "algorithm_description"
            case outputFormat = "output_format"
            case inputFile = "input_file"
            case date
        }

        var completionMetadata: MvsepCompletionMetadata {
            MvsepCompletionMetadata(
                algorithmName: algorithm?.preferredName,
                algorithmDescription: algorithmDescription?.preferredDescription,
                outputFormat: outputFormat?.preferredName,
                inputFilename: inputFile?.preferredFilename,
                processedAt: date?.preferredName
            )
        }
    }

    let success: Bool?
    let status: String
    let data: DataPayload?

    func remoteProgress(stage: MvsepRemoteStage) -> MvsepRemoteProgress {
        MvsepRemoteProgress(
            stage: stage,
            message: data?.message,
            queueCount: data?.queueCount,
            currentOrder: data?.currentOrder,
            finishedChunks: data?.finishedChunks,
            allChunks: data?.allChunks
        )
    }
}

private struct AccountResponse: Decodable {
    struct DataPayload: Decodable {
        let premiumMinutes: JSONValue?
        let premiumEnabled: JSONValue?
        let longFilenamesEnabled: JSONValue?
        let currentQueue: JSONValue?

        enum CodingKeys: String, CodingKey {
            case premiumMinutes = "premium_minutes"
            case premiumEnabled = "premium_enabled"
            case longFilenamesEnabled = "long_filenames_enabled"
            case currentQueue = "current_queue"
        }
    }

    let success: Bool
    let data: DataPayload?
}

private struct HistoryResponse: Decodable {
    let success: Bool
    let data: [MvsepHistoryItem]?
}

private struct ActionResponse: Decodable {
    struct DataPayload: Decodable {
        let message: String?
    }

    let success: Bool
    let message: String?
    let data: DataPayload?

    var resolvedMessage: String? { message ?? data?.message }
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value):
            if let number = Double(value) { return number != 0 }
            return ["true", "yes", "enabled"].contains(value.lowercased())
        default: return nil
        }
    }

    var collectionCount: Int? {
        switch self {
        case .array(let values): return values.count
        case .object(let values): return values.count
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var preferredName: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .object(let values):
            return values["name"]?.preferredName
                ?? values["title"]?.preferredName
                ?? values["format"]?.preferredName
        default: return nil
        }
    }

    var preferredDescription: String? {
        switch self {
        case .string(let value): return value
        case .object(let values):
            return values["short_description"]?.preferredName
                ?? values["description"]?.preferredName
                ?? values["name"]?.preferredName
        default: return nil
        }
    }

    var preferredFilename: String? {
        switch self {
        case .string(let value): return URL(string: value)?.lastPathComponent ?? value
        case .object(let values):
            let candidate = values["download"]?.preferredName
                ?? values["filename"]?.preferredName
                ?? values["name"]?.preferredName
                ?? values["url"]?.preferredName
            return candidate.map { URL(string: $0)?.lastPathComponent ?? $0 }
        case .array(let values): return values.compactMap(\.preferredFilename).first
        default: return nil
        }
    }
}
