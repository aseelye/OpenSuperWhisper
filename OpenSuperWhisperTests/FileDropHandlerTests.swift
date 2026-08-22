import Foundation
import AVFAudio
import UniformTypeIdentifiers
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class FileDropHandlerTests: XCTestCase {
    func testIntentionalCancellationDoesNotPresentCancellationError() async throws {
        let sourceURL = temporaryAudioFile()
        let outputDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let engine = DelayedFileDropEngine()
        let controller = makeController(
            engine: engine,
            recordingDirectory: outputDirectory
        )
        let handler = FileDropHandler(
            sessionController: controller,
            durationLoader: { _ in 1 }
        )

        let operation = Task { @MainActor in
            await handler.handleDrop(of: [self.provider(for: sourceURL)])
        }
        try await waitUntil { handler.isTranscribing }

        handler.cancelTranscription()
        await operation.value

        XCTAssertFalse(handler.isTranscribing)
        XCTAssertNil(handler.errorMessage)
    }

    func testRealDropErrorIsPresented() async throws {
        let sourceURL = temporaryAudioFile()
        let outputDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let expectedError = CoreTranscriptionError.invalidAudioFile(sourceURL)
        let controller = makeController(
            engine: FailingFileDropEngine(error: expectedError),
            recordingDirectory: outputDirectory
        )
        let handler = FileDropHandler(
            sessionController: controller,
            durationLoader: { _ in 1 }
        )

        await handler.handleDrop(of: [provider(for: sourceURL)])

        XCTAssertEqual(handler.errorMessage, expectedError.localizedDescription)
    }

    private func makeController(
        engine: any TranscriptionEngine,
        recordingDirectory: URL
    ) -> DictationSessionController {
        DictationSessionController(
            capture: FileDropTestCapture(),
            engineFactory: { _, _ in engine },
            recordingStore: FileDropRecordingStore(),
            settingsProvider: { Settings() },
            recordingDirectory: recordingDirectory
        )
    }

    private func provider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.audio.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    private func temporaryAudioFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisperDrop-\(UUID().uuidString).wav")
        try? Data("audio".utf8).write(to: url)
        return url
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisperDrop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
private final class FileDropTestCapture: DictationAudioCapture {
    var isRecording = false
    var currentRecordingURL: URL?

    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        _ = bufferHandler
        isRecording = true
    }

    func stop() throws -> URL? {
        isRecording = false
        return currentRecordingURL
    }

    func cancel() {
        isRecording = false
    }
}

@MainActor
private final class FileDropRecordingStore: DictationRecordingStore {
    func addRecording(_ recording: Recording) async throws {
        _ = recording
    }

    func removeRecording(_ recording: Recording) async throws {
        _ = recording
    }
}

private final class DelayedFileDropEngine: TranscriptionEngine, @unchecked Sendable {
    func prepare(locale: Locale) async throws {
        _ = locale
    }

    func startSession(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> any LiveTranscriptionSession {
        _ = (locale, context, expectedTerms)
        throw CoreTranscriptionError.cancelled
    }

    func transcribeFile(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> Transcript {
        _ = (url, locale, context, expectedTerms)
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            throw CoreTranscriptionError.cancelled
        }
        throw CoreTranscriptionError.cancelled
    }
}

private final class FailingFileDropEngine: TranscriptionEngine, @unchecked Sendable {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func prepare(locale: Locale) async throws {
        _ = locale
    }

    func startSession(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> any LiveTranscriptionSession {
        _ = (locale, context, expectedTerms)
        throw CoreTranscriptionError.cancelled
    }

    func transcribeFile(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> Transcript {
        _ = (url, locale, context, expectedTerms)
        throw error
    }
}
