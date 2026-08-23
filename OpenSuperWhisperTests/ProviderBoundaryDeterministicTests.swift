import AVFAudio
import Foundation
import XCTest
@testable import OpenSuperWhisper

final class ProviderBoundaryDeterministicTests: XCTestCase {
    func testProvidersDeclareExplicitRecordingStrategyAndReserveHandlesSynchronously() throws {
        let appleFactory = DeterministicAppleDriverFactory()
        let apple = AppleSpeechTranscriptionEngine(liveSessionFactory: appleFactory)
        XCTAssertEqual(apple.strategy, .live)
        let live = try apple.makeLiveOperation(
            locale: Locale(identifier: "en-US"),
            context: nil,
            expectedTerms: []
        )
        XCTAssertNotNil(live)
        XCTAssertFalse(appleFactory.didMakeDriver)

        let openAI = OpenAITranscriptionEngine(
            apiKey: "test-key",
            chunker: DeterministicChunker(chunks: nil)
        )
        XCTAssertEqual(openAI.strategy, .fileAfterCapture)
        let file = try openAI.makeFileOperation(
            at: URL(fileURLWithPath: "/tmp/provider-reservation.wav"),
            locale: Locale(identifier: "en-US"),
            context: nil,
            expectedTerms: []
        )
        XCTAssertNotNil(file)
    }

    func testBoundedLiveChannelClosesWithTypedOverflowAndDrainsAdmission() async throws {
        let channel = BoundedLiveAudioChannel(maximumDuration: 5)
        let buffer = try makeBuffer(seconds: 1)
        for _ in 0..<5 {
            try await channel.append(buffer: buffer)
        }

        do {
            try await channel.append(buffer: buffer)
            XCTFail("Expected bounded channel overflow")
        } catch let error as TranscriptionLiveInputError {
            XCTAssertEqual(error, .overflow(maximumDuration: 5))
            XCTAssertTrue(error.isRecoverable)
        }

        var delivered = 0
        while true {
            do {
                guard let _ = try await channel.next() else { break }
                delivered += 1
            } catch let error as TranscriptionLiveInputError {
                XCTAssertEqual(error, .overflow(maximumDuration: 5))
                break
            }
        }
        XCTAssertEqual(delivered, 5)
    }

    func testAppleAnalyzerStartFailureIsTerminalAndTeardownIsIdempotent() async throws {
        let factory = DeterministicAppleDriverFactory(startError: .analyzerFailed("synthetic"))
        let engine = AppleSpeechTranscriptionEngine(liveSessionFactory: factory)
        let operation = try XCTUnwrap(
            try engine.makeLiveOperation(
                locale: Locale(identifier: "en-US"),
                context: nil,
                expectedTerms: []
            ) as? AppleSpeechLiveTranscriptionOperation
        )

        do {
            try await operation.start()
            XCTFail("Expected fake analyzer failure")
        } catch let error as CoreTranscriptionError {
            XCTAssertEqual(error, .analyzerFailed("synthetic"))
        }
        await operation.cancelAndWait()
        await operation.cancelAndWait()
        XCTAssertEqual(factory.driver?.cancelCount, 1)
    }

    func testAppleLiveOperationForwardsUpdatesAndFinishesAfterDriverQuiesces() async throws {
        let factory = DeterministicAppleDriverFactory()
        let engine = AppleSpeechTranscriptionEngine(liveSessionFactory: factory)
        let operation = try XCTUnwrap(
            try engine.makeLiveOperation(
                locale: Locale(identifier: "en-US"),
                context: nil,
                expectedTerms: []
            ) as? AppleSpeechLiveTranscriptionOperation
        )
        try await operation.start()
        let buffer = try makeBuffer(seconds: 1)
        try await operation.append(buffer: buffer)
        let transcript = try await operation.finish()
        XCTAssertEqual(transcript.text, "driver transcript")
        XCTAssertEqual(factory.driver?.appendCount, 1)
        XCTAssertEqual(factory.driver?.finishCount, 1)
        await operation.cancelAndWait()
        XCTAssertEqual(factory.driver?.cancelCount, 0)
    }

    func testOpenAIFileOperationEmitsRetryAndUploadProgressAndHonorsSanitization() async throws {
        let fileURL = try TestFixture.temporaryFile(contents: Data("audio".utf8), fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let endpoint = URL(string: "https://provider-boundary.test/\(UUID().uuidString)")!
        let server = ProviderURLProtocolServer(responses: [
            .http(status: 503),
            .success(text: "recovered")
        ])
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        ProviderURLProtocol.register(server, for: endpoint)
        defer {
            session.invalidateAndCancel()
            ProviderURLProtocol.unregister(endpoint)
        }

        let engine = OpenAITranscriptionEngine(
            session: session,
            apiKeyLoader: { "test-key" },
            chunker: DeterministicChunker(chunks: nil),
            configuration: .init(endpoint: endpoint, retryCount: 1, retryDelayNanoseconds: { _ in 0 }),
            sleep: { _ in }
        )
        let operation = try engine.makeFileOperation(
            at: fileURL,
            locale: Locale(identifier: "en-US"),
            context: nil,
            expectedTerms: ["<OpenAI>", "beta > gamma"]
        )
        let eventTask = Task { () -> [TranscriptionOperationEvent] in
            var events: [TranscriptionOperationEvent] = []
            for await event in operation.events { events.append(event) }
            return events
        }
        let transcript = try await operation.value()
        let events = await eventTask.value

        XCTAssertEqual(transcript.text, "recovered")
        XCTAssertTrue(events.contains { if case .retrying = $0.phase { return true }; return false })
        XCTAssertTrue(events.contains { if case .uploading = $0.phase { return true }; return false })
        let body = server.requestBodies.last ?? ""
        XCTAssertFalse(body.contains("<"))
        XCTAssertFalse(body.contains(">"))
    }

    func testOpenAITemporaryChunkArtifactsAreRemovedAndCleanupFailureIsDiagnosed() async throws {
        let sourceURL = try TestFixture.temporaryFile(contents: Data("audio".utf8), fileExtension: "wav")
        let chunkURL = try TestFixture.temporaryFile(contents: Data("chunk".utf8), fileExtension: "m4a")
        let directoryURL = try TestFixture.temporaryDirectory(prefix: "ProviderChunkCleanup")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: chunkURL)
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let endpoint = URL(string: "https://provider-boundary.test/\(UUID().uuidString)")!
        let server = ProviderURLProtocolServer(responses: [.success(text: "chunked")])
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        ProviderURLProtocol.register(server, for: endpoint)
        defer {
            session.invalidateAndCancel()
            ProviderURLProtocol.unregister(endpoint)
        }

        let diagnostics = RecordingDiagnosticSink()
        let fileSystem = RecordingFileSystem(failingURLs: [directoryURL])
        let engine = OpenAITranscriptionEngine(
            session: session,
            apiKeyLoader: { "test-key" },
            chunker: DeterministicChunker(chunks: [
                OpenAIAudioChunk(fileURL: chunkURL, isTemporary: true, cleanupDirectory: directoryURL)
            ]),
            configuration: .init(endpoint: endpoint, retryCount: 0),
            fileSystem: fileSystem,
            diagnosticSink: diagnostics
        )
        let operation = try engine.makeFileOperation(
            at: sourceURL,
            locale: Locale(identifier: "en-US"),
            context: nil,
            expectedTerms: []
        )
        let transcript = try await operation.value()
        XCTAssertEqual(transcript.text, "chunked")
        XCTAssertTrue(fileSystem.removedURLs.contains(chunkURL))
        XCTAssertTrue(fileSystem.removedURLs.contains(directoryURL))
        XCTAssertTrue(diagnostics.events.contains { $0.outcome == .cleanupFailed })
    }

    func testOpenAIKeywordSanitizerNeverEmitsAngleBrackets() {
        let keywords = OpenAITranscriptionEngine.sanitizeKeywords(["<alpha>", "beta > gamma", "<> baz"])
        XCTAssertTrue(keywords.allSatisfy { !$0.contains("<") && !$0.contains(">") })
    }

    func testOpenAISubdivisionCapsAtEightLevelsWithoutSubFiveSecondPieces() {
        let parts = AVFoundationOpenAITranscriptionChunker.subdivisionDurations(
            duration: 1_280,
            maximumLevels: 8,
            minimumDuration: 5
        )
        XCTAssertEqual(parts.count, 256)
        XCTAssertTrue(parts.allSatisfy { $0 >= 5 })

        let constrained = AVFoundationOpenAITranscriptionChunker.subdivisionDurations(
            duration: 40,
            maximumLevels: 8,
            minimumDuration: 5
        )
        XCTAssertEqual(constrained, Array(repeating: 5, count: 8))
    }

    func testOpenAIFileOperationCancelAndWaitQuiescesPendingRequest() async throws {
        let fileURL = try TestFixture.temporaryFile(contents: Data("audio".utf8), fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let endpoint = URL(string: "https://provider-boundary.test/\(UUID().uuidString)")!
        let server = ProviderURLProtocolServer(responses: [.pending])
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        ProviderURLProtocol.register(server, for: endpoint)
        defer {
            session.invalidateAndCancel()
            ProviderURLProtocol.unregister(endpoint)
        }

        let engine = OpenAITranscriptionEngine(
            session: session,
            apiKeyLoader: { "test-key" },
            chunker: DeterministicChunker(chunks: nil),
            configuration: .init(endpoint: endpoint, retryCount: 0)
        )
        let operation = try engine.makeFileOperation(
            at: fileURL,
            locale: Locale(identifier: "en-US"),
            context: nil,
            expectedTerms: []
        )
        let valueTask = Task { try await operation.value() }
        let requestObserved = await server.waitForRequest(timeout: 5)
        XCTAssertTrue(requestObserved)

        await operation.cancelAndWait()
        do {
            _ = try await valueTask.value
            XCTFail("Expected operation cancellation")
        } catch let error as OpenAITranscriptionEngineError {
            XCTAssertEqual(error, .cancelled)
        }
        await operation.cancelAndWait()
    }

    private func makeBuffer(seconds: Double) throws -> AVAudioPCMBuffer {
        let sampleRate = 100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * sampleRate)) else {
            throw NSError(domain: "ProviderBoundaryTests", code: 1)
        }
        buffer.frameLength = buffer.frameCapacity
        return buffer
    }
}

private struct DeterministicChunker: OpenAITranscriptionChunker {
    let chunks: [OpenAIAudioChunk]?

    func makeChunks(
        for fileURL: URL,
        safetyLimitBytes: Int,
        maximumChunkDuration: TimeInterval,
        overlap: TimeInterval
    ) async throws -> [OpenAIAudioChunk]? {
        _ = (fileURL, safetyLimitBytes, maximumChunkDuration, overlap)
        return chunks
    }
}

private final class RecordingFileSystem: OpenAITranscriptionFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private let failingURLs: Set<URL>
    private(set) var removedURLs: [URL] = []

    init(failingURLs: Set<URL> = []) { self.failingURLs = failingURLs }

    func removeItem(at url: URL) throws {
        lock.withLock { removedURLs.append(url) }
        if failingURLs.contains(url) {
            throw NSError(domain: "ProviderBoundaryTests", code: 2)
        }
    }
}

private final class RecordingDiagnosticSink: TranscriptionDiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [TranscriptionDiagnosticEvent] = []

    func record(_ event: TranscriptionDiagnosticEvent) {
        lock.withLock { events.append(event) }
    }
}

private final class DeterministicAppleDriverFactory: AppleSpeechLiveSessionDriverFactory, @unchecked Sendable {
    let startError: CoreTranscriptionError?
    private(set) var didMakeDriver = false
    private(set) var driver: DeterministicAppleDriver?

    init(startError: CoreTranscriptionError? = nil) { self.startError = startError }

    func makeLiveSession(
        locale: Locale,
        context: String?,
        expectedTerms: [String],
        analyzerPriority: TaskPriority
    ) async throws -> any AppleSpeechLiveSessionDriver {
        _ = (locale, context, expectedTerms, analyzerPriority)
        didMakeDriver = true
        let driver = DeterministicAppleDriver(startError: startError)
        self.driver = driver
        return driver
    }
}

private final class DeterministicAppleDriver: AppleSpeechLiveSessionDriver, @unchecked Sendable {
    let updates: AsyncStream<TranscriptUpdate> = AsyncStream { continuation in
        continuation.finish()
    }
    let startError: CoreTranscriptionError?
    private(set) var appendCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    init(startError: CoreTranscriptionError?) { self.startError = startError }

    func start() async throws {
        if let startError { throw startError }
    }

    func append(buffer: AVAudioPCMBuffer) async throws {
        _ = buffer
        appendCount += 1
    }

    func finish() async throws -> Transcript {
        finishCount += 1
        return Transcript(text: "driver transcript")
    }

    func cancelAndWait() async {
        cancelCount += 1
    }
}

private final class ProviderURLProtocolServer: @unchecked Sendable {
    enum Response: Sendable { case success(text: String); case http(status: Int); case pending }
    private let lock = NSLock()
    private var responses: [Response]
    private(set) var requestBodies: [String] = []
    private let requestEvents = TestEventRecorder()

    init(responses: [Response]) { self.responses = responses }

    func response(for request: URLRequest) -> Response {
        let response = lock.withLock { () -> Response in
            if let body = request.httpBody, let text = String(data: body, encoding: .utf8) {
                requestBodies.append(text)
            }
            return responses.isEmpty ? .success(text: "") : responses.removeFirst()
        }
        requestEvents.record()
        return response
    }

    func waitForRequest(timeout: TimeInterval) async -> Bool {
        await requestEvents.wait(timeout: timeout)
    }
}

private final class ProviderURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var servers: [String: ProviderURLProtocolServer] = [:]

    static func register(_ server: ProviderURLProtocolServer, for endpoint: URL) {
        lock.withLock { servers[endpoint.absoluteString] = server }
    }

    static func unregister(_ endpoint: URL) {
        _ = lock.withLock { servers.removeValue(forKey: endpoint.absoluteString) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let server = Self.lock.withLock({ Self.servers[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch server.response(for: request) {
        case let .success(text):
            let data = (try? JSONSerialization.data(withJSONObject: ["text": text])) ?? Data()
            send(data: data, status: 200)
        case let .http(status):
            let data = Data("{\"error\":{\"message\":\"temporary\"}}".utf8)
            send(data: data, status: status)
        case .pending:
            break
        }
    }

    override func stopLoading() {}

    private func send(data: Data, status: Int) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
