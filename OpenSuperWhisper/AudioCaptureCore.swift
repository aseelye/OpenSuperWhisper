@preconcurrency import AVFAudio
import Foundation

/// Configuration shared by the AVAudioEngine implementation and the
/// operation-scoped capture-session boundary.
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

/// Metadata for a completed capture file.
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

/// Errors shared by concrete capture implementations.
public enum AudioCaptureError: LocalizedError, Equatable, Sendable {
    case alreadyCapturing
    case noInputDevice
    case invalidInputFormat
    case unableToCreateFile(String)
    case engineStartFailed(String)
    case copyFailed(String)
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
        case let .copyFailed(message):
            return "Unable to copy an audio buffer: \(message)"
        case let .writeFailed(message):
            return "Unable to write the recording: \(message)"
        case .notCapturing:
            return "Audio capture is not running."
        case .cancelled:
            return "Audio capture was cancelled."
        }
    }
}

// MARK: - Capture driver seams

/// The engine-facing portion of AVAudioEngine used by one capture session.
///
/// Implementations must serialize `installTap`, `removeTap`, `prepare`,
/// `start`, and `stop` themselves, or be called only by the session's
/// lifecycle executor.  The production implementation follows the latter
/// rule.  Keeping this seam small lets tests model device startup and tap
/// races without requiring a microphone.
public protocol AudioCaptureEngineDriver: AnyObject, Sendable {
    var inputFormat: AVAudioFormat { get }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    )

    func removeTap()
    func prepare()
    func start() throws
    func stop()
}

/// Creates an engine for a single operation-scoped capture session.
public protocol AudioCaptureEngineFactory: Sendable {
    func makeEngine() throws -> any AudioCaptureEngineDriver
}

/// Writes one copied PCM buffer to the session's destination.
public protocol AudioCaptureWriterDriver: AnyObject, Sendable {
    func write(from buffer: AVAudioPCMBuffer) throws

    /// Releases any native file descriptor held by the writer.  The default
    /// is intentionally a no-op so tiny test writers only need `write`.
    func close()
}

public extension AudioCaptureWriterDriver {
    func close() {}
}

/// Creates a writer after the engine has supplied the native input format.
public protocol AudioCaptureWriterFactory: Sendable {
    func makeWriter(at url: URL, format: AVAudioFormat) throws -> any AudioCaptureWriterDriver
}

/// Copies a tap buffer while it is still owned by the audio callback.
public protocol AudioCaptureBufferCopier: Sendable {
    func copy(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer
}

/// Filesystem calls needed by capture setup and terminal cleanup.
public protocol AudioCaptureFileSystemDriver: Sendable {
    func createDirectory(at url: URL) throws
    func removeItem(at url: URL) throws
}

/// Delivers callbacks on a serial executor distinct from both the audio tap
/// and the serial writer. Implementations execute submissions FIFO, and
/// `drain` resumes only after all callbacks submitted before it have returned.
public protocol AudioCaptureCallbackExecutor: Sendable {
    func submit(_ callback: @escaping @Sendable () -> Void)
    func drain() async
}

public protocol AudioCaptureCallbackExecutorFactory: Sendable {
    func makeExecutor() -> any AudioCaptureCallbackExecutor
}

/// Dependencies for the concrete capture implementation.  They are narrow on
/// purpose: tests can gate setup, writes, copies, filesystem cleanup, and
/// callback delivery independently without mocking AVAudioEngine wholesale.
public struct AudioCaptureDependencies: Sendable {
    public let engineFactory: any AudioCaptureEngineFactory
    public let writerFactory: any AudioCaptureWriterFactory
    public let bufferCopier: any AudioCaptureBufferCopier
    public let fileSystem: any AudioCaptureFileSystemDriver
    public let callbackExecutorFactory: any AudioCaptureCallbackExecutorFactory

    public init(
        engineFactory: any AudioCaptureEngineFactory,
        writerFactory: any AudioCaptureWriterFactory,
        bufferCopier: any AudioCaptureBufferCopier = DefaultAudioCaptureBufferCopier(),
        fileSystem: any AudioCaptureFileSystemDriver = FileManagerAudioCaptureFileSystem(),
        callbackExecutorFactory: any AudioCaptureCallbackExecutorFactory = DispatchAudioCaptureCallbackExecutorFactory()
    ) {
        self.engineFactory = engineFactory
        self.writerFactory = writerFactory
        self.bufferCopier = bufferCopier
        self.fileSystem = fileSystem
        self.callbackExecutorFactory = callbackExecutorFactory
    }
}

// Compatibility spellings remain available through the pre-1.0 migration
// window; the driver protocols above are the canonical declarations.
public typealias AudioCaptureEngine = AudioCaptureEngineDriver
public typealias AudioCaptureWriter = AudioCaptureWriterDriver
public typealias AudioCaptureCopier = AudioCaptureBufferCopier
public typealias AudioCaptureFileSystem = AudioCaptureFileSystemDriver

/// An operation-scoped capture handle.
///
/// `start` reserves and starts capture.  Once `stopAndDrain` or
/// `cancelAndDrain` begins, admission closes before draining.  Every admitted
/// buffer is written and delivered exactly once, in order; callbacks run
/// before the drain method returns, and no callback occurs after it returns.
/// Implementations must keep real-time audio callbacks and blocking I/O away
/// from the caller's executor.
public protocol DictationAudioCaptureSession: AnyObject, Sendable {
    var currentRecordingURL: URL? { get }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws
    func stopAndDrain() async throws -> AudioCaptureResult?
    func cancelAndDrain() async
}

/// Synchronously creates an operation-scoped capture handle.  The returned
/// session is created before the caller performs its first asynchronous start.
public protocol DictationAudioCaptureFactory: Sendable {
    func makeSession() -> any DictationAudioCaptureSession
}

// MARK: - Recording-file ownership

/// Process-local ownership for a capture destination. Reconciliation can run
/// on MainActor while a capture session is still creating or writing its
/// temporary file, so existence alone is not enough to identify an abandoned
/// capture. Claims are path-normalized and reference-counted to keep test or
/// replacement sessions using the same explicit URL from releasing one
/// another's protection.
final class RecordingCaptureOwnershipRegistry: @unchecked Sendable {
    static let shared = RecordingCaptureOwnershipRegistry()

    private let lock = NSLock()
    private var claims: [String: Int] = [:]

    private init() {}

    func acquire(_ url: URL) -> RecordingCaptureOwnershipLease {
        let key = Self.key(for: url)
        lock.withLock {
            claims[key, default: 0] += 1
        }
        return RecordingCaptureOwnershipLease(registry: self, key: key)
    }

    func contains(_ url: URL) -> Bool {
        let key = Self.key(for: url)
        return lock.withLock { (claims[key] ?? 0) > 0 }
    }

    fileprivate func release(key: String) {
        lock.withLock {
            guard let count = claims[key] else { return }
            if count <= 1 {
                claims.removeValue(forKey: key)
            } else {
                claims[key] = count - 1
            }
        }
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}

/// A session-owned lease. The capture session releases it only after its
/// coordinator has drained; the controller retains the session through the
/// later transcription/persistence boundary, so a stopped temporary file is
/// still protected until ownership has actually transferred or been cleaned.
final class RecordingCaptureOwnershipLease: @unchecked Sendable {
    private let registry: RecordingCaptureOwnershipRegistry
    private let key: String
    private let lock = NSLock()
    private var released = false

    fileprivate init(registry: RecordingCaptureOwnershipRegistry, key: String) {
        self.registry = registry
        self.key = key
    }

    func release() {
        let shouldRelease = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease {
            registry.release(key: key)
        }
    }
}
