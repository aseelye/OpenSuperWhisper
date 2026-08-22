import Foundation
import GRDB
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class RecordingMigrationTests: XCTestCase {
    func testExistingRowsWithoutMetadataRemainReadableAfterSchemaMigration() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("legacy.sqlite")
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try await legacyQueue.write { db in
            try db.create(table: Recording.databaseTableName) { table in
                table.column("id", .text).primaryKey()
                table.column("timestamp", .datetime).notNull()
                table.column("fileName", .text).notNull()
                table.column("transcription", .text).notNull()
                table.column("duration", .double).notNull()
            }
            try db.execute(
                sql: "INSERT INTO recordings (id, timestamp, fileName, transcription, duration) VALUES (?, ?, ?, ?, ?)",
                arguments: [id.uuidString, timestamp, "legacy.wav", "old transcript", 3.25]
            )
        }

        let store = RecordingStore(databasePath: databaseURL, automaticallyLoad: false)
        await store.loadRecordings()

        let recording = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(recording.id, id)
        XCTAssertEqual(recording.timestamp, timestamp)
        XCTAssertEqual(recording.fileName, "legacy.wav")
        XCTAssertEqual(recording.transcription, "old transcript")
        XCTAssertEqual(recording.duration, 3.25, accuracy: 0.001)
        XCTAssertNil(recording.backend)
        XCTAssertNil(recording.locale)
        XCTAssertNil(recording.encodedTranscriptSegments)
        XCTAssertTrue(recording.transcriptSegments.isEmpty)

        let columns = try await legacyQueue.read { db in
            try db.columns(in: Recording.databaseTableName).map(\.name)
        }
        XCTAssertTrue(columns.contains("backend"))
        XCTAssertTrue(columns.contains("locale"))
        XCTAssertTrue(columns.contains("encodedTranscriptSegments"))
    }

    func testPartiallyMigratedRowsAlsoReceiveMissingNullableColumns() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("partial.sqlite")

        let queue = try DatabaseQueue(path: databaseURL.path)
        try await queue.write { db in
            try db.create(table: Recording.databaseTableName) { table in
                table.column("id", .text).primaryKey()
                table.column("timestamp", .datetime).notNull()
                table.column("fileName", .text).notNull()
                table.column("transcription", .text).notNull()
                table.column("duration", .double).notNull()
                table.column("backend", .text)
            }
        }

        let store = RecordingStore(databasePath: databaseURL, automaticallyLoad: false)
        await store.loadRecordings()

        let columns = try await queue.read { db in
            try db.columns(in: Recording.databaseTableName).map(\.name)
        }
        XCTAssertTrue(columns.contains("backend"))
        XCTAssertTrue(columns.contains("locale"))
        XCTAssertTrue(columns.contains("encodedTranscriptSegments"))
    }

    func testTranscriptSegmentEncodingRoundTripsAndMalformedPayloadIsIgnored() throws {
        let segments = [
            TranscriptSegment(text: "first", startTime: 0.25, endTime: 1.5, confidence: 0.86),
            TranscriptSegment(text: "second", startTime: 1.5, endTime: 2.75)
        ]
        let encoded = try XCTUnwrap(Recording.encodeTranscriptSegments(segments))
        let recording = Recording(
            id: UUID(),
            timestamp: Date(),
            fileName: "segments.wav",
            transcription: "first second",
            duration: 2.75,
            backend: TranscriptionBackend.appleSpeech.rawValue,
            locale: "en-US",
            encodedTranscriptSegments: encoded
        )

        XCTAssertEqual(recording.transcriptSegments, segments)
        XCTAssertEqual(recording.encodedTranscriptSegments, encoded)
        XCTAssertEqual(recording.backend, "appleSpeech")
        XCTAssertEqual(recording.locale, "en-US")
        XCTAssertNil(Recording.encodeTranscriptSegments([]))

        let malformed = Recording(
            id: UUID(),
            timestamp: Date(),
            fileName: "bad.wav",
            transcription: "still readable",
            duration: 1,
            encodedTranscriptSegments: Data("not json".utf8)
        )
        XCTAssertTrue(malformed.transcriptSegments.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisperRecording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
