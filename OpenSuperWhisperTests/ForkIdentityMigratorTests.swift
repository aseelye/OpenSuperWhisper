import Foundation
import XCTest
@testable import OpenSuperWhisper

final class ForkIdentityMigratorTests: XCTestCase {
    func testCleanInstallCompletesWithoutTouchingStorage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let outcome = fixture.migrator().migrate()

        guard case .success(let report) = outcome else {
            return XCTFail("expected successful clean install, got \(outcome)")
        }
        XCTAssertFalse(report.storageMigrated)
        XCTAssertFalse(report.preferencesMigrated)
        XCTAssertFalse(report.retentionConfirmationRequired)
        XCTAssertEqual(
            (fixture.newDefaults.persistentDomain(forName: fixture.newDomainName)?[
                ForkIdentityMigrator.migrationVersionKey
            ] as? NSNumber)?.intValue,
            ForkIdentityMigrator.migrationVersion
        )
        XCTAssertNil(fixture.oldDefaults.persistentDomain(forName: fixture.oldDomainName))
    }

    func testLegacyOnlyStorageMovesAtomicallyAndMarksRetentionConfirmation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLegacyStorage(named: "recording.wav", contents: "legacy")
        fixture.oldDefaults.set("legacy value", forKey: "oldPreference")

        let outcome = fixture.migrator().migrate()

        guard case .success(let report) = outcome else {
            return XCTFail("expected successful storage migration, got \(outcome)")
        }
        XCTAssertTrue(report.storageMigrated)
        XCTAssertTrue(report.preferencesMigrated)
        XCTAssertTrue(report.retentionConfirmationRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyDirectory.path))
        XCTAssertEqual(
            try String(contentsOf: fixture.currentDirectory.appendingPathComponent("recording.wav")),
            "legacy"
        )
        XCTAssertEqual(
            fixture.newDefaults.persistentDomain(forName: fixture.newDomainName)?[
                ForkIdentityMigrator.recordingRetentionNeedsInitialConfirmationKey
            ] as? Bool,
            true
        )
        XCTAssertNil(fixture.oldDefaults.persistentDomain(forName: fixture.oldDomainName))
    }

    func testEmptyCurrentScaffoldIsRemovedBeforeLegacyStorageMove() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.currentDirectory,
            withIntermediateDirectories: true
        )
        try fixture.writeLegacyStorage(named: "recording.wav", contents: "legacy")

        let outcome = fixture.migrator().migrate()

        guard case .success = outcome else {
            return XCTFail("expected successful scaffold replacement, got \(outcome)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyDirectory.path))
        XCTAssertEqual(
            try String(contentsOf: fixture.currentDirectory.appendingPathComponent("recording.wav")),
            "legacy"
        )
    }

    func testEmptyLegacyScaffoldIsRemovedWhenCurrentStorageAlreadyHasData() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.legacyDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.currentDirectory,
            withIntermediateDirectories: true
        )
        try Data("new".utf8).write(to: fixture.currentDirectory.appendingPathComponent("new.wav"))

        let outcome = fixture.migrator().migrate()

        guard case .success = outcome else {
            return XCTFail("expected successful cleanup of empty legacy scaffold, got \(outcome)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.currentDirectory.appendingPathComponent("new.wav").path))
    }

    func testPopulatedStorageConflictLeavesBothDirectoriesUntouchedAndBlocksStartup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLegacyStorage(named: "legacy.wav", contents: "old")
        try FileManager.default.createDirectory(
            at: fixture.currentDirectory,
            withIntermediateDirectories: true
        )
        try Data("new".utf8).write(to: fixture.currentDirectory.appendingPathComponent("new.wav"))

        let outcome = fixture.migrator().migrate()

        guard case .conflict(let issue) = outcome else {
            return XCTFail("expected blocking conflict, got \(outcome)")
        }
        XCTAssertTrue(issue.isConflict)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacyDirectory.appendingPathComponent("legacy.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.currentDirectory.appendingPathComponent("new.wav").path))
        XCTAssertNil(fixture.newDefaults.persistentDomain(forName: fixture.newDomainName))
    }

    func testMoveFailureBlocksWithoutCreatingBlankCurrentStorage() throws {
        let fixture = try Fixture(fileManager: FailingMoveFileManager())
        defer { fixture.cleanup() }
        try fixture.writeLegacyStorage(named: "recording.wav", contents: "legacy")

        let outcome = fixture.migrator().migrate()

        guard case .failure(let issue) = outcome else {
            return XCTFail("expected blocking move failure, got \(outcome)")
        }
        XCTAssertFalse(issue.isConflict)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacyDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentDirectory.path))
        XCTAssertNil(fixture.newDefaults.persistentDomain(forName: fixture.newDomainName))
    }

    func testPreferencesCopyCompletelyWithoutOverwritingCurrentKeys() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.oldDefaults.set("from old", forKey: "shared")
        fixture.oldDefaults.set("copied", forKey: "onlyOld")
        fixture.oldDefaults.set(42, forKey: "number")
        fixture.newDefaults.set("from new", forKey: "shared")
        fixture.newDefaults.set("keep", forKey: "onlyNew")

        let outcome = fixture.migrator().migrate()

        guard case .success(let report) = outcome else {
            return XCTFail("expected successful preference migration, got \(outcome)")
        }
        XCTAssertTrue(report.preferencesMigrated)
        let domain = try XCTUnwrap(
            fixture.newDefaults.persistentDomain(forName: fixture.newDomainName)
        )
        XCTAssertEqual(domain["shared"] as? String, "from new")
        XCTAssertEqual(domain["onlyOld"] as? String, "copied")
        XCTAssertEqual(domain["number"] as? Int, 42)
        XCTAssertEqual(domain["onlyNew"] as? String, "keep")
        XCTAssertEqual(domain[ForkIdentityMigrator.recordingRetentionNeedsInitialConfirmationKey] as? Bool, true)
        XCTAssertNil(fixture.oldDefaults.persistentDomain(forName: fixture.oldDomainName))
    }

    func testMigrationIsIdempotentAfterCompletion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLegacyStorage(named: "recording.wav", contents: "legacy")

        guard case .success = fixture.migrator().migrate() else {
            return XCTFail("initial migration failed")
        }
        let second = fixture.migrator().migrate()

        guard case .success(let report) = second else {
            return XCTFail("expected idempotent success, got \(second)")
        }
        XCTAssertTrue(report.wasAlreadyComplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.currentDirectory.appendingPathComponent("recording.wav").path))
    }

    func testUITestLaunchSkipsProductionMigrationAndLeavesLegacyDataUntouched() throws {
        let fileManager = CountingFileManager()
        let fixture = try Fixture(fileManager: fileManager)
        defer { fixture.cleanup() }
        try fixture.writeLegacyStorage(named: "recording.wav", contents: "legacy")
        fixture.oldDefaults.set("old", forKey: "preference")

        let outcome = fixture.migrator(
            arguments: [ForkIdentityMigrator.uiTestLaunchArgument]
        ).migrate()

        guard case .skippedForUITest = outcome else {
            return XCTFail("expected UI-test skip, got \(outcome)")
        }
        XCTAssertEqual(fileManager.moveCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacyDirectory.path))
        XCTAssertNil(fixture.newDefaults.persistentDomain(forName: fixture.newDomainName))
    }

    private final class Fixture {
        let root: URL
        let oldDomainName = "ForkIdentityMigratorTests.old.\(UUID().uuidString)"
        let newDomainName = "ForkIdentityMigratorTests.new.\(UUID().uuidString)"
        let oldDefaults: UserDefaults
        let newDefaults: UserDefaults
        let fileManager: any ForkIdentityFileManaging

        init(fileManager: any ForkIdentityFileManaging = FileManager.default) throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ForkIdentityMigrator-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.oldDefaults = try XCTUnwrap(UserDefaults(suiteName: oldDomainName))
            self.newDefaults = try XCTUnwrap(UserDefaults(suiteName: newDomainName))
            self.fileManager = fileManager
            oldDefaults.removePersistentDomain(forName: oldDomainName)
            newDefaults.removePersistentDomain(forName: newDomainName)
        }

        var legacyDirectory: URL {
            root.appendingPathComponent(ForkIdentityMigrator.legacyBundleIdentifier, isDirectory: true)
        }

        var currentDirectory: URL {
            root.appendingPathComponent(ForkIdentityMigrator.currentBundleIdentifier, isDirectory: true)
        }

        func writeLegacyStorage(named name: String, contents: String) throws {
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: legacyDirectory.appendingPathComponent(name))
        }

        func migrator(
            arguments: [String] = [],
            environment: [String: String] = [:]
        ) -> ForkIdentityMigrator {
            ForkIdentityMigrator(
                fileManager: fileManager,
                applicationSupportDirectory: root,
                legacyUserDefaults: oldDefaults,
                currentUserDefaults: newDefaults,
                legacyDomainName: oldDomainName,
                currentDomainName: newDomainName,
                arguments: arguments,
                environment: environment
            )
        }

        func cleanup() {
            oldDefaults.removePersistentDomain(forName: oldDomainName)
            newDefaults.removePersistentDomain(forName: newDomainName)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class FailingMoveFileManager: ForkIdentityFileManaging {
    private let base = FileManager.default

    func fileExists(atPath path: String) -> Bool { base.fileExists(atPath: path) }

    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        try base.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }

    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw NSError(domain: "ForkIdentityMigratorTests", code: 1)
    }

    func removeItem(at URL: URL) throws { try base.removeItem(at: URL) }
}

private final class CountingFileManager: ForkIdentityFileManaging {
    private let base = FileManager.default
    private(set) var moveCount = 0

    func fileExists(atPath path: String) -> Bool { base.fileExists(atPath: path) }

    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        try base.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }

    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        try base.moveItem(at: srcURL, to: dstURL)
    }

    func removeItem(at URL: URL) throws { try base.removeItem(at: URL) }
}
