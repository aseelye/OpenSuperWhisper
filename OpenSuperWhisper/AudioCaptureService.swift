@preconcurrency import AVFAudio
@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

// MARK: - Production driver implementations

/// The production AVAudioEngine adapter. Lifecycle methods are called by the
/// capture coordinator actor, while the tap callback only copies and admits a
/// buffer to the writer queue.
public final class AVAudioEngineCaptureDriver: AudioCaptureEngineDriver, @unchecked Sendable {
    private let engine: AVAudioEngine
    private let inputNode: AVAudioInputNode
    private let installedLock = NSLock()
    private var tapInstalled = false

    public let inputFormat: AVAudioFormat

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        self.inputNode = engine.inputNode
        self.inputFormat = inputNode.outputFormat(forBus: 0)
    }

    public func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) {
        installedLock.lock()
        guard !tapInstalled else {
            installedLock.unlock()
            return
        }
        tapInstalled = true
        installedLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            handler(buffer)
        }
    }

    public func removeTap() {
        installedLock.lock()
        guard tapInstalled else {
            installedLock.unlock()
            return
        }
        tapInstalled = false
        installedLock.unlock()
        inputNode.removeTap(onBus: 0)
    }

    public func prepare() {
        engine.prepare()
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }
}

public struct AVAudioEngineCaptureFactory: AudioCaptureEngineFactory, Sendable {
    public init() {}

    public func makeEngine() throws -> any AudioCaptureEngineDriver {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        guard !discoverySession.devices.isEmpty else {
            throw AudioCaptureError.noInputDevice
        }
        let driver = AVAudioEngineCaptureDriver()
        guard driver.inputFormat.sampleRate > 0, driver.inputFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }
        return driver
    }
}

/// Serial-use AVAudioFile writer. The capture writer queue is its sole write
/// caller; `close` runs only after that queue and the callback executor drain.
public final class AVAudioFileCaptureWriterDriver: AudioCaptureWriterDriver, @unchecked Sendable {
    private var file: AVAudioFile?

    public init(url: URL, format: AVAudioFormat) throws {
        self.file = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    public func write(from buffer: AVAudioPCMBuffer) throws {
        guard let file else {
            throw AudioCaptureError.writeFailed("The audio file writer is closed.")
        }
        try file.write(from: buffer)
    }

    public func close() {
        file = nil
    }
}

public struct AVAudioFileCaptureWriterFactory: AudioCaptureWriterFactory, Sendable {
    public init() {}

    public func makeWriter(at url: URL, format: AVAudioFormat) throws -> any AudioCaptureWriterDriver {
        do {
            return try AVAudioFileCaptureWriterDriver(url: url, format: format)
        } catch {
            throw AudioCaptureError.unableToCreateFile(error.localizedDescription)
        }
    }
}

/// Copies PCM bytes in the tap callback and reports malformed layouts instead
/// of silently dropping them.
public struct DefaultAudioCaptureBufferCopier: AudioCaptureBufferCopier, Sendable {
    public init() {}

    public func copy(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            throw AudioCaptureError.copyFailed("Unable to allocate a PCM buffer.")
        }
        destination.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            throw AudioCaptureError.copyFailed("The audio buffer lists have different channel layouts.")
        }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            let destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData
            else {
                throw AudioCaptureError.copyFailed("The audio buffer has no backing memory.")
            }
            let byteCount = min(
                Int(sourceBuffer.mDataByteSize),
                Int(destinationBuffer.mDataByteSize)
            )
            guard byteCount >= 0 else {
                throw AudioCaptureError.copyFailed("The audio buffer has an invalid byte count.")
            }
            memcpy(destinationData, sourceData, byteCount)
        }
        return destination
    }
}

public struct FileManagerAudioCaptureFileSystem: AudioCaptureFileSystemDriver, Sendable {
    public init() {}

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// A per-session serial callback executor. It has no synchronous barrier, so
/// capture stop/cancel never blocks the caller's actor while waiting for user
/// callbacks or writer I/O.
public final class DispatchAudioCaptureCallbackExecutor: AudioCaptureCallbackExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(label: String = "ru.starmel.OpenSuperWhisper.audio-callback") {
        self.queue = DispatchQueue(
            label: "\(label).\(UUID().uuidString)",
            qos: .userInitiated
        )
    }

    public func submit(_ callback: @escaping @Sendable () -> Void) {
        queue.async(execute: callback)
    }

    public func drain() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }
}

public struct DispatchAudioCaptureCallbackExecutorFactory: AudioCaptureCallbackExecutorFactory, Sendable {
    public init() {}

    public func makeExecutor() -> any AudioCaptureCallbackExecutor {
        DispatchAudioCaptureCallbackExecutor()
    }
}

public extension AudioCaptureDependencies {
    /// Native AVAudioEngine/AVAudioFile dependencies used by the app singleton.
    static var production: Self {
        Self(
            engineFactory: AVAudioEngineCaptureFactory(),
            writerFactory: AVAudioFileCaptureWriterFactory(),
            bufferCopier: DefaultAudioCaptureBufferCopier(),
            fileSystem: FileManagerAudioCaptureFileSystem(),
            callbackExecutorFactory: DispatchAudioCaptureCallbackExecutorFactory()
        )
    }
}

// MARK: - Admission and queue state

private enum AudioCapturePhase: Sendable {
    case idle
    case starting
    case running
    case draining
    case finished
}

private enum AudioCaptureTerminationRequest: Sendable, Equatable {
    case stop
    case cancel
}

private struct AudioCaptureResources: @unchecked Sendable {
    let destination: URL
    let format: AVAudioFormat
    let writer: any AudioCaptureWriterDriver
    let callbackExecutor: any AudioCaptureCallbackExecutor
    let handler: @Sendable (AVAudioPCMBuffer) -> Void
}

private struct AudioCaptureJob: @unchecked Sendable {
    let generation: UInt64
    let buffer: AVAudioPCMBuffer
    let resources: AudioCaptureResources
}

/// The lock is deliberately limited to lifecycle/admission metadata and queue
/// submission. It is never held while a writer or client callback runs.
private final class AudioCaptureAdmissionState: @unchecked Sendable {
    private let lock = NSLock()
    private let generation: UInt64
    private var phase: AudioCapturePhase = .idle
    private var acceptsBuffers = false
    private var request: AudioCaptureTerminationRequest?
    private var resources: AudioCaptureResources?
    private var frameCount: AVAudioFramePosition = 0
    private var terminalError: AudioCaptureError?
    private var finalResult: AudioCaptureResult?

    init(generation: UInt64) {
        self.generation = generation
    }

    var currentRecordingURL: URL? {
        lock.withLock { resources?.destination }
    }

    var isCapturing: Bool {
        lock.withLock {
            switch phase {
            case .starting, .running, .draining:
                return true
            case .idle, .finished:
                return false
            }
        }
    }

    func reserve() throws {
        try lock.withLock {
            guard phase == .idle else {
                throw AudioCaptureError.alreadyCapturing
            }
            if request != nil {
                phase = .finished
                terminalError = .cancelled
                throw AudioCaptureError.cancelled
            }
            phase = .starting
        }
    }

    func attach(_ resources: AudioCaptureResources) {
        lock.withLock {
            self.resources = resources
            if request == nil {
                phase = .running
                acceptsBuffers = true
            } else {
                phase = .draining
                acceptsBuffers = false
            }
        }
    }

    /// Closes admission before a lifecycle operation removes the tap. Any
    /// buffer that passed this lock transition is already enqueued on the
    /// writer queue before the caller can install its drain marker.
    func requestTermination(_ request: AudioCaptureTerminationRequest) {
        lock.withLock {
            guard phase != .finished else { return }
            if self.request != .cancel || request == .cancel {
                self.request = request
            }
            acceptsBuffers = false
            if phase == .running {
                phase = .draining
            }
        }
    }

    /// Closes the gate for an internal terminal failure without rewriting the
    /// caller's cancellation/stop intent. This distinction lets a start error
    /// remain an engine/write/copy error while still honoring a racing cancel.
    func closeAdmission() {
        lock.withLock {
            guard phase != .finished else { return }
            acceptsBuffers = false
            if phase == .running { phase = .draining }
        }
    }

    var requestedTermination: AudioCaptureTerminationRequest? {
        lock.withLock { request }
    }

    var currentPhase: AudioCapturePhase {
        lock.withLock { phase }
    }

    var activeResources: AudioCaptureResources? {
        lock.withLock { resources }
    }

    func isCurrentGeneration(_ generation: UInt64) -> Bool {
        lock.withLock { self.generation == generation }
    }

    /// Admission and queue submission are one short critical section. The
    /// queue block itself performs no work until after the lock is released.
    func admit(
        _ buffer: AVAudioPCMBuffer,
        queue: DispatchQueue,
        process: @escaping @Sendable (AudioCaptureJob) -> Void
    ) -> Bool {
        lock.lock()
        guard phase == .running,
              acceptsBuffers,
              let resources
        else {
            lock.unlock()
            return false
        }
        let job = AudioCaptureJob(
            generation: generation,
            buffer: buffer,
            resources: resources
        )
        queue.async {
            process(job)
        }
        lock.unlock()
        return true
    }

    func recordCopyFailure(_ error: AudioCaptureError) {
        lock.withLock {
            guard phase != .finished else { return }
            terminalError = terminalError ?? error
            acceptsBuffers = false
            if phase == .running { phase = .draining }
        }
    }

    func recordWriteFailure(_ error: AudioCaptureError) {
        lock.withLock {
            guard phase != .finished else { return }
            terminalError = terminalError ?? error
            acceptsBuffers = false
            if phase == .running { phase = .draining }
        }
    }

    func recordSuccessfulWrite(generation: UInt64, frameLength: AVAudioFrameCount) {
        lock.withLock {
            guard phase != .finished, self.generation == generation else { return }
            frameCount += AVAudioFramePosition(frameLength)
        }
    }

    func errorAndFrameCount() -> (AudioCaptureError?, AVAudioFramePosition) {
        lock.withLock { (terminalError, frameCount) }
    }

    func finish(result: AudioCaptureResult?, error: AudioCaptureError?) {
        lock.withLock {
            finalResult = result
            terminalError = error ?? terminalError
            resources = nil
            acceptsBuffers = false
            phase = .finished
        }
    }

    func completedOutcome() -> (AudioCaptureResult?, AudioCaptureError?) {
        lock.withLock { (finalResult, terminalError) }
    }
}

/// The singleton service owns one microphone resource. Sessions remain
/// operation-scoped, but factory-created sessions share this tiny lease so a
/// replacement cannot start until the previous session has fully drained.
private final class AudioCaptureServiceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: UInt64?

    var isReserved: Bool {
        lock.withLock { activeGeneration != nil }
    }

    func reserve(_ generation: UInt64) throws {
        try lock.withLock {
            guard activeGeneration == nil else {
                throw AudioCaptureError.alreadyCapturing
            }
            activeGeneration = generation
        }
    }

    func release(_ generation: UInt64) {
        lock.withLock {
            if activeGeneration == generation {
                activeGeneration = nil
            }
        }
    }
}

/// Receives tap callbacks and owns the only admission-to-writer transition.
/// The receiver is retained by the coordinator while the operation is live,
/// and each admitted writer job retains it until its callback has been queued.
private final class AudioCaptureTapReceiver: @unchecked Sendable {
    private let state: AudioCaptureAdmissionState
    private let copier: any AudioCaptureBufferCopier
    private let writerQueue: DispatchQueue

    init(
        state: AudioCaptureAdmissionState,
        copier: any AudioCaptureBufferCopier,
        writerQueue: DispatchQueue
    ) {
        self.state = state
        self.copier = copier
        self.writerQueue = writerQueue
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        do {
            let copy = try copier.copy(buffer)
            _ = state.admit(copy, queue: writerQueue) { [self] job in
                process(job)
            }
        } catch let error as AudioCaptureError {
            state.recordCopyFailure(error)
        } catch {
            state.recordCopyFailure(.copyFailed(error.localizedDescription))
        }
    }

    private func process(_ job: AudioCaptureJob) {
        guard state.isCurrentGeneration(job.generation) else { return }
        do {
            try job.resources.writer.write(from: job.buffer)
            state.recordSuccessfulWrite(
                generation: job.generation,
                frameLength: job.buffer.frameLength
            )
        } catch let error as AudioCaptureError {
            state.recordWriteFailure(error)
        } catch {
            state.recordWriteFailure(.writeFailed(error.localizedDescription))
        }

        // This submission happens after the write but on a different executor;
        // the writer queue never runs user code synchronously.
        job.resources.callbackExecutor.submit { [handler = job.resources.handler, buffer = job.buffer] in
            handler(buffer)
        }
    }
}

// MARK: - Operation-scoped session

/// One asynchronous microphone operation. A session is intentionally single
/// use: callers obtain a fresh handle from `AudioCaptureService` for a
/// replacement operation, which makes stale generations unable to write into
/// or call back through a later operation.
public final class AudioCaptureSession: DictationAudioCaptureSession, @unchecked Sendable {
    private let state: AudioCaptureAdmissionState
    private let coordinator: AudioCaptureSessionCoordinator
    public let generation: UInt64

    public convenience init(
        configuration: AudioCaptureConfiguration = .init(),
        dependencies: AudioCaptureDependencies = .production,
        generation: UInt64 = 1,
        fileURL: URL? = nil
    ) {
        self.init(
            configuration: configuration,
            dependencies: dependencies,
            generation: generation,
            fileURL: fileURL,
            serviceLease: nil
        )
    }

    fileprivate init(
        configuration: AudioCaptureConfiguration,
        dependencies: AudioCaptureDependencies,
        generation: UInt64,
        fileURL: URL?,
        serviceLease: AudioCaptureServiceLease?
    ) {
        let state = AudioCaptureAdmissionState(generation: generation)
        let writerQueue = DispatchQueue(
            label: "ru.starmel.OpenSuperWhisper.audio-writer.\(generation).\(UUID().uuidString)",
            qos: .userInitiated
        )
        let receiver = AudioCaptureTapReceiver(
            state: state,
            copier: dependencies.bufferCopier,
            writerQueue: writerQueue
        )
        self.state = state
        self.generation = generation
        self.coordinator = AudioCaptureSessionCoordinator(
            configuration: configuration,
            dependencies: dependencies,
            generation: generation,
            destinationURL: fileURL,
            state: state,
            receiver: receiver,
            writerQueue: writerQueue,
            serviceLease: serviceLease
        )
    }

    public var currentRecordingURL: URL? {
        state.currentRecordingURL
    }

    /// Useful to the temporary synchronous compatibility adapter; new callers
    /// should use the async session methods and not inspect lifecycle state.
    public var isCapturing: Bool {
        state.isCapturing
    }

    public func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        try await withTaskCancellationHandler(operation: {
            try await coordinator.start(onBuffer: onBuffer)
            if Task.isCancelled {
                state.requestTermination(.cancel)
                await coordinator.cancelAndDrain()
                throw AudioCaptureError.cancelled
            }
        }, onCancel: {
            state.requestTermination(.cancel)
            Task {
                await coordinator.cancelAndDrain()
            }
        })
    }

    public func start() async throws {
        try await start(onBuffer: { _ in })
    }

    deinit {
        // A dropped handle must not strand the service lease or an installed
        // tap. Cleanup is idempotent and runs on the coordinator's executor;
        // deinit itself never performs blocking teardown.
        state.requestTermination(.cancel)
        let coordinator = coordinator
        Task {
            await coordinator.cancelAndDrain()
        }
    }

    public func stopAndDrain() async throws -> AudioCaptureResult? {
        state.requestTermination(.stop)
        return try await coordinator.stopAndDrain()
    }

    public func cancelAndDrain() async {
        state.requestTermination(.cancel)
        await coordinator.cancelAndDrain()
    }
}

private actor AudioCaptureSessionCoordinator {
    private let configuration: AudioCaptureConfiguration
    private let dependencies: AudioCaptureDependencies
    private let generation: UInt64
    private let destinationURL: URL?
    private let state: AudioCaptureAdmissionState
    private let receiver: AudioCaptureTapReceiver
    private let writerQueue: DispatchQueue
    private let serviceLease: AudioCaptureServiceLease?

    private var engine: (any AudioCaptureEngineDriver)?
    private var writer: (any AudioCaptureWriterDriver)?
    private var callbackExecutor: (any AudioCaptureCallbackExecutor)?
    private var attachedDestination: URL?
    private var attachedFormat: AVAudioFormat?
    private var leaseReserved = false

    init(
        configuration: AudioCaptureConfiguration,
        dependencies: AudioCaptureDependencies,
        generation: UInt64,
        destinationURL: URL?,
        state: AudioCaptureAdmissionState,
        receiver: AudioCaptureTapReceiver,
        writerQueue: DispatchQueue,
        serviceLease: AudioCaptureServiceLease?
    ) {
        self.configuration = configuration
        self.dependencies = dependencies
        self.generation = generation
        self.destinationURL = destinationURL
        self.state = state
        self.receiver = receiver
        self.writerQueue = writerQueue
        self.serviceLease = serviceLease
    }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        try state.reserve()

        let destination = destinationURL ?? configuration.temporaryDirectory
            .appendingPathComponent("recording-\(UUID().uuidString).wav")
        attachedDestination = destination

        do {
            try serviceLease?.reserve(generation)
            leaseReserved = serviceLease != nil
            try checkForRequestedTermination()
            do {
                try dependencies.fileSystem.createDirectory(
                    at: destination.deletingLastPathComponent()
                )
            } catch let error as AudioCaptureError {
                throw error
            } catch {
                throw AudioCaptureError.unableToCreateFile(error.localizedDescription)
            }

            try checkForRequestedTermination()
            let engine = try dependencies.engineFactory.makeEngine()
            self.engine = engine
            let format = engine.inputFormat
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw AudioCaptureError.invalidInputFormat
            }
            attachedFormat = format

            let writer = try dependencies.writerFactory.makeWriter(at: destination, format: format)
            self.writer = writer
            let callbackExecutor = dependencies.callbackExecutorFactory.makeExecutor()
            self.callbackExecutor = callbackExecutor

            state.attach(
                AudioCaptureResources(
                    destination: destination,
                    format: format,
                    writer: writer,
                    callbackExecutor: callbackExecutor,
                    handler: onBuffer
                )
            )

            engine.installTap(
                bufferSize: configuration.bufferSize,
                format: format
            ) { [weak receiver] buffer in
                receiver?.receive(buffer)
            }

            try checkForRequestedTermination()
            engine.prepare()
            try engine.start()
            try checkForRequestedTermination()
        } catch {
            let terminalError = normalizeStartError(error)
            await terminate(deleteFile: true, error: terminalError)
            throw terminalError
        }
    }

    func stopAndDrain() async throws -> AudioCaptureResult? {
        switch state.currentPhase {
        case .idle:
            return nil
        case .finished:
            let outcome = state.completedOutcome()
            if let error = outcome.1 { throw error }
            return outcome.0
        case .starting, .running, .draining:
            break
        }

        // The public method closes admission before reaching this actor. The
        // repeated close makes this method safe for direct coordinator calls.
        state.requestTermination(.stop)
        let existingError = state.errorAndFrameCount().0
        let wasCancelled = state.requestedTermination == .cancel
        await terminate(
            deleteFile: wasCancelled || existingError != nil,
            error: wasCancelled ? .cancelled : existingError
        )

        let outcome = state.completedOutcome()
        if let error = outcome.1 { throw error }
        return outcome.0
    }

    func cancelAndDrain() async {
        state.requestTermination(.cancel)
        switch state.currentPhase {
        case .idle:
            state.finish(result: nil, error: .cancelled)
        case .finished:
            return
        case .starting, .running, .draining:
            await terminate(deleteFile: true, error: .cancelled)
        }
    }

    private func checkForRequestedTermination() throws {
        guard state.requestedTermination == nil else {
            throw AudioCaptureError.cancelled
        }
        if let terminalError = state.errorAndFrameCount().0 {
            throw terminalError
        }
        if Task.isCancelled {
            state.requestTermination(.cancel)
            throw AudioCaptureError.cancelled
        }
    }

    private func normalizeStartError(_ error: Error) -> AudioCaptureError {
        if state.requestedTermination != nil || Task.isCancelled {
            return .cancelled
        }
        if let stateError = state.errorAndFrameCount().0 {
            return stateError
        }
        if let error = error as? AudioCaptureError {
            return error
        }
        return .engineStartFailed(error.localizedDescription)
    }

    /// Terminal order is: close admission → serialize engine teardown → drain
    /// writer → drain callbacks → close writer → delete on failure/cancel →
    /// publish outcome. No lock is held over any potentially blocking work.
    private func terminate(deleteFile: Bool, error requestedError: AudioCaptureError?) async {
        let phase = state.currentPhase
        guard phase != .finished else { return }
        state.closeAdmission()

        let localEngine = engine
        let localWriter = writer ?? state.activeResources?.writer
        let localCallbackExecutor = callbackExecutor ?? state.activeResources?.callbackExecutor
        let localDestination = attachedDestination ?? state.activeResources?.destination
        let localFormat = attachedFormat ?? state.activeResources?.format

        // AVAudioEngine lifecycle calls are all actor-isolated and therefore
        // cannot overlap another stop/cancel/start on this session.
        localEngine?.removeTap()
        localEngine?.stop()

        // Async queue markers keep the MainActor and lifecycle actor responsive
        // while admitted writes and callbacks complete.
        await drainWriterQueue()
        if let localCallbackExecutor {
            await localCallbackExecutor.drain()
        }
        localWriter?.close()

        // Cancellation may race the final callback. Re-read the request after
        // all admitted work has quiesced so a concurrent cancel cannot publish
        // a successful result or leave the file behind.
        let cancellationRequested = state.requestedTermination == .cancel
        let stateError = state.errorAndFrameCount().0
        let terminalError = cancellationRequested
            ? AudioCaptureError.cancelled
            : (requestedError ?? stateError)
        let shouldDeleteFile = deleteFile || cancellationRequested || terminalError != nil
        if shouldDeleteFile, let localDestination {
            try? dependencies.fileSystem.removeItem(at: localDestination)
        }

        let frames = state.errorAndFrameCount().1
        var result: AudioCaptureResult?
        if terminalError == nil, !shouldDeleteFile,
           let localDestination,
           let localFormat {
            let duration = localFormat.sampleRate > 0
                ? Double(frames) / localFormat.sampleRate
                : 0
            result = AudioCaptureResult(
                fileURL: localDestination,
                duration: duration,
                sampleRate: localFormat.sampleRate,
                channelCount: Int(localFormat.channelCount)
            )
        }

        state.finish(result: result, error: terminalError)
        engine = nil
        writer = nil
        callbackExecutor = nil
        attachedDestination = nil
        attachedFormat = nil
        if leaseReserved {
            serviceLease?.release(generation)
            leaseReserved = false
        }
    }

    private func drainWriterQueue() async {
        await withCheckedContinuation { continuation in
            writerQueue.async {
                continuation.resume()
            }
        }
    }
}

// MARK: - Service/factory and compatibility bridge

/// Factory for operation-scoped capture sessions.
public final class AudioCaptureService: DictationAudioCaptureFactory, @unchecked Sendable {
    public static let shared = AudioCaptureService()

    private let configuration: AudioCaptureConfiguration
    private let dependencies: AudioCaptureDependencies
    private let serviceLease = AudioCaptureServiceLease()
    private let legacyLock = NSLock()
    private var legacySession: AudioCaptureSession?
    private var nextGeneration: UInt64 = 0

    public init(
        configuration: AudioCaptureConfiguration = .init(),
        dependencies: AudioCaptureDependencies = .production
    ) {
        self.configuration = configuration
        self.dependencies = dependencies
    }

    /// Convenience injection spelling for tests and small adapters.
    public convenience init(
        configuration: AudioCaptureConfiguration = .init(),
        engineFactory: any AudioCaptureEngineFactory,
        writerFactory: any AudioCaptureWriterFactory,
        bufferCopier: any AudioCaptureBufferCopier = DefaultAudioCaptureBufferCopier(),
        fileSystem: any AudioCaptureFileSystemDriver = FileManagerAudioCaptureFileSystem(),
        callbackExecutorFactory: any AudioCaptureCallbackExecutorFactory = DispatchAudioCaptureCallbackExecutorFactory()
    ) {
        self.init(
            configuration: configuration,
            dependencies: AudioCaptureDependencies(
                engineFactory: engineFactory,
                writerFactory: writerFactory,
                bufferCopier: bufferCopier,
                fileSystem: fileSystem,
                callbackExecutorFactory: callbackExecutorFactory
            )
        )
    }

    public func makeSession() -> any DictationAudioCaptureSession {
        makeConcreteSession()
    }

    /// Convenience overload used by file-oriented adapters and deterministic
    /// tests that need a stable destination path.
    public func makeSession(fileURL: URL?) -> AudioCaptureSession {
        makeConcreteSession(fileURL: fileURL)
    }

    /// Concrete overload for tests that need to inspect operation state. New
    /// orchestration should depend on the frozen protocol instead.
    public func makeConcreteSession(fileURL: URL? = nil) -> AudioCaptureSession {
        let generation = legacyLock.withLock {
            nextGeneration &+= 1
            return nextGeneration
        }
        return AudioCaptureSession(
            configuration: configuration,
            dependencies: dependencies,
            generation: generation,
            fileURL: fileURL,
            serviceLease: serviceLease
        )
    }

    private func makeConcreteSession() -> AudioCaptureSession {
        makeConcreteSession(fileURL: nil)
    }

    public var isCapturing: Bool {
        legacyLock.withLock { legacySession?.isCapturing ?? serviceLease.isReserved }
    }

    public var currentRecordingURL: URL? {
        legacyLock.withLock { legacySession?.currentRecordingURL }
    }

    public var canRecord: Bool {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return !discoverySession.devices.isEmpty
    }

    // Retained solely for the pre-Wave-2 adapter. New code must use
    // makeSession() and its async lifecycle methods.
    @available(*, deprecated, message: "Use makeSession().start(onBuffer:) instead")
    @discardableResult
    public func startCapture(
        fileURL: URL? = nil,
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil
    ) throws -> URL {
        let session = makeConcreteSession(fileURL: fileURL)
        legacyLock.lock()
        guard legacySession == nil else {
            legacyLock.unlock()
            throw AudioCaptureError.alreadyCapturing
        }
        legacySession = session
        legacyLock.unlock()

        do {
            try blockingAwait {
                try await session.start { buffer in
                    onBuffer?(buffer)
                }
            }
            guard let url = session.currentRecordingURL else {
                throw AudioCaptureError.engineStartFailed("Capture started without a destination file.")
            }
            return url
        } catch {
            clearLegacySession(ifIdenticalTo: session)
            throw error
        }
    }

    @available(*, deprecated, message: "Use stopAndDrain() on the operation session instead")
    @discardableResult
    public func stopCapture() throws -> AudioCaptureResult {
        guard let session = legacyLock.withLock({ legacySession }) else {
            throw AudioCaptureError.notCapturing
        }
        do {
            guard let result = try blockingAwait({ try await session.stopAndDrain() }) else {
                throw AudioCaptureError.notCapturing
            }
            clearLegacySession(ifIdenticalTo: session)
            return result
        } catch {
            clearLegacySession(ifIdenticalTo: session)
            throw error
        }
    }

    @available(*, deprecated, message: "Use cancelAndDrain() on the operation session instead")
    public func cancelCapture() {
        guard let session = legacyLock.withLock({ legacySession }) else { return }
        try? blockingAwait {
            await session.cancelAndDrain()
            return ()
        }
        clearLegacySession(ifIdenticalTo: session)
    }

    private func clearLegacySession(ifIdenticalTo session: AudioCaptureSession) {
        legacyLock.withLock {
            if legacySession === session {
                legacySession = nil
            }
        }
    }

    private func blockingAwait<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = BlockingResultBox<T>()
        Task {
            do {
                resultBox.resolve(.success(try await operation()))
            } catch {
                resultBox.resolve(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try resultBox.value.get()
    }
}

private final class BlockingResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    func resolve(_ result: Result<Value, Error>) {
        lock.withLock { stored = result }
    }

    var value: Result<Value, Error> {
        lock.withLock {
            stored ?? .failure(AudioCaptureError.engineStartFailed("Capture bridge completed without a result."))
        }
    }
}
