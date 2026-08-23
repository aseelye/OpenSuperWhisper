import AVFAudio
import AVFoundation
import Foundation
import SwiftUI

// MARK: - Persistence boundary

/// One controller-facing persistence contract. A commit receipt acknowledges
/// durable insertion, while typed compensation and Recovery results keep
/// cancellation and degraded-history paths explicit.
@MainActor
protocol DictationRecordingStore: AnyObject {
    var status: RecordingHistoryStatus { get }

    func commitRecording(_ recording: Recording) async throws -> RecordingCommitReceipt
    func removeCommittedRecording(_ receipt: RecordingCommitReceipt) async -> RecordingCompensationResult
    func preserveForRecovery(_ request: RecordingRecoveryRequest) async -> RecordingRecoveryResult
}

extension RecordingStore: DictationRecordingStore {}

// Tiny defaults keep unrelated test doubles source-compatible while all
// controller behavior still uses the receipt/recovery operations above.
extension DictationRecordingStore {
    var status: RecordingHistoryStatus { .available }

    func commitRecording(_ recording: Recording) async throws -> RecordingCommitReceipt {
        _ = recording
        throw RecordingStoreError.databaseUnavailable("No persistence implementation was supplied.")
    }

    func removeCommittedRecording(_ receipt: RecordingCommitReceipt) async -> RecordingCompensationResult {
        RecordingCompensationResult(
            recordingID: receipt.recordingID,
            state: .failed,
            error: .databaseUnavailable("No persistence implementation was supplied.")
        )
    }

    func preserveForRecovery(_ request: RecordingRecoveryRequest) async -> RecordingRecoveryResult {
        _ = request
        return RecordingRecoveryResult(
            receipt: nil,
            error: .recoveryDirectoryFailed("No persistence implementation was supplied.")
        )
    }
}

// MARK: - Session presentation contract

enum DictationSessionControlAction: String, Equatable, Sendable {
    case start
    case stop
    case cancel
    case none
}

enum DictationSessionPresentationOwner: String, Equatable, Sendable {
    case none
    case mainWindow
    case shortcut
    case fileDrop
    case importedFile
}

enum DictationSessionTerminalOutcome: String, Equatable, Sendable {
    case succeeded
    case succeededWithHistoryWarning
    case failed
    case cancelled
}

/// Immutable, published projection of the controller's operation context.
///
/// A nil token means no operation is currently admitted. During asynchronous
/// teardown the token remains present and phase is .cancelling; this is what
/// prevents a replacement from claiming the controller early.
struct DictationSessionSnapshot: Equatable, Sendable {
    let token: SessionOperationToken?
    let source: SessionOperationSource?
    let backend: TranscriptionBackend?
    let phase: TranscriptionOperationPhase?
    let progress: Double
    let duration: TimeInterval
    let interimText: String
    let warning: String?
    let outcome: DictationSessionTerminalOutcome?
    let isBusy: Bool
    let canCancel: Bool
    let controlAction: DictationSessionControlAction
    let accessibilityLabel: String
    let presentationOwner: DictationSessionPresentationOwner

    static let idle = DictationSessionSnapshot(
        token: nil,
        source: nil,
        backend: nil,
        phase: nil,
        progress: 0,
        duration: 0,
        interimText: "",
        warning: nil,
        outcome: nil,
        isBusy: false,
        canCancel: false,
        controlAction: .start,
        accessibilityLabel: "Start recording",
        presentationOwner: .none
    )
}

/// A synchronous admission result useful to UI/input workers that need to
/// carry backend/source metadata across loading suspension points.
struct DictationSessionReservation: Equatable, Sendable {
    let token: SessionOperationToken
    let source: SessionOperationSource
    let backend: TranscriptionBackend
}

typealias SessionSnapshot = DictationSessionSnapshot

// MARK: - Controller-owned live appender

private final class DictationAudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// Serializes provider append calls while keeping capture callbacks
/// nonblocking. Admission closes before a capture drain is awaited. The first
/// provider error is retained and delivered after all admitted appends before
/// finalization.
private final class LiveOperationAppender: @unchecked Sendable {
    private let operation: any TranscriptionLiveOperation
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var appendError: Error?
    private var closed = false
    private var errorHandler: ((Error) -> Void)?

    init(
        operation: any TranscriptionLiveOperation,
        errorHandler: @escaping (Error) -> Void
    ) {
        self.operation = operation
        self.errorHandler = errorHandler
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        let box = DictationAudioBufferBox(buffer)
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        let predecessor = tail
        let operation = self.operation
        tail = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            do {
                try await operation.append(buffer: box.buffer)
            } catch {
                self?.record(error)
            }
        }
        lock.unlock()
    }

    func closeAdmission() {
        lock.withLock { closed = true }
    }

    /// Closes admission and waits for every append task that was admitted
    /// before the close.  Cancellation must not release the operation context
    /// while one of those tasks can still call the provider.
    func cancelAndDrain() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            closed = true
            return tail
        }
        task?.cancel()
        await task?.value
    }

    func drain() async throws {
        let task = lock.withLock { tail }
        await task?.value
        if let error = lock.withLock({ appendError }) {
            throw error
        }
    }

    func cancel() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            closed = true
            return tail
        }
        task?.cancel()
    }

    private func record(_ error: Error) {
        let handler: ((Error) -> Void)? = lock.withLock {
            guard appendError == nil else { return nil }
            appendError = error
            closed = true
            return errorHandler
        }
        handler?(error)
    }
}

// MARK: - Controller

/// The one operation owner shared by recording, shortcut, file-drop, and
/// direct imported-file entry points.
@MainActor
final class DictationSessionController: ObservableObject {
    private struct OperationConfiguration: Sendable {
        let backend: TranscriptionBackend
        let locale: Locale
        let context: String?
        let expectedTerms: [String]
        let openAIRetryCount: Int
        let playSoundOnRecordStart: Bool
    }

    private enum PersistenceError: LocalizedError {
        case rollbackDestinationMissing(URL)
        case rollbackSourceAlreadyExists(URL)
        case compensationFailed(
            operationError: String,
            databaseError: String?,
            fileError: String?
        )

        var errorDescription: String? {
            switch self {
            case let .rollbackDestinationMissing(url):
                return "The persisted recording disappeared before it could be rolled back: \(url.lastPathComponent)."
            case let .rollbackSourceAlreadyExists(url):
                return "The original recording location is already occupied: \(url.lastPathComponent)."
            case let .compensationFailed(operationError, databaseError, fileError):
                var details = ["operation: \(operationError)"]
                if let databaseError {
                    details.append("database cleanup: \(databaseError)")
                }
                if let fileError {
                    details.append("file cleanup: \(fileError)")
                }
                return "Unable to compensate persistence (\(details.joined(separator: "; ")))."
            }
        }
    }

    private final class OperationContext: @unchecked Sendable {
        let token: SessionOperationToken
        let source: SessionOperationSource
        let configuration: OperationConfiguration
        let captureSession: any DictationAudioCaptureSession
        var pasteOnCompletion: Bool

        var provider: (any TranscriptionProvider)?
        var providerOperation: (any TranscriptionOperation)?
        var liveOperation: (any TranscriptionLiveOperation)?
        var appender: LiveOperationAppender?

        var phase: TranscriptionOperationPhase = .preparing
        var progress: Double = 0
        var interimText = ""
        var duration: TimeInterval = 0
        var captureStarted = false
        var recordingStartedAt: Date?

        var sourceAudioURL: URL?
        var ownedAudioURL: URL?
        var destinationAudioURL: URL?
        var copySource = false
        var transferCompleted = false
        var rowInserted = false
        /// The write has been entered but did not return a receipt. A store
        /// can insert a row and then throw while publishing it, so
        /// cancellation/failure must still attempt row compensation.
        var rowWriteStarted = false
        var persistenceCompensated = false
        var commitReceipt: RecordingCommitReceipt?
        var recording: Recording?

        var cancellationRequested = false
        var terminalOutcome: DictationSessionTerminalOutcome?
        var failureInProgress = false
        var cancellationTask: Task<Void, Never>?
        var operationTask: Task<Void, Never>?
        var resultTask: Task<Result, Error>?
        var eventsTask: Task<Void, Never>?
        var updatesTask: Task<Void, Never>?

        init(
            token: SessionOperationToken,
            source: SessionOperationSource,
            configuration: OperationConfiguration,
            captureSession: any DictationAudioCaptureSession,
            pasteOnCompletion: Bool
        ) {
            self.token = token
            self.source = source
            self.configuration = configuration
            self.captureSession = captureSession
            self.pasteOnCompletion = pasteOnCompletion
        }
    }

    enum State: Equatable {
        case idle
        case preparing
        case recording
        case finalizing
        case transcribing
        case succeeded
        case failed(String)
        case cancelled

        var isBusy: Bool {
            switch self {
            case .preparing, .recording, .finalizing, .transcribing:
                return true
            case .idle, .succeeded, .failed(_), .cancelled:
                return false
            }
        }

        var isRecording: Bool { self == .recording }
    }

    struct Result: Equatable {
        let recording: Recording
        let transcript: Transcript
    }

    enum ControllerError: LocalizedError, Equatable {
        case busy
        case noAudio
        case notConfigured
        case staleOperation

        var errorDescription: String? {
            switch self {
            case .busy:
                return "A recording or transcription is already in progress."
            case .noAudio:
                return "No audio was captured. Try recording for a little longer."
            case .notConfigured:
                return "Transcription is not ready yet. Please try again shortly."
            case .staleOperation:
                return "This operation is no longer active."
            }
        }
    }

    static let shared = DictationSessionController()

    @Published private(set) var state: State = .idle
    @Published private(set) var snapshot = DictationSessionSnapshot.idle
    @Published private(set) var interimText = ""
    @Published private(set) var finalTranscript: Transcript?
    @Published private(set) var progress: Double = 0
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var historyWarning: String?
    @Published private(set) var lastResult: Result?
    @Published private(set) var lastTerminalOutcome: DictationSessionTerminalOutcome?

    private var captureFactory: any DictationAudioCaptureFactory
    private var providerFactory: (TranscriptionBackend, Int) throws -> any TranscriptionProvider
    private let recordingStore: any DictationRecordingStore
    private let settingsProvider: () -> Settings
    private let recordingDirectory: URL?
    private let pasteHandler: (String) -> Void
    private let recordingStartedHandler: () -> Void
    private let diagnosticSink: any TranscriptionDiagnosticSink

    private var context: OperationContext?
    private var durationTimer: Timer?

    /// Current operation token, if one is reserved. The token remains present
    /// during asynchronous cancellation teardown.
    var operationToken: SessionOperationToken? { context?.token }
    var operationSource: SessionOperationSource? { context?.source }
    var currentAudioURL: URL? { context?.ownedAudioURL }

    init(
        captureFactory: any DictationAudioCaptureFactory = AudioCaptureService.shared,
        providerFactory: ((TranscriptionBackend, Int) throws -> any TranscriptionProvider)? = nil,
        recordingStore: (any DictationRecordingStore)? = nil,
        settingsProvider: @escaping () -> Settings = { Settings() },
        recordingDirectory: URL? = nil,
        pasteHandler: @escaping (String) -> Void = ClipboardUtil.insertTextUsingPasteboard,
        recordingStartedHandler: @escaping () -> Void = { AudioRecorder.shared.playRecordingStartSound() },
        diagnosticSink: any TranscriptionDiagnosticSink = LoggerTranscriptionDiagnosticSink.shared
    ) {
        self.captureFactory = captureFactory
        self.providerFactory = providerFactory ?? Self.makeDefaultProvider
        self.recordingStore = recordingStore ?? RecordingStore.shared
        self.settingsProvider = settingsProvider
        self.recordingDirectory = recordingDirectory
        self.pasteHandler = pasteHandler
        self.recordingStartedHandler = recordingStartedHandler
        self.diagnosticSink = diagnosticSink
    }

    private static func makeDefaultProvider(
        backend: TranscriptionBackend,
        openAIRetryCount: Int
    ) throws -> any TranscriptionProvider {
        switch backend {
        case .appleSpeech:
            return AppleSpeechTranscriptionEngine()
        case .openAI:
            return OpenAITranscriptionEngine(
                configuration: .init(retryCount: openAIRetryCount)
            )
        }
    }

    // MARK: Synchronous admission

    /// Reserves the controller synchronously on MainActor. Callers may safely
    /// suspend after this method and pass the returned token to a later
    /// imported-file call.
    @discardableResult
    func reserve(
        source: SessionOperationSource,
        pasteOnCompletion: Bool = false
    ) -> SessionOperationToken? {
        guard context == nil, !state.isBusy else { return nil }

        let settings = settingsProvider()
        let configuration = OperationConfiguration(
            backend: settings.transcriptionBackend,
            locale: settings.locale,
            context: settings.context,
            expectedTerms: settings.expectedTerms,
            openAIRetryCount: settings.openAIRetryCount,
            playSoundOnRecordStart: settings.playSoundOnRecordStart
        )
        let token = SessionOperationToken()
        let captureSession = captureFactory.makeSession()
        context = OperationContext(
            token: token,
            source: source,
            configuration: configuration,
            captureSession: captureSession,
            pasteOnCompletion: pasteOnCompletion
        )
        finalTranscript = nil
        lastResult = nil
        errorMessage = nil
        historyWarning = nil
        interimText = ""
        progress = 0
        recordingDuration = 0
        lastTerminalOutcome = nil
        publish(context: context!)
        diagnosticSink.record(TranscriptionDiagnosticEvent(
            operationToken: token,
            source: source,
            backend: configuration.backend,
            phase: .preparing,
            outcome: .started
        ))
        return token
    }

    /// Returns immutable metadata captured at reservation time.
    func reservation(for token: SessionOperationToken) -> DictationSessionReservation? {
        guard let context, context.token == token else { return nil }
        return DictationSessionReservation(
            token: token,
            source: context.source,
            backend: context.configuration.backend
        )
    }

    func isReservationActive(_ token: SessionOperationToken) -> Bool {
        context?.token == token
    }

    // MARK: Recording

    /// Starts a recording after synchronously reserving an operation token.
    @discardableResult
    func startRecording(
        source: SessionOperationSource = .mainWindow,
        pasteOnCompletion: Bool = false
    ) -> SessionOperationToken? {
        guard context == nil, !state.isBusy else { return nil }
        guard let token = reserve(source: source, pasteOnCompletion: pasteOnCompletion) else {
            return nil
        }
        startRecording(token: token)
        return token
    }

    /// Starts asynchronous capture/provider preparation for a prior
    /// reservation. This is separate so file-drop and shortcut callers can
    /// claim before their own suspension.
    func startRecording(token: SessionOperationToken) {
        guard let context, context.token == token else { return }
        guard context.operationTask == nil,
              context.terminalOutcome == nil,
              !context.cancellationRequested,
              !context.failureInProgress else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRecording(token: token)
        }
        context.operationTask = task
    }

    /// Stops capture and waits for provider finalization, persistence, and
    /// typed compensation before publishing a terminal result.
    func stopRecording() {
        guard let context else { return }
        switch context.phase {
        case .preparing:
            cancelRecording(token: context.token)
        case .recording:
            if context.failureInProgress { return }
            setPhase(.finalizingAudio, for: context)
            stopDurationTimer()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runStop(token: context.token)
            }
            context.operationTask = task
        case .finalizingAudio, .exporting, .uploading, .retrying, .transcribing,
             .saving, .cancelling:
            break
        }
    }

    // MARK: Imported files

    /// Direct imported-file entry point. Reservation occurs before the first
    /// asynchronous operation and uses .importedFile as its source.
    @discardableResult
    func transcribeFile(
        at url: URL,
        duration: TimeInterval? = nil
    ) async throws -> Result {
        guard context == nil, !state.isBusy else {
            throw ControllerError.busy
        }
        guard let token = reserve(source: .importedFile) else {
            throw ControllerError.busy
        }
        return try await transcribeFile(at: url, duration: duration, token: token)
    }

    /// File-drop entry point for callers that loaded a provider URL after
    /// reserving on MainActor. The source is retained in the context so
    /// presentation and diagnostics do not need a parallel drop marker.
    @discardableResult
    func transcribeFile(
        at url: URL,
        duration: TimeInterval? = nil,
        source: SessionOperationSource
    ) async throws -> Result {
        guard source == .fileDrop || source == .importedFile else {
            throw ControllerError.staleOperation
        }
        guard context == nil, !state.isBusy else {
            throw ControllerError.busy
        }
        guard let token = reserve(source: source) else {
            throw ControllerError.busy
        }
        return try await transcribeFile(at: url, duration: duration, token: token)
    }

    /// Runs an imported file for an already-admitted token. The provider file
    /// handle is created synchronously before its first asynchronous value call.
    @discardableResult
    func transcribeFile(
        at url: URL,
        duration: TimeInterval? = nil,
        token: SessionOperationToken
    ) async throws -> Result {
        guard let context, context.token == token else {
            throw ControllerError.staleOperation
        }
        guard context.source == .fileDrop || context.source == .importedFile else {
            throw ControllerError.staleOperation
        }
        try checkOperationActive(token)

        let fileOperation: any TranscriptionFileOperation
        do {
            let provider = try providerFactory(
                context.configuration.backend,
                context.configuration.openAIRetryCount
            )
            context.provider = provider
            fileOperation = try provider.makeFileOperation(
                at: url,
                locale: context.configuration.locale,
                context: context.configuration.context,
                expectedTerms: context.configuration.expectedTerms
            )
            // Own the handle before checking cancellation.  A synchronous
            // factory may return an operation whose cleanup still matters if
            // cancellation was requested in the same admission turn.
            context.providerOperation = fileOperation
            try checkOperationActive(token)
        } catch {
            if Task.isCancelled || Self.isCancellation(error) {
                await cancelAndWait(token: token)
                throw CoreTranscriptionError.cancelled
            }
            await failOperation(error, token: token, preserveAudio: false)
            throw error
        }

        context.sourceAudioURL = url
        context.copySource = true
        observe(events: fileOperation.events, token: token)
        setPhase(.preparing, for: context)

        let task = Task { @MainActor [weak self] () throws -> Result in
            guard let self else { throw CoreTranscriptionError.cancelled }
            return try await self.runImported(
                fileOperation: fileOperation,
                sourceURL: url,
                duration: duration,
                token: token
            )
        }
        context.resultTask = task

        do {
            return try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                // The cancellation handler cannot suspend. The catch below
                // claims the same path and awaits its cleanup before this API
                // returns to its caller.
                Task { @MainActor [weak self] in
                    self?.cancelRecording(token: token)
                }
            })
        } catch {
            if Task.isCancelled || Self.isCancellation(error) {
                await cancelAndWait(token: token)
                throw CoreTranscriptionError.cancelled
            }
            throw error
        }
    }

    /// Completes a token that was admitted for an imported file but failed
    /// before the controller could construct a provider operation (for
    /// example, an `NSItemProvider` load failure).  Admission remains owned by
    /// the controller while the unused capture session is cancelled and
    /// drained, so a replacement cannot slip in during cleanup.
    ///
    /// The operation must still be in its initial, unstarted preparation
    /// window.  A later phase has its own failure/cancellation coordinator and
    /// cannot be mutated through this narrow boundary.  The returned `Bool`
    /// reports whether this token owned that reserved window; when `true`, the
    /// method returns only after the single failed terminal outcome has been
    /// presented and the operation context has been released.
    @discardableResult
    func failReservedOperation(
        _ error: Error,
        token: SessionOperationToken
    ) async -> Bool {
        guard let context, context.token == token,
              context.source == .fileDrop || context.source == .importedFile,
              context.phase == .preparing,
              context.terminalOutcome == nil,
              !context.cancellationRequested,
              !context.failureInProgress,
              !context.captureStarted,
              context.provider == nil,
              context.providerOperation == nil,
              context.liveOperation == nil,
              context.appender == nil,
              context.operationTask == nil,
              context.resultTask == nil,
              context.eventsTask == nil,
              context.updatesTask == nil else {
            return false
        }

        // Claim the failure before the first suspension.  Cancellation and
        // stale start/transcribe calls can then observe the same visible
        // cancelling phase but cannot replace this terminal decision.
        context.failureInProgress = true
        setPhase(.cancelling, for: context)
        await failOperation(
            error,
            token: token,
            preserveAudio: false,
            claimFailure: false
        )
        return true
    }

    // MARK: Cancellation

    /// Requests cancellation through the same visible .cancelling snapshot
    /// path used by returned-task cancellation. The operation remains claimed
    /// until capture/provider/persistence cleanup has quiesced.
    @discardableResult
    func cancelRecording() -> Bool {
        guard let token = context?.token else { return false }
        return cancelRecording(token: token)
    }

    @discardableResult
    func cancelRecording(token: SessionOperationToken) -> Bool {
        guard let context, context.token == token else { return false }
        guard context.terminalOutcome == nil else { return false }
        // A reserved-operation failure has already claimed the terminal
        // decision.  Its capture/provider drain must finish before the
        // failed snapshot is published, so a concurrent cancel is a no-op
        // that keeps the failure owner intact.
        if context.failureInProgress, context.phase == .cancelling {
            return true
        }
        if context.cancellationRequested { return true }

        context.cancellationRequested = true
        setPhase(.cancelling, for: context)
        context.operationTask?.cancel()
        context.resultTask?.cancel()
        context.appender?.closeAdmission()

        guard context.cancellationTask == nil else { return true }
        let cleanup = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishCancellation(token: token)
        }
        context.cancellationTask = cleanup
        return true
    }

    /// Awaitable cancellation surface for async input owners. Synchronous
    /// controls should continue using `cancelRecording(token:)`; callers that
    /// own a returned task can use this to make the same cleanup boundary
    /// explicit.
    @discardableResult
    func cancelRecordingAndWait(token: SessionOperationToken) async -> Bool {
        guard cancelRecording(token: token) else { return false }
        guard let cancellationTask = context?.cancellationTask else { return true }
        await cancellationTask.value
        return true
    }

    /// Awaits the controller-owned cancellation task. This is intentionally
    /// separate from `cancelRecording`, whose synchronous return is needed by
    /// buttons/shortcuts, while imported async callers must not observe a
    /// cancelled task before capture/provider/persistence teardown is done.
    private func cancelAndWait(token: SessionOperationToken) async {
        guard let context, context.token == token else { return }
        _ = cancelRecording(token: token)
        guard let cancellationTask = context.cancellationTask else { return }
        await cancellationTask.value
    }

    // MARK: Terminal/presentation helpers

    func resetToIdle() {
        guard context == nil, !state.isBusy else { return }
        state = .idle
        snapshot = .idle
        errorMessage = nil
        historyWarning = nil
        interimText = ""
        finalTranscript = nil
        progress = 0
        recordingDuration = 0
    }

    func dismissError() {
        errorMessage = nil
        if case .failed = state {
            state = .idle
            if context == nil { snapshot = .idle }
        }
    }

    // MARK: Operation runners

    private func runRecording(token: SessionOperationToken) async {
        guard let contextForRun = context, contextForRun.token == token else { return }
        do {
            let provider = try providerFactory(
                contextForRun.configuration.backend,
                contextForRun.configuration.openAIRetryCount
            )
            contextForRun.provider = provider

            switch provider.strategy {
            case .live:
                guard let liveOperation = try provider.makeLiveOperation(
                    locale: contextForRun.configuration.locale,
                    context: contextForRun.configuration.context,
                    expectedTerms: contextForRun.configuration.expectedTerms
                ) else {
                    throw ControllerError.notConfigured
                }
                contextForRun.liveOperation = liveOperation
                contextForRun.providerOperation = liveOperation
                observe(events: liveOperation.events, token: token)
                observe(updates: liveOperation.updates, token: token)
                try await liveOperation.start()
                try checkOperationActive(token)

                let appender = LiveOperationAppender(
                    operation: liveOperation,
                    errorHandler: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.handleLiveAppenderError(error, token: token)
                        }
                    }
                )
                contextForRun.appender = appender
            case .fileAfterCapture:
                // The file handle is synchronously reserved after capture
                // stops, because its URL is an owned capture result.
                break
            }

            let appender = contextForRun.appender
            try await contextForRun.captureSession.start { buffer in
                appender?.enqueue(buffer)
            }
            try checkOperationActive(token)
            contextForRun.captureStarted = true
            contextForRun.sourceAudioURL = contextForRun.captureSession.currentRecordingURL
            contextForRun.recordingStartedAt = Date()
            setPhase(.recording, for: contextForRun)
            startDurationTimer(token: token)
            if contextForRun.configuration.playSoundOnRecordStart {
                recordingStartedHandler()
            }
        } catch {
            if contextForRun.cancellationRequested || Self.isCancellation(error) {
                return
            }
            await failOperation(error, token: token, preserveAudio: false)
        }
    }

    private func runStop(token: SessionOperationToken) async {
        guard let context = self.context, context.token == token else { return }
        do {
            let captureResult = try await context.captureSession.stopAndDrain()
            context.appender?.closeAdmission()
            try await context.appender?.drain()
            try checkOperationActive(token)

            guard let captureResult,
                  captureResult.duration > 0 || context.captureSession.currentRecordingURL != nil else {
                throw ControllerError.noAudio
            }
            let audioURL = captureResult.fileURL
            context.sourceAudioURL = audioURL
            context.ownedAudioURL = audioURL
            if captureResult.duration > 0 {
                context.duration = captureResult.duration
            } else if let started = context.recordingStartedAt {
                context.duration = max(0, Date().timeIntervalSince(started))
            } else {
                context.duration = await duration(of: audioURL)
            }
            publish(context: context)

            let transcript: Transcript
            if let liveOperation = context.liveOperation {
                setPhase(.transcribing, for: context)
                transcript = try await liveOperation.finish()
            } else {
                guard let provider = context.provider else {
                    throw ControllerError.notConfigured
                }
                let fileOperation = try provider.makeFileOperation(
                    at: audioURL,
                    locale: context.configuration.locale,
                    context: context.configuration.context,
                    expectedTerms: context.configuration.expectedTerms
                )
                context.providerOperation = fileOperation
                observe(events: fileOperation.events, token: token)
                setPhase(.exporting, for: context)
                transcript = try await fileOperation.value()
            }
            try checkOperationActive(token)

            let savedResult = try await persist(
                audioURL: audioURL,
                transcript: transcript,
                duration: context.duration,
                copySource: false,
                context: context,
                token: token
            )
            try checkOperationActive(token)
            finishSuccess(result: savedResult, token: token)
        } catch {
            guard let current = self.context, current.token == token else { return }
            if current.cancellationRequested { return }
            let preserve = Self.isOverflow(error)
            await failOperation(error, token: token, preserveAudio: preserve)
        }
    }

    private func runImported(
        fileOperation: any TranscriptionFileOperation,
        sourceURL: URL,
        duration: TimeInterval?,
        token: SessionOperationToken
    ) async throws -> Result {
        guard let context, context.token == token else {
            throw ControllerError.staleOperation
        }
        do {
            let transcript = try await fileOperation.value()
            try checkOperationActive(token)
            if let duration {
                context.duration = duration
            } else {
                context.duration = await self.duration(of: sourceURL)
            }
            let result = try await persist(
                audioURL: sourceURL,
                transcript: transcript,
                duration: context.duration,
                copySource: true,
                context: context,
                token: token
            )
            try checkOperationActive(token)
            finishSuccess(result: result, token: token)
            return result
        } catch {
            if let current = self.context, current.token == token,
               current.cancellationRequested {
                throw CoreTranscriptionError.cancelled
            }
            if let current = self.context, current.token == token {
                await failOperation(error, token: token, preserveAudio: false)
            }
            let resolved: Error = Self.isCancellation(error)
                ? CoreTranscriptionError.cancelled
                : error
            throw resolved
        }
    }

    // MARK: Provider events and live updates

    private func observe(
        events: AsyncStream<TranscriptionOperationEvent>,
        token: SessionOperationToken
    ) {
        context?.eventsTask?.cancel()
        let task = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.apply(event: event, token: token)
            }
        }
        context?.eventsTask = task
    }

    private func observe(
        updates: AsyncStream<TranscriptUpdate>,
        token: SessionOperationToken
    ) {
        context?.updatesTask?.cancel()
        let task = Task { @MainActor [weak self] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                self?.apply(update: update, token: token)
            }
        }
        context?.updatesTask = task
    }

    private func apply(
        event: TranscriptionOperationEvent,
        token: SessionOperationToken
    ) {
        guard let context, context.token == token,
              context.terminalOutcome == nil else { return }
        if context.cancellationRequested, event.phase != .cancelling { return }
        setPhase(event.phase, for: context)
        if let upload = event.phase.uploadProgress {
            if let fraction = upload.fraction {
                context.progress = fraction
            } else if let part = upload.part, let total = upload.total, total > 0 {
                context.progress = min(max(Double(part) / Double(total), 0), 1)
            }
        } else if case let .retrying(attempt, maximum) = event.phase,
                  maximum > 0 {
            context.progress = min(
                max(Double(max(attempt - 1, 0)) / Double(maximum), 0),
                1
            )
        }
        diagnosticSink.record(TranscriptionDiagnosticEvent(
            operationToken: token,
            source: context.source,
            backend: context.configuration.backend,
            phase: event.phase,
            outcome: .progressed
        ))
        publish(context: context)
    }

    private func apply(
        update: TranscriptUpdate,
        token: SessionOperationToken
    ) {
        guard let context, context.token == token,
              context.terminalOutcome == nil,
              !context.cancellationRequested else { return }
        context.interimText = update.text
        interimText = update.text
        if let updateProgress = update.progress {
            context.progress = updateProgress
            progress = updateProgress
        }
        publish(context: context)
    }

    private func handleLiveAppenderError(
        _ error: Error,
        token: SessionOperationToken
    ) {
        guard let context, context.token == token,
              context.terminalOutcome == nil,
              !context.cancellationRequested else { return }
        guard !context.failureInProgress else { return }
        context.failureInProgress = true
        setPhase(.finalizingAudio, for: context)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.failOperation(
                error,
                token: token,
                preserveAudio: Self.isOverflow(error),
                claimFailure: false
            )
        }
        context.operationTask = task
    }

    // MARK: Persistence

    private func persist(
        audioURL: URL,
        transcript: Transcript,
        duration: TimeInterval,
        copySource: Bool,
        context: OperationContext,
        token: SessionOperationToken
    ) async throws -> Result {
        setPhase(.saving, for: context)
        let timestamp = Date()
        let fileExtension = persistenceFileExtension(for: audioURL, copySource: copySource)
        let fileName = "\(Int(timestamp.timeIntervalSince1970 * 1_000))-\(UUID().uuidString).\(fileExtension)"
        let recording = Recording(
            id: UUID(),
            timestamp: timestamp,
            fileName: fileName,
            transcription: transcript.text,
            duration: duration,
            backend: context.configuration.backend.rawValue,
            locale: transcript.localeIdentifier.isEmpty
                ? context.configuration.locale.identifier
                : transcript.localeIdentifier,
            encodedTranscriptSegments: Recording.encodeTranscriptSegments(transcript.segments)
        )

        let finalDirectory = recordingDirectory ?? Recording.recordingsDirectory
        let finalURL = finalDirectory.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        context.sourceAudioURL = audioURL
        context.destinationAudioURL = finalURL
        context.copySource = copySource
        context.recording = recording

        do {
            if copySource {
                try FileManager.default.copyItem(at: audioURL, to: finalURL)
            } else {
                try FileManager.default.moveItem(at: audioURL, to: finalURL)
            }
            context.transferCompleted = true
            context.ownedAudioURL = finalURL
            try checkOperationActive(token)

            context.rowWriteStarted = true
            context.commitReceipt = try await recordingStore.commitRecording(recording)
            context.rowInserted = true
            try checkOperationActive(token)
            return Result(recording: recording, transcript: transcript)
        } catch {
            // A healthy transcription must remain usable when history is
            // unavailable. The file has already been transferred into the
            // managed location, so move that owned copy into Recovery and
            // return a successful result carrying a nonfatal warning. A
            // cancellation always wins over this degraded-success path.
            if !context.cancellationRequested,
               !Self.isCancellation(error),
               isHistoryUnavailable(error) {
                var rowCompensationError: Error?
                if context.rowWriteStarted, context.commitReceipt == nil {
                    // A store can have inserted before reporting an error.
                    // Best-effort row compensation prevents a hidden
                    // row/file mismatch while Recovery keeps the audio safe.
                    if let error = await compensateDatabase(context: context) {
                        if isHistoryUnavailable(error) {
                            rowCompensationError = error
                        } else {
                            throw PersistenceError.compensationFailed(
                                operationError: error.localizedDescription,
                                databaseError: error.localizedDescription,
                                fileError: nil
                            )
                        }
                    }
                    if rowCompensationError == nil {
                        context.rowInserted = false
                    }
                }

                if let recoveryError = await preserveOwnedAudioForRecovery(context: context) {
                    throw PersistenceError.compensationFailed(
                        operationError: error.localizedDescription,
                        databaseError: error.localizedDescription,
                        fileError: recoveryError.localizedDescription
                    )
                }
                if let rowCompensationError {
                    historyWarning = "History storage is unavailable. The transcript was copied to the clipboard and the audio was preserved in Recovery. Row cleanup is deferred: \(rowCompensationError.localizedDescription)"
                    diagnosticSink.record(TranscriptionDiagnosticEvent(
                        operationToken: token,
                        source: context.source,
                        backend: context.configuration.backend,
                        phase: .saving,
                        outcome: .compensationFailed
                    ))
                } else {
                    historyWarning = "History storage is unavailable. The transcript was copied to the clipboard and the audio was preserved in Recovery."
                }
                context.persistenceCompensated = true
                return Result(recording: recording, transcript: transcript)
            }
            // Leave transfer/row metadata intact for the terminal path. The
            // cancellation and failure coordinators perform typed rollback or
            // Recovery after all in-flight store work has quiesced.
            throw error
        }
    }

    private func finishSuccess(result: Result, token: SessionOperationToken) {
        guard let context, context.token == token,
              context.terminalOutcome == nil,
              !context.cancellationRequested else { return }

        let warning = historyWarning
        context.terminalOutcome = warning == nil
            ? .succeeded
            : .succeededWithHistoryWarning
        lastTerminalOutcome = context.terminalOutcome
        finalTranscript = result.transcript
        interimText = result.transcript.text
        progress = 1
        lastResult = result
        context.progress = 1
        context.interimText = result.transcript.text
        publish(context: context)
        diagnosticSink.record(TranscriptionDiagnosticEvent(
            operationToken: token,
            source: context.source,
            backend: context.configuration.backend,
            phase: .saving,
            outcome: historyWarning == nil ? .completed : .warning
        ))

        // Snapshot and clear operation-owned resources before invoking any
        // external callback. A callback may synchronously reserve a
        // replacement operation.
        let shouldPaste = context.pasteOnCompletion || historyWarning != nil
        let textToPaste = result.transcript.text
        context.pasteOnCompletion = false
        context.ownedAudioURL = nil
        context.sourceAudioURL = nil
        context.destinationAudioURL = nil
        clearContext(context, finalState: .succeeded)
        if shouldPaste {
            pasteHandler(textToPaste)
        }
    }

    private func failOperation(
        _ error: Error,
        token: SessionOperationToken,
        preserveAudio: Bool,
        claimFailure: Bool = true
    ) async {
        guard let context, context.token == token,
              context.terminalOutcome == nil else { return }
        if context.cancellationRequested { return }
        if claimFailure {
            guard !context.failureInProgress else { return }
            context.failureInProgress = true
        }
        let operationErrorDescription = error.localizedDescription

        // Overflow is the one provider failure where the complete capture
        // must be stopped and preserved. Other failures cancel capture and
        // remove its temporary file.
        if preserveAudio, context.captureStarted {
            if let result = try? await context.captureSession.stopAndDrain() {
                context.sourceAudioURL = result.fileURL
                context.ownedAudioURL = result.fileURL
                if result.duration > 0 { context.duration = result.duration }
            }
            context.appender?.closeAdmission()
        } else {
            context.appender?.closeAdmission()
            await context.captureSession.cancelAndDrain()
        }
        let appenderDrain = Task { [appender = context.appender] in
            await appender?.cancelAndDrain()
        }
        await context.providerOperation?.cancelAndWait()
        await appenderDrain.value
        context.eventsTask?.cancel()
        context.updatesTask?.cancel()
        stopDurationTimer()

        var finalError = error
        if preserveAudio {
            let recovery = await preserveOwnedAudioForRecovery(context: context)
            if let recoveryError = recovery {
                finalError = PersistenceError.compensationFailed(
                    operationError: operationErrorDescription,
                    databaseError: nil,
                    fileError: recoveryError.localizedDescription
                )
                historyWarning = "Recovery preservation needs repair: \(recoveryError.localizedDescription)"
                diagnosticSink.record(TranscriptionDiagnosticEvent(
                    operationToken: token,
                    source: context.source,
                    backend: context.configuration.backend,
                    phase: .saving,
                    outcome: .compensationFailed
                ))
            }
        } else {
            do {
                try await rollbackPersistence(context: context)
            } catch let compensationError {
                finalError = PersistenceError.compensationFailed(
                    operationError: operationErrorDescription,
                    databaseError: nil,
                    fileError: compensationError.localizedDescription
                )
                historyWarning = "Recording cleanup needs repair: \(compensationError.localizedDescription)"
                diagnosticSink.record(TranscriptionDiagnosticEvent(
                    operationToken: token,
                    source: context.source,
                    backend: context.configuration.backend,
                    phase: .saving,
                    outcome: .compensationFailed
                ))
            }
        }

        // A user cancellation that races this failure owns the terminal
        // decision. The cancellation coordinator is waiting on this task and
        // will publish the single cancelled outcome after compensation.
        if context.cancellationRequested {
            return
        }

        context.terminalOutcome = .failed
        lastTerminalOutcome = .failed
        diagnosticSink.record(TranscriptionDiagnosticEvent(
            operationToken: token,
            source: context.source,
            backend: context.configuration.backend,
            phase: .transcribing,
            outcome: .failed
        ))
        present(error: finalError)
        let message = errorMessage ?? "Transcription failed."
        publishTerminal(context: context, outcome: .failed)
        clearContext(context, finalState: .failed(message))
    }

    private func finishCancellation(token: SessionOperationToken) async {
        guard let context, context.token == token else { return }
        guard context.terminalOutcome == nil else { return }
        context.cancellationRequested = true
        setPhase(.cancelling, for: context)

        context.appender?.closeAdmission()
        let appenderDrain = Task { [appender = context.appender] in
            await appender?.cancelAndDrain()
        }
        await context.captureSession.cancelAndDrain()
        await context.providerOperation?.cancelAndWait()
        await appenderDrain.value

        // A store write may ignore task cancellation and return after a test
        // gate or database queue completes. Await the operation before
        // compensating so a durable row can never outlive cancellation.
        context.operationTask?.cancel()
        _ = await context.operationTask?.value
        _ = try? await context.resultTask?.value

        // A cancelled live capture has no persistence transfer to roll back,
        // so remove its temporary WAV while preserving external imported
        // sources.
        if !context.copySource, !context.transferCompleted,
           let sourceURL = context.sourceAudioURL {
            try? FileManager.default.removeItem(at: sourceURL)
            context.ownedAudioURL = nil
        }

        var compensationError: Error?
        do {
            try await rollbackPersistence(context: context)
        } catch {
            compensationError = error
        }

        if let compensationError {
            historyWarning = "Cancellation needs repair before this recording can be removed: \(compensationError.localizedDescription)"
            diagnosticSink.record(TranscriptionDiagnosticEvent(
                operationToken: token,
                source: context.source,
                backend: context.configuration.backend,
                phase: .cancelling,
                outcome: .compensationFailed
            ))
        }

        context.terminalOutcome = .cancelled
        lastTerminalOutcome = .cancelled
        diagnosticSink.record(TranscriptionDiagnosticEvent(
            operationToken: token,
            source: context.source,
            backend: context.configuration.backend,
            phase: .cancelling,
            outcome: .cancelled
        ))
        publishTerminal(context: context, outcome: .cancelled)
        clearContext(context, finalState: .idle)
    }

    private func preserveOwnedAudioForRecovery(
        context: OperationContext
    ) async -> Error? {
        guard let sourceURL = context.ownedAudioURL ?? context.sourceAudioURL else {
            return nil
        }

        // Overflow can terminate before the save phase has constructed a
        // history row. Recovery still needs a durable metadata sidecar, so
        // synthesize a safe placeholder from the one authoritative context.
        let recording = context.recording ?? Recording(
            id: UUID(),
            timestamp: Date(),
            fileName: sourceURL.lastPathComponent.isEmpty
                ? "recovered-recording.wav"
                : sourceURL.lastPathComponent,
            transcription: context.interimText,
            duration: context.duration,
            backend: context.configuration.backend.rawValue,
            locale: context.configuration.locale.identifier,
            encodedTranscriptSegments: nil
        )
        context.recording = recording

        let result = await recordingStore.preserveForRecovery(
            RecordingRecoveryRequest(
                sourceURL: sourceURL,
                recording: recording,
                disposition: .move
            )
        )
        if result.error == nil {
            context.ownedAudioURL = nil
        }
        return result.error
    }

    private func rollbackPersistence(context: OperationContext) async throws {
        guard !context.persistenceCompensated else { return }

        let databaseError = await compensateDatabase(context: context)
        let fileError = databaseError == nil ? compensateFile(context: context) : nil

        if let databaseError, let fileError {
            throw PersistenceError.compensationFailed(
                operationError: "cancellation/failure cleanup",
                databaseError: databaseError.localizedDescription,
                fileError: fileError.localizedDescription
            )
        }
        if let databaseError { throw databaseError }
        if let fileError { throw fileError }
        context.persistenceCompensated = true
    }

    private func compensateDatabase(context: OperationContext) async -> Error? {
        guard let recording = context.recording else { return nil }
        let receipt = context.commitReceipt ?? {
            guard context.rowInserted || context.rowWriteStarted else { return nil }
            // A receipt-less failure is ambiguous by definition. The same
            // typed operation still gives the store a chance to remove it.
            return RecordingCommitReceipt(recordingID: recording.id, databasePath: "")
        }()
        guard let receipt else { return nil }

        let result = await recordingStore.removeCommittedRecording(receipt)
        guard result.requiresRepair else { return nil }
        return result.error ?? RecordingStoreError.databaseDeleteFailed(
            "History compensation could not remove the recording."
        )
    }

    private func compensateFile(context: OperationContext) -> Error? {
        guard context.transferCompleted,
              let sourceURL = context.sourceAudioURL,
              let destinationURL = context.destinationAudioURL else {
            // A transfer may fail after creating a partial destination. For a
            // move, restore the source when it disappeared; otherwise remove
            // only this operation's uniquely named destination.
            var restoredSource = false
            var fileError: Error?
            if let destinationURL = context.destinationAudioURL,
               FileManager.default.fileExists(atPath: destinationURL.path) {
                if !context.copySource,
                   let sourceURL = context.sourceAudioURL,
                   !FileManager.default.fileExists(atPath: sourceURL.path) {
                    do {
                        try FileManager.default.moveItem(at: destinationURL, to: sourceURL)
                        restoredSource = true
                        context.ownedAudioURL = nil
                    } catch {
                        fileError = error
                    }
                } else {
                    do {
                        try FileManager.default.removeItem(at: destinationURL)
                    } catch {
                        fileError = error
                    }
                }
            }
            if !restoredSource, let ownedAudioURL = context.ownedAudioURL {
                do {
                    if FileManager.default.fileExists(atPath: ownedAudioURL.path) {
                        try FileManager.default.removeItem(at: ownedAudioURL)
                    }
                    context.ownedAudioURL = nil
                } catch {
                    fileError = error
                }
            }
            return fileError
        }

        do {
            if context.copySource {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
            } else {
                guard FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw PersistenceError.rollbackDestinationMissing(destinationURL)
                }
                guard !FileManager.default.fileExists(atPath: sourceURL.path) else {
                    throw PersistenceError.rollbackSourceAlreadyExists(sourceURL)
                }
                try FileManager.default.moveItem(at: destinationURL, to: sourceURL)
            }
            context.ownedAudioURL = nil
            return nil
        } catch {
            return error
        }
    }

    // MARK: Context and snapshot lifecycle

    private func setPhase(
        _ phase: TranscriptionOperationPhase,
        for context: OperationContext
    ) {
        guard self.context?.token == context.token,
              context.terminalOutcome == nil else { return }
        context.phase = phase.normalized
        switch phase {
        case .preparing:
            state = .preparing
        case .recording:
            state = .recording
        case .finalizingAudio:
            state = .finalizing
        case .exporting, .uploading, .retrying, .transcribing, .saving:
            state = .transcribing
        case .cancelling:
            // Keep the busy state until token-guarded cleanup completes; the
            // authoritative snapshot exposes cancellation.
            if !state.isBusy { state = .transcribing }
        }
        publish(context: context)
    }

    private func publish(context: OperationContext) {
        guard self.context?.token == context.token else { return }
        interimText = context.interimText
        progress = min(max(context.progress, 0), 1)
        recordingDuration = context.duration
        snapshot = makeSnapshot(context: context, outcome: context.terminalOutcome)
    }

    private func publishTerminal(
        context: OperationContext,
        outcome: DictationSessionTerminalOutcome
    ) {
        guard self.context?.token == context.token else { return }
        snapshot = makeSnapshot(context: context, outcome: outcome)
    }

    private func makeSnapshot(
        context: OperationContext,
        outcome: DictationSessionTerminalOutcome?
    ) -> DictationSessionSnapshot {
        let phase = context.phase.normalized
        let isCancelling = phase == .cancelling
        let controlAction: DictationSessionControlAction
        let accessibilityLabel: String
        switch phase {
        case .preparing:
            controlAction = .cancel
            accessibilityLabel = "Cancel preparation"
        case .recording:
            controlAction = .stop
            accessibilityLabel = "Stop recording"
        case .finalizingAudio:
            controlAction = .cancel
            accessibilityLabel = "Cancel finalizing audio"
        case .exporting:
            controlAction = .cancel
            accessibilityLabel = "Cancel audio export"
        case .uploading:
            controlAction = .cancel
            accessibilityLabel = "Cancel upload"
        case .retrying:
            controlAction = .cancel
            accessibilityLabel = "Cancel retry"
        case .transcribing:
            controlAction = .cancel
            accessibilityLabel = "Cancel transcription"
        case .saving:
            controlAction = .cancel
            accessibilityLabel = "Cancel save"
        case .cancelling:
            controlAction = .none
            accessibilityLabel = "Cancelling"
        }
        return DictationSessionSnapshot(
            token: context.token,
            source: context.source,
            backend: context.configuration.backend,
            phase: phase,
            progress: min(max(context.progress, 0), 1),
            duration: context.duration,
            interimText: context.interimText,
            warning: historyWarning,
            outcome: outcome,
            isBusy: outcome == nil || isCancelling,
            canCancel: outcome == nil && !isCancelling,
            controlAction: controlAction,
            accessibilityLabel: accessibilityLabel,
            presentationOwner: Self.presentationOwner(for: context.source)
        )
    }

    private func clearContext(
        _ context: OperationContext,
        finalState: State
    ) {
        guard self.context?.token == context.token else { return }
        context.eventsTask?.cancel()
        context.updatesTask?.cancel()
        context.eventsTask = nil
        context.updatesTask = nil
        context.appender = nil
        context.providerOperation = nil
        context.liveOperation = nil
        context.provider = nil
        context.ownedAudioURL = nil
        context.sourceAudioURL = nil
        context.destinationAudioURL = nil
        context.pasteOnCompletion = false
        stopDurationTimer()
        self.context = nil
        state = finalState
        if finalState == .idle {
            interimText = ""
            progress = 0
            recordingDuration = 0
            snapshot = .idle
        }
    }

    private func present(error: Error) {
        if let controllerError = error as? ControllerError {
            errorMessage = controllerError.localizedDescription
        } else if let coreError = error as? CoreTranscriptionError {
            errorMessage = coreError.localizedDescription
        } else if let captureError = error as? AudioCaptureError {
            errorMessage = captureError.localizedDescription
        } else {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Capture bookkeeping

    private func checkOperationActive(_ token: SessionOperationToken) throws {
        guard let context, context.token == token,
              !context.cancellationRequested,
              !context.failureInProgress,
              !Task.isCancelled else {
            throw CoreTranscriptionError.cancelled
        }
    }

    private func startDurationTimer(token: SessionOperationToken) {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let context = self.context,
                      context.token == token,
                      let startedAt = context.recordingStartedAt else { return }
                context.duration = max(0, Date().timeIntervalSince(startedAt))
                self.publish(context: context)
            }
        }
        if let durationTimer {
            RunLoop.main.add(durationTimer, forMode: .common)
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func persistenceFileExtension(for url: URL, copySource: Bool) -> String {
        guard copySource else { return "wav" }
        let extensionName = url.pathExtension.lowercased()
        let isSafe = !extensionName.isEmpty
            && extensionName.utf8.count <= 12
            && extensionName.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
            }
        return isSafe ? extensionName : "wav"
    }

    private static func presentationOwner(
        for source: SessionOperationSource
    ) -> DictationSessionPresentationOwner {
        switch source {
        case .mainWindow: return .mainWindow
        case .shortcut: return .shortcut
        case .fileDrop: return .fileDrop
        case .importedFile: return .importedFile
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? CoreTranscriptionError {
            return error == .cancelled
        }
        if let error = error as? AudioCaptureError {
            return error == .cancelled
        }
        if let error = error as? TranscriptionLiveInputError {
            return error == .cancelled
        }
        return false
    }

    private static func isOverflow(_ error: Error) -> Bool {
        if let error = error as? CoreTranscriptionError {
            if case .liveInputOverflow = error { return true }
        }
        if let error = error as? TranscriptionLiveInputError {
            if case .overflow = error { return true }
        }
        return false
    }

    private func isHistoryUnavailable(_ error: Error) -> Bool {
        if let storeError = error as? RecordingStoreError {
            switch storeError {
            case .initializationFailed, .databaseUnavailable:
                return true
            case .databaseReadFailed, .databaseWriteFailed,
                 .databaseDeleteFailed, .fileOperationFailed,
                 .recoveryFailed, .missingRecording:
                break
            }
        }
        if case .unavailable = recordingStore.status { return true }
        return false
    }
}
