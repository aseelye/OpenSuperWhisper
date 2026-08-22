import AVFAudio
import Foundation
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class DictationSessionControllerTests: XCTestCase {
    func testOnlyFinalTranscriptIsPersistedAndPasted() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let capture = TestCapture(recordingURL: sourceURL)
        let session = TestLiveSession(finalTranscript: Transcript(
            text: "correct final text",
            localeIdentifier: "en-US",
            segments: [TranscriptSegment(text: "correct final text", startTime: 0, endTime: 1)]
        ))
        let engine = TestEngine(session: session)
        let store = RecordingStoreSpy()
        var pastedText: String?
        let controller = DictationSessionController(
            capture: capture,
            engineFactory: { _, _ in engine },
            recordingStore: store,
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory,
            pasteHandler: { pastedText = $0 }
        )
        let indicatorDelegate = IndicatorDelegateSpy()
        let indicator = IndicatorViewModel(sessionController: controller)
        indicator.delegate = indicatorDelegate

        controller.startRecording(pasteOnCompletion: true)
        try await waitUntil { controller.state == .recording }

        session.yield(TranscriptUpdate(text: "volatile draft", progress: 0.4))
        try await waitUntil { controller.interimText == "volatile draft" }
        XCTAssertTrue(store.recordings.isEmpty)

        controller.stopRecording()
        try await waitUntil { controller.state == .succeeded }

        XCTAssertEqual(controller.interimText, "correct final text")
        XCTAssertEqual(controller.finalTranscript?.text, "correct final text")
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.recordings.first?.transcription, "correct final text")
        XCTAssertEqual(
            URL(fileURLWithPath: try XCTUnwrap(store.recordings.first?.fileName)).pathExtension,
            "wav"
        )
        XCTAssertEqual(store.recordings.first?.backend, "appleSpeech")
        XCTAssertEqual(store.recordings.first?.locale, "en-US")
        XCTAssertEqual(store.recordings.first?.transcriptSegments.count, 1)
        XCTAssertEqual(pastedText, "correct final text")
        XCTAssertTrue(capture.stopCalled)
        XCTAssertEqual(indicatorDelegate.finishCount, 1)
    }

    func testCancellationStopsCaptureAndSuppressesPersistence() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let capture = TestCapture(recordingURL: sourceURL)
        let session = TestLiveSession(finalTranscript: Transcript(text: "must not save", localeIdentifier: "en-US"))
        let engine = TestEngine(session: session)
        let store = RecordingStoreSpy()
        let controller = DictationSessionController(
            capture: capture,
            engineFactory: { _, _ in engine },
            recordingStore: store,
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        controller.startRecording()
        try await waitUntil { controller.state == .recording }
        controller.cancelRecording()

        try await waitUntil { session.cancelled }
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(capture.cancelCalled)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testBuffersQueuedDuringCaptureStopAreAppendedBeforeFinalization() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let capture = TestCapture(recordingURL: sourceURL)
        capture.bufferOnStop = try audioBuffer()
        let session = TestLiveSession(
            finalTranscript: Transcript(text: "complete", localeIdentifier: "en-US")
        )
        let controller = DictationSessionController(
            capture: capture,
            engineFactory: { _, _ in TestEngine(session: session) },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        controller.startRecording()
        try await waitUntil { controller.state == .recording }
        controller.stopRecording()
        try await waitUntil { controller.state == .succeeded }

        XCTAssertEqual(session.appendedBufferCount, 1)
    }

    func testRetryCountAndRecordingStartSoundAreApplied() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        var settings = Self.testSettings()
        settings.transcriptionBackend = .openAI
        settings.openAIRetryCount = 4
        settings.playSoundOnRecordStart = true
        let session = TestLiveSession(
            finalTranscript: Transcript(text: "done", localeIdentifier: "en-US")
        )
        var receivedRetryCount: Int?
        var soundCount = 0
        let controller = DictationSessionController(
            capture: TestCapture(recordingURL: sourceURL),
            engineFactory: { _, retryCount in
                receivedRetryCount = retryCount
                return TestEngine(session: session)
            },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { settings },
            recordingDirectory: outputDirectory,
            recordingStartedHandler: { soundCount += 1 }
        )

        controller.startRecording()
        try await waitUntil { controller.state == .recording }

        XCTAssertEqual(receivedRetryCount, 4)
        XCTAssertEqual(soundCount, 1)
        controller.cancelRecording()
    }

    func testCancellingWhileLiveSessionStartsNeverStartsCapture() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let capture = TestCapture(recordingURL: sourceURL)
        let session = TestLiveSession(
            finalTranscript: Transcript(text: "stale", localeIdentifier: "en-US")
        )
        let engine = DelayedStartEngine(session: session)
        let controller = DictationSessionController(
            capture: capture,
            engineFactory: { _, _ in engine },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        controller.startRecording()
        try await waitUntil { engine.hasPendingStart }
        controller.cancelRecording()
        engine.resumeStart()

        try await waitUntil { session.cancelled }
        XCTAssertFalse(capture.startCalled)
        XCTAssertFalse(capture.isRecording)
        XCTAssertEqual(controller.state, .idle)
    }

    func testEveryImportedRecordingGetsAUniqueFile() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let session = TestLiveSession(
            finalTranscript: Transcript(text: "saved", localeIdentifier: "en-US")
        )
        let controller = DictationSessionController(
            capture: TestCapture(recordingURL: sourceURL),
            engineFactory: { _, _ in TestEngine(session: session) },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        let first = try await controller.transcribeFile(at: sourceURL, duration: 1)
        let second = try await controller.transcribeFile(at: sourceURL, duration: 1)

        XCTAssertNotEqual(first.recording.fileName, second.recording.fileName)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent(first.recording.fileName).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent(second.recording.fileName).path
        ))
    }

    func testImportedRecordingPreservesNormalizedSourceExtension() async throws {
        let sourceURL = try temporaryAudioFile(fileExtension: "M4A")
        let extensionlessSourceURL = try temporaryAudioFile(fileExtension: "")
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: extensionlessSourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let controller = DictationSessionController(
            capture: TestCapture(recordingURL: sourceURL),
            engineFactory: { _, _ in TestEngine(session: TestLiveSession(
                finalTranscript: Transcript(text: "saved", localeIdentifier: "en-US")
            )) },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        let result = try await controller.transcribeFile(at: sourceURL, duration: 1)

        XCTAssertEqual(
            URL(fileURLWithPath: result.recording.fileName).pathExtension,
            "m4a"
        )
        XCTAssertEqual(
            try Data(contentsOf: outputDirectory.appendingPathComponent(result.recording.fileName)),
            Data("audio".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))

        let fallbackResult = try await controller.transcribeFile(
            at: extensionlessSourceURL,
            duration: 1
        )
        XCTAssertEqual(
            URL(fileURLWithPath: fallbackResult.recording.fileName).pathExtension,
            "wav"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: extensionlessSourceURL.path))
    }

    func testImportedCancellationDuringPrepareNeverStartsTranscription() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let engine = DelayedPrepareEngine(
            transcript: Transcript(text: "must not upload", localeIdentifier: "en-US")
        )
        let controller = DictationSessionController(
            capture: TestCapture(recordingURL: sourceURL),
            engineFactory: { _, _ in engine },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        let operation = Task { @MainActor in
            try? await controller.transcribeFile(at: sourceURL, duration: 1)
        }
        try await waitUntil { engine.hasPendingPrepare }

        controller.cancelRecording()
        engine.resumePrepare()
        _ = await operation.value

        XCTAssertEqual(engine.transcribeFileCallCount, 0)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).count, 0)
    }

    func testStaleImportedOperationCannotClearNextOperationTask() async throws {
        let firstSourceURL = try temporaryAudioFile()
        let secondSourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstSourceURL)
            try? FileManager.default.removeItem(at: secondSourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let firstEngine = DelayedFileEngine(
            transcript: Transcript(text: "first", localeIdentifier: "en-US")
        )
        let secondEngine = DelayedFileEngine(
            transcript: Transcript(text: "second", localeIdentifier: "en-US")
        )
        let store = RecordingStoreSpy()
        var factoryCallCount = 0
        let controller = DictationSessionController(
            capture: TestCapture(recordingURL: firstSourceURL),
            engineFactory: { _, _ in
                factoryCallCount += 1
                return factoryCallCount == 1 ? firstEngine : secondEngine
            },
            recordingStore: store,
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        let firstOperation = Task { @MainActor in
            try? await controller.transcribeFile(at: firstSourceURL, duration: 1)
        }
        try await waitUntil { firstEngine.hasPendingTranscription }
        controller.cancelRecording()

        let secondOperation = Task { @MainActor in
            try? await controller.transcribeFile(at: secondSourceURL, duration: 1)
        }
        try await waitUntil { secondEngine.hasPendingTranscription }

        // Let the stale operation finish after the next operation owns the
        // controller's task slot. Its cleanup must not clear the second task.
        firstEngine.resumeTranscription()
        _ = await firstOperation.value
        XCTAssertTrue(secondEngine.hasPendingTranscription)

        controller.cancelRecording()
        secondEngine.resumeTranscription()
        _ = await secondOperation.value

        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).count, 0)
    }

    func testCancellationDuringHistoryInsertCompensatesBeforeNextOperationSucceeds() async throws {
        let firstSourceURL = try temporaryAudioFile()
        let secondSourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstSourceURL)
            try? FileManager.default.removeItem(at: secondSourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let store = SuspendingRecordingStoreSpy()
        var factoryCallCount = 0
        let controller = DictationSessionController(
            capture: TestCapture(recordingURL: firstSourceURL),
            engineFactory: { _, _ in
                factoryCallCount += 1
                let text = factoryCallCount == 1 ? "first" : "second"
                return TestEngine(session: TestLiveSession(
                    finalTranscript: Transcript(text: text, localeIdentifier: "en-US")
                ))
            },
            recordingStore: store,
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        let firstOperation = Task { @MainActor in
            try? await controller.transcribeFile(at: firstSourceURL, duration: 1)
        }
        try await waitUntil { store.pendingAddCount == 1 }
        let firstPendingRecording = try XCTUnwrap(store.pendingRecordings.first)

        controller.cancelRecording()

        let secondOperation = Task { @MainActor in
            try? await controller.transcribeFile(at: secondSourceURL, duration: 1)
        }
        try await waitUntil { store.pendingAddCount == 2 }
        let secondPendingRecording = try XCTUnwrap(store.pendingRecordings.last)

        // The first row has already been inserted by the suspended store when
        // this continuation resumes. The controller must remove that row and
        // its copied file before the replacement operation can succeed.
        store.resumeNextAdd()
        _ = await firstOperation.value
        try await waitUntil { store.removedRecordings.count == 1 }
        XCTAssertEqual(store.recordings.count, 0)
        XCTAssertEqual(store.pendingAddCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent(firstPendingRecording.fileName).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent(secondPendingRecording.fileName).path
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).count, 1)

        store.resumeNextAdd()
        _ = await secondOperation.value

        let savedRecording = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent(savedRecording.fileName).path
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstSourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondSourceURL.path))
    }

    func testCancellationRemovesInsertedRowWhenFileRollbackFails() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let store = SuspendingRecordingStoreSpy()
        let controller = DictationSessionController(
            capture: TestCapture(recordingURL: sourceURL),
            engineFactory: { _, _ in TestEngine(session: TestLiveSession(
                finalTranscript: Transcript(text: "stale", localeIdentifier: "en-US")
            )) },
            recordingStore: store,
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        let operation = Task { @MainActor in
            try? await controller.transcribeFile(at: sourceURL, duration: 1)
        }
        try await waitUntil { store.pendingAddCount == 1 }
        let pendingRecording = try XCTUnwrap(store.pendingRecordings.first)
        try FileManager.default.removeItem(
            at: outputDirectory.appendingPathComponent(pendingRecording.fileName)
        )

        controller.cancelRecording()
        store.resumeNextAdd()
        _ = await operation.value

        try await waitUntil { store.removedRecordings.count == 1 }
        XCTAssertEqual(store.removedRecordings.first?.id, pendingRecording.id)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).count, 0)
    }

    func testImportedDatabaseFailureRollsBackCopiedFile() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let store = FailingRecordingStoreSpy()
        let controller = DictationSessionController(
            capture: TestCapture(recordingURL: sourceURL),
            engineFactory: { _, _ in
                TestEngine(session: TestLiveSession(
                    finalTranscript: Transcript(text: "db failure", localeIdentifier: "en-US")
                ))
            },
            recordingStore: store,
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        do {
            _ = try await controller.transcribeFile(at: sourceURL, duration: 1)
            XCTFail("Expected database insertion to fail")
        } catch {
            XCTAssertEqual(error as? RecordingStoreTestError, .insertFailed)
        }

        XCTAssertEqual(store.attemptCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).count, 0)
        XCTAssertEqual(controller.state, .failed("The test history store rejected the recording."))
    }

    func testLiveDatabaseFailureRestoresMovedCapture() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let capture = TestCapture(recordingURL: sourceURL)
        let session = TestLiveSession(
            finalTranscript: Transcript(text: "db failure", localeIdentifier: "en-US")
        )
        let controller = DictationSessionController(
            capture: capture,
            engineFactory: { _, _ in TestEngine(session: session) },
            recordingStore: FailingRecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        controller.startRecording()
        try await waitUntil { controller.state == .recording }
        controller.stopRecording()
        try await waitUntil { if case .failed = controller.state { return true }; return false }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).count, 0)
    }

    func testOnboardingIgnoresStatusForPreviouslySelectedLocale() async throws {
        let originalLocale = AppPreferences.shared.localeIdentifier
        defer { AppPreferences.shared.localeIdentifier = originalLocale }

        let manager = DelayedAssetManager()
        let viewModel = OnboardingViewModel(assetManager: manager)
        viewModel.selectedLocaleIdentifier = "en-US"
        try await waitUntil { manager.hasPendingStatus(for: "en-US") }

        viewModel.selectedLocaleIdentifier = "fr-FR"
        try await waitUntil { manager.hasPendingStatus(for: "fr-FR") }
        manager.resumeStatus(for: "fr-FR", state: .supported)
        try await waitUntil {
            viewModel.status.map { LanguageUtil.localeIdentifier(for: $0.locale) == "fr-FR" } == true
        }

        manager.resumeStatus(for: "en-US", state: .installed)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(viewModel.status?.state, .supported)
        XCTAssertFalse(viewModel.isReady)
        XCTAssertEqual(
            LanguageUtil.localeIdentifier(for: viewModel.status?.locale ?? Locale(identifier: "")),
            "fr-FR"
        )
    }

    private static func testSettings() -> Settings {
        var settings = Settings()
        settings.transcriptionBackend = TranscriptionBackend.appleSpeech
        settings.localeIdentifier = "en-US"
        settings.recognitionContext = ""
        return settings
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for controller state")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func temporaryAudioFile(fileExtension: String = "wav") throws -> URL {
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisperController-\(UUID().uuidString)\(suffix)")
        try Data("audio".utf8).write(to: url)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisperController-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func audioBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 16_000,
            channels: 1
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        return buffer
    }
}

@MainActor
private final class TestCapture: DictationAudioCapture {
    private(set) var isRecording = false
    private(set) var currentRecordingURL: URL?
    private(set) var startCalled = false
    private(set) var stopCalled = false
    private(set) var cancelCalled = false
    var bufferOnStop: AVAudioPCMBuffer?
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    init(recordingURL: URL) {
        self.currentRecordingURL = recordingURL
    }

    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        startCalled = true
        self.bufferHandler = bufferHandler
        isRecording = true
    }

    func stop() throws -> URL? {
        stopCalled = true
        isRecording = false
        if let bufferOnStop {
            bufferHandler?(bufferOnStop)
        }
        return currentRecordingURL
    }

    func cancel() {
        cancelCalled = true
        isRecording = false
    }
}

private final class DelayedStartEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let session: TestLiveSession
    private var continuation: CheckedContinuation<any LiveTranscriptionSession, Never>?

    init(session: TestLiveSession) {
        self.session = session
    }

    var hasPendingStart: Bool {
        lock.withLock { continuation != nil }
    }

    func prepare(locale: Locale) async throws {}

    func startSession(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> any LiveTranscriptionSession {
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func transcribeFile(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> Transcript {
        session.finalTranscript
    }

    func resumeStart() {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: session)
    }
}

private final class DelayedPrepareEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let transcript: Transcript
    private var prepareContinuation: CheckedContinuation<Void, Never>?
    private var transcribeCalls = 0

    init(transcript: Transcript) {
        self.transcript = transcript
    }

    var hasPendingPrepare: Bool {
        lock.withLock { prepareContinuation != nil }
    }

    var transcribeFileCallCount: Int {
        lock.withLock { transcribeCalls }
    }

    func prepare(locale: Locale) async throws {
        _ = locale
        await withCheckedContinuation { continuation in
            lock.withLock {
                prepareContinuation = continuation
            }
        }
    }

    func startSession(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> any LiveTranscriptionSession {
        TestLiveSession(finalTranscript: transcript)
    }

    func transcribeFile(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> Transcript {
        _ = (url, locale, context, expectedTerms)
        lock.withLock { transcribeCalls += 1 }
        return transcript
    }

    func resumePrepare() {
        let continuation = lock.withLock {
            let continuation = prepareContinuation
            prepareContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class DelayedFileEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let transcript: Transcript
    private var transcribeContinuation: CheckedContinuation<Transcript, Never>?

    init(transcript: Transcript) {
        self.transcript = transcript
    }

    var hasPendingTranscription: Bool {
        lock.withLock { transcribeContinuation != nil }
    }

    func prepare(locale: Locale) async throws {}

    func startSession(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> any LiveTranscriptionSession {
        TestLiveSession(finalTranscript: transcript)
    }

    func transcribeFile(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> Transcript {
        _ = (url, locale, context, expectedTerms)
        return await withCheckedContinuation { continuation in
            lock.withLock {
                transcribeContinuation = continuation
            }
        }
    }

    func resumeTranscription() {
        let continuation = lock.withLock {
            let continuation = transcribeContinuation
            transcribeContinuation = nil
            return continuation
        }
        continuation?.resume(returning: transcript)
    }
}

private final class TestEngine: TranscriptionEngine, @unchecked Sendable {
    let session: TestLiveSession

    init(session: TestLiveSession) {
        self.session = session
    }

    func prepare(locale: Locale) async throws {}

    func startSession(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> any LiveTranscriptionSession {
        session
    }

    func transcribeFile(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> Transcript {
        session.finalTranscript
    }
}

private final class TestLiveSession: LiveTranscriptionSession, @unchecked Sendable {
    let updates: AsyncStream<TranscriptUpdate>
    let finalTranscript: Transcript
    private let continuation: AsyncStream<TranscriptUpdate>.Continuation
    private(set) var cancelled = false
    private let appendLock = NSLock()
    private var appendedBuffers = 0

    var appendedBufferCount: Int {
        appendLock.lock()
        defer { appendLock.unlock() }
        return appendedBuffers
    }

    init(finalTranscript: Transcript) {
        self.finalTranscript = finalTranscript
        var streamContinuation: AsyncStream<TranscriptUpdate>.Continuation!
        self.updates = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func yield(_ update: TranscriptUpdate) {
        continuation.yield(update)
    }

    func append(buffer: AVAudioPCMBuffer) async throws {
        _ = buffer
        appendLock.withLock {
            appendedBuffers += 1
        }
    }

    func finalize() async throws -> Transcript {
        finalTranscript
    }

    func cancel() async {
        cancelled = true
        continuation.finish()
    }
}

private enum RecordingStoreTestError: LocalizedError, Equatable {
    case insertFailed

    var errorDescription: String? {
        "The test history store rejected the recording."
    }
}

@MainActor
private final class IndicatorDelegateSpy: IndicatorViewDelegate {
    private(set) var finishCount = 0

    func didFinishDecoding(_: IndicatorViewModel) {
        finishCount += 1
    }
}

@MainActor
private final class RecordingStoreSpy: DictationRecordingStore {
    private(set) var recordings: [Recording] = []

    func addRecording(_ recording: Recording) async throws {
        recordings.append(recording)
    }

    func removeRecording(_ recording: Recording) async throws {
        recordings.removeAll { $0.id == recording.id }
    }
}

@MainActor
private final class FailingRecordingStoreSpy: DictationRecordingStore {
    private(set) var attemptCount = 0

    func addRecording(_ recording: Recording) async throws {
        _ = recording
        attemptCount += 1
        throw RecordingStoreTestError.insertFailed
    }

    func removeRecording(_ recording: Recording) async throws {
        _ = recording
    }
}

@MainActor
private final class SuspendingRecordingStoreSpy: DictationRecordingStore {
    private struct PendingInsert {
        let recording: Recording
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var recordings: [Recording] = []
    private(set) var removedRecordings: [Recording] = []
    private var pendingInserts: [PendingInsert] = []

    var pendingAddCount: Int { pendingInserts.count }
    var pendingRecordings: [Recording] { pendingInserts.map(\.recording) }

    func addRecording(_ recording: Recording) async throws {
        await withCheckedContinuation { continuation in
            pendingInserts.append(PendingInsert(recording: recording, continuation: continuation))
        }
        recordings.append(recording)
    }

    func removeRecording(_ recording: Recording) async throws {
        recordings.removeAll { $0.id == recording.id }
        removedRecordings.append(recording)
    }

    func resumeNextAdd() {
        guard !pendingInserts.isEmpty else { return }
        pendingInserts.removeFirst().continuation.resume()
    }
}

@MainActor
private final class DelayedAssetManager: AppleSpeechAssetManaging {
    var supportedLocales: [Locale] = []
    var installedLocales: [Locale] = []
    var activeLocale: Locale?
    var currentStatus: AppleSpeechAssetStatus?

    private var statusContinuations: [String: CheckedContinuation<AppleSpeechAssetStatus, Never>] = [:]

    func refresh() async -> [Locale] { supportedLocales }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? { locale }

    func status(for locale: Locale) async -> AppleSpeechAssetStatus {
        let identifier = LanguageUtil.localeIdentifier(for: locale)
        return await withCheckedContinuation { continuation in
            statusContinuations[identifier] = continuation
        }
    }

    func prepare(locale: Locale) async throws -> Locale { locale }

    func release(locale: Locale?) async {}

    func hasPendingStatus(for identifier: String) -> Bool {
        statusContinuations[LanguageUtil.normalizedLocaleIdentifier(identifier)] != nil
    }

    func resumeStatus(for identifier: String, state: AppleSpeechAssetState) {
        let normalized = LanguageUtil.normalizedLocaleIdentifier(identifier)
        statusContinuations.removeValue(forKey: normalized)?.resume(returning: AppleSpeechAssetStatus(
            locale: LanguageUtil.locale(for: normalized),
            state: state
        ))
    }
}
