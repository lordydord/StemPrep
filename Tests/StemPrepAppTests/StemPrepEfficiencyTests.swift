import XCTest
@testable import StemPrepApp

final class StemPrepEfficiencyTests: XCTestCase {
    func testFingerprintAndSeparationKeyAreStable() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemPrepFingerprint-\(UUID().uuidString).wav")
        try Data("same-audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let first = try await AudioFingerprint.sha256(of: file)
        let second = try await AudioFingerprint.sha256(of: file)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            AudioFingerprint.separationKey(sourceFingerprint: first, renderID: 28, outputFormat: .wav16),
            AudioFingerprint.separationKey(sourceFingerprint: second, renderID: 28, outputFormat: .wav16)
        )
        XCTAssertNotEqual(
            AudioFingerprint.separationKey(sourceFingerprint: first, renderID: 28, outputFormat: .wav16),
            AudioFingerprint.separationKey(sourceFingerprint: first, renderID: 28, outputFormat: .flac24)
        )
    }

    func testRecoveryRecordRoundTripsPausedState() throws {
        let suiteName = "StemPrepEfficiencyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = StemJobRecoveryStore(defaults: defaults)
        let job = ResumableStemJob(
            jobHash: "job-123",
            sourcePath: "/tmp/source.wav",
            folderPath: "/tmp/source Stems",
            sourceName: "source",
            algorithm: .fallback,
            outputFormat: .wav16,
            startedAt: Date(timeIntervalSince1970: 1_720_000_000),
            sourceFingerprint: "fingerprint",
            separationKey: "key",
            isPaused: true
        )

        store.save(job)
        XCTAssertEqual(store.load(), job)
        store.clear()
        XCTAssertNil(store.load())
    }

    func testAlgorithmCatalogueCacheRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemPrepCacheTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AlgorithmCatalogueCache(fileURL: root.appendingPathComponent("algorithms.json"))

        try cache.save([.fallback])

        XCTAssertEqual(cache.load(), [.fallback])
    }

    func testManifestImportAndPersistentHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemPrepHistoryTest-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Track Stems", isDirectory: true)
        let source = root.appendingPathComponent("Track.wav")
        let stemURL = folder.appendingPathComponent("Track_vocals.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source)
        try Data("stem".utf8).write(to: stemURL)
        defer { try? FileManager.default.removeItem(at: root) }

        try OutputStore(root: root).writeManifest(
            to: folder,
            source: source,
            jobHash: "hash",
            algorithm: .fallback,
            outputFormat: .wav16,
            sourceFingerprint: "fingerprint",
            separationKey: "separation-key",
            stems: [CompletedStem(name: "Vocals", url: stemURL)]
        )

        let historyURL = root.appendingPathComponent("history.json")
        let historyStore = CompletedJobHistoryStore(fileURL: historyURL)
        let imported = historyStore.importedManifests(below: root)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].separationKey, "separation-key")
        XCTAssertTrue(imported[0].isAvailable)

        try historyStore.save(imported)
        XCTAssertEqual(historyStore.load(), imported)
    }

    func testOutputOriginalUsesCloneOrCopyWithoutChangingContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemPrepCloneTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Track.wav")
        let contents = Data(repeating: 0x5A, count: 128 * 1024)
        try contents.write(to: source)

        let folder = try OutputStore(root: root).prepareFolder(for: source)
        let original = folder.appendingPathComponent("original.wav")

        XCTAssertEqual(try Data(contentsOf: original), contents)
        XCTAssertEqual(try Data(contentsOf: source), contents)
    }

    func testMultipartBodyStreamsFileWithoutCreatingPackage() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemPrepStreamTest-\(UUID().uuidString).wav")
        try Data("AUDIO-PAYLOAD".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let descriptor = try MultipartBodyDescriptor(
            boundary: "TestBoundary",
            fileFieldName: "audiofile",
            fileURL: file,
            mimeType: "audio/wav",
            fields: [("sep_type", "28"), ("output_format", "1")]
        )

        let body = try readAll(from: descriptor.makeInputStream())
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertEqual(Int64(body.count), descriptor.contentLength)
        XCTAssertTrue(text.contains("AUDIO-PAYLOAD"))
        XCTAssertTrue(text.contains("name=\"sep_type\""))
        XCTAssertTrue(text.contains("\r\n28\r\n"))
        XCTAssertTrue(text.hasSuffix("--TestBoundary--\r\n"))
    }

    @MainActor
    func testStreamedUploadReturnsJobHash() async throws {
        MockUploadURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUploadURLProtocol.self]
        let client = MvsepClient(session: URLSession(configuration: configuration))
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemPrepUploadTest-\(UUID().uuidString).wav")
        try Data("STREAMED-AUDIO".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let hash = try await client.createSeparation(
            audioURL: file,
            apiToken: "test-token",
            algorithm: .fallback,
            outputFormat: .wav16
        ) { _ in }

        XCTAssertEqual(hash, "streamed-job")
        XCTAssertTrue(MockUploadURLProtocol.capturedBody.contains(Data("STREAMED-AUDIO".utf8)))
        XCTAssertTrue(MockUploadURLProtocol.capturedBody.contains(Data("test-token".utf8)))
    }

    @MainActor
    func testPollingRetriesTemporaryServiceFailure() async throws {
        PollRetryURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PollRetryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = MvsepClient(
            session: session,
            downloadTransport: URLSessionDownloadTransport(session: session),
            networkAvailability: AlwaysOnlineNetwork(),
            pollingPolicy: .immediateTests
        )

        let files = try await client.pollResult(jobHash: "retry-job") { _ in }

        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(PollRetryURLProtocol.requestCount, 2)
    }

    @MainActor
    func testDownloadsAreBoundedParallelAndStoredOnce() async throws {
        MockDownloadURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockDownloadURLProtocol.self]
        let client = MvsepClient(session: URLSession(configuration: configuration))
        let outputFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemPrepDownloadTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputFolder) }

        let remoteFiles = (1...5).map { index in
            RemoteStemFile(
                url: "https://stem-prep.test/vocal-\(index).wav",
                download: "vocal-\(index).wav"
            )
        }
        var lastProgress = (completed: 0, total: 0)

        let stems = try await client.download(
            remoteFiles: remoteFiles,
            to: outputFolder,
            sourceName: "Track",
            maxConcurrent: 3
        ) { completed, total in
            lastProgress = (completed, total)
        }

        XCTAssertEqual(stems.count, 5)
        XCTAssertEqual(lastProgress.completed, 5)
        XCTAssertEqual(lastProgress.total, 5)
        XCTAssertGreaterThanOrEqual(MockDownloadURLProtocol.maximumObservedConcurrency, 2)
        XCTAssertLessThanOrEqual(MockDownloadURLProtocol.maximumObservedConcurrency, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputFolder.appendingPathComponent(".mvsep-raw").path))
        XCTAssertTrue(stems.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })

        let visibleFiles = try FileManager.default.contentsOfDirectory(
            at: outputFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(visibleFiles.count, 5)
    }
}

private func readAll(from stream: InputStream) throws -> Data {
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

private struct AlwaysOnlineNetwork: NetworkAvailabilityProviding {
    var isOnline: Bool { true }
    func waitUntilOnline() async { }
}

private final class MockUploadURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()

    static var capturedBody: Data {
        lock.lock()
        defer { lock.unlock() }
        return body
    }

    static func reset() {
        lock.lock()
        body = Data()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mvsep.com" && request.url?.path.contains("separation/create") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requestBody = (request.httpBodyStream.flatMap { try? readAll(from: $0) }) ?? Data()
        Self.lock.lock()
        Self.body = requestBody
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"success\":true,\"data\":{\"hash\":\"streamed-job\"}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

private final class PollRetryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func reset() {
        lock.lock()
        requests = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mvsep.com" && request.url?.path.contains("separation/get") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let attempt = Self.requests
        Self.lock.unlock()
        let statusCode = attempt == 1 ? 503 : 200
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = attempt == 1
            ? Data("temporarily unavailable".utf8)
            : Data("{\"success\":true,\"status\":\"done\",\"data\":{\"files\":[]}}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

private final class MockDownloadURLProtocol: URLProtocol {
    private static let stateLock = NSLock()
    private static var activeRequests = 0
    private static var maximumRequests = 0
    private var finished = false

    static var maximumObservedConcurrency: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return maximumRequests
    }

    static func reset() {
        stateLock.lock()
        activeRequests = 0
        maximumRequests = 0
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stem-prep.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.stateLock.lock()
        Self.activeRequests += 1
        Self.maximumRequests = max(Self.maximumRequests, Self.activeRequests)
        Self.stateLock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !finished, let url = request.url else { return }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "audio/wav"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("test-wave-data".utf8))
            client?.urlProtocolDidFinishLoading(self)
            finishOnce()
        }
    }

    override func stopLoading() {
        finishOnce()
    }

    private func finishOnce() {
        Self.stateLock.lock()
        guard !finished else {
            Self.stateLock.unlock()
            return
        }
        finished = true
        Self.activeRequests -= 1
        Self.stateLock.unlock()
    }
}
