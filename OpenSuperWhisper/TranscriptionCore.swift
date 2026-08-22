@preconcurrency import AVFAudio
import CoreMedia
import Foundation

/// The smallest unit of a transcript that can be persisted or shown with timing
/// details. Times are measured in seconds from the beginning of the recording.
public struct TranscriptSegment: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Double?

    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil
    ) {
        self.text = text
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
        self.confidence = confidence.map { min(max($0, 0), 1) }
    }

    public var duration: TimeInterval { max(0, endTime - startTime) }
    public var timeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 1_000),
            end: CMTime(seconds: endTime, preferredTimescale: 1_000)
        )
    }
}

/// A finalized transcript. `text` intentionally contains no timing decorations;
/// timing data is available through `segments` for history and other clients.
public struct Transcript: Codable, Equatable, Sendable {
    public let text: String
    public let locale: Locale
    public let segments: [TranscriptSegment]

    public init(text: String, locale: Locale = Locale(identifier: "und"), segments: [TranscriptSegment] = []) {
        self.text = text
        self.locale = locale
        self.segments = segments.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime { return lhs.endTime < rhs.endTime }
            return lhs.startTime < rhs.startTime
        }
    }

    public init(text: String, localeIdentifier: String?, segments: [TranscriptSegment] = []) {
        let identifier = localeIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "und"
        self.init(
            text: text,
            locale: Locale(identifier: identifier),
            segments: segments
        )
    }

    public var localeIdentifier: String { locale.identifier }

    // Locale has not conformed to Codable on every SDK supported by the old
    // project. Encode its stable identifier explicitly so history migrations
    // remain portable across SDK versions.
    private enum CodingKeys: String, CodingKey {
        case text
        case localeIdentifier
        case segments
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(locale.identifier, forKey: .localeIdentifier)
        try container.encode(segments, forKey: .segments)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        let identifier = try container.decodeIfPresent(String.self, forKey: .localeIdentifier)
        let segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        self.init(text: text, localeIdentifier: identifier, segments: segments)
    }
}

/// A progressive update emitted while an engine is working. Volatile updates
/// may replace an earlier range; only updates with `isFinal == true` should be
/// used for persistence, clipboard, or paste operations.
public struct TranscriptUpdate: Codable, Equatable, Sendable {
    public let text: String
    public let segments: [TranscriptSegment]
    public let isFinal: Bool
    public let progress: Double?
    public let localeIdentifier: String?

    public init(
        text: String,
        segments: [TranscriptSegment] = [],
        isFinal: Bool = false,
        progress: Double? = nil,
        locale: Locale? = nil
    ) {
        self.text = text
        self.segments = segments
        self.isFinal = isFinal
        self.progress = progress.map { min(max($0, 0), 1) }
        self.localeIdentifier = locale?.identifier
    }

    public init(
        text: String,
        segments: [TranscriptSegment] = [],
        isFinal: Bool = false,
        progress: Double? = nil,
        localeIdentifier: String?
    ) {
        self.text = text
        self.segments = segments
        self.isFinal = isFinal
        self.progress = progress.map { min(max($0, 0), 1) }
        self.localeIdentifier = localeIdentifier
    }

    public var locale: Locale? {
        guard let localeIdentifier, !localeIdentifier.isEmpty else { return nil }
        return Locale(identifier: localeIdentifier)
    }

    public var transcript: Transcript {
        Transcript(text: text, localeIdentifier: localeIdentifier, segments: segments)
    }
}

/// A provider-neutral stream of live updates. Concrete engines may add
/// provider-specific preparation and diagnostics, but clients only need these
/// operations to drive recording, shortcut bubbles, and final persistence.
public protocol LiveTranscriptionSession: AnyObject, Sendable {
    var updates: AsyncStream<TranscriptUpdate> { get }

    func append(buffer: AVAudioPCMBuffer) async throws
    func finalize() async throws -> Transcript
    func cancel() async
}

/// A provider-neutral transcription engine. A live session accepts copied audio
/// buffers; file transcription is used for dropped/imported recordings and
/// backends that intentionally upload only after capture stops.
public protocol TranscriptionEngine: Sendable {
    func prepare(locale: Locale) async throws
    func startSession(
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> any LiveTranscriptionSession
    func transcribeFile(
        at url: URL,
        locale: Locale,
        context: String?,
        expectedTerms: [String]
    ) async throws -> Transcript
}

/// Errors shared by capture and transcription implementations.
public enum CoreTranscriptionError: LocalizedError, Equatable, Sendable {
    case unavailable
    case unsupportedLocale(Locale)
    case assetsUnavailable(Locale)
    case preparationFailed(String)
    case audioFormatUnavailable
    case audioCaptureFailed(String)
    case analyzerFailed(String)
    case cancelled
    case invalidAudioFile(URL)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The transcription service is unavailable."
        case let .unsupportedLocale(locale):
            return "Speech transcription does not support \(locale.identifier)."
        case let .assetsUnavailable(locale):
            return "Speech language assets for \(locale.identifier) are not installed."
        case let .preparationFailed(message):
            return "Unable to prepare transcription: \(message)"
        case .audioFormatUnavailable:
            return "No compatible audio format is available for transcription."
        case let .audioCaptureFailed(message):
            return "Audio capture failed: \(message)"
        case let .analyzerFailed(message):
            return "Speech analysis failed: \(message)"
        case .cancelled:
            return "Transcription was cancelled."
        case let .invalidAudioFile(url):
            return "The audio file could not be opened: \(url.lastPathComponent)."
        }
    }
}

/// Reconciles SpeechAnalyzer's range-based volatile and final results. Apple
/// can revise text in a previously emitted range, so appending result strings
/// is incorrect. This value type replaces intersecting ranges and maintains a
/// stable chronological segment order instead.
public struct TranscriptAssembler: Sendable {
    private struct Entry: Sendable {
        var segment: TranscriptSegment
        var isFinal: Bool
        var sequence: Int
    }

    private var entries: [Entry] = []
    private var nextSequence = 0
    private var locale: Locale

    public init(locale: Locale = Locale(identifier: "und")) {
        self.locale = locale
    }

    public init(localeIdentifier: String) {
        self.init(locale: Locale(identifier: localeIdentifier.isEmpty ? "und" : localeIdentifier))
    }

    public var segments: [TranscriptSegment] {
        entries
            .sorted { lhs, rhs in
                if lhs.segment.startTime == rhs.segment.startTime {
                    if lhs.segment.endTime == rhs.segment.endTime { return lhs.sequence < rhs.sequence }
                    return lhs.segment.endTime < rhs.segment.endTime
                }
                return lhs.segment.startTime < rhs.segment.startTime
            }
            .map(\.segment)
    }

    public var text: String { Self.joinText(segments.map(\.text)) }

    public var transcript: Transcript { Transcript(text: text, locale: locale, segments: segments) }

    public mutating func reset(locale: Locale? = nil) {
        entries.removeAll(keepingCapacity: true)
        nextSequence = 0
        if let locale { self.locale = locale }
    }

    @discardableResult
    public mutating func ingest(
        text: String,
        range: CMTimeRange,
        isFinal: Bool,
        confidence: Double? = nil,
        locale: Locale? = nil
    ) -> TranscriptUpdate {
        if let locale { self.locale = locale }

        let start = max(0, range.start.seconds.isFinite ? range.start.seconds : 0)
        let duration = range.duration.seconds.isFinite ? max(0, range.duration.seconds) : 0
        let end = max(start, start + duration)
        let segment = TranscriptSegment(text: text, startTime: start, endTime: end, confidence: confidence)

        // A zero-length result is still useful (for example, an empty final
        // result), but must not erase every prior segment.
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.removeAll { existing in
                guard Self.rangesIntersect(existing.segment, segment) else { return false }
                // A volatile correction should not erase a finalized segment
                // merely because Apple's range has a small boundary overlap.
                // If it fully covers that segment, it is still a deliberate
                // replacement. Final results always win overlapping ranges.
                if isFinal || !existing.isFinal { return true }
                return Self.rangeContains(segment, existing.segment)
            }
            entries.append(Entry(segment: segment, isFinal: isFinal, sequence: nextSequence))
            nextSequence += 1
        }

        return TranscriptUpdate(
            text: self.text,
            segments: self.segments,
            isFinal: isFinal,
            progress: nil,
            locale: self.locale
        )
    }

    @discardableResult
    public mutating func ingest(
        segment: TranscriptSegment,
        isFinal: Bool,
        locale: Locale? = nil
    ) -> TranscriptUpdate {
        ingest(
            text: segment.text,
            range: segment.timeRange,
            isFinal: isFinal,
            confidence: segment.confidence,
            locale: locale
        )
    }

    /// Ingests a complete update when the provider has already assembled its
    /// own segments. Segment ranges are preferred; text-only updates replace
    /// the complete current result and remain useful for non-time-indexed APIs.
    @discardableResult
    public mutating func ingest(_ update: TranscriptUpdate) -> TranscriptUpdate {
        if let locale = update.locale { self.locale = locale }
        if !update.segments.isEmpty {
            for segment in update.segments {
                _ = ingest(segment: segment, isFinal: update.isFinal)
            }
        } else if !update.text.isEmpty {
            let end = entries.map { $0.segment.endTime }.max() ?? 0
            entries.removeAll()
            _ = ingest(
                text: update.text,
                range: CMTimeRange(start: .zero, duration: CMTime(seconds: max(end, 0), preferredTimescale: 1_000)),
                isFinal: update.isFinal,
                locale: self.locale
            )
        }
        return TranscriptUpdate(
            text: text,
            segments: segments,
            isFinal: update.isFinal,
            progress: update.progress,
            locale: self.locale
        )
    }

    private static func rangesIntersect(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        // Treat touching non-empty ranges as distinct words/segments. For a
        // zero-length range use containment so corrections still replace the
        // prior point instead of accumulating duplicates.
        if lhs.duration == 0 || rhs.duration == 0 {
            let point = lhs.duration == 0 ? lhs.startTime : rhs.startTime
            return point >= lhs.startTime && point <= lhs.endTime &&
                point >= rhs.startTime && point <= rhs.endTime
        }
        return lhs.startTime < rhs.endTime && rhs.startTime < lhs.endTime
    }

    private static func rangeContains(_ outer: TranscriptSegment, _ inner: TranscriptSegment) -> Bool {
        outer.startTime <= inner.startTime && outer.endTime >= inner.endTime
    }

    private static func joinText(_ pieces: [String]) -> String {
        var result = ""
        for piece in pieces {
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if result.isEmpty {
                result = text
            } else if Self.needsSpace(beforeAppending: text, to: result) {
                result += " " + text
            } else {
                result += text
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func needsSpace(beforeAppending text: String, to result: String) -> Bool {
        guard let first = text.first, let last = result.last else { return false }
        if first.isWhitespace || last.isWhitespace { return false }
        if ".,!?;:%)]}»”’\"".contains(first) { return false }
        if "([{«“‘".contains(last) { return false }
        return true
    }
}
