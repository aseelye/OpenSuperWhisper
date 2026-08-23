import AVFAudio
import Foundation
import XCTest
@testable import OpenSuperWhisper

final class OperationContractsTests: XCTestCase {
    func testProgressPhasesNormalizeCountsAndFraction() {
        let uploading = TranscriptionOperationPhase.uploading(
            part: -3,
            total: 0,
            fraction: 4
        )

        XCTAssertEqual(uploading.uploadProgress?.part, 1)
        XCTAssertEqual(uploading.uploadProgress?.total, 1)
        XCTAssertEqual(uploading.uploadProgress?.fraction, 1)

        let inconsistent = TranscriptionOperationPhase.uploading(
            part: 7,
            total: 2,
            fraction: -.infinity
        )
        XCTAssertEqual(inconsistent.uploadProgress?.part, 7)
        XCTAssertEqual(inconsistent.uploadProgress?.total, 7)
        XCTAssertEqual(inconsistent.uploadProgress?.fraction, 0)

        let unknownFraction = TranscriptionOperationPhase.uploading(
            part: nil,
            total: nil,
            fraction: .nan
        )
        XCTAssertNil(unknownFraction.uploadProgress?.part)
        XCTAssertNil(unknownFraction.uploadProgress?.total)
        XCTAssertNil(unknownFraction.uploadProgress?.fraction)

        let retrying = TranscriptionOperationPhase.retrying(attempt: 0, maximum: -1)
        XCTAssertEqual(retrying.retryProgress?.attempt, 1)
        XCTAssertEqual(retrying.retryProgress?.maximum, 1)
    }

    func testStrategyAndFactoriesCreateHandlesSynchronously() throws {
        let provider = ContractProviderFake(strategy: .live)
        XCTAssertEqual(provider.strategy, .live)
        XCTAssertFalse(provider.liveFactoryWasSuspended)

        let live = try provider.makeLiveOperation(
            locale: Locale(identifier: "en-US"),
            context: nil,
            expectedTerms: []
        )
        XCTAssertNotNil(live)
        XCTAssertTrue(provider.liveHandleWasCreated)

        let file = try provider.makeFileOperation(
            at: URL(fileURLWithPath: "/tmp/recording.wav"),
            locale: Locale(identifier: "en-US"),
            context: nil,
            expectedTerms: []
        )
        XCTAssertNotNil(file)
        XCTAssertTrue(provider.fileHandleWasCreated)

        let fileOnlyProvider = ContractProviderFake(strategy: .fileAfterCapture)
        XCTAssertNil(
            try fileOnlyProvider.makeLiveOperation(
                locale: Locale(identifier: "en-US"),
                context: nil,
                expectedTerms: []
            )
        )
        XCTAssertNotNil(
            try fileOnlyProvider.makeFileOperation(
                at: URL(fileURLWithPath: "/tmp/imported.wav"),
                locale: Locale(identifier: "en-US"),
                context: nil,
                expectedTerms: []
            )
        )
    }

    func testCaptureFactoryCreatesSessionBeforeAsyncStart() async throws {
        let factory = ContractCaptureFactoryFake()
        let session = factory.makeSession()

        XCTAssertTrue(factory.didCreateSession)
        XCTAssertFalse(factory.sessionStartWasCalled)
        try await session.start(onBuffer: { _ in })
        XCTAssertTrue(factory.sessionStartWasCalled)
    }

    func testCancelAndWaitIsIdempotentForOperationHandle() async {
        let operation = ContractLiveOperationFake()

        await operation.cancelAndWait()
        await operation.cancelAndWait()

        XCTAssertEqual(operation.cancelCallCount, 1)
    }

    func testDiagnosticValueHasNoUserContentFields() {
        let event = TranscriptionDiagnosticEvent(
            operationToken: SessionOperationToken(),
            source: .shortcut,
            backend: .appleSpeech,
            phase: .transcribing,
            captureGeneration: 4,
            chunkIndex: 2,
            outcome: .completed
        )

        let labels = Set(Mirror(reflecting: event).children.compactMap(\.label))
        XCTAssertFalse(labels.contains("transcript"))
        XCTAssertFalse(labels.contains("prompt"))
        XCTAssertFalse(labels.contains("secret"))
        XCTAssertFalse(labels.contains("apiKey"))
        XCTAssertFalse(labels.contains("audio"))
        XCTAssertEqual(event.outcomeCategory, .completed)
        NoOpTranscriptionDiagnosticSink.shared.record(event)
    }
}

private final class ContractProviderFake: TranscriptionProvider, @unchecked Sendable {
    let strategy: RecordingTranscriptionStrategy
    private(set) var liveHandleWasCreated = false
    private(set) var fileHandleWasCreated = false
    // This remains false by construction: factory calls contain no async work.
    let liveFactoryWasSuspended = false

    init(strategy: RecordingTranscriptionStrategy) {
        self.strategy = strategy
    }

    func makeLiveOperation(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> (any TranscriptionLiveOperation)? {
        guard strategy == .live else { return nil }
        liveHandleWasCreated = true
        return ContractLiveOperationFake()
    }

    func makeFileOperation(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> any TranscriptionFileOperation {
        fileHandleWasCreated = true
        return ContractFileOperationFake()
    }
}

private final class ContractCaptureFactoryFake: DictationAudioCaptureFactory, @unchecked Sendable {
    private(set) var didCreateSession = false
    private(set) var sessionStartWasCalled = false

    func makeSession() -> any DictationAudioCaptureSession {
        didCreateSession = true
        return ContractCaptureSessionFake(onStart: { [weak self] in
            self?.sessionStartWasCalled = true
        })
    }
}

private final class ContractCaptureSessionFake: DictationAudioCaptureSession, @unchecked Sendable {
    private let onStart: () -> Void

    init(onStart: @escaping () -> Void) {
        self.onStart = onStart
    }

    var currentRecordingURL: URL? { nil }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        onStart()
    }

    func stopAndDrain() async throws -> AudioCaptureResult? { nil }

    func cancelAndDrain() async {}
}

private final class ContractLiveOperationFake: TranscriptionLiveOperation, @unchecked Sendable {
    private let lock = NSLock()
    private var didCancel = false
    private var cancelCalls = 0

    let events = AsyncStream<TranscriptionOperationEvent> { continuation in
        continuation.finish()
    }

    var cancelCallCount: Int {
        lock.withLock { cancelCalls }
    }

    func start() async throws {}

    func append(buffer: AVAudioPCMBuffer) async throws {}

    func finish() async throws -> Transcript {
        Transcript(text: "")
    }

    func cancelAndWait() async {
        lock.withLock {
            guard !didCancel else { return }
            didCancel = true
            cancelCalls += 1
        }
    }
}

private final class ContractFileOperationFake: TranscriptionFileOperation, @unchecked Sendable {
    let events = AsyncStream<TranscriptionOperationEvent> { continuation in
        continuation.finish()
    }

    func value() async throws -> Transcript {
        Transcript(text: "")
    }

    func cancelAndWait() async {}
}
