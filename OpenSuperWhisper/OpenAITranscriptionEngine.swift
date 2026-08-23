import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Errors raised by the completed-file OpenAI transcription backend.
public enum OpenAITranscriptionEngineError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case keychainFailure(String)
    case invalidAudioFile(String)
    case fileTooLarge(limitBytes: Int)
    case httpError(status: Int, message: String?)
    case responseDecodingFailed
    case network(URLError)
    case chunkingFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "An OpenAI API key is required for cloud transcription."
        case let .keychainFailure(message):
            return "Unable to read the OpenAI API key from Keychain: \(message)"
        case let .invalidAudioFile(name):
            return "The audio file could not be opened: \(name)."
        case let .fileTooLarge(limitBytes):
            return "The audio file exceeds the OpenAI upload safety limit of \(limitBytes / (1024 * 1024)) MB."
        case let .httpError(status, message):
            if let message, !message.isEmpty {
                return "OpenAI API error (status \(status)): \(message)"
            }
            return "OpenAI API request failed with status \(status)."
        case .responseDecodingFailed:
            return "Unable to decode the OpenAI transcription response."
        case let .network(error):
            return "Network error contacting OpenAI: \(error.localizedDescription)"
        case let .chunkingFailed(message):
            return "Unable to split the audio for OpenAI: \(message)"
        case .cancelled:
            return "OpenAI transcription was cancelled."
        }
    }
}

/// A chunk produced for a long recording. The default AVFoundation chunker
/// marks its files as temporary so the engine removes them after uploading.
public struct OpenAIAudioChunk: Sendable {
    public let fileURL: URL
    public let isTemporary: Bool
    public let cleanupDirectory: URL?

    public init(
        fileURL: URL,
        isTemporary: Bool = false,
        cleanupDirectory: URL? = nil
    ) {
        self.fileURL = fileURL
        self.isTemporary = isTemporary
        self.cleanupDirectory = cleanupDirectory
    }
}

/// Lets tests and future audio pipelines supply deterministic chunk files
/// without invoking AVAssetExportSession. Returning nil means the original
/// file is safe to upload as one request.
public protocol OpenAITranscriptionChunker: Sendable {
    func makeChunks(
        for fileURL: URL,
        safetyLimitBytes: Int,
        maximumChunkDuration: TimeInterval,
        overlap: TimeInterval
    ) async throws -> [OpenAIAudioChunk]?
}

/// Narrow filesystem seam used only for temporary artifact cleanup. Keeping
/// it separate from the chunker makes cleanup failures deterministic in unit
/// tests without replacing URLSession or AVFoundation.
public protocol OpenAITranscriptionFileSystem: Sendable {
    func removeItem(at url: URL) throws
}

public struct DefaultOpenAITranscriptionFileSystem: OpenAITranscriptionFileSystem {
    public init() {}

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Media-export seam for the AVFoundation chunker. The production exporter
/// uses AVAssetExportSession; tests can return deterministic files (including
/// an intentionally oversized first export) without relying on a codec.
public protocol OpenAITranscriptionChunkExporter: Sendable {
    func export(
        fileURL: URL,
        start: TimeInterval,
        duration: TimeInterval,
        outputURL: URL,
        fileLengthLimit: Int
    ) async throws
}

public final class AVFoundationOpenAITranscriptionChunkExporter: @unchecked Sendable, OpenAITranscriptionChunkExporter {
    public init() {}

    public func export(
        fileURL: URL,
        start: TimeInterval,
        duration: TimeInterval,
        outputURL: URL,
        fileLengthLimit: Int
    ) async throws {
        let asset = AVURLAsset(url: fileURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw OpenAITranscriptionEngineError.chunkingFailed("The M4A export session could not be created.")
        }
        let assetDuration = try await asset.load(.duration)
        let timescale: CMTimeScale = assetDuration.timescale == 0 ? 600 : assetDuration.timescale
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: timescale),
            duration: CMTime(seconds: duration, preferredTimescale: timescale)
        )
        exportSession.fileLengthLimit = Int64(fileLengthLimit)
        let box = AVFoundationOpenAITranscriptionChunker.ExportSessionBox(exportSession)
        do {
            try await withTaskCancellationHandler(operation: {
                try await box.value.export(to: outputURL, as: .m4a)
            }, onCancel: {
                box.value.cancelExport()
            })
        } catch is CancellationError {
            throw OpenAITranscriptionEngineError.cancelled
        } catch {
            if Task.isCancelled { throw OpenAITranscriptionEngineError.cancelled }
            throw error
        }
    }
}

/// Settings specific to the OpenAI file-upload backend. The 24 MiB ceiling
/// deliberately leaves one MiB below the API's documented 25 MB limit.
public struct OpenAITranscriptionConfiguration: Sendable {
    public var endpoint: URL
    public var retryCount: Int
    public var uploadSafetyLimitBytes: Int
    public var maximumChunkDuration: TimeInterval
    public var chunkOverlap: TimeInterval
    public var contextCharacterLimit: Int
    public var retryDelayNanoseconds: @Sendable (Int) -> UInt64

    public init(
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        retryCount: Int = 1,
        uploadSafetyLimitBytes: Int = 24 * 1024 * 1024,
        maximumChunkDuration: TimeInterval = 6 * 60,
        chunkOverlap: TimeInterval = 5,
        contextCharacterLimit: Int = 2_000,
        retryDelayNanoseconds: @escaping @Sendable (Int) -> UInt64 = { attempt in
            let seconds = min(pow(2.0, Double(attempt)), 8.0)
            return UInt64(seconds * 1_000_000_000)
        }
    ) {
        self.endpoint = endpoint
        self.retryCount = max(0, retryCount)
        self.uploadSafetyLimitBytes = max(1, uploadSafetyLimitBytes)
        self.maximumChunkDuration = max(1, maximumChunkDuration)
        self.chunkOverlap = max(0, min(chunkOverlap, self.maximumChunkDuration / 2))
        self.contextCharacterLimit = max(100, contextCharacterLimit)
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }
}

/// OpenAI's completed-file transcription implementation. It intentionally
/// does not open a realtime session: the selected gpt-transcribe workflow is
/// an upload made after capture has stopped.
public final class OpenAITranscriptionEngine: @unchecked Sendable, TranscriptionProvider {
    public static let model = "gpt-transcribe"
    public let strategy: RecordingTranscriptionStrategy = .fileAfterCapture

    private let session: URLSession
    private let apiKeyLoader: @Sendable () throws -> String?
    private let chunker: any OpenAITranscriptionChunker
    private let configuration: OpenAITranscriptionConfiguration
    private let sleep: @Sendable (UInt64) async throws -> Void
    fileprivate let fileSystem: any OpenAITranscriptionFileSystem
    fileprivate let diagnosticSink: any TranscriptionDiagnosticSink
    init(
        session: URLSession? = nil,
        apiKeyLoader: @escaping @Sendable () throws -> String? = {
            try OpenAIAPIKeyStore.shared.loadKey()
        },
        chunker: any OpenAITranscriptionChunker = AVFoundationOpenAITranscriptionChunker(),
        configuration: OpenAITranscriptionConfiguration = .init(),
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        fileSystem: any OpenAITranscriptionFileSystem = DefaultOpenAITranscriptionFileSystem(),
        diagnosticSink: any TranscriptionDiagnosticSink = LoggerTranscriptionDiagnosticSink.shared
    ) {
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.default
            sessionConfiguration.timeoutIntervalForRequest = 300
            sessionConfiguration.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: sessionConfiguration)
        }
        self.apiKeyLoader = apiKeyLoader
        self.chunker = chunker
        self.configuration = configuration
        self.sleep = sleep
        self.fileSystem = fileSystem
        self.diagnosticSink = diagnosticSink
    }

    /// Convenience initializer useful for integration tests and command-line
    /// callers that already have a key. The app uses the Keychain-backed
    /// initializer above.
    convenience init(
        apiKey: String,
        session: URLSession? = nil,
        chunker: any OpenAITranscriptionChunker = AVFoundationOpenAITranscriptionChunker(),
        configuration: OpenAITranscriptionConfiguration = .init(),
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        fileSystem: any OpenAITranscriptionFileSystem = DefaultOpenAITranscriptionFileSystem(),
        diagnosticSink: any TranscriptionDiagnosticSink = LoggerTranscriptionDiagnosticSink.shared
    ) {
        self.init(
            session: session,
            apiKeyLoader: { apiKey },
            chunker: chunker,
            configuration: configuration,
            sleep: sleep,
            fileSystem: fileSystem,
            diagnosticSink: diagnosticSink
        )
    }

    /// Public production initializer. Diagnostic and filesystem seams remain
    /// internal because they use app-private sink types; @testable provider
    /// tests use the designated initializer above when they need injection.
    public convenience init(
        apiKey: String,
        session: URLSession? = nil,
        chunker: any OpenAITranscriptionChunker = AVFoundationOpenAITranscriptionChunker(),
        configuration: OpenAITranscriptionConfiguration = .init(),
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.init(
            session: session,
            apiKeyLoader: { apiKey },
            chunker: chunker,
            configuration: configuration,
            sleep: sleep,
            fileSystem: DefaultOpenAITranscriptionFileSystem(),
            diagnosticSink: LoggerTranscriptionDiagnosticSink.shared
        )
    }

    /// Synchronous provider factory. It only captures immutable operation
    /// configuration; Keychain, export, retry, and network work begin in
    /// `value()`.
    public func makeFileOperation(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> any TranscriptionFileOperation {
        OpenAIFileTranscriptionOperation(
            session: session,
            apiKeyLoader: apiKeyLoader,
            chunker: chunker,
            configuration: configuration,
            sleep: sleep,
            fileSystem: fileSystem,
            diagnosticSink: diagnosticSink,
            fileURL: url,
            locale: locale,
            context: context,
            expectedTerms: expectedTerms
        )
    }

    public func makeLiveOperation(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> (any TranscriptionLiveOperation)? {
        _ = (locale, context, expectedTerms)
        return nil
    }

    // MARK: - Multipart and normalization helpers

    static func makeMultipartBody(
        fileURL: URL,
        boundary: String,
        locale: String?,
        prompt: String?,
        keywords: [String]
    ) throws -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").utf8))
            body.append(Data("\r\n".utf8))
        }

        func appendFile() throws {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            } catch {
                throw OpenAITranscriptionEngineError.invalidAudioFile(fileURL.lastPathComponent)
            }

            let rawFilename = fileURL.lastPathComponent
            let filename = rawFilename
                .replacingOccurrences(of: "\\", with: "_")
                .replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\r", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
            let mimeType = Self.mimeType(for: fileURL)

            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
            body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }

        appendField(name: "model", value: model)
        if let prompt, !prompt.isEmpty {
            appendField(name: "prompt", value: prompt)
        }
        for keyword in keywords {
            appendField(name: "keywords[]", value: keyword)
        }
        if let locale, !locale.isEmpty {
            appendField(name: "languages[]", value: locale)
        }
        appendField(name: "response_format", value: "json")
        try appendFile()
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    fileprivate static func isJSONContentType(_ value: String?) -> Bool {
        guard let value else { return true }
        let mimeType = value
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let mimeType else { return false }
        return mimeType == "application/json" || mimeType.hasSuffix("+json")
    }

    static func normalizedLanguageIdentifier(_ identifier: String) -> String? {
        let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let normalizedSeparators = raw.replacingOccurrences(of: "_", with: "-")
        let pieces = normalizedSeparators.split(separator: "-").map(String.init)
        guard let first = pieces.first, !first.isEmpty else { return nil }
        let base = first.lowercased()
        guard base != "auto", base != "und" else { return nil }

        if base == "zh", pieces.count > 1 {
            let region = pieces.dropFirst().first(where: { $0.count == 2 || $0.count == 3 })?.uppercased()
            let supported: Set<String> = ["CN", "TW", "HK"]
            if let region, supported.contains(region) {
                return "zh-\(region.lowercased())"
            }
        }
        return base
    }

    static func sanitizePrompt(_ prompt: String?) -> String? {
        guard let prompt else { return nil }
        let cleaned = replaceControlCharacters(in: prompt)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(4_000))
    }

    static func sanitizeKeywords(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for value in values {
            for line in value.components(separatedBy: .newlines) {
                let withoutBullet = line.replacingOccurrences(
                    of: "^\\s*(?:[-*•]|\\d+[.)])\\s*",
                    with: "",
                    options: .regularExpression
                )
                let withoutRejectedCharacters = withoutBullet
                    .components(separatedBy: CharacterSet(charactersIn: "<>"))
                    .joined(separator: " ")
                let cleaned = replaceControlCharacters(in: withoutRejectedCharacters)
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }

                let keyword = String(cleaned.prefix(200))
                let key = keyword.folding(
                    options: String.CompareOptions([.caseInsensitive, .diacriticInsensitive]),
                    locale: Locale.current
                )
                guard seen.insert(key).inserted else { continue }
                result.append(keyword)
                if result.count == 100 { return result }
            }
        }
        return result
    }

    private static func replaceControlCharacters(in text: String) -> String {
        text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
    }

    static func cleanTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mergeTranscript(_ current: String, _ next: String) -> String {
        let left = cleanTranscript(current)
        let right = cleanTranscript(next)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        let leftWords = left.split(separator: " ").map(String.init)
        let rightWords = right.split(separator: " ").map(String.init)
        let maximumOverlap = min(64, min(leftWords.count, rightWords.count))
        var overlap = 0

        if maximumOverlap > 0 {
            for count in stride(from: maximumOverlap, through: 1, by: -1) {
                let leftSuffix = leftWords.suffix(count).map(Self.canonicalWord)
                let rightPrefix = rightWords.prefix(count).map(Self.canonicalWord)
                if leftSuffix == rightPrefix {
                    overlap = count
                    break
                }
            }
        }

        let remainder = rightWords.dropFirst(overlap).joined(separator: " ")
        guard !remainder.isEmpty else { return left }
        return "\(left) \(remainder)"
    }

    private static func canonicalWord(_ word: String) -> String {
        word
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if let error = error as? OpenAITranscriptionEngineError {
            switch error {
            case let .httpError(status, _):
                return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
            case let .network(urlError):
                return shouldRetry(urlError)
            default:
                return false
            }
        }
        if let urlError = error as? URLError {
            return shouldRetry(urlError)
        }
        return false
    }

    private static func shouldRetry(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .secureConnectionFailed,
             .cannotLoadFromNetwork,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    fileprivate static func decodeAPIErrorMessage(_ data: Data) -> String? {
        if let response = try? JSONDecoder().decode(OpenAIAPIErrorResponse.self, from: data) {
            return response.error.message
        }
        return String(data: data, encoding: .utf8)
    }
}

/// One independently cancellable OpenAI upload. The handle owns every child
/// task and temporary artifact for the provider boundary.
private final class OpenAIFileTranscriptionOperation: @unchecked Sendable, TranscriptionFileOperation {
    let events: AsyncStream<TranscriptionOperationEvent>

    private let eventContinuation: AsyncStream<TranscriptionOperationEvent>.Continuation
    private let session: URLSession
    private let apiKeyLoader: @Sendable () throws -> String?
    private let chunker: any OpenAITranscriptionChunker
    private let configuration: OpenAITranscriptionConfiguration
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let fileSystem: any OpenAITranscriptionFileSystem
    private let diagnosticSink: any TranscriptionDiagnosticSink
    private let fileURL: URL
    private let locale: Locale
    private let context: String?
    private let expectedTerms: [String]
    private let operationToken = SessionOperationToken()
    private let stateLock = NSLock()
    private var workTask: Task<Transcript, Error>?
    private var requestTask: Task<(Data, URLResponse), Error>?
    private var delayTask: Task<Void, Error>?
    private var cancelled = false
    private var eventsFinished = false

    init(
        session: URLSession,
        apiKeyLoader: @escaping @Sendable () throws -> String?,
        chunker: any OpenAITranscriptionChunker,
        configuration: OpenAITranscriptionConfiguration,
        sleep: @escaping @Sendable (UInt64) async throws -> Void,
        fileSystem: any OpenAITranscriptionFileSystem,
        diagnosticSink: any TranscriptionDiagnosticSink,
        fileURL: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) {
        var continuation: AsyncStream<TranscriptionOperationEvent>.Continuation?
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation!
        self.session = session
        self.apiKeyLoader = apiKeyLoader
        self.chunker = chunker
        self.configuration = configuration
        self.sleep = sleep
        self.fileSystem = fileSystem
        self.diagnosticSink = diagnosticSink
        self.fileURL = fileURL
        self.locale = locale
        self.context = context
        self.expectedTerms = expectedTerms
        self.eventContinuation.onTermination = { [weak self] _ in
            self?.requestCancel()
        }
    }

    func value() async throws -> Transcript {
        let task = makeWorkTask()
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            self.requestCancel()
        })
    }

    func cancelAndWait() async {
        let task = requestCancelAndReturnTask()
        _ = try? await task?.value
    }

    /// Synchronous cancellation request used by the operation's termination
    /// callback; `cancelAndWait()` remains the public quiescence boundary.
    func requestCancel() {
        _ = requestCancelAndReturnTask()
    }

    @discardableResult
    private func requestCancelAndReturnTask() -> Task<Transcript, Error>? {
        let values: (Task<Transcript, Error>?, Task<(Data, URLResponse), Error>?, Task<Void, Error>?) = stateLock.withLock {
            cancelled = true
            return (workTask, requestTask, delayTask)
        }
        values.0?.cancel()
        values.1?.cancel()
        values.2?.cancel()
        return values.0
    }

    private func makeWorkTask() -> Task<Transcript, Error> {
        stateLock.lock()
        if let workTask {
            stateLock.unlock()
            return workTask
        }
        if cancelled {
            let task = Task<Transcript, Error> { throw OpenAITranscriptionEngineError.cancelled }
            workTask = task
            stateLock.unlock()
            return task
        }
        let task = Task { [self] in
            do {
                let transcript = try await run()
                recordDiagnostic(phase: .transcribing, outcome: .completed)
                finishEvents()
                return transcript
            } catch is CancellationError {
                recordDiagnostic(phase: .cancelling, outcome: .cancelled)
                finishEvents()
                throw OpenAITranscriptionEngineError.cancelled
            } catch let error as OpenAITranscriptionEngineError {
                recordDiagnostic(
                    phase: error == .cancelled ? .cancelling : .transcribing,
                    outcome: error == .cancelled ? .cancelled : .failed
                )
                finishEvents()
                throw error
            } catch {
                if isCancelled() || Task.isCancelled {
                    recordDiagnostic(phase: .cancelling, outcome: .cancelled)
                    finishEvents()
                    throw OpenAITranscriptionEngineError.cancelled
                }
                recordDiagnostic(phase: .transcribing, outcome: .failed)
                finishEvents()
                throw error
            }
        }
        workTask = task
        stateLock.unlock()
        return task
    }

    private func run() async throws -> Transcript {
        try checkCancellation()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw OpenAITranscriptionEngineError.invalidAudioFile(fileURL.lastPathComponent)
        }

        emit(.preparing)
        let apiKey = try loadAPIKey()
        let prompt = OpenAITranscriptionEngine.sanitizePrompt(context)
        let keywords = OpenAITranscriptionEngine.sanitizeKeywords(expectedTerms)
        let language = OpenAITranscriptionEngine.normalizedLanguageIdentifier(locale.identifier)

        emit(.exporting)
        let chunks = try await chunker.makeChunks(
            for: fileURL,
            safetyLimitBytes: configuration.uploadSafetyLimitBytes,
            maximumChunkDuration: configuration.maximumChunkDuration,
            overlap: configuration.chunkOverlap
        )
        defer { cleanup(chunks ?? []) }

        let text: String
        if let chunks, !chunks.isEmpty {
            text = try await transcribeChunks(
                chunks,
                locale: language,
                prompt: prompt,
                keywords: keywords,
                apiKey: apiKey
            )
        } else {
            let size = try fileSize(of: fileURL)
            guard size <= configuration.uploadSafetyLimitBytes else {
                throw OpenAITranscriptionEngineError.fileTooLarge(
                    limitBytes: configuration.uploadSafetyLimitBytes
                )
            }
            emit(.uploading(part: 1, total: 1, fraction: 0))
            text = try await transcribeFileWithRetries(
                fileURL,
                locale: language,
                prompt: prompt,
                keywords: keywords,
                apiKey: apiKey,
                part: 1,
                total: 1
            )
            emit(.uploading(part: 1, total: 1, fraction: 1))
        }

        try checkCancellation()
        emit(.transcribing)
        return Transcript(
            text: OpenAITranscriptionEngine.cleanTranscript(text),
            locale: locale,
            segments: []
        )
    }

    private func transcribeChunks(
        _ chunks: [OpenAIAudioChunk],
        locale: String?,
        prompt: String?,
        keywords: [String],
        apiKey: String
    ) async throws -> String {
        var combined = ""
        for (offset, chunk) in chunks.enumerated() {
            try checkCancellation()
            let chunkSize = try fileSize(of: chunk.fileURL)
            guard chunkSize <= configuration.uploadSafetyLimitBytes else {
                throw OpenAITranscriptionEngineError.fileTooLarge(
                    limitBytes: configuration.uploadSafetyLimitBytes
                )
            }
            let contextualPrompt: String?
            if combined.isEmpty {
                contextualPrompt = prompt
            } else {
                let tail = String(combined.suffix(configuration.contextCharacterLimit))
                contextualPrompt = OpenAITranscriptionEngine.sanitizePrompt(
                    [prompt, "Previous transcript context: \(tail)"].compactMap { $0 }.joined(separator: "\n")
                )
            }

            let part = offset + 1
            emit(.uploading(part: part, total: chunks.count, fraction: 0))
            let chunkText = try await transcribeFileWithRetries(
                chunk.fileURL,
                locale: locale,
                prompt: contextualPrompt,
                keywords: keywords,
                apiKey: apiKey,
                part: part,
                total: chunks.count
            )
            emit(.uploading(part: part, total: chunks.count, fraction: 1))
            combined = OpenAITranscriptionEngine.mergeTranscript(
                combined,
                OpenAITranscriptionEngine.cleanTranscript(chunkText)
            )
        }
        return combined
    }

    private func transcribeFileWithRetries(
        _ fileURL: URL,
        locale: String?,
        prompt: String?,
        keywords: [String],
        apiKey: String,
        part: Int,
        total: Int
    ) async throws -> String {
        var attempt = 0
        while true {
            try checkCancellation()
            do {
                return try await performRequest(
                    fileURL: fileURL,
                    locale: locale,
                    prompt: prompt,
                    keywords: keywords,
                    apiKey: apiKey
                )
            } catch {
                if let openAIError = error as? OpenAITranscriptionEngineError,
                   openAIError == .cancelled {
                    throw openAIError
                }
                guard attempt < configuration.retryCount, shouldRetry(error) else {
                    throw error
                }
                attempt += 1
                emit(.retrying(attempt: attempt, maximum: configuration.retryCount))
                try checkCancellation()
                let delay = Task<Void, Error> {
                    try await sleep(configuration.retryDelayNanoseconds(attempt))
                }
                registerDelay(delay)
                defer { clearDelay(delay) }
                try await withTaskCancellationHandler(operation: {
                    try await delay.value
                }, onCancel: {
                    delay.cancel()
                })
                _ = (part, total)
            }
        }
    }

    private func performRequest(
        fileURL: URL,
        locale: String?,
        prompt: String?,
        keywords: [String],
        apiKey: String
    ) async throws -> String {
        try checkCancellation()
        let boundary = "OpenSuperWhisper-\(UUID().uuidString)"
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try OpenAITranscriptionEngine.makeMultipartBody(
            fileURL: fileURL,
            boundary: boundary,
            locale: locale,
            prompt: prompt,
            keywords: keywords
        )

        let requestTask = Task<(Data, URLResponse), Error> {
            do { return try await session.data(for: request) }
            catch let error as URLError { throw OpenAITranscriptionEngineError.network(error) }
        }
        registerRequest(requestTask)
        defer { clearRequest(requestTask) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withTaskCancellationHandler(operation: {
                try await requestTask.value
            }, onCancel: {
                requestTask.cancel()
            })
        } catch is CancellationError {
            throw OpenAITranscriptionEngineError.cancelled
        } catch let error as OpenAITranscriptionEngineError {
            if case let .network(urlError) = error, urlError.code == .cancelled {
                throw OpenAITranscriptionEngineError.cancelled
            }
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscriptionEngineError.responseDecodingFailed
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAITranscriptionEngineError.httpError(
                status: httpResponse.statusCode,
                message: OpenAITranscriptionEngine.decodeAPIErrorMessage(data)
            )
        }
        guard OpenAITranscriptionEngine.isJSONContentType(httpResponse.value(forHTTPHeaderField: "Content-Type")),
              let decoded = try? JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data) else {
            throw OpenAITranscriptionEngineError.responseDecodingFailed
        }
        return decoded.text
    }

    private func loadAPIKey() throws -> String {
        let key: String?
        do { key = try apiKeyLoader() }
        catch { throw OpenAITranscriptionEngineError.keychainFailure(error.localizedDescription) }
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw OpenAITranscriptionEngineError.missingAPIKey }
        return trimmed
    }

    private func fileSize(of url: URL) throws -> Int {
        do { return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        catch { throw OpenAITranscriptionEngineError.invalidAudioFile(url.lastPathComponent) }
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let error = error as? OpenAITranscriptionEngineError {
            switch error {
            case let .httpError(status, _):
                return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
            case let .network(urlError): return shouldRetry(urlError)
            default: return false
            }
        }
        if let urlError = error as? URLError { return shouldRetry(urlError) }
        return false
    }

    private func shouldRetry(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .secureConnectionFailed,
             .cannotLoadFromNetwork, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled || isCancelled() { throw OpenAITranscriptionEngineError.cancelled }
    }

    private func isCancelled() -> Bool { stateLock.withLock { cancelled } }

    private func registerRequest(_ request: Task<(Data, URLResponse), Error>) {
        let cancel = stateLock.withLock { () -> Bool in
            requestTask = request
            return cancelled
        }
        if cancel { request.cancel() }
    }

    private func clearRequest(_ request: Task<(Data, URLResponse), Error>) {
        _ = request
        stateLock.withLock { requestTask = nil }
    }

    private func registerDelay(_ delay: Task<Void, Error>) {
        let cancel = stateLock.withLock { () -> Bool in
            delayTask = delay
            return cancelled
        }
        if cancel { delay.cancel() }
    }

    private func clearDelay(_ delay: Task<Void, Error>) {
        _ = delay
        stateLock.withLock { delayTask = nil }
    }

    private func emit(_ phase: TranscriptionOperationPhase) {
        eventContinuation.yield(TranscriptionOperationEvent(phase: phase))
        diagnosticSink.record(
            TranscriptionDiagnosticEvent(
                operationToken: operationToken,
                source: .importedFile,
                backend: .openAI,
                phase: phase,
                chunkIndex: phase.uploadProgress?.part,
                outcome: .progressed
            )
        )
    }

    private func cleanup(_ chunks: [OpenAIAudioChunk]) {
        var files = Set<URL>()
        var directories = Set<URL>()
        for chunk in chunks {
            if chunk.isTemporary { files.insert(chunk.fileURL) }
            if let directory = chunk.cleanupDirectory { directories.insert(directory) }
        }
        for file in files {
            do { try fileSystem.removeItem(at: file) }
            catch { diagnoseCleanupFailure() }
        }
        for directory in directories {
            do { try fileSystem.removeItem(at: directory) }
            catch { diagnoseCleanupFailure() }
        }
    }

    private func diagnoseCleanupFailure() {
        recordDiagnostic(phase: .exporting, outcome: .cleanupFailed)
    }

    private func recordDiagnostic(
        phase: TranscriptionOperationPhase,
        outcome: TranscriptionDiagnosticOutcome
    ) {
        diagnosticSink.record(
            TranscriptionDiagnosticEvent(
                operationToken: operationToken,
                source: .importedFile,
                backend: .openAI,
                phase: phase,
                outcome: outcome
            )
        )
    }

    private func finishEvents() {
        stateLock.lock()
        guard !eventsFinished else {
            stateLock.unlock()
            return
        }
        eventsFinished = true
        stateLock.unlock()
        eventContinuation.finish()
    }
}

private struct OpenAITranscriptionResponse: Decodable {
    let text: String
}

private struct OpenAIAPIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError
}

/// AVFoundation-backed chunking used by the app. It exports short overlapping
/// M4A files so each upload remains under the safety ceiling.
public final class AVFoundationOpenAITranscriptionChunker: @unchecked Sendable, OpenAITranscriptionChunker {
    private let exporter: any OpenAITranscriptionChunkExporter

    public init(exporter: any OpenAITranscriptionChunkExporter = AVFoundationOpenAITranscriptionChunkExporter()) {
        self.exporter = exporter
    }

    public func makeChunks(
        for fileURL: URL,
        safetyLimitBytes: Int,
        maximumChunkDuration: TimeInterval,
        overlap: TimeInterval
    ) async throws -> [OpenAIAudioChunk]? {
        let inputSize: Int
        do {
            inputSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw OpenAITranscriptionEngineError.invalidAudioFile(fileURL.lastPathComponent)
        }

        let asset = AVURLAsset(url: fileURL)
        let totalSeconds: Double
        do {
            totalSeconds = CMTimeGetSeconds(try await asset.load(.duration))
        } catch {
            if inputSize > safetyLimitBytes {
                throw OpenAITranscriptionEngineError.chunkingFailed("The file duration could not be read.")
            }
            return nil
        }

        let durationIsUsable = totalSeconds.isFinite && totalSeconds > 0
        let needsChunking = inputSize > safetyLimitBytes ||
            (durationIsUsable && totalSeconds > maximumChunkDuration)
        guard needsChunking else { return nil }
        guard durationIsUsable else {
            throw OpenAITranscriptionEngineError.chunkingFailed("The file has no readable duration.")
        }

        let targetBytes = max(1, safetyLimitBytes - 512 * 1024)
        let bitrate: Double
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            if let track = tracks.first {
                let estimated = Double(try await track.load(.estimatedDataRate))
                bitrate = estimated.isFinite && estimated > 0 ? estimated : 64_000
            } else {
                bitrate = 64_000
            }
        } catch {
            bitrate = 64_000
        }

        let secondsBySize = Double(targetBytes * 8) / bitrate
        let outputDuration = min(
            maximumChunkDuration,
            secondsBySize.isFinite && secondsBySize > 0 ? secondsBySize : maximumChunkDuration
        )
        let layout = Self.chunkLayout(outputDuration: outputDuration, overlap: overlap)
        let coreDuration = layout.coreDuration
        let effectiveOverlap = layout.overlap
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisper-OpenAI-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw OpenAITranscriptionEngineError.chunkingFailed("Unable to create a temporary chunk directory.")
        }

        var chunks: [OpenAIAudioChunk] = []
        var coreStart: TimeInterval = 0

        do {
            while coreStart < totalSeconds {
                try Task.checkCancellation()
                let coreEnd = min(totalSeconds, coreStart + coreDuration)
                let start = coreStart == 0 ? 0 : max(0, coreStart - effectiveOverlap)
                let end = coreEnd >= totalSeconds
                    ? totalSeconds
                    : min(totalSeconds, coreEnd + effectiveOverlap)
                let duration = max(0, end - start)
                guard duration > 0 else { break }

                let outputURLs = try await exportWithSubdivision(
                    asset: asset,
                    fileURL: fileURL,
                    start: start,
                    duration: duration,
                    directory: directory,
                    outputIndex: chunks.count,
                    fileLengthLimit: safetyLimitBytes,
                    level: 0
                )
                for outputURL in outputURLs {
                    chunks.append(
                        OpenAIAudioChunk(
                            fileURL: outputURL,
                            isTemporary: true,
                            cleanupDirectory: directory
                        )
                    )
                }
                coreStart = coreEnd
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if error is CancellationError {
                throw OpenAITranscriptionEngineError.cancelled
            }
            throw error
        }

        guard !chunks.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            throw OpenAITranscriptionEngineError.chunkingFailed("No audio chunks were produced.")
        }
        return chunks
    }

    static func chunkLayout(
        outputDuration: TimeInterval,
        overlap: TimeInterval
    ) -> (coreDuration: TimeInterval, overlap: TimeInterval) {
        let safeOutputDuration = max(1, outputDuration)
        let maximumOverlap = max(0, (safeOutputDuration - 1) / 2)
        let effectiveOverlap = min(max(0, overlap), maximumOverlap)
        return (
            coreDuration: safeOutputDuration - (2 * effectiveOverlap),
            overlap: effectiveOverlap
        )
    }

    /// Deterministic subdivision policy shared by the exporter and tests. A
    /// candidate is split at most eight times and is never split into pieces
    /// shorter than five seconds solely to satisfy an upload ceiling.
    public static func subdivisionDurations(
        duration: TimeInterval,
        maximumLevels: Int = 8,
        minimumDuration: TimeInterval = 5
    ) -> [TimeInterval] {
        let safeDuration = max(0, duration)
        guard safeDuration > 0 else { return [] }
        let levels = max(0, maximumLevels)
        let minimum = max(0.001, minimumDuration)
        var count = 1
        for _ in 0..<levels {
            if safeDuration / Double(count * 2) < minimum { break }
            count *= 2
        }
        let part = safeDuration / Double(count)
        return Array(repeating: part, count: count)
    }

    private func exportWithSubdivision(
        asset: AVAsset,
        fileURL: URL,
        start: TimeInterval,
        duration: TimeInterval,
        directory: URL,
        outputIndex: Int,
        fileLengthLimit: Int,
        level: Int
    ) async throws -> [URL] {
        try Task.checkCancellation()
        let outputURL = directory.appendingPathComponent("chunk-\(outputIndex)-\(level).m4a")
        do {
            try await exporter.export(
                fileURL: fileURL,
                start: start,
                duration: duration,
                outputURL: outputURL,
                fileLengthLimit: fileLengthLimit
            )
            let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= fileLengthLimit else {
                throw OpenAITranscriptionEngineError.fileTooLarge(limitBytes: fileLengthLimit)
            }
            return [outputURL]
        } catch is CancellationError {
            throw OpenAITranscriptionEngineError.cancelled
        } catch {
            if Task.isCancelled {
                throw OpenAITranscriptionEngineError.cancelled
            }
            let oversized = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
            let isSizeFailure = oversized > fileLengthLimit ||
                (error as? OpenAITranscriptionEngineError).map {
                    if case .fileTooLarge = $0 { return true }
                    return false
                } == true
            let half = duration / 2
            guard isSizeFailure, level < 8, half >= 5 else {
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
            try? FileManager.default.removeItem(at: outputURL)
            let first = try await exportWithSubdivision(
                asset: asset,
                fileURL: fileURL,
                start: start,
                duration: half,
                directory: directory,
                outputIndex: outputIndex * 2,
                fileLengthLimit: fileLengthLimit,
                level: level + 1
            )
            let second = try await exportWithSubdivision(
                asset: asset,
                fileURL: fileURL,
                start: start + half,
                duration: duration - half,
                directory: directory,
                outputIndex: outputIndex * 2 + 1,
                fileLengthLimit: fileLengthLimit,
                level: level + 1
            )
            return first + second
        }
    }

    fileprivate final class ExportSessionBox: @unchecked Sendable {
        let value: AVAssetExportSession

        init(_ value: AVAssetExportSession) {
            self.value = value
        }
    }
}
