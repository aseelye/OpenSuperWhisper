import AVFAudio
import Combine
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class FileDropHandlerTests: XCTestCase {
    func testDropReservesBeforeProviderCallbackAndBlocksReplacement() async throws {
        let sourceURL = try TestFixture.temporaryFile(contents: Data("audio".utf8), fileExtension: "wav")
        let outputDirectory = try TestFixture.temporaryDirectory(prefix: "DropOutput")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let callbackReady = TestEventRecorder()
        var providerCompletion: ((Result<URL?, Error>) -> Void)?
        let operation = ImmediateFileOperation()
        let controller = makeController(
            operation: operation,
            recordingDirectory: outputDirectory
        )
        let handler = FileDropHandler(
            sessionController: controller,
            providerLoader: { _, completion in
                providerCompletion = completion
                callbackReady.record()
            },
            durationLoader: { _ in 1 }
        )

        let task = Task { @MainActor in
            await handler.handleDrop(of: [self.audioProvider()])
        }
        await waitForController(
            controller,
            description: "drop reservation",
            condition: {
                controller.snapshot.source == .fileDrop
                    && handler.isTranscribing
            }
        )
        await waitForTestEvent(callbackReady, description: "provider callback seam")

        XCTAssertNil(controller.reserve(source: .mainWindow))
        XCTAssertEqual(controller.snapshot.presentationOwner, .fileDrop)

        providerCompletion?(.success(sourceURL))
        await task.value
        XCTAssertFalse(handler.isTranscribing)
        XCTAssertNil(controller.operationToken)
    }

    func testCancellationKeepsDropClaimedUntilLateCallbackReturns() async throws {
        let sourceURL = try TestFixture.temporaryFile(contents: Data("audio".utf8), fileExtension: "wav")
        let outputDirectory = try TestFixture.temporaryDirectory(prefix: "DropCancel")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let callbackReady = TestEventRecorder()
        var providerCompletion: ((Result<URL?, Error>) -> Void)?
        let controller = makeController(
            operation: ImmediateFileOperation(),
            recordingDirectory: outputDirectory
        )
        let handler = FileDropHandler(
            sessionController: controller,
            providerLoader: { _, completion in
                providerCompletion = completion
                callbackReady.record()
            },
            durationLoader: { _ in 1 }
        )

        let task = Task { @MainActor in
            await handler.handleDrop(of: [self.audioProvider()])
        }
        await waitForTestEvent(callbackReady, description: "provider callback seam")
        XCTAssertTrue(handler.isTranscribing)
        XCTAssertTrue(handler.cancelTranscription())
        XCTAssertEqual(controller.snapshot.phase, .cancelling)
        XCTAssertNil(controller.reserve(source: .shortcut))

        // The provider can call back after cancellation. The stale callback
        // must not start an import, paste, error banner, or replacement.
        providerCompletion?(.success(sourceURL))
        await task.value
        XCTAssertFalse(handler.isTranscribing)
        XCTAssertNil(handler.errorMessage)
        XCTAssertNil(controller.operationToken)
    }

    func testRejectedDropCreatesNoLocalEffects() async {
        let controller = makeController(
            operation: ImmediateFileOperation(),
            recordingDirectory: FileManager.default.temporaryDirectory
        )
        let winner = controller.reserve(source: .mainWindow)
        var providerLoaded = false
        let handler = FileDropHandler(
            sessionController: controller,
            providerLoader: { _, _ in providerLoaded = true }
        )

        await handler.handleDrop(of: [audioProvider()])

        XCTAssertNil(handler.errorMessage)
        XCTAssertNil(handler.operationToken)
        XCTAssertFalse(providerLoaded)
        XCTAssertEqual(controller.operationToken, winner)
    }

    func testPostReservationFailureIsPresentedOnlyByController() async throws {
        let sourceURL = try TestFixture.temporaryFile(contents: Data("audio".utf8), fileExtension: "wav")
        let outputDirectory = try TestFixture.temporaryDirectory(prefix: "DropError")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let expectedError = CoreTranscriptionError.invalidAudioFile(sourceURL)
        let controller = makeController(
            operation: FailingFileOperation(error: expectedError),
            recordingDirectory: outputDirectory
        )
        let handler = FileDropHandler(
            sessionController: controller,
            providerLoader: { _, completion in completion(.success(sourceURL)) },
            durationLoader: { _ in 1 }
        )

        await handler.handleDrop(of: [audioProvider()])

        XCTAssertNil(handler.errorMessage)
        XCTAssertEqual(controller.errorMessage, expectedError.localizedDescription)
    }

    func testProviderLoaderFailureIsPresentedOnceByController() async throws {
        let expectedURL = URL(fileURLWithPath: "/tmp/provider-loader-failure.wav")
        let expectedError = CoreTranscriptionError.invalidAudioFile(expectedURL)
        let controller = makeController(
            operation: ImmediateFileOperation(),
            recordingDirectory: FileManager.default.temporaryDirectory
        )
        var presentedMessages: [String] = []
        var terminalOutcomes: [DictationSessionTerminalOutcome] = []
        let errorObservation = controller.$errorMessage
            .dropFirst()
            .sink { message in
                if let message { presentedMessages.append(message) }
            }
        let outcomeObservation = controller.$lastTerminalOutcome
            .dropFirst()
            .sink { outcome in
                if let outcome { terminalOutcomes.append(outcome) }
            }
        defer {
            errorObservation.cancel()
            outcomeObservation.cancel()
        }

        let handler = FileDropHandler(
            sessionController: controller,
            providerLoader: { _, completion in completion(.failure(expectedError)) }
        )

        await handler.handleDrop(of: [audioProvider()])

        XCTAssertNil(handler.errorMessage)
        XCTAssertNil(handler.operationToken)
        XCTAssertNil(controller.operationToken)
        XCTAssertEqual(controller.errorMessage, expectedError.localizedDescription)
        XCTAssertEqual(controller.snapshot.outcome, .failed)
        XCTAssertEqual(controller.lastTerminalOutcome, .failed)
        XCTAssertEqual(presentedMessages, [expectedError.localizedDescription])
        XCTAssertEqual(terminalOutcomes, [.failed])
    }

    func testReservedFailureRejectsStaleAndDuplicateTokens() async {
        let controller = makeController(
            operation: ImmediateFileOperation(),
            recordingDirectory: FileManager.default.temporaryDirectory
        )
        let error = CoreTranscriptionError.unavailable
        let token = controller.reserve(source: .fileDrop)!

        let staleRejected = await controller.failReservedOperation(
            error,
            token: SessionOperationToken()
        )
        XCTAssertFalse(staleRejected)
        XCTAssertEqual(controller.operationToken, token)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.snapshot.outcome, nil)

        let failureClaimed = await controller.failReservedOperation(error, token: token)
        XCTAssertTrue(failureClaimed)
        XCTAssertNil(controller.operationToken)
        XCTAssertEqual(controller.lastTerminalOutcome, .failed)
        let duplicateRejected = await controller.failReservedOperation(error, token: token)
        XCTAssertFalse(duplicateRejected)
    }

    func testReservedFailureRejectsAfterRecordingStarts() async {
        let controller = makeController(
            operation: ImmediateFileOperation(),
            recordingDirectory: FileManager.default.temporaryDirectory
        )
        let error = CoreTranscriptionError.unavailable
        let token = controller.reserve(source: .fileDrop)!
        controller.startRecording(token: token)

        await waitForController(
            controller,
            description: "recording phase",
            condition: { controller.snapshot.phase == .recording }
        )

        let laterPhaseRejected = await controller.failReservedOperation(error, token: token)
        XCTAssertFalse(laterPhaseRejected)
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.lastTerminalOutcome)
        let cancellationClaimed = await controller.cancelRecordingAndWait(token: token)
        XCTAssertTrue(cancellationClaimed)
    }

    func testPreReservationInvalidDropAndExpiryAreInjectable() async {
        var expiryCallback: (() -> Void)?
        let controller = makeController(
            operation: ImmediateFileOperation(),
            recordingDirectory: FileManager.default.temporaryDirectory
        )
        let handler = FileDropHandler(
            sessionController: controller,
            expiryScheduler: { callback, _ in
                expiryCallback = callback
                return AnyCancellable {}
            }
        )

        await handler.handleDrop(of: [NSItemProvider()])
        XCTAssertEqual(handler.errorMessage, "Drop an audio file to transcribe.")
        XCTAssertNil(controller.operationToken)
        expiryCallback?()
        XCTAssertNil(handler.errorMessage)
    }

    private func makeController(
        operation: any TranscriptionFileOperation,
        recordingDirectory: URL
    ) -> DictationSessionController {
        DictationSessionController(
            captureFactory: NoopCaptureFactory(),
            providerFactory: { _, _ in FixedFileProvider(operation: operation) },
            recordingStore: DropRecordingStore(),
            settingsProvider: { Settings() },
            recordingDirectory: recordingDirectory,
            pasteHandler: { _ in }
        )
    }

    private func audioProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.audio.identifier,
            visibility: .all
        ) { completion in
            completion(Data("audio".utf8), nil)
            return nil
        }
        return provider
    }
}

private struct NoopCaptureFactory: DictationAudioCaptureFactory, Sendable {
    func makeSession() -> any DictationAudioCaptureSession { NoopCaptureSession() }
}

private final class NoopCaptureSession: DictationAudioCaptureSession, @unchecked Sendable {
    var currentRecordingURL: URL?

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        _ = onBuffer
    }

    func stopAndDrain() async throws -> AudioCaptureResult? { nil }
    func cancelAndDrain() async {}
}

@MainActor
private final class DropRecordingStore: DictationRecordingStore {
    var status: RecordingHistoryStatus { .available }

    func commitRecording(_ recording: Recording) async throws -> RecordingCommitReceipt {
        RecordingCommitReceipt(recordingID: recording.id, databasePath: "test")
    }

    func removeCommittedRecording(_ receipt: RecordingCommitReceipt) async -> RecordingCompensationResult {
        RecordingCompensationResult(recordingID: receipt.recordingID, state: .removed)
    }

    func preserveForRecovery(_ request: RecordingRecoveryRequest) async -> RecordingRecoveryResult {
        _ = request
        return RecordingRecoveryResult(receipt: nil)
    }
}

private final class FixedFileProvider: TranscriptionProvider, @unchecked Sendable {
    let operation: any TranscriptionFileOperation

    init(operation: any TranscriptionFileOperation) { self.operation = operation }

    var strategy: RecordingTranscriptionStrategy { .fileAfterCapture }

    func makeLiveOperation(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> (any TranscriptionLiveOperation)? {
        _ = (locale, context, expectedTerms)
        return nil
    }

    func makeFileOperation(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> any TranscriptionFileOperation {
        _ = (url, locale, context, expectedTerms)
        return operation
    }
}

private final class ImmediateFileOperation: TranscriptionFileOperation, @unchecked Sendable {
    var events: AsyncStream<TranscriptionOperationEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func value() async throws -> Transcript {
        Transcript(text: "drop transcript", localeIdentifier: "en-US", segments: [])
    }

    func cancelAndWait() async {}
}

private final class FailingFileOperation: TranscriptionFileOperation, @unchecked Sendable {
    let error: Error

    init(error: Error) { self.error = error }

    var events: AsyncStream<TranscriptionOperationEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func value() async throws -> Transcript { throw error }
    func cancelAndWait() async {}
}
