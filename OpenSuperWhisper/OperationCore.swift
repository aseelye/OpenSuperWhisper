@preconcurrency import AVFAudio
import Foundation

/// The identity assigned to one admitted dictation operation.
///
/// A token is intentionally a value rather than a task or controller
/// reference.  Callers can carry it across suspension points and compare it
/// before applying a completion without retaining operation-owned resources.
public struct SessionOperationToken: Hashable, Sendable {
    public let uuid: UUID

    public init() {
        self.uuid = UUID()
    }

    public init(_ uuid: UUID) {
        self.uuid = uuid
    }

    public init(uuid: UUID) {
        self.uuid = uuid
    }

    public init(id: UUID) {
        self.uuid = id
    }

    public var rawValue: UUID { uuid }
    public var id: UUID { uuid }
}

/// Contract spellings used by the remediation plan. These are aliases, not a
/// second token/source model.
public typealias OperationToken = SessionOperationToken

/// The surface that admitted an operation.  Sources are deliberately limited
/// to presentation/input origins; they do not contain user-provided text.
public enum SessionOperationSource: String, CaseIterable, Codable, Hashable, Sendable {
    case mainWindow
    case shortcut
    case fileDrop
    case importedFile
}

public typealias OperationSource = SessionOperationSource

/// A provider-neutral phase used by operation events and diagnostics.
///
/// Upload and retry counts are normalized by the labelled factories
/// (`.uploading(part:total:fraction:)` and `.retrying(attempt:maximum:)`).  The
/// unlabeled enum payloads keep ordinary enum pattern matching available to
/// callers while the factories provide the canonical normalized values.
public enum TranscriptionOperationPhase: Equatable, Sendable {
    case preparing
    case recording
    case finalizingAudio
    case exporting
    case uploading(Int?, Int?, Double?)
    case retrying(Int, Int)
    case transcribing
    case saving
    case cancelling

    /// Constructs an upload phase with bounded progress and valid counts.
    public static func uploading(
        part: Int? = nil,
        total: Int? = nil,
        fraction: Double? = nil
    ) -> Self {
        let progress = TranscriptionUploadProgress(part: part, total: total, fraction: fraction)
        return .uploading(progress.part, progress.total, progress.fraction)
    }

    /// Constructs a retry phase with positive, ordered attempt counts.
    public static func retrying(attempt: Int, maximum: Int) -> Self {
        let progress = TranscriptionRetryProgress(attempt: attempt, maximum: maximum)
        return .retrying(progress.attempt, progress.maximum)
    }

    public var uploadProgress: TranscriptionUploadProgress? {
        guard case let .uploading(part, total, fraction) = self else { return nil }
        return TranscriptionUploadProgress(part: part, total: total, fraction: fraction)
    }

    public var retryProgress: TranscriptionRetryProgress? {
        guard case let .retrying(attempt, maximum) = self else { return nil }
        return TranscriptionRetryProgress(attempt: attempt, maximum: maximum)
    }

    /// Returns the canonical representation even when a caller constructed
    /// the unlabeled enum payload directly.
    public var normalized: Self {
        switch self {
        case .preparing, .recording, .finalizingAudio, .exporting,
             .transcribing, .saving, .cancelling:
            return self
        case let .uploading(part, total, fraction):
            return .uploading(part: part, total: total, fraction: fraction)
        case let .retrying(attempt, maximum):
            return .retrying(attempt: attempt, maximum: maximum)
        }
    }
}

/// Normalized upload progress carried by `TranscriptionOperationPhase`.
public struct TranscriptionUploadProgress: Equatable, Sendable {
    public let part: Int?
    public let total: Int?
    public let fraction: Double?

    public init(part: Int? = nil, total: Int? = nil, fraction: Double? = nil) {
        let normalizedPart = part.map { max(1, $0) }
        var normalizedTotal = total.map { max(1, $0) }
        if let normalizedPart, let total = normalizedTotal {
            // A part cannot be outside the advertised total.  Raising the
            // total preserves the observed part while restoring that
            // invariant for diagnostic and UI consumers.
            normalizedTotal = max(total, normalizedPart)
        }
        self.part = normalizedPart
        self.total = normalizedTotal
        self.fraction = Self.normalizeFraction(fraction)
    }

    private static func normalizeFraction(_ value: Double?) -> Double? {
        guard let value else { return nil }
        guard !value.isNaN else { return nil }
        if value == .infinity { return 1 }
        if value == -.infinity { return 0 }
        return min(max(value, 0), 1)
    }
}

/// Normalized retry counts carried by `TranscriptionOperationPhase`.
public struct TranscriptionRetryProgress: Equatable, Sendable {
    public let attempt: Int
    public let maximum: Int

    public init(attempt: Int, maximum: Int) {
        let normalizedAttempt = max(1, attempt)
        self.attempt = normalizedAttempt
        self.maximum = max(normalizedAttempt, max(maximum, 1))
    }
}

/// A provider event that is safe to expose to presentation and diagnostics.
///
/// `message` is reserved for short, diagnostic-safe status text.  This value
/// deliberately has no transcript, prompt, request-body, API-key, or audio
/// fields; callers must not put user content into the message.
public struct TranscriptionOperationEvent: Equatable, Sendable {
    public let phase: TranscriptionOperationPhase
    public let message: String?

    public init(phase: TranscriptionOperationPhase, message: String? = nil) {
        self.phase = phase.normalized
        self.message = message
    }
}

/// The common lifetime boundary for one provider operation.
///
/// Implementations own their tasks and resources.  `cancelAndWait()` is
/// required to be idempotent and returns only after owned work has quiesced.
public protocol TranscriptionOperation: AnyObject, Sendable {
    var events: AsyncStream<TranscriptionOperationEvent> { get }

    func cancelAndWait() async
}

/// A provider operation that obtains its result from an already captured file.
public protocol TranscriptionFileOperation: TranscriptionOperation {
    func value() async throws -> Transcript
}

/// A provider operation that consumes copied live audio before finalization.
public protocol TranscriptionLiveOperation: TranscriptionOperation {
    /// Progressive transcript updates are optional at the provider boundary;
    /// the default is an already-finished stream for providers that only
    /// produce a final value.
    var updates: AsyncStream<TranscriptUpdate> { get }
    func start() async throws
    func append(buffer: AVAudioPCMBuffer) async throws
    func finish() async throws -> Transcript
}

public extension TranscriptionLiveOperation {
    var updates: AsyncStream<TranscriptUpdate> {
        AsyncStream { continuation in continuation.finish() }
    }
}

// Compatibility spellings make the role names easy to discover while keeping
// one canonical protocol declaration for downstream implementations.
public typealias FileTranscriptionOperation = TranscriptionFileOperation
public typealias LiveTranscriptionOperation = TranscriptionLiveOperation

/// Whether a provider consumes audio while it is recorded or after capture.
public enum RecordingTranscriptionStrategy: String, CaseIterable, Codable, Hashable, Sendable {
    case live
    case fileAfterCapture
}

/// Provider boundary for the post-compatibility operation handles.
///
/// Factory methods are synchronous by design: construction reserves the
/// operation handle before any asynchronous preparation, upload, or request
/// work begins.  A file-after-capture provider returns `nil` from the live
/// factory; a live provider supplies a live handle.
public protocol TranscriptionProvider: Sendable {
    var strategy: RecordingTranscriptionStrategy { get }

    func makeLiveOperation(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> (any TranscriptionLiveOperation)?

    func makeFileOperation(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) throws -> any TranscriptionFileOperation
}
