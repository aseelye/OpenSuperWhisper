import Foundation
import XCTest
@testable import OpenSuperWhisper

final class AppPreferencesMigrationTests: XCTestCase {
    func testLegacyLocalBackendAndLanguageAreMigratedWithoutDeletingUnrelatedDefaults() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let root = try makeTemporaryDirectory()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let legacyDirectory = root.appendingPathComponent("whisper-models", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("old model".utf8).write(to: legacyDirectory.appendingPathComponent("model.bin"))
        let sibling = root.appendingPathComponent("whisper-models.keep", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        defaults.set("local", forKey: "transcriptionBackend")
        defaults.set("zh_TW", forKey: "whisperLanguage")
        defaults.set("meeting vocabulary", forKey: "initialPrompt")
        defaults.set(true, forKey: "showTimestamps")
        defaults.set("keep me", forKey: "unrelatedPreference")

        XCTAssertTrue(AppPreferences.migrateLegacyPreferencesIfNeeded(
            defaults: defaults,
            legacyDirectory: legacyDirectory
        ))

        XCTAssertEqual(defaults.string(forKey: "transcriptionBackend"), TranscriptionBackend.appleSpeech.rawValue)
        XCTAssertEqual(
            defaults.string(forKey: "localeIdentifier"),
            LanguageUtil.localeIdentifier(forLegacyWhisperLanguage: "zh_TW")
        )
        XCTAssertEqual(defaults.string(forKey: "recognitionContext"), "meeting vocabulary")
        XCTAssertEqual(defaults.bool(forKey: "showTimingDetailsInHistory"), true)
        XCTAssertEqual(defaults.string(forKey: "unrelatedPreference"), "keep me")

        for key in [
            "whisperLanguage", "initialPrompt", "showTimestamps", "selectedModelPath",
            "translateToEnglish", "temperature", "useAsianAutocorrect"
        ] {
            XCTAssertNil(defaults.object(forKey: key), "obsolete key should be removed: \(key)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testExistingOpenAIBackendIsPreserved() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let root = try makeTemporaryDirectory()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        defaults.set("openAI", forKey: "transcriptionBackend")
        XCTAssertTrue(AppPreferences.migrateLegacyPreferencesIfNeeded(
            defaults: defaults,
            legacyDirectory: root.appendingPathComponent("missing-whisper-models")
        ))

        XCTAssertEqual(defaults.string(forKey: "transcriptionBackend"), TranscriptionBackend.openAI.rawValue)
    }

    func testMigrationCompletionMakesLegacyCleanupIdempotentAndExact() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let root = try makeTemporaryDirectory()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let exactDirectory = root.appendingPathComponent("whisper-models", isDirectory: true)
        let similarlyNamedDirectory = root.appendingPathComponent("whisper-models.backup", isDirectory: true)
        try FileManager.default.createDirectory(at: exactDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: similarlyNamedDirectory, withIntermediateDirectories: true)

        XCTAssertTrue(AppPreferences.migrateLegacyPreferencesIfNeeded(
            defaults: defaults,
            legacyDirectory: exactDirectory
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exactDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: similarlyNamedDirectory.path))

        // Reintroducing a directory after the migration must not make a later
        // startup remove it: completion is the idempotence guard.
        try FileManager.default.createDirectory(at: exactDirectory, withIntermediateDirectories: true)
        try Data("do not remove".utf8).write(to: exactDirectory.appendingPathComponent("sentinel"))

        XCTAssertFalse(AppPreferences.migrateLegacyPreferencesIfNeeded(
            defaults: defaults,
            legacyDirectory: exactDirectory
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exactDirectory.appendingPathComponent("sentinel").path))
        XCTAssertEqual(defaults.bool(forKey: "appleSpeechPreferencesMigrationCompleted"), true)
    }

    func testFailedLegacyCleanupIsRetriedBeforeMigrationCompletion() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let root = try makeTemporaryDirectory()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let legacyDirectory = root.appendingPathComponent("whisper-models", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("old model".utf8).write(to: legacyDirectory.appendingPathComponent("model.bin"))

        let fileOperations = ToggleableFileOperations()
        XCTAssertTrue(AppPreferences.migrateLegacyPreferencesIfNeeded(
            defaults: defaults,
            fileManager: fileOperations,
            legacyDirectory: legacyDirectory
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDirectory.path))
        XCTAssertFalse(defaults.bool(forKey: "appleSpeechPreferencesMigrationCompleted"))

        fileOperations.shouldFailRemoval = false
        XCTAssertTrue(AppPreferences.migrateLegacyPreferencesIfNeeded(
            defaults: defaults,
            fileManager: fileOperations,
            legacyDirectory: legacyDirectory
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDirectory.path))
        XCTAssertTrue(defaults.bool(forKey: "appleSpeechPreferencesMigrationCompleted"))
    }

    func testLegacyLocaleFallbackHandlesAutoAndUnknownValues() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let root = try makeTemporaryDirectory()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        defaults.set("auto", forKey: "whisperLanguage")
        XCTAssertTrue(AppPreferences.migrateLegacyPreferencesIfNeeded(
            defaults: defaults,
            legacyDirectory: root.appendingPathComponent("missing-whisper-models")
        ))
        XCTAssertEqual(
            defaults.string(forKey: "localeIdentifier"),
            LanguageUtil.defaultLocaleIdentifier
        )

        // The migration completion marker is intentionally isolated per run;
        // exercise the unknown-language fallback with a fresh defaults suite.
        let (unknownDefaults, unknownSuiteName) = try makeIsolatedDefaults()
        defer { unknownDefaults.removePersistentDomain(forName: unknownSuiteName) }
        unknownDefaults.set("xx", forKey: "whisperLanguage")
        XCTAssertTrue(AppPreferences.migrateLegacyPreferencesIfNeeded(
            defaults: unknownDefaults,
            legacyDirectory: root.appendingPathComponent("missing-whisper-models-2")
        ))
        XCTAssertEqual(
            unknownDefaults.string(forKey: "localeIdentifier"),
            LanguageUtil.defaultLocaleIdentifier
        )
    }

    private func makeIsolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "OpenSuperWhisperTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "OpenSuperWhisperTests", code: 1)
        }
        return (defaults, suiteName)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisperMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class ToggleableFileOperations: AppPreferencesFileOperations {
    var shouldFailRemoval = true

    private let fileManager = FileManager.default

    func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    func removeItem(at URL: URL) throws {
        if shouldFailRemoval {
            throw NSError(domain: "OpenSuperWhisperTests", code: 2)
        }
        try fileManager.removeItem(at: URL)
    }
}
