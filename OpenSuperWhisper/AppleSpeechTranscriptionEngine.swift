@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech

private final class SendablePCMBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

private final class ConverterInputState: @unchecked Sendable {
    var supplied = false
}

/// Thin seam around SpeechAnalyzer/SpeechTranscriber. The provider operation
/// owns the handle and cancellation; this driver owns only OS Speech objects.
public protocol AppleSpeechLiveSessionDriver: AnyObject, Sendable {
    var updates: AsyncStream<TranscriptUpdate> { get }

    func start() async throws
    func append(buffer: AVAudioPCMBuffer) async throws
    func finish() async throws -> Transcript
    func cancelAndWait() async

    /// A driver returns a typed failure when its analyzer/result stream dies
    /// before `finish()`. The default keeps simple test doubles source
    /// compatible while production drivers override it.
    func terminalError() async -> CoreTranscriptionError?
}

public extension AppleSpeechLiveSessionDriver {
    func start() async throws {}
    func terminalError() async -> CoreTranscriptionError? { nil }
}

public protocol AppleSpeechLiveSessionDriverFactory: Sendable {
    func makeLiveSession(
        locale: Locale,
        context: String?,
        expectedTerms: [String],
        analyzerPriority: TaskPriority
    ) async throws -> any AppleSpeechLiveSessionDriver
}

// Compatibility spellings remain available through the pre-1.0 migration
// window; the operation-handle protocols above are the canonical declarations.
public typealias AppleSpeechLiveDriver = AppleSpeechLiveSessionDriver
public typealias AppleSpeechLiveDriverFactory = AppleSpeechLiveSessionDriverFactory

/// On-device transcription backed by macOS 26's SpeechAnalyzer and
/// SpeechTranscriber. The analyzer retains its model for the process lifetime
/// and the asset manager keeps the selected locale reserved between sessions.
public final class AppleSpeechTranscriptionEngine: TranscriptionProvider, @unchecked Sendable {
    public let strategy: RecordingTranscriptionStrategy = .live
    private let configuredAssetManager: (any AppleSpeechAssetManaging)?
    private let analyzerPriority: TaskPriority
    private let liveSessionFactory: any AppleSpeechLiveSessionDriverFactory
    private let diagnosticSink: any TranscriptionDiagnosticSink

    init(
        assetManager: (any AppleSpeechAssetManaging)? = nil,
        analyzerPriority: TaskPriority = .userInitiated,
        liveSessionFactory: (any AppleSpeechLiveSessionDriverFactory)? = nil,
        diagnosticSink: any TranscriptionDiagnosticSink = LoggerTranscriptionDiagnosticSink.shared
    ) {
        self.configuredAssetManager = assetManager
        self.analyzerPriority = analyzerPriority
        self.liveSessionFactory = liveSessionFactory ?? AppleSpeechSystemLiveSessionDriverFactory(
            assetManager: assetManager,
            analyzerPriority: analyzerPriority
        )
        self.diagnosticSink = diagnosticSink
    }

    /// Public production initializer. The diagnostics seam is internal so
    /// provider tests can inject it without exposing app-private backend
    /// preference types as API surface.
    public convenience init(
        assetManager: (any AppleSpeechAssetManaging)? = nil,
        analyzerPriority: TaskPriority = .userInitiated,
        liveSessionFactory: (any AppleSpeechLiveSessionDriverFactory)? = nil
    ) {
        self.init(
            assetManager: assetManager,
            analyzerPriority: analyzerPriority,
            liveSessionFactory: liveSessionFactory,
            diagnosticSink: LoggerTranscriptionDiagnosticSink.shared
        )
    }

    /// Synchronously reserves a live handle. Asset preparation and Speech
    /// analyzer construction start only when the caller awaits `start()`.
    public func makeLiveOperation(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> (any TranscriptionLiveOperation)? {
        AppleSpeechLiveTranscriptionOperation(
            factory: liveSessionFactory,
            locale: locale,
            context: context,
            expectedTerms: expectedTerms,
            analyzerPriority: analyzerPriority,
            diagnosticSink: diagnosticSink
        )
    }

    public func makeFileOperation(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> any TranscriptionFileOperation {
        AppleSpeechFileTranscriptionOperation { [self] in
            try await transcribeFileValue(
                at: url,
                locale: locale,
                context: context,
                expectedTerms: expectedTerms
            )
        }
    }

    private func transcribeFileValue(
        at url: URL,
        locale: Locale,
        context: String? = nil,
        expectedTerms: [String] = []
    ) async throws -> Transcript {
        let resolvedLocale = try await prepareAndResolve(locale: locale)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CoreTranscriptionError.invalidAudioFile(url)
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw CoreTranscriptionError.invalidAudioFile(url)
        }

        let transcriber = Self.makeTranscriber(locale: resolvedLocale)
        let analysisContext = Self.makeAnalysisContext(context: context, expectedTerms: expectedTerms)
        let options = SpeechAnalyzer.Options(priority: analyzerPriority, modelRetention: .processLifetime)
        var analyzerForCancellation: SpeechAnalyzer?
        var resultTaskForCancellation: Task<Transcript, Error>?

        do {
            // The file initializer selects/validates a compatible format and
            // lets SpeechAnalyzer handle the complete post-recording stream.
            let analyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile,
                modules: [transcriber],
                options: options,
                analysisContext: analysisContext,
                finishAfterFile: true
            )
            analyzerForCancellation = analyzer
            let resultTask = Self.collectResults(from: transcriber, locale: resolvedLocale)
            resultTaskForCancellation = resultTask
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await resultTask.value
        } catch is CancellationError {
            resultTaskForCancellation?.cancel()
            await analyzerForCancellation?.cancelAndFinishNow()
            throw CoreTranscriptionError.cancelled
        } catch let error as CoreTranscriptionError {
            resultTaskForCancellation?.cancel()
            await analyzerForCancellation?.cancelAndFinishNow()
            throw error
        } catch {
            resultTaskForCancellation?.cancel()
            await analyzerForCancellation?.cancelAndFinishNow()
            throw CoreTranscriptionError.analyzerFailed(error.localizedDescription)
        }
    }

    private func prepareAndResolve(locale: Locale) async throws -> Locale {
        let manager = await assetManager()
        do {
            return try await manager.prepare(locale: locale)
        } catch is CancellationError {
            throw CoreTranscriptionError.cancelled
        } catch let error as CoreTranscriptionError {
            throw error
        } catch {
            throw CoreTranscriptionError.preparationFailed(error.localizedDescription)
        }
    }

    private func assetManager() async -> any AppleSpeechAssetManaging {
        if let configuredAssetManager { return configuredAssetManager }
        return await MainActor.run { AppleSpeechAssetManager.shared }
    }

    fileprivate static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
    }

    fileprivate static func makeAnalysisContext(context: String?, expectedTerms: [String]) -> AnalysisContext {
        let contextLines = [context].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let terms = expectedTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let values = (contextLines + terms).joined(separator: "\n")
        let analysisContext = AnalysisContext()
        if !values.isEmpty {
            analysisContext.contextualStrings[.general] = [values]
        }
        return analysisContext
    }

    fileprivate static func resultConfidence(_ text: AttributedString) -> Double? {
        let values = text.runs.compactMap {
            $0[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    fileprivate static func collectResults(
        from transcriber: SpeechTranscriber,
        locale: Locale
    ) -> Task<Transcript, Error> {
        Task.detached(priority: .userInitiated) {
            var assembler = TranscriptAssembler(locale: locale)
            do {
                for try await result in transcriber.results {
                    _ = assembler.ingest(
                        text: String(result.text.characters),
                        range: result.range,
                        isFinal: result.isFinal,
                        confidence: AppleSpeechTranscriptionEngine.resultConfidence(result.text),
                        locale: locale
                    )
                }
                return assembler.transcript
            } catch is CancellationError {
                throw CoreTranscriptionError.cancelled
            } catch {
                throw CoreTranscriptionError.analyzerFailed(error.localizedDescription)
            }
        }
    }
}

private final actor AppleSpeechLiveTranscriptionSession: AppleSpeechLiveSessionDriver {
    private enum LifecycleState {
        case active
        case inputEnded
        case finished
        case cancelled
        case failed(CoreTranscriptionError)
    }

    nonisolated let updates: AsyncStream<TranscriptUpdate>

    private let updateContinuation: AsyncStream<TranscriptUpdate>.Continuation
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let locale: Locale
    private let targetFormat: AVAudioFormat
    private var analyzerTask: Task<Void, Error>?
    private var resultTask: Task<Void, Error>?
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?
    private var nextBufferStart: TimeInterval = 0
    private var assembler: TranscriptAssembler
    private var analyzerError: Error?
    private var lifecycleState: LifecycleState = .active
    private var teardownStarted = false
    private var nextFinalizeWaiterID = 0
    private var finalizeWaiters: [Int: CheckedContinuation<Transcript, Error>] = [:]

    private init(
        locale: Locale,
        transcriber: SpeechTranscriber,
        analyzer: SpeechAnalyzer,
        targetFormat: AVAudioFormat,
        stream: AsyncStream<TranscriptUpdate>,
        continuation: AsyncStream<TranscriptUpdate>.Continuation
    ) {
        self.locale = locale
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.targetFormat = targetFormat
        self.updates = stream
        self.updateContinuation = continuation
        self.assembler = TranscriptAssembler(locale: locale)
    }

    static func make(
        locale: Locale,
        transcriber: SpeechTranscriber,
        analysisContext: AnalysisContext,
        analyzerPriority: TaskPriority
    ) async throws -> AppleSpeechLiveTranscriptionSession {
        let modules: [any SpeechModule] = [transcriber]
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw CoreTranscriptionError.audioFormatUnavailable
        }
        let options = SpeechAnalyzer.Options(priority: analyzerPriority, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: modules, options: options)
        try await analyzer.setContext(analysisContext)
        try await analyzer.prepareToAnalyze(in: targetFormat)

        var continuation: AsyncStream<TranscriptUpdate>.Continuation?
        let stream = AsyncStream<TranscriptUpdate> { continuation = $0 }
        guard let continuation else {
            throw CoreTranscriptionError.analyzerFailed("Unable to create the update stream.")
        }

        let session = AppleSpeechLiveTranscriptionSession(
            locale: locale,
            transcriber: transcriber,
            analyzer: analyzer,
            targetFormat: targetFormat,
            stream: stream,
            continuation: continuation
        )
        return session
    }

    func start() async throws {
        switch lifecycleState {
        case .active:
            startAnalysis()
        case .cancelled:
            throw CoreTranscriptionError.cancelled
        case let .failed(error):
            throw error
        case .inputEnded, .finished:
            return
        }
    }

    private func startAnalysis() {
        let inputStream = AsyncStream<AnalyzerInput> { continuation in
            // The continuation is installed by `startAnalysis` below. This
            // closure is replaced immediately; keeping construction here
            // avoids exposing analyzer-specific stream state to callers.
            self.installInputContinuation(continuation)
        }
        analyzerTask = Task { [weak self, analyzer] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch is CancellationError {
                throw CoreTranscriptionError.cancelled
            } catch {
                await self?.recordAnalyzerError(error)
                await self?.finishUpdates()
                throw CoreTranscriptionError.analyzerFailed(error.localizedDescription)
            }
        }
        resultTask = Task { [weak self, transcriber] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    await self.consume(result)
                }
            } catch is CancellationError {
                throw CoreTranscriptionError.cancelled
            } catch {
                await self.recordAnalyzerError(error)
                await self.finishUpdates()
                throw CoreTranscriptionError.analyzerFailed(error.localizedDescription)
            }
        }
    }

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    private func installInputContinuation(_ continuation: AsyncStream<AnalyzerInput>.Continuation) {
        inputContinuation = continuation
    }

    func append(buffer: AVAudioPCMBuffer) async throws {
        guard case .active = lifecycleState else { throw CoreTranscriptionError.cancelled }
        guard buffer.frameLength > 0 else { return }
        if let analyzerError { throw analyzerError }

        let converted = try convert(buffer: buffer)
        let start = CMTime(seconds: nextBufferStart, preferredTimescale: 1_000)
        nextBufferStart += Double(converted.frameLength) / converted.format.sampleRate
        inputContinuation?.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
    }

    func finish() async throws -> Transcript {
        try await finishAnalysis()
    }

    private func finishAnalysis() async throws -> Transcript {
        switch lifecycleState {
        case .finished:
            return assembler.transcript
        case .cancelled:
            throw CoreTranscriptionError.cancelled
        case let .failed(error):
            throw error
        case .inputEnded:
            // A second caller must wait for the in-flight finalization rather
            // than observing a partially assembled transcript.
            return try await waitForFinalization()
        case .active:
            lifecycleState = .inputEnded
            inputContinuation?.finish()
        }

        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try checkFinalizationWasNotCancelled()
            if let analyzerTask { _ = try await analyzerTask.value }
            try checkFinalizationWasNotCancelled()
            if let resultTask { _ = try await resultTask.value }
            try checkFinalizationWasNotCancelled()

            let transcript = assembler.transcript
            updateContinuation.yield(
                TranscriptUpdate(
                    text: transcript.text,
                    segments: transcript.segments,
                    isFinal: true,
                    progress: 1,
                    locale: locale
                )
            )

            // Finalization has produced the value; close analyzer input and
            // await both owned tasks before publishing a successful terminal
            // state so an abandoned handle cannot retain live Speech work.
            await tearDown()
            lifecycleState = .finished
            updateContinuation.finish()
            resumeFinalizeWaiters(returning: transcript)
            return transcript
        } catch is CancellationError {
            let error = await failFinalization(with: .cancelled)
            throw error
        } catch let error as CoreTranscriptionError {
            let error = await failFinalization(with: error)
            throw error
        } catch {
            let error = await failFinalization(
                with: .analyzerFailed(error.localizedDescription)
            )
            throw error
        }
    }

    func cancel() async {
        switch lifecycleState {
        case .finished, .cancelled, .failed:
            return
        case .active, .inputEnded:
            lifecycleState = .cancelled
        }
        inputContinuation?.finish()
        await tearDown()
        resumeFinalizeWaiters(throwing: .cancelled)
    }

    func cancelAndWait() async {
        await cancel()
    }

    func terminalError() async -> CoreTranscriptionError? {
        if let analyzerError {
            if let error = analyzerError as? CoreTranscriptionError { return error }
            return .analyzerFailed(analyzerError.localizedDescription)
        }
        if case let .failed(error) = lifecycleState { return error }
        return nil
    }

    private func checkFinalizationWasNotCancelled() throws {
        guard !Task.isCancelled else { throw CoreTranscriptionError.cancelled }
        guard case .cancelled = lifecycleState else { return }
        throw CoreTranscriptionError.cancelled
    }

    private func waitForFinalization() async throws -> Transcript {
        let waiterID = nextFinalizeWaiterID
        nextFinalizeWaiterID += 1
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Transcript, Error>) in
                finalizeWaiters[waiterID] = continuation
                if Task.isCancelled {
                    cancelFinalizeWaiter(id: waiterID)
                }
            }
        }, onCancel: {
            Task { await self.cancelFinalizeWaiter(id: waiterID) }
        })
    }

    private func cancelFinalizeWaiter(id: Int) {
        guard let waiter = finalizeWaiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CoreTranscriptionError.cancelled)
    }

    private func failFinalization(with error: CoreTranscriptionError) async -> CoreTranscriptionError {
        let finalError: CoreTranscriptionError
        if case .cancelled = lifecycleState {
            // An explicit session cancellation wins over an analyzer error
            // that may race with it while finalization is suspended.
            finalError = .cancelled
        } else {
            finalError = error
            lifecycleState = error == .cancelled ? .cancelled : .failed(error)
        }

        await tearDown()
        resumeFinalizeWaiters(throwing: finalError)
        return finalError
    }

    private func tearDown() async {
        guard !teardownStarted else { return }
        teardownStarted = true
        inputContinuation?.finish()
        inputContinuation = nil
        let analyzerTask = analyzerTask
        let resultTask = resultTask
        analyzerTask?.cancel()
        resultTask?.cancel()
        await analyzer.cancelAndFinishNow()
        _ = try? await analyzerTask?.value
        _ = try? await resultTask?.value
        self.analyzerTask = nil
        self.resultTask = nil
        updateContinuation.finish()
    }

    private func resumeFinalizeWaiters(returning transcript: Transcript) {
        let waiters = Array(finalizeWaiters.values)
        finalizeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: transcript)
        }
    }

    private func resumeFinalizeWaiters(throwing error: CoreTranscriptionError) {
        let waiters = Array(finalizeWaiters.values)
        finalizeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func consume(_ result: SpeechTranscriber.Result) {
        let update = assembler.ingest(
            text: String(result.text.characters),
            range: result.range,
            isFinal: result.isFinal,
            confidence: AppleSpeechTranscriptionEngine.resultConfidence(result.text),
            locale: locale
        )
        updateContinuation.yield(update)
    }

    private func recordAnalyzerError(_ error: Error) {
        analyzerError = error
    }

    private func finishUpdates() {
        updateContinuation.finish()
    }

    private func convert(buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        if inputFormat == targetFormat {
            return buffer
        }
        if lastInputFormat != inputFormat || converter == nil {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            lastInputFormat = inputFormat
        }
        guard let converter else { throw CoreTranscriptionError.audioFormatUnavailable }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(max(1, Int(ceil(Double(buffer.frameLength) * ratio)) + 2))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw CoreTranscriptionError.audioFormatUnavailable
        }
        let inputBox = SendablePCMBufferBox(buffer)
        let inputState = ConverterInputState()
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if inputState.supplied {
                // This converter is reused for the lifetime of the live
                // session. Each call supplies one temporary buffer, not the
                // end of the microphone stream.
                status.pointee = .noDataNow
                return nil
            }
            inputState.supplied = true
            status.pointee = .haveData
            return inputBox.buffer
        }
        if let conversionError {
            throw CoreTranscriptionError.analyzerFailed(conversionError.localizedDescription)
        }
        return output
    }
}

/// Production Speech driver factory. Preparation is intentionally part of the
/// asynchronous operation start, never the provider's synchronous factory.
private final class AppleSpeechSystemLiveSessionDriverFactory: @unchecked Sendable, AppleSpeechLiveSessionDriverFactory {
    private let configuredAssetManager: (any AppleSpeechAssetManaging)?
    private let analyzerPriority: TaskPriority

    init(
        assetManager: (any AppleSpeechAssetManaging)?,
        analyzerPriority: TaskPriority
    ) {
        self.configuredAssetManager = assetManager
        self.analyzerPriority = analyzerPriority
    }

    func makeLiveSession(
        locale: Locale,
        context: String?,
        expectedTerms: [String],
        analyzerPriority: TaskPriority
    ) async throws -> any AppleSpeechLiveSessionDriver {
        let manager: any AppleSpeechAssetManaging
        if let configuredAssetManager {
            manager = configuredAssetManager
        } else {
            manager = await MainActor.run { AppleSpeechAssetManager.shared }
        }
        let resolvedLocale: Locale
        do {
            resolvedLocale = try await manager.prepare(locale: locale)
        } catch is CancellationError {
            throw CoreTranscriptionError.cancelled
        } catch let error as CoreTranscriptionError {
            throw error
        } catch {
            throw CoreTranscriptionError.preparationFailed(error.localizedDescription)
        }
        let transcriber = AppleSpeechTranscriptionEngine.makeTranscriber(locale: resolvedLocale)
        let analysisContext = AppleSpeechTranscriptionEngine.makeAnalysisContext(
            context: context,
            expectedTerms: expectedTerms
        )
        do {
            return try await AppleSpeechLiveTranscriptionSession.make(
                locale: resolvedLocale,
                transcriber: transcriber,
                analysisContext: analysisContext,
                analyzerPriority: analyzerPriority
            )
        } catch let error as CoreTranscriptionError {
            throw error
        } catch {
            throw CoreTranscriptionError.analyzerFailed(error.localizedDescription)
        }
    }
}

/// A provider operation with a five-second serial admission queue. The queue
/// closes on overflow; capture integration can then stop and move its complete
/// WAV to Recovery while retaining the typed error.
public final class AppleSpeechLiveTranscriptionOperation: @unchecked Sendable, TranscriptionLiveOperation {
    private enum FinishReservation {
        case terminal(CoreTranscriptionError)
        case cached(Transcript)
        case cancelled
        case notStarted
        case alreadyFinishing(any AppleSpeechLiveSessionDriver)
        case begin(any AppleSpeechLiveSessionDriver, Task<Void, Error>?)
    }

    public let events: AsyncStream<TranscriptionOperationEvent>
    public let updates: AsyncStream<TranscriptUpdate>

    private let eventContinuation: AsyncStream<TranscriptionOperationEvent>.Continuation
    private let updateContinuation: AsyncStream<TranscriptUpdate>.Continuation
    private let factory: any AppleSpeechLiveSessionDriverFactory
    private let locale: Locale
    private let context: String?
    private let expectedTerms: [String]
    private let analyzerPriority: TaskPriority
    private let diagnosticSink: any TranscriptionDiagnosticSink
    private let channel = BoundedLiveAudioChannel(maximumDuration: 5)
    private let operationToken = SessionOperationToken()
    private let stateLock = NSLock()
    private var driver: (any AppleSpeechLiveSessionDriver)?
    private var startTask: Task<Void, Error>?
    private var consumerTask: Task<Void, Error>?
    private var monitorTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var terminal: CoreTranscriptionError?
    private var finalTranscript: Transcript?
    private var started = false
    private var finished = false
    private var cancelled = false
    private var eventsFinished = false

    init(
        factory: any AppleSpeechLiveSessionDriverFactory,
        locale: Locale,
        context: String?,
        expectedTerms: [String],
        analyzerPriority: TaskPriority,
        diagnosticSink: any TranscriptionDiagnosticSink = LoggerTranscriptionDiagnosticSink.shared
    ) {
        var eventContinuation: AsyncStream<TranscriptionOperationEvent>.Continuation?
        var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation?
        self.events = AsyncStream { eventContinuation = $0 }
        self.updates = AsyncStream { updateContinuation = $0 }
        self.eventContinuation = eventContinuation!
        self.updateContinuation = updateContinuation!
        self.factory = factory
        self.locale = locale
        self.context = context
        self.expectedTerms = expectedTerms
        self.analyzerPriority = analyzerPriority
        self.diagnosticSink = diagnosticSink
        self.eventContinuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.cancelAndWait() }
        }
        self.updateContinuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.cancelAndWait() }
        }
    }

    public func start() async throws {
        let task: Task<Void, Error>? = stateLock.withLock {
            if cancelled { return nil }
            if let startTask { return startTask }
            let newTask = Task { [self] in try await startUnderlying() }
            self.startTask = newTask
            return newTask
        }
        guard let task else {
            throw CoreTranscriptionError.cancelled
        }
        do {
            try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
                self.requestCancellation()
            })
        } catch is CancellationError {
            await cancelAndWait()
            throw CoreTranscriptionError.cancelled
        }
    }

    public func append(buffer: AVAudioPCMBuffer) async throws {
        let admissionState = stateLock.withLock { (started, finished, cancelled, terminal) }
        guard admissionState.0 else { throw TranscriptionLiveInputError.notStarted }
        if let terminal = admissionState.3 { throw terminal }
        if admissionState.1 || admissionState.2 { throw TranscriptionLiveInputError.cancelled }
        do {
            try await channel.append(buffer: buffer)
        } catch let error as TranscriptionLiveInputError {
            if case let .overflow(maximumDuration) = error {
                let typed = CoreTranscriptionError.liveInputOverflow(maximumDuration: maximumDuration)
                recordTerminal(typed)
                requestCancellation()
                // Overflow is terminal for this operation. Start teardown in
                // the background so the capture boundary receives the typed
                // recoverable error promptly while the driver still reaches a
                // quiescent state even when the caller only handles the
                // append failure.
                Task { await self.cancelAndWait() }
                throw typed
            }
            throw error
        }
    }

    public func finish() async throws -> Transcript {
        let reservation = reserveFinish()
        let driver: any AppleSpeechLiveSessionDriver
        let consumer: Task<Void, Error>?
        switch reservation {
        case let .terminal(error):
            throw error
        case let .cached(transcript):
            return transcript
        case .cancelled:
            throw CoreTranscriptionError.cancelled
        case .notStarted:
            throw TranscriptionLiveInputError.notStarted
        case let .alreadyFinishing(currentDriver):
            return try await currentDriver.finish()
        case let .begin(currentDriver, consumerTask):
            driver = currentDriver
            consumer = consumerTask
        }

        emit(.finalizingAudio)
        channel.finish()
        do {
            try await consumer?.value
            if let terminal = stateLock.withLock({ self.terminal }) { throw terminal }
            emit(.transcribing)
            let transcript = try await driver.finish()
            if let terminal = await driver.terminalError() { throw terminal }
            stateLock.withLock { finalTranscript = transcript }
            await quiesceMonitor()
            stateLock.withLock {
                self.driver = nil
                self.started = false
            }
            diagnosticSink.record(
                TranscriptionDiagnosticEvent(
                    operationToken: operationToken,
                    source: .mainWindow,
                    backend: .appleSpeech,
                    phase: .transcribing,
                    outcome: .completed
                )
            )
            finishStreams()
            return transcript
        } catch is CancellationError {
            await cancelAndWait()
            throw CoreTranscriptionError.cancelled
        } catch let error as CoreTranscriptionError {
            recordTerminal(error)
            await releaseAndCancel(driver)
            await quiesceMonitor()
            finishStreams()
            throw error
        } catch {
            let typed = error as? CoreTranscriptionError ?? .analyzerFailed(error.localizedDescription)
            recordTerminal(typed)
            await releaseAndCancel(driver)
            await quiesceMonitor()
            finishStreams()
            throw typed
        }
    }

    private func reserveFinish() -> FinishReservation {
        stateLock.withLock {
            if let terminal { return .terminal(terminal) }
            if let finalTranscript { return .cached(finalTranscript) }
            if cancelled { return .cancelled }
            guard started, let currentDriver = self.driver else {
                return .notStarted
            }
            if finished { return .alreadyFinishing(currentDriver) }
            finished = true
            return .begin(currentDriver, consumerTask)
        }
    }

    public func cancelAndWait() async {
        let task: Task<Void, Never> = stateLock.withLock {
            if let cancellationTask { return cancellationTask }
            let newTask = Task { [self] in await performCancellation() }
            self.cancellationTask = newTask
            return newTask
        }
        await task.value
    }

    private func startUnderlying() async throws {
        emit(.preparing)
        do {
            try Task.checkCancellation()
            let driver = try await factory.makeLiveSession(
                locale: locale,
                context: context,
                expectedTerms: expectedTerms,
                analyzerPriority: analyzerPriority
            )
            do {
                try Task.checkCancellation()
                stateLock.withLock {
                    self.driver = driver
                    self.started = true
                }
                try await driver.start()
                try Task.checkCancellation()
                let consumer = Task { [self] in try await consume(driver) }
                let monitor = Task { [self] in await monitorUpdates(driver) }
                let cancellationWon = stateLock.withLock { () -> Bool in
                    guard !cancelled else { return true }
                    consumerTask = consumer
                    monitorTask = monitor
                    return false
                }
                if cancellationWon {
                    consumer.cancel()
                    monitor.cancel()
                    await driver.cancelAndWait()
                    _ = try? await consumer.value
                    _ = await monitor.value
                    throw CoreTranscriptionError.cancelled
                }
                emit(.recording)
            } catch {
                stateLock.withLock {
                    self.driver = nil
                    self.started = false
                }
                await driver.cancelAndWait()
                throw error
            }
        } catch is CancellationError {
            recordTerminal(.cancelled)
            throw CoreTranscriptionError.cancelled
        } catch let error as CoreTranscriptionError {
            recordTerminal(error)
            throw error
        } catch {
            let typed = CoreTranscriptionError.analyzerFailed(error.localizedDescription)
            recordTerminal(typed)
            throw typed
        }
    }

    private func consume(_ driver: any AppleSpeechLiveSessionDriver) async throws {
        do {
            while let buffer = try await channel.next() {
                try await driver.append(buffer: buffer)
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            throw CoreTranscriptionError.cancelled
        } catch let error as CoreTranscriptionError {
            recordTerminal(error)
            channel.cancel()
            await releaseAndCancel(driver)
            throw error
        } catch {
            let terminal = (error as? TranscriptionLiveInputError).map {
                CoreTranscriptionError.analyzerFailed($0.localizedDescription)
            } ?? .analyzerFailed(error.localizedDescription)
            recordTerminal(terminal)
            channel.cancel()
            await releaseAndCancel(driver)
            throw terminal
        }
    }

    private func monitorUpdates(_ driver: any AppleSpeechLiveSessionDriver) async {
        for await update in driver.updates {
            updateContinuation.yield(update)
        }
        if let error = await driver.terminalError() {
            recordTerminal(error)
            channel.cancel()
        }
    }

    private func quiesceMonitor() async {
        let monitor = stateLock.withLock { monitorTask }
        monitor?.cancel()
        _ = await monitor?.value
    }

    private func performCancellation() async {
        // Publish cancellation before taking ownership snapshots so a racing
        // analyzer failure cannot replace the caller's explicit cancellation
        // with a late framework error. A completed transcript remains a valid
        // idempotent result and is therefore left untouched.
        recordTerminal(.cancelled)
        let snapshot: (
            start: Task<Void, Error>?,
            consumer: Task<Void, Error>?,
            monitor: Task<Void, Never>?,
            driver: (any AppleSpeechLiveSessionDriver)?,
            wasFinished: Bool
        ) = stateLock.withLock {
            cancelled = true
            let snapshot = (
                start: startTask,
                consumer: consumerTask,
                monitor: monitorTask,
                driver: self.driver,
                wasFinished: finished
            )
            self.driver = nil
            started = false
            return snapshot
        }
        let start = snapshot.start
        let consumer = snapshot.consumer
        let monitor = snapshot.monitor
        let driver = snapshot.driver
        let wasFinished = snapshot.wasFinished
        emit(.cancelling)
        channel.cancel()
        start?.cancel()
        consumer?.cancel()
        monitor?.cancel()
        if !wasFinished {
            if let driver { await driver.cancelAndWait() }
        }
        _ = try? await start?.value
        _ = try? await consumer?.value
        _ = await monitor?.value
        finishStreams()
    }

    private func requestCancellation() {
        channel.cancel()
        stateLock.withLock { cancelled = true }
    }

    private func releaseAndCancel(_ driver: any AppleSpeechLiveSessionDriver) async {
        let shouldCancel = stateLock.withLock { () -> Bool in
            guard self.driver != nil else { return false }
            self.driver = nil
            self.started = false
            return true
        }
        if shouldCancel { await driver.cancelAndWait() }
    }

    private func recordTerminal(_ error: CoreTranscriptionError) {
        let recorded = stateLock.withLock { () -> (Bool, CoreTranscriptionError) in
            guard terminal == nil, finalTranscript == nil else { return (false, error) }
            let effectiveError: CoreTranscriptionError
            if cancelled, case .liveInputOverflow = error {
                effectiveError = error
            } else if cancelled {
                effectiveError = .cancelled
            } else {
                effectiveError = error
            }
            terminal = effectiveError
            return (true, effectiveError)
        }
        guard recorded.0 else { return }
        let terminalError = recorded.1
        diagnosticSink.record(
            TranscriptionDiagnosticEvent(
                operationToken: operationToken,
                source: .mainWindow,
                backend: .appleSpeech,
                phase: terminalError == .cancelled ? .cancelling : .transcribing,
                outcome: terminalError == .cancelled ? .cancelled : .failed
            )
        )
    }

    private func emit(_ phase: TranscriptionOperationPhase) {
        eventContinuation.yield(TranscriptionOperationEvent(phase: phase))
        diagnosticSink.record(
            TranscriptionDiagnosticEvent(
                operationToken: operationToken,
                source: .mainWindow,
                backend: .appleSpeech,
                phase: phase,
                outcome: .progressed
            )
        )
    }

    private func finishStreams() {
        stateLock.lock()
        guard !eventsFinished else {
            stateLock.unlock()
            return
        }
        eventsFinished = true
        stateLock.unlock()
        eventContinuation.finish()
        updateContinuation.finish()
    }
}

/// File adapter for Apple's post-capture provider boundary.
private final class AppleSpeechFileTranscriptionOperation: @unchecked Sendable, TranscriptionFileOperation {
    let events: AsyncStream<TranscriptionOperationEvent>
    private let eventContinuation: AsyncStream<TranscriptionOperationEvent>.Continuation
    private let work: @Sendable () async throws -> Transcript
    private let lock = NSLock()
    private var task: Task<Transcript, Error>?
    private var cancelled = false

    init(work: @escaping @Sendable () async throws -> Transcript) {
        var continuation: AsyncStream<TranscriptionOperationEvent>.Continuation?
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation!
        self.work = work
        self.eventContinuation.onTermination = { [weak self] _ in
            self?.requestCancel()
        }
    }

    func value() async throws -> Transcript {
        let task = makeTask()
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: { self.requestCancel() })
    }

    func cancelAndWait() async {
        let task = lock.withLock { () -> Task<Transcript, Error>? in
            cancelled = true
            return self.task
        }
        task?.cancel()
        _ = try? await task?.value
        eventContinuation.finish()
    }

    private func makeTask() -> Task<Transcript, Error> {
        lock.lock()
        if let task {
            lock.unlock()
            return task
        }
        if cancelled {
            let canceled = Task<Transcript, Error> { throw CoreTranscriptionError.cancelled }
            task = canceled
            lock.unlock()
            return canceled
        }
        let newTask = Task { [self] in
            eventContinuation.yield(TranscriptionOperationEvent(phase: .preparing))
            do {
                try Task.checkCancellation()
                eventContinuation.yield(TranscriptionOperationEvent(phase: .transcribing))
                let result = try await work()
                eventContinuation.finish()
                return result
            } catch is CancellationError {
                eventContinuation.yield(TranscriptionOperationEvent(phase: .cancelling))
                eventContinuation.finish()
                throw CoreTranscriptionError.cancelled
            } catch {
                eventContinuation.finish()
                throw error
            }
        }
        task = newTask
        lock.unlock()
        return newTask
    }

    private func requestCancel() {
        lock.withLock {
            cancelled = true
            task?.cancel()
        }
    }
}
