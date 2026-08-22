import AVFAudio
import AVFoundation
import Foundation
import SwiftUI

/// The capture boundary used by the session controller.  The concrete
/// `AudioCaptureService` can be adapted to this protocol without making the
/// UI know whether capture is backed by AVAudioEngine or a deterministic test
/// source.
@MainActor
protocol DictationAudioCapture: AnyObject {
    var isRecording: Bool { get }
    var currentRecordingURL: URL? { get }

    /// The callback receives buffers that have already been copied away from
    /// the real-time audio callback. Implementations must not perform file
    /// I/O or transcription work on that callback's thread.
    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop() throws -> URL?
    func cancel()
}

/// The only recording-store operation the controller needs. Keeping this
/// boundary small lets lifecycle tests observe persistence without opening the
/// app's real history database.
@MainActor
protocol DictationRecordingStore: AnyObject {
    func addRecording(_ recording: Recording) async throws
    func removeRecording(_ recording: Recording) async throws
}

extension RecordingStore: DictationRecordingStore {}

private final class DictationAudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// Registers appends synchronously from the capture queue, then performs them
/// sequentially. Once capture has drained its queue, `drain()` represents every
/// buffer that must reach the live transcriber before finalization.
private final class LiveBufferAppender: @unchecked Sendable {
    private let session: any LiveTranscriptionSession
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var appendError: Error?

    init(session: any LiveTranscriptionSession) {
        self.session = session
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        let buffer = DictationAudioBufferBox(buffer)
        lock.lock()
        let predecessor = tail
        let session = self.session
        tail = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            do {
                try await session.append(buffer: buffer.buffer)
            } catch {
                self?.record(error)
            }
        }
        lock.unlock()
    }

    func drain() async throws {
        let task = withLock { tail }
        await task?.value
        if let error = withLock({ appendError }) {
            throw error
        }
    }

    func cancel() {
        withLock { tail }?.cancel()
    }

    private func record(_ error: Error) {
        lock.lock()
        if appendError == nil {
            appendError = error
        }
        lock.unlock()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Bridges the provider-neutral controller to the AVAudioEngine capture
/// service. The service owns the real-time tap, WAV writer, and cancellation;
/// this adapter only translates its result shape into the controller's
/// lifecycle.
@MainActor
final class AudioCaptureServiceAdapter: DictationAudioCapture {
    private let service: AudioCaptureService

    init(service: AudioCaptureService = .shared) {
        self.service = service
    }

    var isRecording: Bool { service.isCapturing }
    var currentRecordingURL: URL? { service.currentRecordingURL }

    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        _ = try service.startCapture(onBuffer: bufferHandler)
    }

    func stop() throws -> URL? {
        let result = try service.stopCapture()
        guard result.duration > 0 else {
            try? FileManager.default.removeItem(at: result.fileURL)
            return nil
        }
        return result.fileURL
    }

    func cancel() {
        service.cancelCapture()
    }
}

/// The single state machine shared by the main window, shortcut indicator,
/// and file-drop flow. Only finalized `Transcript` values are persisted or
/// pasted; `TranscriptUpdate` values are presentation-only.
@MainActor
final class DictationSessionController: ObservableObject {
    private struct OperationConfiguration {
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

        var errorDescription: String? {
            switch self {
            case .busy:
                return "A recording or transcription is already in progress."
            case .noAudio:
                return "No audio was captured. Try recording for a little longer."
            case .notConfigured:
                return "Transcription is not ready yet. Please try again shortly."
            }
        }
    }

    static let shared = DictationSessionController()

    @Published private(set) var state: State = .idle
    @Published private(set) var interimText = ""
    @Published private(set) var finalTranscript: Transcript?
    @Published private(set) var progress: Double = 0
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastResult: Result?

    private var capture: (any DictationAudioCapture)?
    private var engineFactory: ((TranscriptionBackend, Int) throws -> any TranscriptionEngine)?
    private let recordingStore: any DictationRecordingStore
    private let settingsProvider: () -> Settings
    private let recordingDirectory: URL?
    private let pasteHandler: (String) -> Void
    private let recordingStartedHandler: () -> Void

    private var activeEngine: (any TranscriptionEngine)?
    private var liveSession: (any LiveTranscriptionSession)?
    private var liveBufferAppender: LiveBufferAppender?
    private var updatesTask: Task<Void, Never>?
    private var updatesTaskOperationID: UUID?
    private var operationTask: Task<Void, Never>?
    private var operationTaskOperationID: UUID?
    private var fileTranscriptionTask: Task<Transcript, Error>?
    private var fileTranscriptionTaskOperationID: UUID?
    private var durationTimer: Timer?
    private var recordingStartDate: Date?
    private var operationID: UUID?
    private var activeConfiguration: OperationConfiguration?
    private var currentAudioURL: URL?
    private var pasteOnCompletion = false
    private var cancellationRequested = false

    init(
        recordingStore: (any DictationRecordingStore)? = nil,
        settingsProvider: @escaping () -> Settings = { Settings() },
        recordingDirectory: URL? = nil,
        pasteHandler: @escaping (String) -> Void = ClipboardUtil.insertTextUsingPasteboard,
        recordingStartedHandler: @escaping () -> Void = { AudioRecorder.shared.playRecordingStartSound() }
    ) {
        self.recordingStore = recordingStore ?? RecordingStore.shared
        self.settingsProvider = settingsProvider
        self.recordingDirectory = recordingDirectory
        self.pasteHandler = pasteHandler
        self.recordingStartedHandler = recordingStartedHandler
        self.capture = AudioCaptureServiceAdapter()
        self.engineFactory = { backend, openAIRetryCount in
            switch backend {
            case .appleSpeech:
                return AppleSpeechTranscriptionEngine()
            case .openAI:
                return OpenAITranscriptionEngine(
                    configuration: .init(retryCount: openAIRetryCount)
                )
            }
        }
    }

    init(
        capture: any DictationAudioCapture,
        engineFactory: @escaping (TranscriptionBackend, Int) throws -> any TranscriptionEngine,
        recordingStore: (any DictationRecordingStore)? = nil,
        settingsProvider: @escaping () -> Settings = { Settings() },
        recordingDirectory: URL? = nil,
        pasteHandler: @escaping (String) -> Void = ClipboardUtil.insertTextUsingPasteboard,
        recordingStartedHandler: @escaping () -> Void = { AudioRecorder.shared.playRecordingStartSound() }
    ) {
        self.recordingStore = recordingStore ?? RecordingStore.shared
        self.settingsProvider = settingsProvider
        self.recordingDirectory = recordingDirectory
        self.pasteHandler = pasteHandler
        self.recordingStartedHandler = recordingStartedHandler
        self.capture = capture
        self.engineFactory = engineFactory
    }

    /// Inject the provider-neutral engine factory and capture service from
    /// app composition. Keeping this boundary here lets the controller remain
    /// stable while Apple/OpenAI engine implementations evolve.
    func configure(
        capture: any DictationAudioCapture,
        engineFactory: @escaping (TranscriptionBackend, Int) throws -> any TranscriptionEngine
    ) {
        guard !state.isBusy else { return }
        self.capture = capture
        self.engineFactory = engineFactory
    }

    /// Starts one recording operation. `pasteOnCompletion` is only used by
    /// the shortcut indicator; both paths save the same final-only transcript.
    func startRecording(pasteOnCompletion: Bool = false) {
        guard !state.isBusy else { return }
        guard let capture, let engineFactory else {
            present(error: ControllerError.notConfigured)
            return
        }

        let (operationID, configuration) = beginOperation(
            settings: settingsProvider(),
            state: .preparing,
            pasteOnCompletion: pasteOnCompletion
        )
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try engineFactory(configuration.backend, configuration.openAIRetryCount)
                try await engine.prepare(locale: configuration.locale)
                try Task.checkCancellation()
                guard self.isOperationActive(operationID) else {
                    throw CoreTranscriptionError.cancelled
                }
                self.activeEngine = engine

                // OpenAI intentionally transcribes completed files. Its live
                // session may be unavailable, which is not a preparation
                // failure as long as capture can start.
                let preparedSession: (any LiveTranscriptionSession)?
                do {
                    preparedSession = try await engine.startSession(
                        locale: configuration.locale,
                        context: configuration.context,
                        expectedTerms: configuration.expectedTerms
                    )
                } catch where configuration.backend == .openAI {
                    preparedSession = nil
                }

                // `startSession` may ignore task cancellation and return after
                // the user has already cancelled this operation. Never start
                // capture for that stale session, and explicitly tear it down.
                guard self.operationID == operationID,
                      !self.cancellationRequested,
                      !Task.isCancelled else {
                    if let preparedSession {
                        await preparedSession.cancel()
                    }
                    return
                }

                self.liveSession = preparedSession
                if let liveSession = preparedSession {
                    self.liveBufferAppender = LiveBufferAppender(session: liveSession)
                    self.observe(updates: liveSession.updates, operationID: operationID)
                }

                let bufferAppender = self.liveBufferAppender
                try capture.start { buffer in
                    bufferAppender?.enqueue(buffer)
                }

                guard self.isOperationActive(operationID) else { return }
                self.currentAudioURL = capture.currentRecordingURL
                self.recordingStartDate = Date()
                self.startDurationTimer(operationID: operationID)
                self.state = .recording
                if configuration.playSoundOnRecordStart {
                    self.recordingStartedHandler()
                }
            } catch {
                guard self.operationID == operationID else { return }
                self.fail(error, operationID: operationID)
            }
        }
        operationTask = task
        operationTaskOperationID = operationID
    }

    /// Ends capture and waits for the provider's final result before saving or
    /// pasting. This method is intentionally idempotent for rapid key events.
    func stopRecording() {
        if state == .preparing {
            // A second shortcut press can arrive before asset preparation or
            // analyzer startup completes. Treat it as a cancellation instead
            // of allowing the preparation task to start a recording after the
            // user has already released the shortcut.
            cancelRecording()
            return
        }
        guard state == .recording else { return }
        guard let operationID, let capture, let engine = activeEngine,
              let configuration = activeConfiguration else { return }
        let bufferAppender = liveBufferAppender

        state = .finalizing
        stopDurationTimer()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                self.currentAudioURL = capture.currentRecordingURL
                guard let audioURL = try capture.stop() else {
                    throw ControllerError.noAudio
                }
                self.currentAudioURL = audioURL
                try await bufferAppender?.drain()
                try self.checkOperationActive(operationID)

                let transcript: Transcript
                if let liveSession = self.liveSession {
                    transcript = try await liveSession.finalize()
                } else {
                    try self.checkOperationActive(operationID)
                    self.state = .transcribing
                    transcript = try await engine.transcribeFile(
                        at: audioURL,
                        locale: configuration.locale,
                        context: configuration.context,
                        expectedTerms: configuration.expectedTerms
                    )
                }

                try Task.checkCancellation()
                try self.checkOperationActive(operationID)
                let duration = self.recordingDuration > 0
                    ? self.recordingDuration
                    : await self.duration(of: audioURL)
                try self.checkOperationActive(operationID)
                let recording = try await self.persist(
                    audioURL: audioURL,
                    transcript: transcript,
                    duration: duration,
                    copySource: false,
                    configuration: configuration,
                    operationID: operationID
                )
                try self.checkOperationActive(operationID)
                self.currentAudioURL = nil
                self.finish(
                    result: Result(recording: recording, transcript: transcript),
                    operationID: operationID
                )
            } catch {
                guard self.operationID == operationID, !self.cancellationRequested else { return }
                self.fail(error, operationID: operationID)
            }
        }
        operationTask = task
        operationTaskOperationID = operationID
    }

    /// Cancels capture and provider work. Cancellation never reaches history
    /// or the pasteboard, even if a final callback races with the key event.
    func cancelRecording() {
        guard state.isBusy else {
            resetToIdle()
            return
        }

        cancellationRequested = true
        let operationID = self.operationID
        if operationTaskOperationID == operationID {
            operationTask?.cancel()
        }
        if fileTranscriptionTaskOperationID == operationID {
            fileTranscriptionTask?.cancel()
        }
        if updatesTaskOperationID == operationID {
            updatesTask?.cancel()
        }
        liveBufferAppender?.cancel()
        liveBufferAppender = nil
        capture?.cancel()
        let session = liveSession
        liveSession = nil
        activeEngine = nil
        stopDurationTimer()
        if let session {
            Task { await session.cancel() }
        }
        removeIfPresent(currentAudioURL)
        state = .cancelled
        clearOperation()
        state = .idle
    }

    /// Runs the same selected engine's file entry point for an imported audio
    /// file. The caller owns security-scoped access while this async operation
    /// is running. The source is copied into history only after finalization.
    @discardableResult
    func transcribeFile(
        at url: URL,
        duration: TimeInterval? = nil
    ) async throws -> Result {
        guard !state.isBusy else {
            throw ControllerError.busy
        }
        guard let engineFactory else {
            throw ControllerError.notConfigured
        }

        let (operationID, configuration) = beginOperation(
            settings: settingsProvider(),
            state: .transcribing
        )

        do {
            let engine = try engineFactory(configuration.backend, configuration.openAIRetryCount)
            let transcriptionTask = Task { @MainActor [weak self] () throws -> Transcript in
                guard let self else { throw CoreTranscriptionError.cancelled }

                // Preparation is part of the cancellable imported-file task.
                // Some providers may return from prepare after their task has
                // been cancelled, so the identity check immediately after it
                // is required before creating any upload/transcription work.
                try Task.checkCancellation()
                try await engine.prepare(locale: configuration.locale)
                try Task.checkCancellation()
                try self.checkOperationActive(operationID)

                self.activeEngine = engine
                try Task.checkCancellation()
                try self.checkOperationActive(operationID)
                let transcript = try await engine.transcribeFile(
                    at: url,
                    locale: configuration.locale,
                    context: configuration.context,
                    expectedTerms: configuration.expectedTerms
                )
                try Task.checkCancellation()
                try self.checkOperationActive(operationID)
                return transcript
            }
            fileTranscriptionTask = transcriptionTask
            fileTranscriptionTaskOperationID = operationID
            defer { clearFileTranscriptionTask(for: operationID) }
            let transcript = try await withTaskCancellationHandler(
                operation: { try await transcriptionTask.value },
                onCancel: { transcriptionTask.cancel() }
            )
            try Task.checkCancellation()
            try checkOperationActive(operationID)
            let fileDuration: TimeInterval
            if let duration {
                fileDuration = duration
            } else {
                fileDuration = await self.duration(of: url)
            }
            try checkOperationActive(operationID)
            let recording = try await persist(
                audioURL: url,
                transcript: transcript,
                duration: fileDuration,
                copySource: true,
                configuration: configuration,
                operationID: operationID
            )
            try checkOperationActive(operationID)
            let result = Result(recording: recording, transcript: transcript)
            finish(result: result, operationID: operationID)
            return result
        } catch {
            let resolvedError: Error = error is CancellationError
                ? CoreTranscriptionError.cancelled
                : error
            if self.operationID == operationID, !self.cancellationRequested {
                fail(resolvedError, operationID: operationID)
            }
            throw resolvedError
        }
    }

    func resetToIdle() {
        guard !state.isBusy else { return }
        clearOperation()
        state = .idle
        errorMessage = nil
    }

    func dismissError() {
        errorMessage = nil
        if case .failed = state { state = .idle }
    }

    // MARK: - Live updates

    private func observe(updates: AsyncStream<TranscriptUpdate>, operationID: UUID) {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.operationID == operationID else { return }
                    self.apply(update)
                }
            }
        }
        updatesTaskOperationID = operationID
    }

    private func apply(_ update: TranscriptUpdate) {
        // A volatile update may be corrected repeatedly. It is deliberately
        // never sent to persistence or pasteboard.
        interimText = update.text
        if let progress = update.progress {
            self.progress = progress
        }
    }

    // MARK: - Persistence

    private func persist(
        audioURL: URL,
        transcript: Transcript,
        duration: TimeInterval,
        copySource: Bool,
        configuration: OperationConfiguration,
        operationID: UUID
    ) async throws -> Recording {
        try checkOperationActive(operationID)
        let timestamp = Date()
        let fileExtension = persistenceFileExtension(for: audioURL, copySource: copySource)
        let fileName = "\(Int(timestamp.timeIntervalSince1970 * 1_000))-\(UUID().uuidString).\(fileExtension)"
        let recording = Recording(
            id: UUID(),
            timestamp: timestamp,
            fileName: fileName,
            transcription: transcript.text,
            duration: duration,
            backend: configuration.backend.rawValue,
            locale: transcript.localeIdentifier.isEmpty
                ? configuration.locale.identifier
                : transcript.localeIdentifier,
            encodedTranscriptSegments: Recording.encodeTranscriptSegments(transcript.segments)
        )

        let finalDirectory = recordingDirectory ?? Recording.recordingsDirectory
        let finalURL = finalDirectory.appendingPathComponent(fileName)
        let directory = finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destinationExisted = FileManager.default.fileExists(atPath: finalURL.path)
        var transferCompleted = false
        var rowInserted = false

        do {
            try installFileTransfer(
                sourceURL: audioURL,
                finalURL: finalURL,
                copySource: copySource
            )
            transferCompleted = true

            // Cancellation can arrive while a file operation is in flight.
            // Do not begin the history write for an operation that is no
            // longer current; put a moved source back before leaving.
            try checkOperationActive(operationID)
            try await recordingStore.addRecording(recording)
            rowInserted = true

            // The store write can suspend. Recheck before reporting success;
            // if cancellation or a replacement operation arrived meanwhile,
            // compensate both the row and the file below.
            try checkOperationActive(operationID)
            return recording
        } catch {
            let originalError = error
            var fileRolledBack = false

            if rowInserted {
                // Always attempt both sides of compensation. A filesystem
                // failure must not prevent removing the inserted row.
                var fileError: Error?
                do {
                    try rollbackFileTransfer(
                        sourceURL: audioURL,
                        finalURL: finalURL,
                        copySource: copySource,
                        requireDestination: true
                    )
                    fileRolledBack = true
                } catch let rollbackError {
                    fileError = rollbackError
                }

                var databaseError: Error?
                do {
                    try await recordingStore.removeRecording(recording)
                } catch let removalError {
                    databaseError = removalError

                    // Keep a committed row paired with a playable destination
                    // if row deletion fails. If the first rollback failed,
                    // this may restore the destination from the source.
                    do {
                        try ensureFileTransfer(
                            sourceURL: audioURL,
                            finalURL: finalURL,
                            copySource: copySource
                        )
                    } catch let restorationError {
                        if fileError == nil {
                            fileError = restorationError
                        }
                    }
                }

                if databaseError != nil || fileError != nil {
                    throw PersistenceError.compensationFailed(
                        operationError: originalError.localizedDescription,
                        databaseError: databaseError?.localizedDescription,
                        fileError: fileError?.localizedDescription
                    )
                }
            } else if transferCompleted || !destinationExisted {
                do {
                    try rollbackFileTransfer(
                        sourceURL: audioURL,
                        finalURL: finalURL,
                        copySource: copySource,
                        requireDestination: transferCompleted
                    )
                    fileRolledBack = true
                } catch let rollbackError {
                    throw PersistenceError.compensationFailed(
                        operationError: originalError.localizedDescription,
                        databaseError: nil,
                        fileError: rollbackError.localizedDescription
                    )
                }
            }

            // A failed move is restored when possible.  Keep `fail` from
            // treating that restored source as an in-progress capture and
            // deleting it again.
            if !copySource, transferCompleted, fileRolledBack,
               self.operationID == operationID {
                currentAudioURL = nil
            }
            throw originalError
        }
    }

    private func finish(result: Result, operationID: UUID) {
        guard self.operationID == operationID, !cancellationRequested else { return }
        finalTranscript = result.transcript
        interimText = result.transcript.text
        progress = 1
        lastResult = result
        state = .succeeded
        clearUpdatesTask(for: operationID)
        activeEngine = nil
        liveSession = nil
        liveBufferAppender = nil
        activeConfiguration = nil
        clearOperationTask(for: operationID)
        self.operationID = nil
        stopDurationTimer()

        if pasteOnCompletion {
            pasteHandler(result.transcript.text)
        }
        pasteOnCompletion = false
    }

    private func fail(_ error: Error, operationID: UUID) {
        guard self.operationID == operationID, !cancellationRequested else { return }
        capture?.cancel()
        removeIfPresent(currentAudioURL)
        let session = liveSession
        clearUpdatesTask(for: operationID)
        activeEngine = nil
        liveSession = nil
        liveBufferAppender?.cancel()
        liveBufferAppender = nil
        activeConfiguration = nil
        stopDurationTimer()
        if let session {
            // Analyzer failures can arrive from the live result stream while
            // capture is still running.  Explicitly finish that session so
            // its input/result tasks and SpeechAnalyzer reservation do not
            // outlive the failed controller operation.
            Task { await session.cancel() }
        }
        present(error: error)
        state = .failed(errorMessage ?? "Transcription failed.")
        clearOperationTask(for: operationID)
        self.operationID = nil
        pasteOnCompletion = false
    }

    private func present(error: Error) {
        if let controllerError = error as? ControllerError {
            errorMessage = controllerError.localizedDescription
        } else if let coreError = error as? CoreTranscriptionError {
            errorMessage = coreError.localizedDescription
        } else {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Capture bookkeeping

    private func isOperationActive(_ operationID: UUID) -> Bool {
        self.operationID == operationID && !cancellationRequested
    }

    private func checkOperationActive(_ operationID: UUID) throws {
        guard isOperationActive(operationID), !Task.isCancelled else {
            throw CoreTranscriptionError.cancelled
        }
    }

    private func clearOperationTask(for operationID: UUID) {
        guard operationTaskOperationID == operationID else { return }
        operationTask = nil
        operationTaskOperationID = nil
    }

    private func clearFileTranscriptionTask(for operationID: UUID) {
        guard fileTranscriptionTaskOperationID == operationID else { return }
        fileTranscriptionTask = nil
        fileTranscriptionTaskOperationID = nil
    }

    private func clearUpdatesTask(for operationID: UUID) {
        guard updatesTaskOperationID == operationID else { return }
        updatesTask?.cancel()
        updatesTask = nil
        updatesTaskOperationID = nil
    }

    private func clearOperation() {
        if let operationID {
            clearOperationTask(for: operationID)
            clearFileTranscriptionTask(for: operationID)
            clearUpdatesTask(for: operationID)
        } else {
            // There is no active operation to protect when resetting an idle
            // or failed controller. Clean up any completed stale handles too.
            operationTask?.cancel()
            operationTask = nil
            operationTaskOperationID = nil
            fileTranscriptionTask?.cancel()
            fileTranscriptionTask = nil
            fileTranscriptionTaskOperationID = nil
            updatesTask?.cancel()
            updatesTask = nil
            updatesTaskOperationID = nil
        }
        activeEngine = nil
        liveSession = nil
        liveBufferAppender?.cancel()
        liveBufferAppender = nil
        activeConfiguration = nil
        operationID = nil
        currentAudioURL = nil
        pasteOnCompletion = false
        cancellationRequested = false
        interimText = ""
        finalTranscript = nil
        progress = 0
        recordingDuration = 0
    }

    private func beginOperation(
        settings: Settings,
        state: State,
        pasteOnCompletion: Bool = false
    ) -> (UUID, OperationConfiguration) {
        let id = UUID()
        let configuration = OperationConfiguration(
            backend: settings.transcriptionBackend,
            locale: settings.locale,
            context: settings.context,
            expectedTerms: settings.expectedTerms,
            openAIRetryCount: settings.openAIRetryCount,
            playSoundOnRecordStart: settings.playSoundOnRecordStart
        )
        operationID = id
        activeConfiguration = configuration
        self.pasteOnCompletion = pasteOnCompletion
        cancellationRequested = false
        interimText = ""
        finalTranscript = nil
        lastResult = nil
        errorMessage = nil
        progress = 0
        recordingDuration = 0
        self.state = state
        return (id, configuration)
    }

    private func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func removeIfPresent(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
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

    private func installFileTransfer(
        sourceURL: URL,
        finalURL: URL,
        copySource: Bool
    ) throws {
        if copySource {
            try FileManager.default.copyItem(at: sourceURL, to: finalURL)
        } else {
            try FileManager.default.moveItem(at: sourceURL, to: finalURL)
        }
    }

    private func ensureFileTransfer(
        sourceURL: URL,
        finalURL: URL,
        copySource: Bool
    ) throws {
        guard !FileManager.default.fileExists(atPath: finalURL.path) else { return }
        try installFileTransfer(
            sourceURL: sourceURL,
            finalURL: finalURL,
            copySource: copySource
        )
    }

    /// Reverts the file side of persistence. The helper reports failures
    /// rather than deleting a destination as a last resort; the caller can
    /// retain a row and its playable destination when row deletion fails.
    private func rollbackFileTransfer(
        sourceURL: URL,
        finalURL: URL,
        copySource: Bool,
        requireDestination: Bool
    ) throws {
        if copySource {
            guard FileManager.default.fileExists(atPath: finalURL.path) else {
                if requireDestination {
                    throw PersistenceError.rollbackDestinationMissing(finalURL)
                }
                return
            }
            try FileManager.default.removeItem(at: finalURL)
            return
        }

        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            if requireDestination {
                throw PersistenceError.rollbackDestinationMissing(finalURL)
            }
            return
        }
        guard !FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw PersistenceError.rollbackSourceAlreadyExists(sourceURL)
        }
        try FileManager.default.moveItem(at: finalURL, to: sourceURL)
    }

    private func startDurationTimer(operationID: UUID) {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == operationID,
                      let start = self.recordingStartDate else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
        if let durationTimer {
            RunLoop.main.add(durationTimer, forMode: .common)
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartDate = nil
    }
}
