@preconcurrency import AVFAudio
@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

public struct AudioCaptureConfiguration: Sendable {
    public var bufferSize: AVAudioFrameCount
    public var temporaryDirectory: URL

    public init(
        bufferSize: AVAudioFrameCount = 1_024,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisper", isDirectory: true)
    ) {
        self.bufferSize = max(128, bufferSize)
        self.temporaryDirectory = temporaryDirectory
    }
}

public struct AudioCaptureResult: Sendable {
    public let fileURL: URL
    public let duration: TimeInterval
    public let sampleRate: Double
    public let channelCount: Int

    public init(fileURL: URL, duration: TimeInterval, sampleRate: Double, channelCount: Int) {
        self.fileURL = fileURL
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public enum AudioCaptureError: LocalizedError, Equatable, Sendable {
    case alreadyCapturing
    case noInputDevice
    case invalidInputFormat
    case unableToCreateFile(String)
    case engineStartFailed(String)
    case writeFailed(String)
    case notCapturing
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            return "Audio capture is already running."
        case .noInputDevice:
            return "No microphone is available."
        case .invalidInputFormat:
            return "The microphone returned an invalid audio format."
        case let .unableToCreateFile(message):
            return "Unable to create the temporary recording: \(message)"
        case let .engineStartFailed(message):
            return "Unable to start microphone capture: \(message)"
        case let .writeFailed(message):
            return "Unable to write the recording: \(message)"
        case .notCapturing:
            return "Audio capture is not running."
        case .cancelled:
            return "Audio capture was cancelled."
        }
    }
}

/// AVAudioEngine-based microphone capture. The input tap does one operation:
/// copy the incoming buffer. Disk I/O, user callbacks, and transcription are
/// performed by a serial worker queue after the render callback returns.
public final class AudioCaptureService: @unchecked Sendable {
    public static let shared = AudioCaptureService()

    private let configuration: AudioCaptureConfiguration
    private let stateLock = NSLock()
    private let writeQueue: DispatchQueue
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var currentURL: URL?
    private var inputFormat: AVAudioFormat?
    private var frameCount: AVAudioFramePosition = 0
    private var captureError: AudioCaptureError?
    private var isCapturingValue = false
    // A start reserves the lifecycle before doing any AVAudioEngine/file
    // setup. This closes the check-then-setup window where two callers could
    // both observe an idle service and later overwrite each other's state.
    private var isStartingValue = false
    // Cancellation can arrive while startCapture is still preparing the
    // engine, before there is a published capture for cancelCapture() to
    // tear down. The start owner consumes this flag before committing.
    private var pendingCancelValue = false
    // A canceled capture must keep the lifecycle occupied until its queued
    // writes have drained. Otherwise a new start could publish a new file
    // while stale work is still waiting on writeQueue.
    private var isDrainingValue = false
    private var nextCaptureGeneration: UInt64 = 0
    private var startingGeneration: UInt64?
    private var activeGeneration: UInt64?
    private var drainingGeneration: UInt64?
    private var acceptsBuffersValue = false
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    public init(configuration: AudioCaptureConfiguration = .init()) {
        self.configuration = configuration
        self.writeQueue = DispatchQueue(label: "ru.starmel.OpenSuperWhisper.audio-capture", qos: .userInitiated)
    }

    public var isCapturing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isCapturingValue
    }

    public var currentRecordingURL: URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentURL
    }

    public var canRecord: Bool {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return !discoverySession.devices.isEmpty
    }

    /// Starts capture and returns the temporary WAV URL immediately.
    @discardableResult
    public func startCapture(
        fileURL: URL? = nil,
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil
    ) throws -> URL {
        stateLock.lock()
        guard !isCapturingValue, !isStartingValue, !isDrainingValue else {
            stateLock.unlock()
            throw AudioCaptureError.alreadyCapturing
        }
        nextCaptureGeneration &+= 1
        let generation = nextCaptureGeneration
        isStartingValue = true
        startingGeneration = generation
        pendingCancelValue = false
        stateLock.unlock()

        // Every setup failure below must release the reservation so a later
        // start can retry. The reservation is committed once engine startup
        // succeeds.
        var startCommitted = false
        defer {
            if !startCommitted {
                stateLock.lock()
                if startingGeneration == generation {
                    isStartingValue = false
                    startingGeneration = nil
                    pendingCancelValue = false
                }
                stateLock.unlock()
            }
        }

        guard canRecord else { throw AudioCaptureError.noInputDevice }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }

        let destination = fileURL ?? configuration.temporaryDirectory
            .appendingPathComponent("recording-\(UUID().uuidString).wav")
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw AudioCaptureError.unableToCreateFile(error.localizedDescription)
        }

        let file: AVAudioFile
        do {
            // Keep the native input sample rate and channel count. SpeechAnalyzer
            // performs any required conversion off the audio render thread.
            file = try AVAudioFile(forWriting: destination, settings: format.settings)
        } catch {
            throw AudioCaptureError.unableToCreateFile(error.localizedDescription)
        }

        stateLock.lock()
        guard isStartingValue, startingGeneration == generation, !pendingCancelValue else {
            stateLock.unlock()
            try? FileManager.default.removeItem(at: destination)
            throw AudioCaptureError.cancelled
        }
        audioEngine = engine
        audioFile = file
        currentURL = destination
        inputFormat = format
        frameCount = 0
        captureError = nil
        bufferHandler = onBuffer
        isCapturingValue = true
        activeGeneration = generation
        acceptsBuffersValue = true
        stateLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: configuration.bufferSize, format: format) { [weak self] buffer, _ in
            guard let self, let copy = Self.copyBuffer(buffer) else { return }
            self.enqueue(copy, generation: generation)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            stateLock.lock()
            if activeGeneration == generation {
                audioEngine = nil
                audioFile = nil
                currentURL = nil
                inputFormat = nil
                isCapturingValue = false
                activeGeneration = nil
                acceptsBuffersValue = false
                bufferHandler = nil
            }
            stateLock.unlock()
            try? FileManager.default.removeItem(at: destination)
            stateLock.lock()
            let cancelled = pendingCancelValue && startingGeneration == generation
            stateLock.unlock()
            if cancelled {
                throw AudioCaptureError.cancelled
            }
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }

        stateLock.lock()
        let cancelled = pendingCancelValue
            || !isCapturingValue
            || !isStartingValue
            || activeGeneration != generation
            || startingGeneration != generation
        if !cancelled {
            // Mark the start committed before exposing the non-starting state;
            // cancellation can then only race with an already-completed
            // lifecycle transition, never a half-committed start.
            startCommitted = true
            isStartingValue = false
            startingGeneration = nil
            pendingCancelValue = false
        }
        stateLock.unlock()
        if cancelled {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            writeQueue.sync {}
            stateLock.lock()
            if activeGeneration == generation {
                audioEngine = nil
                audioFile = nil
                currentURL = nil
                inputFormat = nil
                isCapturingValue = false
                activeGeneration = nil
                acceptsBuffersValue = false
                bufferHandler = nil
            }
            stateLock.unlock()
            try? FileManager.default.removeItem(at: destination)
            throw AudioCaptureError.cancelled
        }
        return destination
    }

    /// Stops capture, drains pending writes, and returns metadata for the WAV.
    @discardableResult
    public func stopCapture() throws -> AudioCaptureResult {
        stateLock.lock()
        guard isCapturingValue, !isStartingValue,
              let engine = audioEngine,
              let fileURL = currentURL,
              let format = inputFormat,
              let generation = activeGeneration
        else {
            stateLock.unlock()
            throw AudioCaptureError.notCapturing
        }
        acceptsBuffersValue = false
        stateLock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // The serial queue has already accepted all copies made by the tap.
        writeQueue.sync {}

        stateLock.lock()
        guard activeGeneration == generation else {
            stateLock.unlock()
            throw AudioCaptureError.cancelled
        }
        let pendingError = captureError
        let frames = frameCount
        captureError = nil
        audioEngine = nil
        audioFile = nil
        bufferHandler = nil
        isCapturingValue = false
        activeGeneration = nil
        currentURL = nil
        inputFormat = nil
        acceptsBuffersValue = false
        stateLock.unlock()

        if let pendingError {
            try? FileManager.default.removeItem(at: fileURL)
            throw pendingError
        }
        let duration = format.sampleRate > 0 ? Double(frames) / format.sampleRate : 0
        return AudioCaptureResult(
            fileURL: fileURL,
            duration: duration,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
    }

    /// Stops the engine, drains queued writes, and removes the temporary file.
    public func cancelCapture() {
        stateLock.lock()
        guard isCapturingValue || isStartingValue else {
            stateLock.unlock()
            return
        }
        if isStartingValue {
            pendingCancelValue = true
        }
        guard isCapturingValue else {
            // startCapture() owns setup and will tear down its local engine
            // and file after observing the pending cancellation.
            stateLock.unlock()
            return
        }
        let engine = audioEngine
        let fileURL = currentURL
        let generation = activeGeneration
        if let generation {
            isDrainingValue = true
            drainingGeneration = generation
        }
        audioEngine = nil
        audioFile = nil
        currentURL = nil
        inputFormat = nil
        bufferHandler = nil
        isCapturingValue = false
        activeGeneration = nil
        acceptsBuffersValue = false
        captureError = nil
        frameCount = 0
        stateLock.unlock()

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        writeQueue.sync {}
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        stateLock.lock()
        if drainingGeneration == generation {
            isDrainingValue = false
            drainingGeneration = nil
        }
        stateLock.unlock()
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        stateLock.lock()
        guard acceptsBuffersValue else {
            stateLock.unlock()
            return
        }
        // Keep admission and submission under the same lock. stopCapture()
        // flips acceptsBuffersValue before installing its writeQueue barrier;
        // holding this lock through async() guarantees an accepted buffer is
        // submitted before that barrier, so the final tap buffer cannot be
        // stranded behind the drain.
        writeQueue.async { [weak self] in
            self?.process(buffer, generation: generation)
        }
        stateLock.unlock()
    }

    private func process(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        stateLock.lock()
        guard isCapturingValue, activeGeneration == generation, let file = audioFile else {
            stateLock.unlock()
            return
        }
        do {
            try file.write(from: buffer)
            frameCount += AVAudioFramePosition(buffer.frameLength)
        } catch {
            captureError = .writeFailed(error.localizedDescription)
        }
        let handler = bufferHandler
        stateLock.unlock()

        // This callback is intentionally outside the input tap. A live session
        // can enqueue conversion/transcription work without blocking disk I/O.
        handler?(buffer)
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        destination.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            let destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else {
                continue
            }
            let byteCount = min(Int(sourceBuffer.mDataByteSize), Int(destinationBuffer.mDataByteSize))
            memcpy(destinationData, sourceData, byteCount)
        }
        return destination
    }
}
