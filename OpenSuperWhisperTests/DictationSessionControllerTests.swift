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
        let engine = TestProvider(session: session)
        let store = RecordingStoreSpy()
        var pastedText: String?
        let controller = DictationSessionController(
            captureFactory: capture,
            providerFactory: { _, _ in engine },
            recordingStore: store,
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory,
            pasteHandler: { pastedText = $0 }
        )
        let indicatorDelegate = IndicatorDelegateSpy()
        let indicator = IndicatorViewModel(sessionController: controller)
        indicator.delegate = indicatorDelegate

        XCTAssertNotNil(indicator.startRecording())
        await waitForController(controller, description: "recording state") {
            controller.state == .recording
        }

        session.yield(TranscriptUpdate(text: "volatile draft", progress: 0.4))
        await waitForController(controller, description: "interim transcript") {
            controller.interimText == "volatile draft"
        }
        XCTAssertTrue(store.recordings.isEmpty)

        controller.stopRecording()
        await waitForController(controller, description: "successful recording") {
            controller.state == .succeeded
        }

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
        let engine = TestProvider(session: session)
        let store = RecordingStoreSpy()
        let controller = DictationSessionController(
            captureFactory: capture,
            providerFactory: { _, _ in engine },
            recordingStore: store,
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        controller.startRecording()
        await waitForController(controller, description: "recording state") {
            controller.state == .recording
        }
        controller.cancelRecording()

        await waitForTestEvent(session.cancelEvent, description: "live session cancellation")
        await waitForController(controller, description: "idle after cancellation") {
            controller.state == .idle
        }
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(capture.cancelCalled)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testCancellationPublishesVisibleCancellingAndRejectsReplacement() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let capture = TestCapture(recordingURL: sourceURL)
        let session = TestLiveSession(finalTranscript: Transcript(text: "unused", localeIdentifier: "en-US"))
        let engine = DelayedStartProvider(session: session)
        let controller = DictationSessionController(
            captureFactory: capture,
            providerFactory: { _, _ in engine },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        let token = try XCTUnwrap(controller.startRecording(source: .shortcut))
        await waitForTestEvent(engine.startEvent, description: "live session start gate")
        XCTAssertEqual(controller.snapshot.token, token)
        XCTAssertEqual(controller.snapshot.phase, .preparing)

        XCTAssertTrue(controller.cancelRecording(token: token))
        XCTAssertEqual(controller.snapshot.token, token)
        XCTAssertEqual(controller.snapshot.phase, .cancelling)
        XCTAssertFalse(controller.snapshot.canCancel)
        XCTAssertNil(controller.startRecording(source: .mainWindow))

        engine.resumeStart()
        await waitForTestEvent(session.cancelEvent, description: "live session cancellation")
        await waitForController(controller, description: "idle after cancellation") {
            controller.state == .idle
        }
        XCTAssertNil(controller.operationToken)
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
            captureFactory: capture,
            providerFactory: { _, _ in TestProvider(session: session) },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        controller.startRecording()
        await waitForController(controller, description: "recording state") {
            controller.state == .recording
        }
        controller.stopRecording()
        await waitForController(controller, description: "successful recording") {
            controller.state == .succeeded
        }

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
            captureFactory: TestCapture(recordingURL: sourceURL),
            providerFactory: { _, retryCount in
                receivedRetryCount = retryCount
                return TestProvider(session: session)
            },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { settings },
            recordingDirectory: outputDirectory,
            recordingStartedHandler: { soundCount += 1 }
        )

        controller.startRecording()
        await waitForController(controller, description: "recording state") {
            controller.state == .recording
        }

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
        let engine = DelayedStartProvider(session: session)
        let controller = DictationSessionController(
            captureFactory: capture,
            providerFactory: { _, _ in engine },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        controller.startRecording()
        await waitForTestEvent(engine.startEvent, description: "live session start gate")
        controller.cancelRecording()
        engine.resumeStart()

        await waitForTestEvent(session.cancelEvent, description: "live session cancellation")
        await waitForController(controller, description: "idle after cancellation") {
            controller.state == .idle
        }
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
            captureFactory: TestCapture(recordingURL: sourceURL),
            providerFactory: { _, _ in TestProvider(session: session) },
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

    func testFailReservedOperationPublishesMatchingControllerFailure() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let capture = TestCapture(recordingURL: sourceURL)
        let diagnostics = ControllerDiagnosticSinkSpy()
        let controller = DictationSessionController(
            captureFactory: capture,
            providerFactory: { _, _ in TestProvider(session: TestLiveSession(
                finalTranscript: Transcript(text: "unused", localeIdentifier: "en-US")
            )) },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory,
            diagnosticSink: diagnostics
        )

        let token = try XCTUnwrap(controller.reserve(source: .fileDrop))
        let error = NSError(
            domain: "DictationSessionControllerTests",
            code: 901,
            userInfo: [NSLocalizedDescriptionKey: "Provider item failed to load."]
        )

        let accepted = await controller.failReservedOperation(error, token: token)
        XCTAssertTrue(accepted)
        XCTAssertEqual(controller.state, .failed("Provider item failed to load."))
        XCTAssertEqual(controller.snapshot.token, token)
        XCTAssertEqual(controller.snapshot.outcome, .failed)
        XCTAssertEqual(controller.errorMessage, "Provider item failed to load.")
        XCTAssertNil(controller.operationToken)
        XCTAssertFalse(capture.startCalled)
        XCTAssertEqual(capture.cancelCallCount, 1)
    }

    func testFailReservedOperationEmitsExactlyOneTerminalFailure() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let capture = TestCapture(recordingURL: sourceURL)
        let diagnostics = ControllerDiagnosticSinkSpy()
        let controller = DictationSessionController(
            captureFactory: capture,
            providerFactory: { _, _ in TestProvider(session: TestLiveSession(
                finalTranscript: Transcript(text: "unused", localeIdentifier: "en-US")
            )) },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory,
            diagnosticSink: diagnostics
        )

        let token = try XCTUnwrap(controller.reserve(source: .fileDrop))
        let error = NSError(
            domain: "DictationSessionControllerTests",
            code: 902,
            userInfo: [NSLocalizedDescriptionKey: "Provider item failed to load."]
        )

        let accepted = await controller.failReservedOperation(error, token: token)
        let duplicate = await controller.failReservedOperation(error, token: token)
        XCTAssertTrue(accepted)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(
            diagnostics.events.filter { $0.outcome == .failed }.count,
            1
        )
        XCTAssertEqual(capture.cancelCallCount, 1)
        XCTAssertEqual(controller.lastTerminalOutcome, .failed)
    }

    func testFailReservedOperationIgnoresStaleToken() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let capture = TestCapture(recordingURL: sourceURL)
        let controller = DictationSessionController(
            captureFactory: capture,
            providerFactory: { _, _ in TestProvider(session: TestLiveSession(
                finalTranscript: Transcript(text: "unused", localeIdentifier: "en-US")
            )) },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        let staleToken = try XCTUnwrap(controller.reserve(source: .fileDrop))
        let failure = NSError(
            domain: "DictationSessionControllerTests",
            code: 903,
            userInfo: [NSLocalizedDescriptionKey: "First provider item failed."]
        )
        let accepted = await controller.failReservedOperation(failure, token: staleToken)
        XCTAssertTrue(accepted)

        let replacementToken = try XCTUnwrap(controller.reserve(source: .fileDrop))
        let staleFailure = NSError(
            domain: "DictationSessionControllerTests",
            code: 904,
            userInfo: [NSLocalizedDescriptionKey: "Stale provider item failed."]
        )
        let staleResult = await controller.failReservedOperation(staleFailure, token: staleToken)
        XCTAssertFalse(staleResult)
        XCTAssertEqual(controller.operationToken, replacementToken)
        XCTAssertEqual(controller.snapshot.token, replacementToken)
        XCTAssertEqual(controller.snapshot.phase, .preparing)
        XCTAssertNil(controller.errorMessage)

        let cancelled = await controller.cancelRecordingAndWait(token: replacementToken)
        XCTAssertTrue(cancelled)
        XCTAssertNil(controller.operationToken)
    }

    func testFailReservedOperationHoldsReservationUntilCaptureDrainCompletes() async throws {
        let outputDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let capture = ReservedFailureCapture()
        let controller = DictationSessionController(
            captureFactory: capture,
            providerFactory: { _, _ in TestProvider(session: TestLiveSession(
                finalTranscript: Transcript(text: "unused", localeIdentifier: "en-US")
            )) },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        let token = try XCTUnwrap(controller.reserve(source: .fileDrop))
        let error = NSError(
            domain: "DictationSessionControllerTests",
            code: 905,
            userInfo: [NSLocalizedDescriptionKey: "Provider item failed to load."]
        )
        let failureTask = Task { @MainActor in
            await controller.failReservedOperation(error, token: token)
        }

        await waitForTestEvent(capture.cancelStarted, description: "reserved failure capture drain")
        XCTAssertEqual(controller.snapshot.token, token)
        XCTAssertEqual(controller.snapshot.phase, .cancelling)
        XCTAssertNil(controller.reserve(source: .fileDrop))

        capture.releaseCancel()
        let accepted = await failureTask.value
        XCTAssertTrue(accepted)
        XCTAssertNil(controller.operationToken)

        let replacementToken = try XCTUnwrap(controller.reserve(source: .fileDrop))
        let cancellationTask = Task { @MainActor in
            await controller.cancelRecordingAndWait(token: replacementToken)
        }
        await waitForTestEvent(capture.cancelStarted, description: "replacement capture drain")
        capture.releaseCancel()
        let cancelled = await cancellationTask.value
        XCTAssertTrue(cancelled)
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
            captureFactory: TestCapture(recordingURL: sourceURL),
            providerFactory: { _, _ in TestProvider(session: TestLiveSession(
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

        let engine = DelayedPrepareProvider(
            transcript: Transcript(text: "must not upload", localeIdentifier: "en-US")
        )
        let controller = DictationSessionController(
            captureFactory: TestCapture(recordingURL: sourceURL),
            providerFactory: { _, _ in engine },
            recordingStore: RecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        let operation = Task { @MainActor in
            try? await controller.transcribeFile(at: sourceURL, duration: 1)
        }
        await waitForTestEvent(engine.prepareEvent, description: "file preparation gate")

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

        let firstEngine = DelayedFileProvider(
            transcript: Transcript(text: "first", localeIdentifier: "en-US")
        )
        let secondEngine = DelayedFileProvider(
            transcript: Transcript(text: "second", localeIdentifier: "en-US")
        )
        let store = RecordingStoreSpy()
        var factoryCallCount = 0
        let controller = DictationSessionController(
            captureFactory: TestCapture(recordingURL: firstSourceURL),
            providerFactory: { _, _ in
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
        await waitForTestEvent(firstEngine.transcriptionEvent, description: "first file transcription gate")
        controller.cancelRecording()

        // Replacement is rejected while the first provider is still draining.
        // Resume the non-cooperative fake so cancellation can finish, then
        // admit the replacement with a fresh token.
        firstEngine.resumeTranscription()
        _ = await firstOperation.value

        XCTAssertNil(controller.operationToken)
        let secondOperation = Task { @MainActor in
            try? await controller.transcribeFile(at: secondSourceURL, duration: 1)
        }
        await waitForTestEvent(secondEngine.transcriptionEvent, description: "second file transcription gate")

        // The first token's completion cannot clear the second operation's
        // task slot because the controller admitted it only after cleanup.
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
            captureFactory: TestCapture(recordingURL: firstSourceURL),
            providerFactory: { _, _ in
                factoryCallCount += 1
                let text = factoryCallCount == 1 ? "first" : "second"
                return TestProvider(session: TestLiveSession(
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
        await waitForTestEvent(store.pendingAddEvent, description: "first history insert gate")
        let firstPendingRecording = try XCTUnwrap(store.pendingRecordings.first)

        controller.cancelRecording()

        // A replacement is rejected until the suspended insert returns and
        // its commit receipt/row compensation has completed.
        let rejectedReplacement = Task { @MainActor in
            try? await controller.transcribeFile(at: secondSourceURL, duration: 1)
        }
        _ = await rejectedReplacement.value
        XCTAssertEqual(store.pendingAddCount, 1)

        // Let the first row become durable, then allow cancellation to remove
        // it and release the controller reservation before starting the next
        // operation.
        store.resumeNextAdd()
        _ = await firstOperation.value
        await waitForTestEvent(store.removeEvent, description: "first history compensation")

        let secondOperation = Task { @MainActor in
            try? await controller.transcribeFile(at: secondSourceURL, duration: 1)
        }
        await waitForTestEvent(store.pendingAddEvent, description: "second history insert gate")
        let secondPendingRecording = try XCTUnwrap(store.pendingRecordings.last)

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
            captureFactory: TestCapture(recordingURL: sourceURL),
            providerFactory: { _, _ in TestProvider(session: TestLiveSession(
                finalTranscript: Transcript(text: "stale", localeIdentifier: "en-US")
            )) },
            recordingStore: store,
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        let operation = Task { @MainActor in
            try? await controller.transcribeFile(at: sourceURL, duration: 1)
        }
        await waitForTestEvent(store.pendingAddEvent, description: "history insert gate")
        let pendingRecording = try XCTUnwrap(store.pendingRecordings.first)
        try FileManager.default.removeItem(
            at: outputDirectory.appendingPathComponent(pendingRecording.fileName)
        )

        controller.cancelRecording()
        store.resumeNextAdd()
        _ = await operation.value

        await waitForTestEvent(store.removeEvent, description: "history compensation")
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
            captureFactory: TestCapture(recordingURL: sourceURL),
            providerFactory: { _, _ in
                TestProvider(session: TestLiveSession(
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

    func testUnavailableHistorySucceedsWithWarningAndPreservesImportedAudio() async throws {
        let sourceURL = try temporaryAudioFile(fileExtension: "m4a")
        let outputDirectory = try temporaryDirectory()
        let recoveryDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
            try? FileManager.default.removeItem(at: recoveryDirectory)
        }

        var pastedText: String?
        var copiedText: String?
        let controller = DictationSessionController(
            captureFactory: TestCapture(recordingURL: sourceURL),
            providerFactory: { _, _ in TestProvider(session: TestLiveSession(
                finalTranscript: Transcript(text: "kept despite history", localeIdentifier: "en-US")
            )) },
            recordingStore: UnavailableRecordingStoreSpy(recoveryDirectory: recoveryDirectory),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory,
            pasteHandler: { pastedText = $0 },
            copyHandler: { copiedText = $0 }
        )

        let token = try XCTUnwrap(controller.reserve(
            source: .importedFile,
            pasteOnCompletion: true
        ))
        let result = try await controller.transcribeFile(
            at: sourceURL,
            duration: 1,
            token: token
        )

        XCTAssertEqual(result.transcript.text, "kept despite history")
        XCTAssertEqual(controller.state, .succeeded)
        XCTAssertEqual(controller.lastTerminalOutcome, .succeededWithHistoryWarning)
        XCTAssertEqual(controller.snapshot.outcome, .succeededWithHistoryWarning)
        XCTAssertNotNil(controller.historyWarning)
        XCTAssertNil(pastedText)
        XCTAssertEqual(copiedText, "kept despite history")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "m4a" }.count, 1)
    }

    func testUnavailableHistoryDoesNotMoveImportedSourceWhenManagedCopyFails() async throws {
        let sourceURL = try temporaryAudioFile(fileExtension: "m4a")
        let outputDirectory = try temporaryDirectory()
        let recoveryDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
            try? FileManager.default.removeItem(at: recoveryDirectory)
        }

        // Keep the directory present so `persist` reaches the managed-copy
        // operation, then make that copy fail without removing the imported
        // source. Restore permissions before the cleanup defer removes it.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: outputDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: outputDirectory.path
            )
        }

        let controller = DictationSessionController(
            captureFactory: TestCapture(recordingURL: sourceURL),
            providerFactory: { _, _ in TestProvider(session: TestLiveSession(
                finalTranscript: Transcript(text: "copy must fail", localeIdentifier: "en-US")
            )) },
            recordingStore: UnavailableRecordingStoreSpy(recoveryDirectory: recoveryDirectory),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        do {
            _ = try await controller.transcribeFile(at: sourceURL, duration: 1)
            XCTFail("Expected managed copy to fail")
        } catch {
            // The copy error is a normal persistence failure, not a degraded
            // history success, even though the store reports unavailable.
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).count, 0)
        if case .failed = controller.state {
            // Expected terminal state.
        } else {
            XCTFail("A managed-copy failure must not report degraded success")
        }
    }

    func testLiveInputOverflowPreservesCaptureInRecoveryBeforeFailure() async throws {
        let sourceURL = try temporaryAudioFile()
        let outputDirectory = try temporaryDirectory()
        let recoveryDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
            try? FileManager.default.removeItem(at: recoveryDirectory)
        }

        let capture = TestCapture(recordingURL: sourceURL)
        capture.bufferOnStop = try audioBuffer()
        let overflow = CoreTranscriptionError.liveInputOverflow(maximumDuration: 5)
        let session = TestLiveSession(
            finalTranscript: Transcript(text: "must recover", localeIdentifier: "en-US"),
            appendError: overflow
        )
        let store = RecordingStoreSpy(recoveryDirectory: recoveryDirectory)
        let controller = DictationSessionController(
            captureFactory: capture,
            providerFactory: { _, _ in TestProvider(session: session) },
            recordingStore: store,
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        controller.startRecording()
        await waitForController(controller, description: "recording state") {
            controller.state == .recording
        }
        controller.stopRecording()
        await waitForController(controller, description: "overflow failure") {
            if case .failed = controller.state { return true }
            return false
        }

        XCTAssertTrue(controller.errorMessage?.contains("preserved for recovery") == true)
        XCTAssertTrue(controller.currentAudioURL == nil)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "wav" }.count, 1)
        XCTAssertTrue(store.recordings.isEmpty)
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
            captureFactory: capture,
            providerFactory: { _, _ in TestProvider(session: session) },
            recordingStore: FailingRecordingStoreSpy(),
            settingsProvider: { Self.testSettings() },
            recordingDirectory: outputDirectory
        )

        controller.startRecording()
        await waitForController(controller, description: "recording state") {
            controller.state == .recording
        }
        controller.stopRecording()
        await waitForController(controller, description: "failed persistence state") {
            if case .failed = controller.state { return true }
            return false
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).count, 0)
    }

    func testOnboardingIgnoresStatusForPreviouslySelectedLocale() async throws {
        let manager = DelayedAssetManager()
        let viewModel = OnboardingViewModel(assetManager: manager)
        let identifier = viewModel.selectedLocaleIdentifier

        viewModel.refreshAssetStatus()
        await waitForTestEvent(manager.statusRequestedEvent, description: "first locale status request")

        viewModel.refreshAssetStatus()
        await waitForTestEvent(manager.statusRequestedEvent, description: "replacement status request")
        manager.resumeStatus(for: identifier, state: .supported)
        await waitForOnboarding(viewModel, description: "replacement locale status") {
            viewModel.status?.state == .supported
        }

        // Complete the canceled request after the replacement. Its stale
        // result must not overwrite the newer status for the same locale.
        manager.resumeStatus(for: identifier, state: .installed, oldest: true)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(viewModel.status?.state, .supported)
        XCTAssertFalse(viewModel.isReady)
        XCTAssertEqual(
            LanguageUtil.localeIdentifier(for: viewModel.status?.locale ?? Locale(identifier: "")),
            identifier
        )
    }

    private static func testSettings() -> Settings {
        var settings = Settings()
        settings.transcriptionBackend = TranscriptionBackend.appleSpeech
        settings.localeIdentifier = "en-US"
        settings.recognitionContext = ""
        return settings
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

private final class TestCapture: DictationAudioCaptureFactory, DictationAudioCaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var recordingURL: URL?
    private var didStart = false
    private var didStop = false
    private var didCancel = false
    private var cancelCount = 0
    private var stopBuffer: AVAudioPCMBuffer?
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    let startEvent = TestEventRecorder()
    let stopEvent = TestEventRecorder()
    let cancelEvent = TestEventRecorder()

    init(recordingURL: URL) {
        self.recordingURL = recordingURL
    }

    var isRecording: Bool { lock.withLock { recording } }
    var currentRecordingURL: URL? { lock.withLock { recordingURL } }
    var startCalled: Bool { lock.withLock { didStart } }
    var stopCalled: Bool { lock.withLock { didStop } }
    var cancelCalled: Bool { lock.withLock { didCancel } }
    var cancelCallCount: Int { lock.withLock { cancelCount } }

    var bufferOnStop: AVAudioPCMBuffer? {
        get { lock.withLock { stopBuffer } }
        set { lock.withLock { stopBuffer = newValue } }
    }

    func makeSession() -> any DictationAudioCaptureSession { self }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        lock.withLock {
            didStart = true
            recording = true
            bufferHandler = onBuffer
        }
        startEvent.record()
    }

    func stopAndDrain() async throws -> AudioCaptureResult? {
        let payload = lock.withLock {
            didStop = true
            recording = false
            return (stopBuffer, bufferHandler, recordingURL)
        }
        if let buffer = payload.0 {
            payload.1?(buffer)
        }
        stopEvent.record()
        guard let url = payload.2 else { return nil }
        return AudioCaptureResult(fileURL: url, duration: 1, sampleRate: 1, channelCount: 1)
    }

    func cancelAndDrain() async {
        lock.withLock {
            didCancel = true
            cancelCount += 1
            recording = false
        }
        cancelEvent.record()
    }
}

private final class ReservedFailureCapture: DictationAudioCaptureFactory, DictationAudioCaptureSession, @unchecked Sendable {
    let cancelStarted = TestEventRecorder()
    private let lock = NSLock()
    private var cancelContinuation: CheckedContinuation<Void, Never>?

    func makeSession() -> any DictationAudioCaptureSession { self }

    var currentRecordingURL: URL? { nil }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        _ = onBuffer
    }

    func stopAndDrain() async throws -> AudioCaptureResult? { nil }

    func cancelAndDrain() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                cancelContinuation = continuation
            }
            cancelStarted.record()
        }
    }

    func releaseCancel() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { cancelContinuation = nil }
            return cancelContinuation
        }
        continuation?.resume()
    }
}

private final class TestProvider: TranscriptionProvider, @unchecked Sendable {
    let strategy: RecordingTranscriptionStrategy
    private let makeLive: @Sendable () -> any TranscriptionLiveOperation
    private let makeFile: @Sendable (URL) -> any TranscriptionFileOperation

    init(
        session: TestLiveSession,
        strategy: RecordingTranscriptionStrategy = .live
    ) {
        self.strategy = strategy
        makeLive = { session }
        makeFile = { _ in TestFileOperation(transcript: session.finalTranscript) }
    }

    init(
        strategy: RecordingTranscriptionStrategy,
        liveOperation: @escaping @Sendable () -> any TranscriptionLiveOperation,
        fileOperation: @escaping @Sendable (URL) -> any TranscriptionFileOperation
    ) {
        self.strategy = strategy
        makeLive = liveOperation
        makeFile = fileOperation
    }

    func makeLiveOperation(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> (any TranscriptionLiveOperation)? {
        guard strategy == .live else { return nil }
        return makeLive()
    }

    func makeFileOperation(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> any TranscriptionFileOperation {
        makeFile(url)
    }
}

private final class TestFileOperation: TranscriptionFileOperation, @unchecked Sendable {
    let events: AsyncStream<TranscriptionOperationEvent>
    private let eventContinuation: AsyncStream<TranscriptionOperationEvent>.Continuation
    private let transcript: Transcript
    private let lock = NSLock()
    private var cancelled = false

    init(transcript: Transcript) {
        self.transcript = transcript
        var continuation: AsyncStream<TranscriptionOperationEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func value() async throws -> Transcript {
        guard !lock.withLock({ cancelled }), !Task.isCancelled else {
            throw CoreTranscriptionError.cancelled
        }
        eventContinuation.yield(TranscriptionOperationEvent(phase: .exporting))
        eventContinuation.yield(TranscriptionOperationEvent(phase: .transcribing))
        eventContinuation.finish()
        return transcript
    }

    func cancelAndWait() async {
        lock.withLock { cancelled = true }
        eventContinuation.yield(TranscriptionOperationEvent(phase: .cancelling))
        eventContinuation.finish()
    }
}

private final class DelayedStartProvider: TranscriptionProvider, @unchecked Sendable {
    let strategy: RecordingTranscriptionStrategy = .live
    private let operation: DelayedStartOperation

    init(session: TestLiveSession) {
        operation = DelayedStartOperation(session: session)
    }

    var startEvent: TestEventRecorder { operation.startEvent }
    var hasPendingStart: Bool { operation.hasPendingStart }
    func resumeStart() { operation.resumeStart() }

    func makeLiveOperation(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> (any TranscriptionLiveOperation)? { operation }

    func makeFileOperation(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> any TranscriptionFileOperation {
        TestFileOperation(transcript: Transcript(text: "unused", localeIdentifier: "en-US"))
    }
}

private final class DelayedStartOperation: TranscriptionLiveOperation, @unchecked Sendable {
    let events: AsyncStream<TranscriptionOperationEvent>
    let updates: AsyncStream<TranscriptUpdate>
    let startEvent = TestEventRecorder()
    private let eventContinuation: AsyncStream<TranscriptionOperationEvent>.Continuation
    private let updateContinuation: AsyncStream<TranscriptUpdate>.Continuation
    private let session: TestLiveSession
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var cancelled = false

    init(session: TestLiveSession) {
        self.session = session
        var eventContinuation: AsyncStream<TranscriptionOperationEvent>.Continuation!
        var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation!
        events = AsyncStream { eventContinuation = $0 }
        updates = AsyncStream { updateContinuation = $0 }
        self.eventContinuation = eventContinuation
        self.updateContinuation = updateContinuation
    }

    var hasPendingStart: Bool { lock.withLock { startContinuation != nil } }

    func start() async throws {
        await withCheckedContinuation { continuation in
            lock.withLock {
                startContinuation = continuation
                startEvent.record()
            }
        }
        guard !lock.withLock({ cancelled }), !Task.isCancelled else {
            throw CoreTranscriptionError.cancelled
        }
        try await session.start()
        eventContinuation.yield(TranscriptionOperationEvent(phase: .preparing))
        eventContinuation.yield(TranscriptionOperationEvent(phase: .recording))
    }

    func append(buffer: AVAudioPCMBuffer) async throws {
        try await session.append(buffer: buffer)
    }

    func finish() async throws -> Transcript {
        try await session.finish()
    }

    func cancelAndWait() async {
        lock.withLock { cancelled = true }
        await session.cancelAndWait()
        updateContinuation.finish()
        eventContinuation.yield(TranscriptionOperationEvent(phase: .cancelling))
        eventContinuation.finish()
    }

    func resumeStart() {
        let continuation = lock.withLock {
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class DelayedPrepareProvider: TranscriptionProvider, @unchecked Sendable {
    let strategy: RecordingTranscriptionStrategy = .fileAfterCapture
    private let operation: DelayedPrepareOperation

    init(transcript: Transcript) { operation = DelayedPrepareOperation(transcript: transcript) }
    var prepareEvent: TestEventRecorder { operation.prepareEvent }
    var hasPendingPrepare: Bool { operation.hasPendingPrepare }
    var transcribeFileCallCount: Int { operation.transcribeFileCallCount }
    func resumePrepare() { operation.resumePrepare() }

    func makeLiveOperation(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> (any TranscriptionLiveOperation)? { nil }

    func makeFileOperation(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> any TranscriptionFileOperation { operation }
}

private final class DelayedPrepareOperation: TranscriptionFileOperation, @unchecked Sendable {
    let events: AsyncStream<TranscriptionOperationEvent>
    let prepareEvent = TestEventRecorder()
    private let eventContinuation: AsyncStream<TranscriptionOperationEvent>.Continuation
    private let transcript: Transcript
    private let lock = NSLock()
    private var prepareContinuation: CheckedContinuation<Void, Never>?
    private var transcribeCalls = 0
    private var cancelled = false

    init(transcript: Transcript) {
        self.transcript = transcript
        var continuation: AsyncStream<TranscriptionOperationEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    var hasPendingPrepare: Bool { lock.withLock { prepareContinuation != nil } }
    var transcribeFileCallCount: Int { lock.withLock { transcribeCalls } }

    func value() async throws -> Transcript {
        guard !lock.withLock({ cancelled }) else { throw CoreTranscriptionError.cancelled }
        eventContinuation.yield(TranscriptionOperationEvent(phase: .preparing))
        await withCheckedContinuation { continuation in
            lock.withLock {
                prepareContinuation = continuation
                prepareEvent.record()
            }
        }
        guard !lock.withLock({ cancelled }), !Task.isCancelled else {
            throw CoreTranscriptionError.cancelled
        }
        lock.withLock { transcribeCalls += 1 }
        eventContinuation.yield(TranscriptionOperationEvent(phase: .transcribing))
        eventContinuation.finish()
        return transcript
    }

    func cancelAndWait() async {
        lock.withLock { cancelled = true }
        eventContinuation.yield(TranscriptionOperationEvent(phase: .cancelling))
        eventContinuation.finish()
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

private final class DelayedFileProvider: TranscriptionProvider, @unchecked Sendable {
    let strategy: RecordingTranscriptionStrategy = .fileAfterCapture
    private let operation: DelayedFileOperation

    init(transcript: Transcript) { operation = DelayedFileOperation(transcript: transcript) }
    var transcriptionEvent: TestEventRecorder { operation.transcriptionEvent }
    var hasPendingTranscription: Bool { operation.hasPendingTranscription }
    func resumeTranscription() { operation.resumeTranscription() }

    func makeLiveOperation(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> (any TranscriptionLiveOperation)? { nil }

    func makeFileOperation(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> any TranscriptionFileOperation { operation }
}

private final class DelayedFileOperation: TranscriptionFileOperation, @unchecked Sendable {
    let events: AsyncStream<TranscriptionOperationEvent>
    let transcriptionEvent = TestEventRecorder()
    private let eventContinuation: AsyncStream<TranscriptionOperationEvent>.Continuation
    private let transcript: Transcript
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Transcript, Never>?
    private var cancelled = false

    init(transcript: Transcript) {
        self.transcript = transcript
        var eventContinuation: AsyncStream<TranscriptionOperationEvent>.Continuation!
        events = AsyncStream { eventContinuation = $0 }
        self.eventContinuation = eventContinuation
    }

    var hasPendingTranscription: Bool { lock.withLock { continuation != nil } }

    func value() async throws -> Transcript {
        guard !lock.withLock({ cancelled }) else { throw CoreTranscriptionError.cancelled }
        eventContinuation.yield(TranscriptionOperationEvent(phase: .transcribing))
        let value = await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                transcriptionEvent.record()
            }
        }
        guard !lock.withLock({ cancelled }), !Task.isCancelled else {
            throw CoreTranscriptionError.cancelled
        }
        eventContinuation.finish()
        return value
    }

    func cancelAndWait() async {
        lock.withLock { cancelled = true }
        eventContinuation.yield(TranscriptionOperationEvent(phase: .cancelling))
        eventContinuation.finish()
    }

    func resumeTranscription() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: transcript)
    }
}

private final class TestLiveSession: TranscriptionLiveOperation, @unchecked Sendable {
    let events: AsyncStream<TranscriptionOperationEvent>
    let updates: AsyncStream<TranscriptUpdate>
    let finalTranscript: Transcript
    let cancelEvent = TestEventRecorder()
    let updateEvent = TestEventRecorder()
    let appendEvent = TestEventRecorder()
    private let eventContinuation: AsyncStream<TranscriptionOperationEvent>.Continuation
    private let updateContinuation: AsyncStream<TranscriptUpdate>.Continuation
    private let appendError: Error?
    private let lock = NSLock()
    private var cancelledValue = false
    private var appendedBuffers = 0

    init(finalTranscript: Transcript, appendError: Error? = nil) {
        self.finalTranscript = finalTranscript
        self.appendError = appendError
        var eventContinuation: AsyncStream<TranscriptionOperationEvent>.Continuation!
        var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation!
        events = AsyncStream { eventContinuation = $0 }
        updates = AsyncStream { updateContinuation = $0 }
        self.eventContinuation = eventContinuation
        self.updateContinuation = updateContinuation
    }

    var cancelled: Bool { lock.withLock { cancelledValue } }
    var appendedBufferCount: Int { lock.withLock { appendedBuffers } }

    func yield(_ update: TranscriptUpdate) {
        updateContinuation.yield(update)
        updateEvent.record()
    }

    func start() async throws {
        guard !lock.withLock({ cancelledValue }) else { throw CoreTranscriptionError.cancelled }
        eventContinuation.yield(TranscriptionOperationEvent(phase: .preparing))
        eventContinuation.yield(TranscriptionOperationEvent(phase: .recording))
    }

    func append(buffer: AVAudioPCMBuffer) async throws {
        _ = buffer
        guard !lock.withLock({ cancelledValue }) else { throw CoreTranscriptionError.cancelled }
        if let appendError { throw appendError }
        lock.withLock { appendedBuffers += 1 }
        appendEvent.record()
    }

    func finish() async throws -> Transcript {
        eventContinuation.yield(TranscriptionOperationEvent(phase: .finalizingAudio))
        eventContinuation.yield(TranscriptionOperationEvent(phase: .transcribing))
        updateContinuation.finish()
        eventContinuation.finish()
        return finalTranscript
    }

    func cancelAndWait() async {
        lock.withLock { cancelledValue = true }
        cancelEvent.record()
        updateContinuation.finish()
        eventContinuation.yield(TranscriptionOperationEvent(phase: .cancelling))
        eventContinuation.finish()
    }
}

private enum RecordingStoreTestError: LocalizedError, Equatable {
    case insertFailed

    var errorDescription: String? {
        "The test history store rejected the recording."
    }
}

private final class ControllerDiagnosticSinkSpy: TranscriptionDiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [TranscriptionDiagnosticEvent] = []

    var events: [TranscriptionDiagnosticEvent] {
        lock.withLock { recordedEvents }
    }

    func record(_ event: TranscriptionDiagnosticEvent) {
        lock.withLock { recordedEvents.append(event) }
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
    let status: RecordingHistoryStatus = .available
    private(set) var recordings: [Recording] = []
    private let recoveryDirectory: URL?

    init(recoveryDirectory: URL? = nil) {
        self.recoveryDirectory = recoveryDirectory
    }

    func commitRecording(_ recording: Recording) async throws -> RecordingCommitReceipt {
        recordings.append(recording)
        return RecordingCommitReceipt(recordingID: recording.id, databasePath: "test")
    }

    func removeCommittedRecording(_ receipt: RecordingCommitReceipt) async -> RecordingCompensationResult {
        let wasPresent = recordings.contains { $0.id == receipt.recordingID }
        recordings.removeAll { $0.id == receipt.recordingID }
        return RecordingCompensationResult(
            recordingID: receipt.recordingID,
            state: wasPresent ? .removed : .alreadyAbsent
        )
    }

    func preserveForRecovery(_ request: RecordingRecoveryRequest) async -> RecordingRecoveryResult {
        guard let recoveryDirectory else {
            return RecordingRecoveryResult(
                receipt: nil,
                error: .recoveryDirectoryFailed("Test recovery directory was not configured.")
            )
        }
        return preserveTestAudio(request, in: recoveryDirectory)
    }
}

@MainActor
private final class FailingRecordingStoreSpy: DictationRecordingStore {
    let status: RecordingHistoryStatus = .available
    private(set) var attemptCount = 0

    func commitRecording(_ recording: Recording) async throws -> RecordingCommitReceipt {
        _ = recording
        attemptCount += 1
        throw RecordingStoreTestError.insertFailed
    }

    func removeCommittedRecording(_ receipt: RecordingCommitReceipt) async -> RecordingCompensationResult {
        RecordingCompensationResult(recordingID: receipt.recordingID, state: .alreadyAbsent)
    }

    func preserveForRecovery(_ request: RecordingRecoveryRequest) async -> RecordingRecoveryResult {
        _ = request
        return RecordingRecoveryResult(
            receipt: nil,
            error: .recoveryDirectoryFailed("Test recovery is not expected on a database failure.")
        )
    }
}

@MainActor
private final class UnavailableRecordingStoreSpy: DictationRecordingStore {
    let status: RecordingHistoryStatus = .unavailable("test history outage")
    private let recoveryDirectory: URL

    init(recoveryDirectory: URL) {
        self.recoveryDirectory = recoveryDirectory
    }

    func commitRecording(_ recording: Recording) async throws -> RecordingCommitReceipt {
        _ = recording
        throw RecordingStoreError.databaseUnavailable("test history outage")
    }

    func removeCommittedRecording(_ receipt: RecordingCommitReceipt) async -> RecordingCompensationResult {
        RecordingCompensationResult(recordingID: receipt.recordingID, state: .alreadyAbsent)
    }

    func preserveForRecovery(_ request: RecordingRecoveryRequest) async -> RecordingRecoveryResult {
        preserveTestAudio(request, in: recoveryDirectory)
    }
}

@MainActor
private final class SuspendingRecordingStoreSpy: DictationRecordingStore {
    private struct PendingInsert {
        let recording: Recording
        let continuation: CheckedContinuation<RecordingCommitReceipt, Error>
    }

    let status: RecordingHistoryStatus = .available
    private(set) var recordings: [Recording] = []
    private(set) var removedRecordings: [Recording] = []
    private var pendingInserts: [PendingInsert] = []
    let pendingAddEvent = TestEventRecorder()
    let removeEvent = TestEventRecorder()

    var pendingAddCount: Int { pendingInserts.count }
    var pendingRecordings: [Recording] { pendingInserts.map(\.recording) }

    func commitRecording(_ recording: Recording) async throws -> RecordingCommitReceipt {
        let receipt = try await withCheckedThrowingContinuation { continuation in
            pendingInserts.append(PendingInsert(recording: recording, continuation: continuation))
            pendingAddEvent.record()
        }
        recordings.append(recording)
        return receipt
    }

    func removeCommittedRecording(_ receipt: RecordingCommitReceipt) async -> RecordingCompensationResult {
        guard let recording = recordings.first(where: { $0.id == receipt.recordingID }) else {
            return RecordingCompensationResult(
                recordingID: receipt.recordingID,
                state: .alreadyAbsent
            )
        }
        recordings.removeAll { $0.id == receipt.recordingID }
        removedRecordings.append(recording)
        removeEvent.record()
        return RecordingCompensationResult(recordingID: receipt.recordingID, state: .removed)
    }

    func preserveForRecovery(_ request: RecordingRecoveryRequest) async -> RecordingRecoveryResult {
        _ = request
        return RecordingRecoveryResult(
            receipt: nil,
            error: .recoveryDirectoryFailed("Test recovery is not expected on this path.")
        )
    }

    func resumeNextAdd() {
        guard !pendingInserts.isEmpty else { return }
        let pending = pendingInserts.removeFirst()
        pending.continuation.resume(returning: RecordingCommitReceipt(
            recordingID: pending.recording.id,
            databasePath: "test"
        ))
    }
}

private func preserveTestAudio(
    _ request: RecordingRecoveryRequest,
    in recoveryDirectory: URL
) -> RecordingRecoveryResult {
    do {
        try FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
        let destination = recoveryDirectory.appendingPathComponent(
            "recovery-\(request.recording.id.uuidString)-\(request.recording.fileName)"
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        switch request.disposition {
        case .copy:
            try FileManager.default.copyItem(at: request.sourceURL, to: destination)
        case .move:
            try FileManager.default.moveItem(at: request.sourceURL, to: destination)
        }
        return RecordingRecoveryResult(receipt: RecordingRecoveryReceipt(
            recordingID: request.recording.id,
            audioURL: destination,
            transcriptURL: nil,
            metadataURL: nil
        ))
    } catch {
        return RecordingRecoveryResult(
            receipt: nil,
            error: .audioTransferFailed(error.localizedDescription)
        )
    }
}

@MainActor
private final class DelayedAssetManager: AppleSpeechAssetManaging {
    var supportedLocales: [Locale] = []
    var installedLocales: [Locale] = []
    var activeLocale: Locale?
    var currentStatus: AppleSpeechAssetStatus?

    private var statusContinuations: [String: [CheckedContinuation<AppleSpeechAssetStatus, Never>]] = [:]
    let statusRequestedEvent = TestEventRecorder()

    func refresh() async -> [Locale] { supportedLocales }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? { locale }

    func status(for locale: Locale) async -> AppleSpeechAssetStatus {
        let identifier = LanguageUtil.localeIdentifier(for: locale)
        statusRequestedEvent.record()
        return await withCheckedContinuation { continuation in
            statusContinuations[identifier, default: []].append(continuation)
        }
    }

    func prepare(locale: Locale) async throws -> Locale { locale }

    func release(locale: Locale?) async {}

    func hasPendingStatus(for identifier: String) -> Bool {
        !(statusContinuations[LanguageUtil.normalizedLocaleIdentifier(identifier)] ?? []).isEmpty
    }

    func resumeStatus(
        for identifier: String,
        state: AppleSpeechAssetState,
        oldest: Bool = false
    ) {
        let normalized = LanguageUtil.normalizedLocaleIdentifier(identifier)
        guard var continuations = statusContinuations[normalized], !continuations.isEmpty else { return }
        let continuation = oldest ? continuations.removeFirst() : continuations.removeLast()
        if continuations.isEmpty {
            statusContinuations.removeValue(forKey: normalized)
        } else {
            statusContinuations[normalized] = continuations
        }
        continuation.resume(returning: AppleSpeechAssetStatus(
            locale: LanguageUtil.locale(for: normalized),
            state: state
        ))
    }
}
