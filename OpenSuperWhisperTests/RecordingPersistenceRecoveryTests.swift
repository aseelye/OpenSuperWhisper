import Foundation
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class RecordingPersistenceRecoveryTests: XCTestCase {
    func testStartupFailureIsRepresentedWithoutTerminating() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let databaseURL = blocker.appendingPathComponent("history.sqlite")

        let store = RecordingStore(
            databasePath: databaseURL,
            automaticallyLoad: false,
            recordingsDirectory: directory.appendingPathComponent("recordings"),
            recoveryDirectory: directory.appendingPathComponent("Recovery")
        )

        guard case .unavailable = store.status else {
            return XCTFail("A database setup error must be observable as unavailable")
        }
        let load = await store.loadRecordings()
        XCTAssertEqual(load.state, .unavailable)
        XCTAssertTrue(store.recordings.isEmpty)

        let outcome = await store.commitRecordingResult(
            makeRecording(fileName: "unavailable.wav")
        )
        guard case .failed = outcome else {
            return XCTFail("A failed setup must never return a durable commit receipt")
        }
    }

    func testDurableCommitReturnsReceiptAndPublishesRow() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let recording = makeRecording(fileName: "commit.wav", transcription: "durable transcript")
        try Data([1, 2, 3]).write(to: store.url(for: recording))

        let receipt = try await store.commitRecording(recording)

        XCTAssertEqual(receipt.recordingID, recording.id)
        XCTAssertEqual(receipt.databasePath, fixture.databaseURL.path)
        XCTAssertEqual(store.recordings, [recording])
        XCTAssertEqual(store.status, .available)
    }

    func testDeletionDatabaseFailureRestoresQuarantinedAudio() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore(databaseFailureInjector: { operation in
            operation == .delete
                ? .databaseDeleteFailed("injected deletion failure")
                : nil
        })
        let recording = makeRecording(fileName: "delete.wav")
        let fileURL = store.url(for: recording)
        try Data([7, 8, 9]).write(to: fileURL)
        _ = try await store.commitRecording(recording)

        let result = await store.deleteRecordingAndAwait(recording)

        XCTAssertEqual(result.state, .databaseFailedFileRestored)
        XCTAssertFalse(result.rowRemoved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(store.recordings, [recording])
    }

    func testDeletionCleanupFailureIsTypedAndLeavesRepairItem() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileSystem = FailingRecordingFileSystem(failRemovePaths: [])
        let store = fixture.makeStore(fileSystem: fileSystem)
        let recording = makeRecording(fileName: "cleanup.wav")
        let fileURL = store.url(for: recording)
        try Data([4, 5, 6]).write(to: fileURL)
        _ = try await store.commitRecording(recording)
        fileSystem.failRemovePaths.insert(fixture.quarantineDirectory.path)

        let result = await store.deleteRecordingAndAwait(recording)

        XCTAssertEqual(result.state, .deletedWithCleanupPending)
        XCTAssertTrue(result.rowRemoved)
        XCTAssertTrue(result.requiresRepair)
        XCTAssertNotNil(result.quarantineURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testBulkDeletionReconcilesOnlyOnceAfterRemovingAllRows() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileSystem = FailingRecordingFileSystem(failRemovePaths: [])
        let store = fixture.makeStore(fileSystem: fileSystem)

        for index in 0..<3 {
            let recording = makeRecording(fileName: "bulk-\(index).wav")
            try Data([UInt8(index)]).write(to: store.url(for: recording))
            _ = try await store.commitRecording(recording)
        }
        fileSystem.contentsOfDirectoryCallCount = 0

        let result = await store.deleteAllRecordingsAndAwait()

        XCTAssertNil(result.error)
        XCTAssertEqual(result.results.count, 3)
        XCTAssertTrue(result.results.allSatisfy(\.succeeded))
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertEqual(fileSystem.contentsOfDirectoryCallCount, 4)
    }

    func testReconciliationQuarantinesOrphansAndIsIdempotent() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        try FileManager.default.createDirectory(at: fixture.recordingsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.temporaryDirectory, withIntermediateDirectories: true)
        let orphan = fixture.recordingsDirectory.appendingPathComponent(
            "1700000000000-\(UUID().uuidString).wav"
        )
        let temporary = fixture.temporaryDirectory.appendingPathComponent(
            "recording-\(UUID().uuidString).wav"
        )
        let unknownAudio = fixture.recordingsDirectory.appendingPathComponent("manual.wav")
        let untouched = fixture.recordingsDirectory.appendingPathComponent("notes.txt")
        try Data([1]).write(to: orphan)
        try Data([2]).write(to: temporary)
        try Data([4]).write(to: unknownAudio)
        try Data([3]).write(to: untouched)

        let first = await store.reconcile()
        let second = await store.reconcile()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.orphanedAudio.count, 1)
        XCTAssertEqual(first.temporaryCaptures.count, 1)
        XCTAssertTrue(first.recoveredArtifacts.allSatisfy { artifact in
            guard let recoveryURL = artifact.recoveryURL else { return false }
            return FileManager.default.fileExists(atPath: recoveryURL.path)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path))
    }

    func testActiveTemporaryCaptureIsNotReconciledUntilOwnershipIsReleased() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let captureURL = fixture.temporaryDirectory.appendingPathComponent(
            "recording-\(UUID().uuidString).wav"
        )
        try Data([21, 22]).write(to: captureURL)

        let lease = RecordingCaptureOwnershipRegistry.shared.acquire(captureURL)
        let activeReport = await store.reconcile()

        XCTAssertTrue(activeReport.temporaryCaptures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureURL.path))

        lease.release()
        let releasedReport = await store.reconcile()

        XCTAssertEqual(releasedReport.temporaryCaptures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureURL.path))
    }

    func testMissingAudioPreservesRowAndReportsUnavailableState() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let recording = makeRecording(fileName: "missing.wav", transcription: "keep this text")
        _ = try await store.commitRecording(recording)

        let load = await store.loadRecordings()

        XCTAssertEqual(load.recordings, [recording])
        XCTAssertEqual(store.missingRecordings, [recording])
        guard case .missing(let missingURL) = store.availability(for: recording) else {
            return XCTFail("A row whose file is absent must remain explicitly unavailable")
        }
        XCTAssertEqual(missingURL, store.url(for: recording))
        XCTAssertEqual(recording.transcription, "keep this text")
    }

    func testRecoveryPreservesTranscriptWhenDatabaseUnavailable() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let blocker = fixture.directory.appendingPathComponent("database-blocker")
        try Data("blocker".utf8).write(to: blocker)
        let store = RecordingStore(
            databasePath: blocker.appendingPathComponent("history.sqlite"),
            automaticallyLoad: false,
            recordingsDirectory: fixture.recordingsDirectory,
            recoveryDirectory: fixture.recoveryDirectory,
            temporaryCaptureDirectory: fixture.temporaryDirectory,
            quarantineDirectory: fixture.quarantineDirectory
        )
        let source = fixture.directory.appendingPathComponent("captured.wav")
        try Data([11, 12]).write(to: source)
        let recording = makeRecording(fileName: "captured.wav", transcription: "recover me")

        let receipt = try await store.preserveAudioForRecovery(
            from: source,
            recording: recording,
            disposition: .move
        )

        XCTAssertEqual(store.status, .unavailable(store.status.diagnosticMessage ?? ""))
        XCTAssertNotNil(receipt.audioURL)
        XCTAssertNotNil(receipt.transcriptURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let transcript = try String(contentsOf: try XCTUnwrap(receipt.transcriptURL), encoding: .utf8)
        XCTAssertEqual(transcript, recording.transcription)
    }

    func testRecoveryArtifactDeletionRemovesAudioAndSidecars() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let source = fixture.directory.appendingPathComponent("recovery-source.wav")
        try Data([31, 32]).write(to: source)
        let recording = makeRecording(fileName: "recovery-source.wav", transcription: "keep transcript")

        let receipt = try await store.preserveAudioForRecovery(
            from: source,
            recording: recording,
            disposition: .move
        )
        let artifact = try XCTUnwrap(store.recoveryItems.first)
        let result = await store.deleteRecoveryArtifactAndAwait(artifact)

        XCTAssertEqual(result.state, .deleted)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(store.recoveryItems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(receipt.audioURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(receipt.transcriptURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(receipt.metadataURL).path))
    }

    func testRecoveryArtifactDeletionFailureKeepsInventoryForRetry() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileSystem = FailingRecordingFileSystem(failRemovePaths: [])
        let store = fixture.makeStore(fileSystem: fileSystem)
        let source = fixture.directory.appendingPathComponent("recovery-failure.wav")
        try Data([41]).write(to: source)
        let recording = makeRecording(fileName: "recovery-failure.wav")

        let receipt = try await store.preserveAudioForRecovery(
            from: source,
            recording: recording,
            disposition: .move
        )
        let artifact = try XCTUnwrap(store.recoveryItems.first)
        let audioURL = try XCTUnwrap(receipt.audioURL)
        fileSystem.failRemovePaths.insert(audioURL.path)

        let result = await store.deleteRecoveryArtifactAndAwait(artifact)

        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.requiresRepair)
        XCTAssertEqual(store.recoveryItems.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testBulkRecoveryDeletionRemovesAllReviewedArtifacts() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        var recoveredAudioURLs: [URL] = []

        for index in 0..<3 {
            let source = fixture.directory.appendingPathComponent("bulk-recovery-\(index).wav")
            try Data([UInt8(index)]).write(to: source)
            let recording = makeRecording(fileName: source.lastPathComponent)
            let receipt = try await store.preserveAudioForRecovery(
                from: source,
                recording: recording,
                disposition: .move
            )
            recoveredAudioURLs.append(try XCTUnwrap(receipt.audioURL))
        }

        let results = await store.deleteAllRecoveryArtifactsAndAwait()

        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy(\.succeeded))
        XCTAssertTrue(store.recoveryItems.isEmpty)
        XCTAssertTrue(recoveredAudioURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
    }

    func testRecoveryArtifactDeletionRejectsOutOfTreeTargets() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let outside = fixture.directory.appendingPathComponent("outside.wav")
        try Data([51]).write(to: outside)
        let artifact = RecordingRecoveryArtifact(
            kind: .orphanAudio,
            originalURL: outside,
            recoveryURL: outside
        )

        let result = await store.deleteRecoveryArtifactAndAwait(artifact)

        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testMissingAudioRepairCopiesSourceAndRetainsIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let recording = makeRecording(fileName: "repair.wav", transcription: "repair me")
        _ = try await store.commitRecording(recording)
        let source = fixture.directory.appendingPathComponent("selected.wav")
        try Data([61, 62, 63]).write(to: source)

        let result = await store.restoreMissingAudio(for: recording, from: source)

        XCTAssertEqual(result.state, .restored)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try Data(contentsOf: store.url(for: recording)),
            Data([61, 62, 63])
        )
        XCTAssertTrue(store.availability(for: recording).isPlayable)
        XCTAssertTrue(store.missingRecordings.isEmpty)
    }

    func testMissingAudioRepairRejectsDifferentExtensionAndDoesNotCopy() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let recording = makeRecording(fileName: "repair.wav")
        _ = try await store.commitRecording(recording)
        let source = fixture.directory.appendingPathComponent("selected.m4a")
        try Data([71]).write(to: source)

        let result = await store.restoreMissingAudio(for: recording, from: source)

        XCTAssertEqual(result.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: recording).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMissingAudioRepairNeverOverwritesDestination() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let recording = makeRecording(fileName: "repair.wav")
        _ = try await store.commitRecording(recording)
        let source = fixture.directory.appendingPathComponent("selected.wav")
        try Data([81]).write(to: source)
        let destination = store.url(for: recording)
        try Data([82]).write(to: destination)

        let result = await store.restoreMissingAudio(for: recording, from: source)

        XCTAssertEqual(result.state, .alreadyPresent)
        XCTAssertEqual(try Data(contentsOf: destination), Data([82]))
        XCTAssertEqual(try Data(contentsOf: source), Data([81]))
    }

    private func makeRecording(
        fileName: String,
        transcription: String = "transcript"
    ) -> Recording {
        Recording(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            fileName: fileName,
            transcription: transcription,
            duration: 1
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisperPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private struct Fixture {
        let directory: URL
        let databaseURL: URL
        let recordingsDirectory: URL
        let recoveryDirectory: URL
        let temporaryDirectory: URL
        let quarantineDirectory: URL

        @MainActor
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

    private func makeFixture() throws -> Fixture {
        let directory = try makeTemporaryDirectory()
        let fixture = Fixture(
            directory: directory,
            databaseURL: directory.appendingPathComponent("history.sqlite"),
            recordingsDirectory: directory.appendingPathComponent("recordings", isDirectory: true),
            recoveryDirectory: directory.appendingPathComponent("Recovery", isDirectory: true),
            temporaryDirectory: directory.appendingPathComponent("temporary", isDirectory: true),
            quarantineDirectory: directory.appendingPathComponent("quarantine", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: fixture.recordingsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.recoveryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.quarantineDirectory, withIntermediateDirectories: true)
        return fixture
    }
}

private final class FailingRecordingFileSystem: RecordingFileSystem {
    private let local = LocalRecordingFileSystem()
    var failRemovePaths: Set<String>
    var contentsOfDirectoryCallCount = 0

    init(failRemovePaths: Set<String>) {
        self.failRemovePaths = failRemovePaths
    }

    func fileExists(at url: URL) -> Bool { local.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { local.isDirectory(at: url) }
    func createDirectory(at url: URL) throws { try local.createDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] {
        contentsOfDirectoryCallCount += 1
        return try local.contentsOfDirectory(at: url)
    }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try local.copyItem(at: sourceURL, to: destinationURL)
    }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try local.moveItem(at: sourceURL, to: destinationURL)
    }
    func removeItem(at url: URL) throws {
        if failRemovePaths.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) {
            throw NSError(domain: "RecordingPersistenceRecoveryTests", code: 1)
        }
        try local.removeItem(at: url)
    }
    func write(_ data: Data, to url: URL) throws { try local.write(data, to: url) }
}
