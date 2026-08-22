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
    case liveTranscriptionUnavailable
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
        case .liveTranscriptionUnavailable:
            return "OpenAI transcription starts after recording stops."
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
public final class OpenAITranscriptionEngine: @unchecked Sendable, TranscriptionEngine {
    public static let model = "gpt-transcribe"

    private let session: URLSession
    private let apiKeyLoader: @Sendable () throws -> String?
    private let chunker: any OpenAITranscriptionChunker
    private let configuration: OpenAITranscriptionConfiguration
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let stateLock = NSLock()
    private var activeRequest: Task<(Data, URLResponse), Error>?
    private var cancelled = false

    init(
        session: URLSession? = nil,
        apiKeyLoader: @escaping @Sendable () throws -> String? = {
            try OpenAIAPIKeyStore.shared.loadKey()
        },
        chunker: any OpenAITranscriptionChunker = AVFoundationOpenAITranscriptionChunker(),
        configuration: OpenAITranscriptionConfiguration = .init(),
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
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
    }

    /// Convenience initializer useful for integration tests and command-line
    /// callers that already have a key. The app uses the Keychain-backed
    /// initializer above.
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
            sleep: sleep
        )
    }

    public func prepare(locale: Locale) async throws {
        try checkCancellation()
        // There is no model or language asset to download for OpenAI. Keeping
        // preparation as a cancellation-aware no-op lets the controller use
        // the same lifecycle for local and cloud engines.
        _ = locale
    }

    public func startSession(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> any LiveTranscriptionSession {
        _ = (locale, context, expectedTerms)
        throw OpenAITranscriptionEngineError.liveTranscriptionUnavailable
    }

    public func transcribeFile(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> Transcript {
        beginOperation()

        do {
            try checkCancellation()
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw OpenAITranscriptionEngineError.invalidAudioFile(url.lastPathComponent)
            }

            let apiKey = try loadAPIKey()
            let prompt = Self.sanitizePrompt(context)
            let keywords = Self.sanitizeKeywords(expectedTerms)
            let language = Self.normalizedLanguageIdentifier(locale.identifier)

            let chunks = try await chunker.makeChunks(
                for: url,
                safetyLimitBytes: configuration.uploadSafetyLimitBytes,
                maximumChunkDuration: configuration.maximumChunkDuration,
                overlap: configuration.chunkOverlap
            )

            let result: String
            if let chunks, !chunks.isEmpty {
                result = try await transcribeChunks(
                    chunks,
                    locale: language,
                    prompt: prompt,
                    keywords: keywords,
                    apiKey: apiKey
                )
            } else {
                let fileSize = try fileSize(of: url)
                guard fileSize <= configuration.uploadSafetyLimitBytes else {
                    throw OpenAITranscriptionEngineError.fileTooLarge(
                        limitBytes: configuration.uploadSafetyLimitBytes
                    )
                }
                result = try await transcribeFileWithRetries(
                    url,
                    locale: language,
                    prompt: prompt,
                    keywords: keywords,
                    apiKey: apiKey
                )
            }

            try checkCancellation()
            return Transcript(text: Self.cleanTranscript(result), locale: locale, segments: [])
        } catch is CancellationError {
            throw OpenAITranscriptionEngineError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw OpenAITranscriptionEngineError.cancelled
        } catch let error as OpenAITranscriptionEngineError {
            if case let .network(urlError) = error, urlError.code == .cancelled {
                throw OpenAITranscriptionEngineError.cancelled
            }
            throw error
        } catch {
            if isCancelled() || Task.isCancelled {
                throw OpenAITranscriptionEngineError.cancelled
            }
            throw error
        }
    }

    /// Cancels the active upload. URLSession also observes cancellation of the
    /// caller's task, so both controller-driven and task-driven cancellation
    /// stop network work promptly.
    public func cancel() {
        let request = withStateLock {
            cancelled = true
            return activeRequest
        }
        request?.cancel()
    }

    // MARK: - Request lifecycle

    private func beginOperation() {
        withStateLock {
            cancelled = false
            activeRequest = nil
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled || isCancelled() {
            throw OpenAITranscriptionEngineError.cancelled
        }
    }

    private func isCancelled() -> Bool {
        withStateLock { cancelled }
    }

    private func loadAPIKey() throws -> String {
        let key: String?
        do {
            key = try apiKeyLoader()
        } catch {
            throw OpenAITranscriptionEngineError.keychainFailure(error.localizedDescription)
        }

        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw OpenAITranscriptionEngineError.missingAPIKey
        }
        return trimmed
    }

    private func fileSize(of url: URL) throws -> Int {
        do {
            return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw OpenAITranscriptionEngineError.invalidAudioFile(url.lastPathComponent)
        }
    }

    private func transcribeChunks(
        _ chunks: [OpenAIAudioChunk],
        locale: String?,
        prompt: String?,
        keywords: [String],
        apiKey: String
    ) async throws -> String {
        var combined = ""
        let temporaryFiles = chunks.filter(\.isTemporary).map(\.fileURL)
        let cleanupDirectories = Set(chunks.compactMap(\.cleanupDirectory))

        defer {
            for fileURL in temporaryFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
            for directoryURL in cleanupDirectories {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        for chunk in chunks {
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
                let contextLine = "Previous transcript context: \(tail)"
                contextualPrompt = Self.sanitizePrompt(
                    [prompt, contextLine].compactMap { $0 }.joined(separator: "\n")
                )
            }

            let chunkText = try await transcribeFileWithRetries(
                chunk.fileURL,
                locale: locale,
                prompt: contextualPrompt,
                keywords: keywords,
                apiKey: apiKey
            )
            combined = Self.mergeTranscript(combined, Self.cleanTranscript(chunkText))
        }

        return combined
    }

    private func transcribeFileWithRetries(
        _ fileURL: URL,
        locale: String?,
        prompt: String?,
        keywords: [String],
        apiKey: String
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
                if let engineError = error as? OpenAITranscriptionEngineError,
                   engineError == .cancelled {
                    throw error
                }

                guard attempt < max(0, configuration.retryCount), Self.shouldRetry(error) else {
                    throw error
                }

                attempt += 1
                try checkCancellation()
                try await sleep(configuration.retryDelayNanoseconds(attempt))
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
        let boundary = "OpenSuperWhisper-\(UUID().uuidString)"
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeMultipartBody(
            fileURL: fileURL,
            boundary: boundary,
            locale: locale,
            prompt: prompt,
            keywords: keywords
        )

        let requestTask = Task<(Data, URLResponse), Error> {
            do {
                return try await session.data(for: request)
            } catch let error as URLError {
                throw OpenAITranscriptionEngineError.network(error)
            }
        }
        registerActiveRequest(requestTask)
        defer { withStateLock { activeRequest = nil } }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await withTaskCancellationHandler(operation: {
                try await requestTask.value
            }, onCancel: {
                requestTask.cancel()
            })
        } catch is CancellationError {
            throw OpenAITranscriptionEngineError.cancelled
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscriptionEngineError.responseDecodingFailed
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.decodeAPIErrorMessage(data)
            throw OpenAITranscriptionEngineError.httpError(
                status: httpResponse.statusCode,
                message: message
            )
        }

        guard Self.isJSONContentType(httpResponse.value(forHTTPHeaderField: "Content-Type")) else {
            throw OpenAITranscriptionEngineError.responseDecodingFailed
        }
        guard let decoded = try? JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data) else {
            throw OpenAITranscriptionEngineError.responseDecodingFailed
        }
        return decoded.text
    }

    /// Registers a request while holding the same lock used by `cancel()`.
    /// If cancellation won the race before registration, cancel the newly
    /// registered task immediately instead of leaving it orphaned.
    private func registerActiveRequest(_ request: Task<(Data, URLResponse), Error>) {
        let shouldCancel = withStateLock {
            activeRequest = request
            return cancelled
        }
        if shouldCancel {
            request.cancel()
        }
    }

    private static func isJSONContentType(_ value: String?) -> Bool {
        // Content-Type is advisory on responses from intermediaries. When it
        // is omitted, still require the body to decode as the expected JSON
        // shape below; an HTML/proxy page therefore cannot slip through.
        guard let value else { return true }
        let mimeType = value
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let mimeType else { return false }
        return mimeType == "application/json" || mimeType.hasSuffix("+json")
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
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

    private static func decodeAPIErrorMessage(_ data: Data) -> String? {
        if let response = try? JSONDecoder().decode(OpenAIAPIErrorResponse.self, from: data) {
            return response.error.message
        }
        return String(data: data, encoding: .utf8)
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
    public init() {}

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

                let outputURL = directory.appendingPathComponent("chunk-\(chunks.count).m4a")
                try await export(
                    asset: asset,
                    start: start,
                    duration: duration,
                    outputURL: outputURL,
                    fileLengthLimit: safetyLimitBytes
                )

                let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= safetyLimitBytes else {
                    throw OpenAITranscriptionEngineError.fileTooLarge(limitBytes: safetyLimitBytes)
                }
                chunks.append(
                    OpenAIAudioChunk(
                        fileURL: outputURL,
                        isTemporary: true,
                        cleanupDirectory: directory
                    )
                )
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

    private func export(
        asset: AVAsset,
        start: TimeInterval,
        duration: TimeInterval,
        outputURL: URL,
        fileLengthLimit: Int
    ) async throws {
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

        let box = ExportSessionBox(exportSession)
        do {
            try await withTaskCancellationHandler(operation: {
                try await box.value.export(to: outputURL, as: .m4a)
            }, onCancel: {
                box.value.cancelExport()
            })
        } catch is CancellationError {
            throw OpenAITranscriptionEngineError.cancelled
        } catch {
            if Task.isCancelled {
                throw OpenAITranscriptionEngineError.cancelled
            }
            throw error
        }
    }

    private final class ExportSessionBox: @unchecked Sendable {
        let value: AVAssetExportSession

        init(_ value: AVAssetExportSession) {
            self.value = value
        }
    }
}
