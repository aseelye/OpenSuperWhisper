import CoreMedia
import XCTest
@testable import OpenSuperWhisper

final class TranscriptCoreTests: XCTestCase {
    private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1_000),
            duration: CMTime(seconds: duration, preferredTimescale: 1_000)
        )
    }

    func testVolatileCorrectionReplacesEarlierRangeWithoutDuplication() {
        var assembler = TranscriptAssembler(locale: Locale(identifier: "en-US"))

        _ = assembler.ingest(text: "hello", range: range(0, 1), isFinal: false)
        XCTAssertEqual(assembler.text, "hello")

        _ = assembler.ingest(text: "hello wurld", range: range(0, 2), isFinal: false)
        XCTAssertEqual(assembler.text, "hello wurld")
        XCTAssertEqual(assembler.segments.count, 1)

        _ = assembler.ingest(text: "hello world", range: range(0, 2), isFinal: true)
        XCTAssertEqual(assembler.text, "hello world")
        XCTAssertEqual(assembler.segments.count, 1)
        XCTAssertTrue(assembler.ingest(text: "", range: range(0, 2), isFinal: true).isFinal)
    }

    func testFinalReplacementPreservesAdjacentSegmentsAndMetadata() {
        var assembler = TranscriptAssembler(locale: Locale(identifier: "en-US"))

        _ = assembler.ingest(
            text: "one",
            range: range(0, 1),
            isFinal: true,
            confidence: 0.82
        )
        _ = assembler.ingest(
            text: "two",
            range: range(1, 1),
            isFinal: true,
            confidence: 0.91
        )
        _ = assembler.ingest(
            text: "won",
            range: range(0, 1),
            isFinal: true,
            confidence: 0.97
        )

        XCTAssertEqual(assembler.text, "won two")
        XCTAssertEqual(assembler.segments.count, 2)
        XCTAssertEqual(assembler.segments[0].text, "won")
        XCTAssertEqual(assembler.segments[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(assembler.segments[0].endTime, 1, accuracy: 0.001)
        XCTAssertEqual(assembler.segments[0].confidence ?? -1, 0.97, accuracy: 0.001)
        XCTAssertEqual(assembler.segments[1].text, "two")
    }

    func testSegmentsAreOrderedByAudioRangeAndPunctuationIsNotSpaced() {
        var assembler = TranscriptAssembler(locale: Locale(identifier: "en-US"))

        _ = assembler.ingest(text: "world!", range: range(1, 1), isFinal: true)
        _ = assembler.ingest(text: "Hello", range: range(0, 1), isFinal: true)

        XCTAssertEqual(assembler.text, "Hello world!")
        XCTAssertEqual(assembler.transcript.localeIdentifier, "en-US")
    }

    func testTranscriptAndSegmentsRoundTripThroughCodable() throws {
        var assembler = TranscriptAssembler(localeIdentifier: "en-US")
        _ = assembler.ingest(
            text: "record this",
            range: range(0, 1.5),
            isFinal: true,
            confidence: 0.88
        )

        let encoded = try JSONEncoder().encode(assembler.transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: encoded)

        XCTAssertEqual(decoded, assembler.transcript)
        XCTAssertEqual(decoded.segments.first?.confidence ?? -1, 0.88, accuracy: 0.001)
    }
}
