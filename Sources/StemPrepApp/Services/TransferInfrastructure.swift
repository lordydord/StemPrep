import Foundation
import Network

struct MultipartBodyDescriptor: Sendable {
    let prefix: Data
    let fileURL: URL
    let suffix: Data
    let contentLength: Int64

    init(
        boundary: String,
        fileFieldName: String,
        fileURL: URL,
        mimeType: String,
        fields: [(String, String)]
    ) throws {
        var prefixText = "--\(boundary)\r\n"
        prefixText += "Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
        prefixText += "Content-Type: \(mimeType)\r\n\r\n"

        var suffixText = "\r\n"
        for (name, value) in fields {
            suffixText += "--\(boundary)\r\n"
            suffixText += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            suffixText += "\(value)\r\n"
        }
        suffixText += "--\(boundary)--\r\n"

        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        self.prefix = Data(prefixText.utf8)
        self.fileURL = fileURL
        self.suffix = Data(suffixText.utf8)
        self.contentLength = Int64(prefix.count) + Int64(fileSize) + Int64(suffix.count)
    }

    func makeTemporaryUploadFile(
        in directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let manager = FileManager.default
        let uploadURL = directory.appendingPathComponent("StemPrepUpload-\(UUID().uuidString).multipart")
        guard manager.createFile(
            atPath: uploadURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let output = try FileHandle(forWritingTo: uploadURL)
            defer { try? output.close() }

            try output.write(contentsOf: prefix)
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }

            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }

            try output.write(contentsOf: suffix)
            try output.synchronize()

            let stagedSize = try uploadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(stagedSize) == contentLength else {
                throw CocoaError(.fileWriteUnknown)
            }
            return uploadURL
        } catch {
            try? manager.removeItem(at: uploadURL)
            throw error
        }
    }
}

final class FileBackedUploadWorker: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let descriptor: MultipartBodyDescriptor
    private let configuration: URLSessionConfiguration
    private let onProgress: @MainActor (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var task: URLSessionUploadTask?
    private var receivedData = Data()
    private var receivedResponse: URLResponse?
    private var session: URLSession?

    init(
        descriptor: MultipartBodyDescriptor,
        configuration: URLSessionConfiguration = .default,
        onProgress: @escaping @MainActor (Double) -> Void
    ) {
        self.descriptor = descriptor
        self.configuration = configuration
        self.onProgress = onProgress
    }

    func upload(request originalRequest: URLRequest) async throws -> (Data, URLResponse) {
        let uploadFileURL = try descriptor.makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: uploadFileURL) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var request = originalRequest
                request.setValue(String(descriptor.contentLength), forHTTPHeaderField: "Content-Length")

                let configuration = self.configuration.copy() as! URLSessionConfiguration
                configuration.waitsForConnectivity = true
                configuration.timeoutIntervalForRequest = 15 * 60
                configuration.timeoutIntervalForResource = 2 * 60 * 60
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.uploadTask(with: request, fromFile: uploadFileURL)

                lock.lock()
                self.continuation = continuation
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        Task { @MainActor in onProgress(progress) }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        receivedResponse = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else if let receivedResponse {
            finish(.success((receivedData, receivedResponse)))
        } else {
            finish(.failure(URLError(.badServerResponse)))
        }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        task = nil
        session = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

protocol DownloadTransport: Sendable {
    func download(from remoteURL: URL, to destinationURL: URL) async throws -> URLResponse
}

struct URLSessionDownloadTransport: DownloadTransport, @unchecked Sendable {
    let session: URLSession

    func download(from remoteURL: URL, to destinationURL: URL) async throws -> URLResponse {
        let (temporary, response) = try await session.download(from: remoteURL)
        let manager = FileManager.default
        if manager.fileExists(atPath: destinationURL.path) {
            try manager.removeItem(at: destinationURL)
        }
        try manager.moveItem(at: temporary, to: destinationURL)
        return response
    }
}

final class BackgroundDownloadCoordinator: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, DownloadTransport, @unchecked Sendable {
    static let shared = BackgroundDownloadCoordinator()
    static let identifier = "\(AppIdentity.bundleIdentifier).background-downloads"

    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<URLResponse, Error>] = [:]
    private var tasks: [Int: URLSessionDownloadTask] = [:]
    private var backgroundEventsCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = 2 * 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    func activate() {
        _ = session
    }

    func attachBackgroundEventsCompletion(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.identifier else {
            completion()
            return
        }
        activate()
        lock.lock()
        backgroundEventsCompletion = completion
        lock.unlock()
    }

    func download(from remoteURL: URL, to destinationURL: URL) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: remoteURL)
                task.taskDescription = destinationURL.path
                lock.lock()
                continuations[task.taskIdentifier] = continuation
                tasks[task.taskIdentifier] = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancelTask(forDestination: destinationURL)
        }
    }

    private func cancelTask(forDestination destinationURL: URL) {
        lock.lock()
        let task = tasks.values.first { $0.taskDescription == destinationURL.path }
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destinationPath = downloadTask.taskDescription else {
            complete(taskID: downloadTask.taskIdentifier, result: .failure(URLError(.cannotCreateFile)))
            return
        }

        do {
            let destination = URL(fileURLWithPath: destinationPath)
            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: location, to: destination)
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            complete(taskID: downloadTask.taskIdentifier, result: .success(response))
        } catch {
            complete(taskID: downloadTask.taskIdentifier, result: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            complete(taskID: task.taskIdentifier, result: .failure(error))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = backgroundEventsCompletion
        backgroundEventsCompletion = nil
        lock.unlock()
        DispatchQueue.main.async { completion?() }
    }

    private func complete(taskID: Int, result: Result<URLResponse, Error>) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: taskID)
        tasks.removeValue(forKey: taskID)
        lock.unlock()
        continuation?.resume(with: result)
    }
}

protocol NetworkAvailabilityProviding: Sendable {
    var isOnline: Bool { get }
    func waitUntilOnline() async
}

final class NetworkAvailability: NetworkAvailabilityProviding, @unchecked Sendable {
    static let shared = NetworkAvailability()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleIdentifier).network")
    private let lock = NSLock()
    private var online = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(isOnline: path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }

    func waitUntilOnline() async {
        if isOnline { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            if online {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func update(isOnline: Bool) {
        lock.lock()
        online = isOnline
        let pending = isOnline ? waiters : []
        if isOnline { waiters.removeAll() }
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

struct PollingPolicy: Sendable {
    let queuedDelay: Duration
    let processingDelay: Duration
    let unknownDelay: Duration
    let retryDelays: [Duration]

    static let production = PollingPolicy(
        queuedDelay: .seconds(12),
        processingDelay: .seconds(4),
        unknownDelay: .seconds(7),
        retryDelays: [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(60)]
    )

    static let immediateTests = PollingPolicy(
        queuedDelay: .milliseconds(1),
        processingDelay: .milliseconds(1),
        unknownDelay: .milliseconds(1),
        retryDelays: [.milliseconds(1)]
    )
}
