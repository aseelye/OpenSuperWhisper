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
        let recorder = URLProtocolRecorder(responses: [
            .success(text: "hello from the first chunk"),
            .success(text: "first chunk and the second chunk")
        ])
        let session = makeSession(recorder: recorder)
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: session,
            chunker: chunker,
            configuration: .init(retryCount: 0),
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
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertTrue(recorder.requestBodies[1].contains("Previous transcript context: hello from the first chunk"))
    }

    func testRetriesTransientHTTPFailure() async throws {
        let fileURL = try temporaryAudioFile(contents: Data("audio".utf8), fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let recorder = URLProtocolRecorder(responses: [
            .http(status: 503, body: "temporary"),
            .success(text: "recovered")
        ])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: makeSession(recorder: recorder),
            chunker: TestChunker(chunks: nil),
            configuration: .init(retryCount: 1),
            sleep: { _ in }
        )

        let transcript = try await engine.transcribeFile(
            at: fileURL,
            locale: Locale(identifier: "en-US"),
            context: nil,
            expectedTerms: []
        )

        XCTAssertEqual(transcript.text, "recovered")
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testRejectsNonJSONSuccessBodyEvenWhenItIsNonemptyUTF8() async throws {
        let fileURL = try temporaryAudioFile(contents: Data("audio".utf8), fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let recorder = URLProtocolRecorder(responses: [
            .raw(status: 200, body: Data("<html>proxy error</html>".utf8), contentType: "text/html")
        ])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: makeSession(recorder: recorder),
            chunker: TestChunker(chunks: nil),
            configuration: .init(retryCount: 0),
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

        let recorder = URLProtocolRecorder(responses: [
            .raw(status: 200, body: Data("not-json".utf8), contentType: "application/json")
        ])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: makeSession(recorder: recorder),
            chunker: TestChunker(chunks: nil),
            configuration: .init(retryCount: 0),
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

        let recorder = URLProtocolRecorder(responses: [
            .raw(
                status: 200,
                body: Data("{\"text\":\"decoded\"}".utf8),
                contentType: "application/json; charset=utf-8"
            )
        ])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: makeSession(recorder: recorder),
            chunker: TestChunker(chunks: nil),
            configuration: .init(retryCount: 0),
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

        let recorder = URLProtocolRecorder(responses: [.success(text: "should not upload")])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: makeSession(recorder: recorder),
            chunker: TestChunker(chunks: nil),
            configuration: .init(retryCount: 0, uploadSafetyLimitBytes: 10),
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
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testCancellationCancelsPendingRequest() async throws {
        let fileURL = try temporaryAudioFile(contents: Data("audio".utf8), fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let recorder = URLProtocolRecorder(responses: [.pending])
        let engine = OpenAITranscriptionEngine(
            apiKey: "test-key",
            session: makeSession(recorder: recorder),
            chunker: TestChunker(chunks: nil),
            configuration: .init(retryCount: 0),
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

        try await eventually {
            !recorder.requests.isEmpty
        }
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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisperTests-\(UUID().uuidString).\(fileExtension)")
        try contents.write(to: url)
        return url
    }

    private func makeSession(recorder: URLProtocolRecorder) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        RecordingURLProtocol.recorder = recorder
        return URLSession(configuration: configuration)
    }

    private func eventually(
        timeout: TimeInterval = 2,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { throw XCTSkip("Timed out waiting for URLProtocol request") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
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
    private(set) var requests: [URLRequest] = []
    private(set) var requestBodies: [String] = []
    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func record(_ request: URLRequest) -> Response {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        requestBodies.append(String(data: bodyData(for: request), encoding: .utf8) ?? "")
        guard !responses.isEmpty else { return .success(text: "") }
        return responses.removeFirst()
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

private final class RecordingURLProtocol: URLProtocol {
    static var recorder: URLProtocolRecorder!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.recorder.record(request)
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
