import Foundation
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class RecordingRetentionStoreTests: XCTestCase {
    func testPolicyNormalizationAndDefault() {
        XCTAssertEqual(RecordingRetentionPolicy(), .days(7))
        XCTAssertEqual(RecordingRetentionPolicy(days: 0), .days(1))
        XCTAssertEqual(RecordingRetentionPolicy(days: 9_999), .days(3650))
        XCTAssertEqual(RecordingRetentionPolicy.days(0).normalized, .days(1))
        XCTAssertEqual(RecordingRetentionPolicy.days(9_999).normalized, .days(3650))
        XCTAssertEqual(RecordingRetentionPolicy.forever.normalized, .forever)
    }

    func testPreviewUsesStrictCutoffAndManagedBytesOnly() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = makeRecording(
            fileName: "old.wav",
            timestamp: now.addingTimeInterval(-8 * 86_400)
        )
        let boundary = makeRecording(
            fileName: "boundary.wav",
            timestamp: now.addingTimeInterval(-7 * 86_400)
        )
        let recent = makeRecording(
            fileName: "recent.wav",
            timestamp: now.addingTimeInterval(-2 * 86_400)
        )
        try Data([1, 2, 3]).write(to: store.url(for: old))
        try Data([4, 5]).write(to: store.url(for: boundary))
        _ = try await store.commitRecording(old)
        _ = try await store.commitRecording(boundary)
        _ = try await store.commitRecording(recent)

        let preview = await store.previewRetention(policy: .days(7), now: now)

        XCTAssertEqual(preview.cutoff, now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(preview.eligibleEntryCount, 1)
        XCTAssertEqual(preview.totalManagedAudioBytes, 3)
        XCTAssertEqual(preview.policy, .days(7))
        let forever = await store.previewRetention(policy: .forever, now: now)
        XCTAssertEqual(forever.eligibleEntryCount, 0)
        XCTAssertEqual(forever.totalManagedAudioBytes, 0)
    }

    func testOneDayBoundaryIsAlsoStrictlyOlder() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let boundary = makeRecording(
            fileName: "boundary.wav",
            timestamp: now.addingTimeInterval(-86_400)
        )
        let old = makeRecording(
            fileName: "old.wav",
            timestamp: now.addingTimeInterval(-86_400 - 0.001)
        )
        try Data([1]).write(to: store.url(for: old))
        _ = try await store.commitRecording(boundary)
        _ = try await store.commitRecording(old)

        let preview = await store.previewRetention(policy: .days(1), now: now)

        XCTAssertEqual(preview.eligibleEntryCount, 1)
        XCTAssertEqual(preview.totalManagedAudioBytes, 1)
    }

    func testMissingAudioCountsAsZeroAndApplyLeavesUnrelatedFilesUntouched() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = makeRecording(
            fileName: "old.wav",
            timestamp: now.addingTimeInterval(-8 * 86_400)
        )
        let missing = makeRecording(
            fileName: "missing.wav",
            timestamp: now.addingTimeInterval(-8 * 86_400)
        )
        let recent = makeRecording(fileName: "recent.wav", timestamp: now)
        try Data([1, 2, 3, 4]).write(to: store.url(for: old))
        _ = try await store.commitRecording(old)
        _ = try await store.commitRecording(missing)
        try Data([5]).write(to: store.url(for: recent))
        _ = try await store.commitRecording(recent)

        let orphan = fixture.recordingsDirectory.appendingPathComponent(
            "1700000000000-\(UUID().uuidString).wav"
        )
        let temporary = fixture.temporaryDirectory.appendingPathComponent(
            "recording-\(UUID().uuidString).wav"
        )
        let unknown = fixture.recordingsDirectory.appendingPathComponent("manual.wav")
        let recovery = fixture.recoveryDirectory.appendingPathComponent("reviewed.wav")
        try Data([7]).write(to: orphan)
        try Data([8]).write(to: temporary)
        try Data([9]).write(to: unknown)
        try Data([10]).write(to: recovery)

        let preview = await store.previewRetention(policy: .days(7), now: now)
        XCTAssertEqual(preview.eligibleEntryCount, 2)
        XCTAssertEqual(preview.totalManagedAudioBytes, 4)

        let result = await store.applyRetention(policy: .days(7), now: now)

        XCTAssertEqual(result.deletionResults.count, 2)
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: old).path))
        XCTAssertFalse(store.recordings.contains(old))
        // Retention removes the history row even when its managed audio is
        // already missing; the row and WAV are one deletion unit.
        XCTAssertFalse(store.recordings.contains(missing))
        XCTAssertTrue(store.recordings.contains(recent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testDatabaseFailureRestoresAudioAndContinuesBatch() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore(databaseFailureInjector: { operation in
            operation == .delete ? .databaseDeleteFailed("retention delete failed") : nil
        })
        let now = Date(timeIntervalSince1970: 2_000_000)
        let recording = makeRecording(
            fileName: "old.wav",
            timestamp: now.addingTimeInterval(-8 * 86_400)
        )
        let fileURL = store.url(for: recording)
        try Data([1, 2, 3]).write(to: fileURL)
        _ = try await store.commitRecording(recording)

        let result = await store.applyRetention(policy: .days(7), now: now)

        XCTAssertEqual(result.deletionResults.count, 1)
        XCTAssertEqual(result.deletionResults[0].state, .databaseFailedFileRestored)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(store.recordings.contains(recording))
    }

    func testFileQuarantineFailureLeavesRowAndContinuesBatch() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let first = makeRecording(
            fileName: "first.wav",
            timestamp: now.addingTimeInterval(-8 * 86_400)
        )
        let second = makeRecording(
            fileName: "second.wav",
            timestamp: now.addingTimeInterval(-8 * 86_400)
        )
        let failingFileSystem = RetentionFailingFileSystem(failingMoveSources: [])
        let store = fixture.makeStore(fileSystem: failingFileSystem)
        try Data([1]).write(to: store.url(for: first))
        try Data([2]).write(to: store.url(for: second))
        _ = try await store.commitRecording(first)
        _ = try await store.commitRecording(second)
        failingFileSystem.failingMoveSources.insert(store.url(for: first).path)

        let result = await store.applyRetention(policy: .days(7), now: now)

        XCTAssertEqual(result.deletionResults.count, 2)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.deletionResults.contains { $0.recordingID == first.id && !$0.succeeded })
        XCTAssertTrue(result.deletionResults.contains { $0.recordingID == second.id && $0.succeeded })
        XCTAssertTrue(store.recordings.contains(first))
        XCTAssertFalse(store.recordings.contains(second))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: second).path))
    }

    func testConcurrentRetentionRunsDeleteEachRowAtMostOnce() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let recording = makeRecording(
            fileName: "old.wav",
            timestamp: now.addingTimeInterval(-8 * 86_400)
        )
        try Data([1]).write(to: store.url(for: recording))
        _ = try await store.commitRecording(recording)

        async let first = store.applyRetention(policy: .days(7), now: now)
        async let second = store.applyRetention(policy: .days(7), now: now)
        let firstResult = await first
        let secondResult = await second
        let results = [firstResult, secondResult]

        XCTAssertEqual(results.flatMap(\.deletionResults).filter(\.rowRemoved).count, 1)
        XCTAssertEqual(results.map(\.preview.eligibleEntryCount).reduce(0, +), 1)
        XCTAssertFalse(store.recordings.contains(recording))
    }

    func testPendingArtifactCleanupRequiresAuthoritativeRowAbsence() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let absentID = UUID()
        let absentURL = fixture.quarantineDirectory.appendingPathComponent(
            "pending-\(absentID.uuidString)-absent.wav"
        )
        try Data([1]).write(to: absentURL)

        let absentReport = await store.reconcile()
        XCTAssertTrue(absentReport.recoveredArtifacts.filter {
            $0.kind == .pendingDeletion
        }.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentURL.path))

        let row = makeRecording(fileName: "kept.wav")
        _ = try await store.commitRecording(row)
        let existingURL = fixture.quarantineDirectory.appendingPathComponent(
            "pending-\(row.id.uuidString)-kept.wav"
        )
        try Data([2]).write(to: existingURL)
        let existingReport = await store.reconcile()
        let pendingArtifacts = existingReport.recoveredArtifacts.filter {
            $0.kind == .pendingDeletion
        }
        XCTAssertEqual(pendingArtifacts.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: existingURL.path))
        XCTAssertTrue(pendingArtifacts[0].recoveryURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false)

        let unknownFixture = try RetentionFixture()
        defer { unknownFixture.remove() }
        let unknownStore = unknownFixture.makeStore(databaseFailureInjector: { operation in
            operation == .read ? .databaseReadFailed("read unavailable") : nil
        })
        let unknownURL = unknownFixture.quarantineDirectory.appendingPathComponent(
            "pending-\(UUID().uuidString)-unknown.wav"
        )
        try Data([3]).write(to: unknownURL)
        let unknownReport = await unknownStore.reconcile()
        XCTAssertEqual(unknownReport.recoveredArtifacts.filter {
            $0.kind == .pendingDeletion
        }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unknownURL.path))
    }

    private func makeRecording(
        fileName: String,
        timestamp: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> Recording {
        Recording(
            id: UUID(),
            timestamp: timestamp,
            fileName: fileName,
            transcription: fileName,
            duration: 1
        )
    }
}

@MainActor
private final class RetentionFixture {
    let directory: URL
    let databaseURL: URL
    let recordingsDirectory: URL
    let recoveryDirectory: URL
    let temporaryDirectory: URL
    let quarantineDirectory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisperRetention-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directory.appendingPathComponent("history.sqlite")
        recordingsDirectory = directory.appendingPathComponent("recordings", isDirectory: true)
        recoveryDirectory = directory.appendingPathComponent("Recovery", isDirectory: true)
        temporaryDirectory = directory.appendingPathComponent("temporary", isDirectory: true)
        quarantineDirectory = directory.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
    }

    func makeStore(
        fileSystem: RecordingFileSystem = LocalRecordingFileSystem(),
        databaseFailureInjector: ((RecordingDatabaseOperation) -> RecordingStoreError?)? = nil
    ) -> RecordingStore {
        RecordingStore(
            databasePath: databaseURL,
            automaticallyLoad: false,
            recordingsDirectory: recordingsDirectory,
            recoveryDirectory: recoveryDirectory,
            temporaryCaptureDirectory: temporaryDirectory,
            quarantineDirectory: quarantineDirectory,
            fileSystem: fileSystem,
            databaseFailureInjector: databaseFailureInjector
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class RetentionFailingFileSystem: RecordingFileSystem {
    private let local = LocalRecordingFileSystem()
    var failingMoveSources: Set<String>

    init(failingMoveSources: Set<String>) {
        self.failingMoveSources = failingMoveSources
    }

    func fileExists(at url: URL) -> Bool { local.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { local.isDirectory(at: url) }
    func fileSize(at url: URL) -> Int64? { local.fileSize(at: url) }
    func createDirectory(at url: URL) throws { try local.createDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try local.contentsOfDirectory(at: url)
    }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try local.copyItem(at: sourceURL, to: destinationURL)
    }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if failingMoveSources.contains(sourceURL.path) {
            throw NSError(
                domain: "RecordingRetentionStoreTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Injected move failure"]
            )
        }
        try local.moveItem(at: sourceURL, to: destinationURL)
    }
    func removeItem(at url: URL) throws { try local.removeItem(at: url) }
    func write(_ data: Data, to url: URL) throws { try local.write(data, to: url) }
}
