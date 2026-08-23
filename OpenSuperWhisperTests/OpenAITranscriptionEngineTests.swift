import Foundation
import XCTest
@testable import OpenSuperWhisper

final class OpenAITranscriptionEngineTests: XCTestCase {
    func testMultipartUsesGPTTranscribeLanguagesPromptAndSanitizedKeywords() throws {
        let fileURL = try temporaryAudioFile(contents: Data("audio".utf8), fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let body = try OpenAITranscriptionEngine.makeMultipartBody(
            fileURL: fileURL,
            boundary: "test-boundary",
            locale: OpenAITranscriptionEngine.normalizedLanguageIdentifier("zh-TW"),
            prompt: OpenAITranscriptionEngine.sanitizePrompt("  keep\nthis\r\ncontext  "),
            keywords: OpenAITranscriptionEngine.sanitizeKeywords([
                "- OpenAI\n2. GPT-Transcribe",
                "openai",
                "   "
            ])
        )
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
        XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(text.contains("name=\"languages[]\"\r\n\r\nzh-tw"))
        XCTAssertTrue(text.contains("name=\"prompt\"\r\n\r\nkeep this context"))
        XCTAssertEqual(text.components(separatedBy: "name=\"keywords[]\"").count - 1, 2)
        XCTAssertFalse(text.contains("name=\"language\""))
        XCTAssertFalse(text.contains("translate"))
    }

    func testLanguageNormalizationPreservesChineseRegionsAndUsesBaseOtherwise() {
        XCTAssertEqual(OpenAITranscriptionEngine.normalizedLanguageIdentifier("zh_CN"), "zh-cn")
        XCTAssertEqual(OpenAITranscriptionEngine.normalizedLanguageIdentifier("zh_TW"), "zh-tw")
        XCTAssertEqual(OpenAITranscriptionEngine.normalizedLanguageIdentifier("zh-Hant-HK"), "zh-hk")
        XCTAssertEqual(OpenAITranscriptionEngine.normalizedLanguageIdentifier("en-US"), "en")
        XCTAssertEqual(OpenAITranscriptionEngine.normalizedLanguageIdentifier("pt_BR"), "pt")
        XCTAssertNil(OpenAITranscriptionEngine.normalizedLanguageIdentifier("auto"))
    }

    func testKeywordSanitizationRemovesAPIRejectedAngleBrackets() {
        XCTAssertEqual(
            OpenAITranscriptionEngine.sanitizeKeywords(["<alpha>", "beta > gamma", "<>"]),
            ["alpha", "beta gamma"]
        )
    }

    func testChunkLayoutKeepsBothOverlapMarginsWithinOutputDuration() {
        let normal = AVFoundationOpenAITranscriptionChunker.chunkLayout(
            outputDuration: 60,
            overlap: 5
        )
        XCTAssertEqual(normal.coreDuration, 50)
        XCTAssertEqual(normal.overlap, 5)
        XCTAssertEqual(normal.coreDuration + 2 * normal.overlap, 60)

        let constrained = AVFoundationOpenAITranscriptionChunker.chunkLayout(
            outputDuration: 5,
            overlap: 5
        )
        XCTAssertEqual(constrained.coreDuration, 1)
        XCTAssertEqual(constrained.overlap, 2)
        XCTAssertEqual(constrained.coreDuration + 2 * constrained.overlap, 5)
    }

    func testChunkResultsCarryContextAndDeduplicateOverlap() async throws {
        let firstURL = try temporaryAudioFile(contents: Data("first".utf8), fileExtension: "m4a")
        let secondURL = try temporaryAudioFile(contents: Data("second".utf8), fileExtension: "m4a")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let chunker = TestChunker(chunks: [
            OpenAIAudioChunk(fileURL: firstURL),
            OpenAIAudioChunk(fileURL: secondURL)
        ])
        let client = makeClient(responses: [
            .success(text: "hello from the first chunk"),
            .success(text: "first chunk and the second chunk")
        ])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: client.session,
            chunker: chunker,
            configuration: .init(endpoint: client.endpoint, retryCount: 0),
            sleep: { _ in }
        )

        let transcript = try await engine.transcribeFile(
            at: firstURL,
            locale: Locale(identifier: "en-US"),
            context: "meeting notes",
            expectedTerms: ["OpenAI"]
        )

        XCTAssertEqual(transcript.text, "hello from the first chunk and the second chunk")
        XCTAssertTrue(transcript.segments.isEmpty)
        XCTAssertEqual(client.recorder.requests.count, 2)
        XCTAssertTrue(client.recorder.requestBodies[1].contains("Previous transcript context: hello from the first chunk"))
    }

    func testRetriesTransientHTTPFailure() async throws {
        let fileURL = try temporaryAudioFile(contents: Data("audio".utf8), fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let client = makeClient(responses: [
            .http(status: 503, body: "temporary"),
            .success(text: "recovered")
        ])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: client.session,
            chunker: TestChunker(chunks: nil),
            configuration: .init(endpoint: client.endpoint, retryCount: 1),
            sleep: { _ in }
        )

        let transcript = try await engine.transcribeFile(
            at: fileURL,
            locale: Locale(identifier: "en-US"),
            context: nil,
            expectedTerms: []
        )

        XCTAssertEqual(transcript.text, "recovered")
        XCTAssertEqual(client.recorder.requests.count, 2)
    }

    func testParallelClientsKeepResponsesIsolated() async throws {
        let firstURL = try temporaryAudioFile(contents: Data("first".utf8), fileExtension: "wav")
        let secondURL = try temporaryAudioFile(contents: Data("second".utf8), fileExtension: "wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let firstClient = makeClient(responses: [.success(text: "first response")])
        let secondClient = makeClient(responses: [.success(text: "second response")])
        let firstEngine = OpenAITranscriptionEngine(
            apiKey: "first-key",
            session: firstClient.session,
            chunker: TestChunker(chunks: nil),
            configuration: .init(endpoint: firstClient.endpoint, retryCount: 0),
            sleep: { _ in }
        )
        let secondEngine = OpenAITranscriptionEngine(
            apiKey: "second-key",
            session: secondClient.session,
            chunker: TestChunker(chunks: nil),
            configuration: .init(endpoint: secondClient.endpoint, retryCount: 0),
            sleep: { _ in }
        )

        async let firstResult = firstEngine.transcribeFile(
            at: firstURL,
            locale: Locale(identifier: "en-US"),
            context: nil,
            expectedTerms: []
        )
        async let secondResult = secondEngine.transcribeFile(
            at: secondURL,
            locale: Locale(identifier: "en-US"),
            context: nil,
            expectedTerms: []
        )

        let (firstTranscript, secondTranscript) = try await (firstResult, secondResult)
        XCTAssertEqual(firstTranscript.text, "first response")
        XCTAssertEqual(secondTranscript.text, "second response")
        XCTAssertEqual(firstClient.recorder.requests.count, 1)
        XCTAssertEqual(secondClient.recorder.requests.count, 1)
    }

    func testRejectsNonJSONSuccessBodyEvenWhenItIsNonemptyUTF8() async throws {
        let fileURL = try temporaryAudioFile(contents: Data("audio".utf8), fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let client = makeClient(responses: [
            .raw(status: 200, body: Data("<html>proxy error</html>".utf8), contentType: "text/html")
        ])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: client.session,
            chunker: TestChunker(chunks: nil),
            configuration: .init(endpoint: client.endpoint, retryCount: 0),
            sleep: { _ in }
        )

        do {
            _ = try await engine.transcribeFile(
                at: fileURL,
                locale: Locale(identifier: "en-US"),
                context: nil,
                expectedTerms: []
            )
            XCTFail("Expected response decoding failure")
        } catch let error as OpenAITranscriptionEngineError {
            XCTAssertEqual(error, .responseDecodingFailed)
        }
    }

    func testRejectsMalformedJSONSuccessBody() async throws {
        let fileURL = try temporaryAudioFile(contents: Data("audio".utf8), fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let client = makeClient(responses: [
            .raw(status: 200, body: Data("not-json".utf8), contentType: "application/json")
        ])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: client.session,
            chunker: TestChunker(chunks: nil),
            configuration: .init(endpoint: client.endpoint, retryCount: 0),
            sleep: { _ in }
        )

        do {
            _ = try await engine.transcribeFile(
                at: fileURL,
                locale: Locale(identifier: "en-US"),
                context: nil,
                expectedTerms: []
            )
            XCTFail("Expected response decoding failure")
        } catch let error as OpenAITranscriptionEngineError {
            XCTAssertEqual(error, .responseDecodingFailed)
        }
    }

    func testAcceptsJSONResponseWithCharsetContentType() async throws {
        let fileURL = try temporaryAudioFile(contents: Data("audio".utf8), fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let client = makeClient(responses: [
            .raw(
                status: 200,
                body: Data("{\"text\":\"decoded\"}".utf8),
                contentType: "application/json; charset=utf-8"
            )
        ])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: client.session,
            chunker: TestChunker(chunks: nil),
            configuration: .init(endpoint: client.endpoint, retryCount: 0),
            sleep: { _ in }
        )

        let transcript = try await engine.transcribeFile(
            at: fileURL,
            locale: Locale(identifier: "en-US"),
            context: nil,
            expectedTerms: []
        )

        XCTAssertEqual(transcript.text, "decoded")
    }

    func testRejectsFileAboveConfiguredSafetyLimitBeforeUpload() async throws {
        let fileURL = try temporaryAudioFile(contents: Data(repeating: 0, count: 11), fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let client = makeClient(responses: [.success(text: "should not upload")])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: client.session,
            chunker: TestChunker(chunks: nil),
            configuration: .init(endpoint: client.endpoint, retryCount: 0, uploadSafetyLimitBytes: 10),
            sleep: { _ in }
        )

        do {
            _ = try await engine.transcribeFile(
                at: fileURL,
                locale: Locale(identifier: "en-US"),
                context: nil,
                expectedTerms: []
            )
            XCTFail("Expected file-size rejection")
        } catch let error as OpenAITranscriptionEngineError {
            XCTAssertEqual(error, .fileTooLarge(limitBytes: 10))
        }
        XCTAssertTrue(client.recorder.requests.isEmpty)
    }

    func testCancellationCancelsPendingRequest() async throws {
        let fileURL = try temporaryAudioFile(contents: Data("audio".utf8), fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let client = makeClient(responses: [.pending])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: client.session,
            chunker: TestChunker(chunks: nil),
            configuration: .init(endpoint: client.endpoint, retryCount: 0),
            sleep: { _ in }
        )
        let task = Task {
            try await engine.transcribeFile(
                at: fileURL,
                locale: Locale(identifier: "en-US"),
                context: nil,
                expectedTerms: []
            )
        }

        let requestObserved = await client.recorder.waitForRequest(timeout: 5)
        XCTAssertTrue(requestObserved, "The cancellation fixture never observed a request")
        engine.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as OpenAITranscriptionEngineError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    // MARK: - Test support

    private func temporaryAudioFile(contents: Data, fileExtension: String) throws -> URL {
        try TestFixture.temporaryFile(contents: contents, fileExtension: fileExtension)
    }

    private func makeClient(responses: [URLProtocolRecorder.Response]) -> TestOpenAIClient {
        TestOpenAIClient(responses: responses)
    }
}

private struct TestChunker: OpenAITranscriptionChunker {
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

private final class URLProtocolRecorder: @unchecked Sendable {
    enum Response: Sendable {
        case success(text: String)
        case http(status: Int, body: String)
        case raw(status: Int, body: Data, contentType: String?)
        case pending
    }

    private let lock = NSLock()
    private let requestEvents = TestEventRecorder()
    private(set) var requests: [URLRequest] = []
    private(set) var requestBodies: [String] = []
    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func record(_ request: URLRequest) -> Response {
        let response = lock.withLock { () -> Response in
            requests.append(request)
            requestBodies.append(String(data: bodyData(for: request), encoding: .utf8) ?? "")
            guard !responses.isEmpty else { return .success(text: "") }
            return responses.removeFirst()
        }
        requestEvents.record()
        return response
    }

    func waitForRequest(timeout: TimeInterval) async -> Bool {
        await requestEvents.wait(timeout: timeout)
    }

    private func bodyData(for request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var body = Data()
        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

/// URLProtocol does not expose the URLSession configuration to a protocol
/// instance. Each test client therefore gets a unique endpoint token, and the
/// registry routes only that token to its instance-owned recorder. There is no
/// process-global "current recorder" that a parallel test can overwrite.
private enum RecordingURLProtocolRegistry {
    private static let lock = NSLock()
    private static var recorders: [String: URLProtocolRecorder] = [:]

    static func register(_ recorder: URLProtocolRecorder) -> String {
        let token = UUID().uuidString
        lock.withLock { recorders[token] = recorder }
        return token
    }

    static func recorder(for url: URL?) -> URLProtocolRecorder? {
        guard let token = url?.pathComponents.last else { return nil }
        return lock.withLock { recorders[token] }
    }

    static func unregister(_ token: String) {
        _ = lock.withLock { recorders.removeValue(forKey: token) }
    }
}

private final class TestOpenAIClient {
    let session: URLSession
    let recorder: URLProtocolRecorder
    let endpoint: URL
    private let token: String

    init(responses: [URLProtocolRecorder.Response]) {
        let recorder = URLProtocolRecorder(responses: responses)
        let token = RecordingURLProtocolRegistry.register(recorder)
        self.recorder = recorder
        self.token = token
        self.endpoint = URL(string: "https://open-super-whisper.test/\(token)")!

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
        RecordingURLProtocolRegistry.unregister(token)
    }
}

private final class RecordingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let recorder = RecordingURLProtocolRegistry.recorder(for: request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = recorder.record(request)
        switch response {
        case let .success(text):
            let data = (try? JSONSerialization.data(withJSONObject: ["text": text])) ?? Data()
            send(data: data, status: 200, contentType: "application/json")
        case let .http(status, body):
            let data = Data("{\"error\":{\"message\":\"\(body)\"}}".utf8)
            send(data: data, status: status, contentType: "application/json")
        case let .raw(status, body, contentType):
            send(data: body, status: status, contentType: contentType)
        case .pending:
            // Keep the request open until URLSession cancels it.
            return
        }
    }

    private func send(data: Data, status: Int, contentType: String?) {
        var headers: [String: String] = [:]
        if let contentType {
            headers["Content-Type"] = contentType
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
}
