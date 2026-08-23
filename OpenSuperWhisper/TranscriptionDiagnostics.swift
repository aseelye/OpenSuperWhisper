import Foundation
import os

// TranscriptionBackend is the app's persisted provider selection. The enum
// has no mutable or reference state, so it is safe to carry in diagnostics.
extension TranscriptionBackend: @unchecked Sendable {}

/// A bounded category for local operation diagnostics.  Categories carry no
/// user content; cleanup and compensation outcomes are represented explicitly
/// so a sink never needs to parse free-form messages.
enum TranscriptionDiagnosticOutcome: String, Codable, Equatable, Hashable, Sendable {
    case started
    case progressed
    case completed
    case failed
    case cancelled
    case warning
    case cleanupFailed
    case compensationFailed

    // Common terminology aliases keep call sites readable without adding
    // duplicate wire values or user-content-bearing cases.
    static var success: Self { .completed }
    static var failure: Self { .failed }
}

typealias TranscriptionDiagnosticOutcomeCategory = TranscriptionDiagnosticOutcome

/// A local, privacy-preserving event for one transcription operation.
///
/// This value deliberately contains only identity, source/backend, phase,
/// bounded indices, and an outcome category.  It has no transcript, prompt,
/// API key, request body, audio, or free-form user-content field.
struct TranscriptionDiagnosticEvent: Equatable, Sendable {
    let operationToken: SessionOperationToken
    let source: SessionOperationSource
    let backend: TranscriptionBackend
    let phase: TranscriptionOperationPhase
    let captureGeneration: UInt64?
    let chunkIndex: Int?
    let outcome: TranscriptionDiagnosticOutcome

    /// A stable spelling for sinks that serialize events by operation ID.
    var operationID: UUID { operationToken.uuid }

    init(
        operationToken: SessionOperationToken,
        source: SessionOperationSource,
        backend: TranscriptionBackend,
        phase: TranscriptionOperationPhase,
        captureGeneration: UInt64? = nil,
        chunkIndex: Int? = nil,
        outcome: TranscriptionDiagnosticOutcome
    ) {
        self.operationToken = operationToken
        self.source = source
        self.backend = backend
        self.phase = phase
        self.captureGeneration = captureGeneration
        self.chunkIndex = chunkIndex
        self.outcome = outcome
    }

    init(
        operationToken: SessionOperationToken,
        source: SessionOperationSource,
        backend: TranscriptionBackend,
        phase: TranscriptionOperationPhase,
        captureGeneration: UInt64? = nil,
        chunkIndex: Int? = nil,
        outcomeCategory: TranscriptionDiagnosticOutcome
    ) {
        self.init(
            operationToken: operationToken,
            source: source,
            backend: backend,
            phase: phase,
            captureGeneration: captureGeneration,
            chunkIndex: chunkIndex,
            outcome: outcomeCategory
        )
    }

    var outcomeCategory: TranscriptionDiagnosticOutcome { outcome }
}

/// A deliberately small injectable local diagnostics sink.
protocol TranscriptionDiagnosticSink: Sendable {
    func record(_ event: TranscriptionDiagnosticEvent)
}

/// Default sink used when a caller does not need diagnostics.
struct NoOpTranscriptionDiagnosticSink: TranscriptionDiagnosticSink {
    static let shared = NoOpTranscriptionDiagnosticSink()

    init() {}

    func record(_ event: TranscriptionDiagnosticEvent) {}
}

extension TranscriptionDiagnosticSink {
    static var noOp: any TranscriptionDiagnosticSink {
        NoOpTranscriptionDiagnosticSink.shared
    }
}

/// The production local sink. It deliberately logs only bounded identifiers
/// and categories; transcripts, prompts, API keys, request bodies, and audio
/// never enter the message.
final class LoggerTranscriptionDiagnosticSink: TranscriptionDiagnosticSink {
    static let shared = LoggerTranscriptionDiagnosticSink()

    private let logger: Logger

    init(logger: Logger = Logger(subsystem: "OpenSuperWhisper", category: "transcription")) {
        self.logger = logger
    }

    func record(_ event: TranscriptionDiagnosticEvent) {
        let capture = event.captureGeneration.map(String.init) ?? "-"
        let chunk = event.chunkIndex.map(String.init) ?? "-"
        logger.debug(
            "operation=\(event.operationToken.uuid.uuidString, privacy: .public) source=\(event.source.rawValue, privacy: .public) backend=\(event.backend.rawValue, privacy: .public) phase=\(String(describing: event.phase), privacy: .public) capture=\(capture, privacy: .public) chunk=\(chunk, privacy: .public) outcome=\(event.outcome.rawValue, privacy: .public)"
        )
    }
}
