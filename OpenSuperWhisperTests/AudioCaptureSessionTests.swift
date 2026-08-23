import AVFAudio
import Foundation
import XCTest
@testable import OpenSuperWhisper

/// Direct capture-boundary tests.  They intentionally exercise the concrete
/// session with fake engine/writer seams rather than the controller's legacy
/// capture double.
final class AudioCaptureSessionTests: XCTestCase {
    func testStopClosesAdmissionAndDrainsEveryAdmittedBufferInOrder() async throws {
        let harness = try CaptureHarness()
        let session = harness.makeSession()
        let callbacks = LockedValues<[Int]>([])

        try await session.start { buffer in
            callbacks.mutate { $0.append(Int(buffer.frameLength)) }
        }

        harness.engine.emit(harness.buffer(frames: 1))
        harness.engine.emit(harness.buffer(frames: 2))
        harness.engine.emit(harness.buffer(frames: 3))

        let result = try await session.stopAndDrain()
        XCTAssertEqual(harness.writer.writes, [1, 2, 3])
        XCTAssertEqual(callbacks.value, [1, 2, 3])
        XCTAssertEqual(result?.duration ?? -1, 6.0 / 16_000.0, accuracy: 0.000_001)
        XCTAssertFalse(harness.fileSystem.removed)
        XCTAssertNil(session.currentRecordingURL)

        // The fake engine can still invoke its old tap closure, but the closed
        // admission gate rejects it and no callback can appear after drain.
        harness.engine.emit(harness.buffer(frames: 4))
        await Task.yield()
        XCTAssertEqual(callbacks.value, [1, 2, 3])
    }

    func testCallbackDeliveryIsCompleteBeforeStopReturns() async throws {
        let harness = try CaptureHarness()
        let session = harness.makeSession()
        let callbackFinished = XCTestExpectation(description: "callback finished")

        try await session.start { _ in
            callbackFinished.fulfill()
        }
        harness.engine.emit(harness.buffer(frames: 8))

        _ = try await session.stopAndDrain()
        await fulfillment(of: [callbackFinished], timeout: 1)
        XCTAssertEqual(harness.writer.writes, [8])
    }

    func testWriteFailurePropagatesAsTypedErrorAfterDrain() async throws {
        let harness = try CaptureHarness(writerError: .writeFailed("injected"))
        let session = harness.makeSession()
        let callbacks = LockedValues<Int>(0)

        try await session.start { _ in
            callbacks.mutate { $0 += 1 }
        }
        harness.engine.emit(harness.buffer(frames: 1))

        do {
            _ = try await session.stopAndDrain()
            XCTFail("Expected write failure")
        } catch let error as AudioCaptureError {
            guard case .writeFailed("injected") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(callbacks.value, 1)
        XCTAssertTrue(harness.fileSystem.removed)
    }

    func testCopyFailureIsTerminalAndTyped() async throws {
        let harness = try CaptureHarness(copyError: .copyFailed("injected"))
        let session = harness.makeSession()
        let callbacks = LockedValues<Int>(0)
        try await session.start { _ in callbacks.mutate { $0 += 1 } }

        harness.engine.emit(harness.buffer(frames: 1))

        do {
            _ = try await session.stopAndDrain()
            XCTFail("Expected copy failure")
        } catch let error as AudioCaptureError {
            guard case .copyFailed("injected") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(callbacks.value, 0)
        XCTAssertTrue(harness.fileSystem.removed)
    }

    func testStartFailureDrainsAdmittedBufferBeforeDeletingFile() async throws {
        let harness = try CaptureHarness()
        harness.engine.startError = AudioCaptureError.engineStartFailed("injected")
        let session = harness.makeSession()
        let callbacks = LockedValues<[Int]>([])

        do {
            try await session.start { buffer in
                callbacks.mutate { $0.append(Int(buffer.frameLength)) }
            }
            XCTFail("Expected start failure")
        } catch let error as AudioCaptureError {
            guard case .engineStartFailed("injected") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        // TestEngine emits while its start method is failing, after tap
        // installation.  The session must await both writer and callback
        // queues before returning or removing the file.
        XCTAssertEqual(harness.writer.writes, [5])
        XCTAssertEqual(callbacks.value, [5])
        XCTAssertTrue(harness.writer.closed)
        XCTAssertTrue(harness.fileSystem.removed)
    }

    func testCancellationQuiescesOldGenerationAndDoesNotReachReplacement() async throws {
        let harness = try CaptureHarness()
        let oldSession = harness.makeSession(generation: 11)
        let callbacks = LockedValues<[Int]>([])
        try await oldSession.start { buffer in
            callbacks.mutate { $0.append(Int(buffer.frameLength)) }
        }
        harness.engine.emit(harness.buffer(frames: 1))
        await oldSession.cancelAndDrain()
        harness.engine.emit(harness.buffer(frames: 2))
        XCTAssertEqual(callbacks.value, [1])

        let replacementEngine = TestCaptureEngine(format: harness.format)
        let replacementWriter = TestCaptureWriter()
        let replacement = AudioCaptureSession(
            configuration: harness.configuration,
            dependencies: AudioCaptureDependencies(
                engineFactory: TestCaptureEngineFactory(engine: replacementEngine),
                writerFactory: TestCaptureWriterFactory(writer: replacementWriter),
                bufferCopier: TestCaptureCopier(),
                fileSystem: harness.fileSystem,
                callbackExecutorFactory: TestCallbackExecutorFactory()
            ),
            generation: 12
        )
        try await replacement.start { buffer in
            callbacks.mutate { $0.append(Int(buffer.frameLength) + 10) }
        }
        replacementEngine.emit(harness.buffer(frames: 3))
        _ = try await replacement.stopAndDrain()
        XCTAssertEqual(callbacks.value, [1, 13])
    }
}

// MARK: Test seam implementations

private final class CaptureHarness {
    let format: AVAudioFormat
    let configuration: AudioCaptureConfiguration
    let engine: TestCaptureEngine
    let writer: TestCaptureWriter
    let fileSystem: TestCaptureFileSystem
    private let copier: TestCaptureCopier

    init(
        writerError: AudioCaptureError? = nil,
        copyError: AudioCaptureError? = nil
    ) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw NSError(domain: "AudioCaptureSessionTests", code: 1)
        }
        self.format = format
        self.configuration = AudioCaptureConfiguration(
            bufferSize: 128,
            temporaryDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("AudioCaptureSessionTests-\(UUID().uuidString)")
        )
        self.engine = TestCaptureEngine(format: format)
        self.writer = TestCaptureWriter(error: writerError)
        self.fileSystem = TestCaptureFileSystem()
        self.copier = TestCaptureCopier(error: copyError)
    }

    func makeSession(generation: UInt64 = 1) -> AudioCaptureSession {
        AudioCaptureSession(
            configuration: configuration,
            dependencies: AudioCaptureDependencies(
                engineFactory: TestCaptureEngineFactory(engine: engine),
                writerFactory: TestCaptureWriterFactory(writer: writer),
                bufferCopier: copier,
                fileSystem: fileSystem,
                callbackExecutorFactory: TestCallbackExecutorFactory()
            ),
            generation: generation
        )
    }

    func buffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))!
        buffer.frameLength = frames
        return buffer
    }
}

private final class TestCaptureEngineFactory: AudioCaptureEngineFactory, @unchecked Sendable {
    let engine: TestCaptureEngine
    init(engine: TestCaptureEngine) { self.engine = engine }
    func makeEngine() throws -> any AudioCaptureEngineDriver { engine }
}

private final class TestCaptureEngine: AudioCaptureEngineDriver, @unchecked Sendable {
    let inputFormat: AVAudioFormat
    private let lock = NSLock()
    private var tap: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var startError: Error?

    init(format: AVAudioFormat) { inputFormat = format }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) {
        lock.withLock { tap = handler }
    }

    func removeTap() {}
    func prepare() {}

    func start() throws {
        if let startError {
            if let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 5) {
                buffer.frameLength = 5
                tapSnapshot()?(buffer)
            }
            throw startError
        }
    }

    func stop() {}

    func emit(_ buffer: AVAudioPCMBuffer) {
        tapSnapshot()?(buffer)
    }

    private func tapSnapshot() -> ((AVAudioPCMBuffer) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return tap
    }
}

private final class TestCaptureWriterFactory: AudioCaptureWriterFactory, @unchecked Sendable {
    let writer: TestCaptureWriter
    init(writer: TestCaptureWriter) { self.writer = writer }
    func makeWriter(at url: URL, format: AVAudioFormat) throws -> any AudioCaptureWriterDriver { writer }
}

private final class TestCaptureWriter: AudioCaptureWriterDriver, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var writes = [Int]()
    private(set) var closed = false
    let error: AudioCaptureError?

    init(error: AudioCaptureError? = nil) { self.error = error }

    func write(from buffer: AVAudioPCMBuffer) throws {
        if let error { throw error }
        lock.withLock { writes.append(Int(buffer.frameLength)) }
    }

    func close() { lock.withLock { closed = true } }
}

private final class TestCaptureCopier: AudioCaptureBufferCopier, @unchecked Sendable {
    let error: AudioCaptureError?
    init(error: AudioCaptureError? = nil) { self.error = error }
    func copy(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if let error { throw error }
        return buffer
    }
}

private struct TestCaptureFileSystem: AudioCaptureFileSystemDriver, @unchecked Sendable {
    private let state = LockedValues(false)
    func createDirectory(at url: URL) throws {}
    func removeItem(at url: URL) throws { state.set(true) }
    var removed: Bool { state.value }
}

private struct TestCallbackExecutorFactory: AudioCaptureCallbackExecutorFactory, Sendable {
    func makeExecutor() -> any AudioCaptureCallbackExecutor {
        DispatchAudioCaptureCallbackExecutor(label: "AudioCaptureSessionTests.callback")
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func set(_ value: Value) { lock.withLock { storage = value } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}
