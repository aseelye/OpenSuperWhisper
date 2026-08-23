import Foundation
import XCTest
@testable import OpenSuperWhisper

final class RecordingStoragePathTests: XCTestCase {
    func testUITestOverrideUsesIsolatedRootInsteadOfApplicationSupportHistory() throws {
        let isolatedRoot = try TestFixture.temporaryDirectory(prefix: "OpenSuperWhisperUITestStorage")
        defer { try? FileManager.default.removeItem(at: isolatedRoot) }

        let bundleIdentifier = "ru.starmel.OpenSuperWhisper"
        let environment = [
            "OPEN_SUPER_WHISPER_UI_TEST": "1",
            Recording.uiTestStorageRootEnvironmentKey: isolatedRoot.path
        ]
        let applicationDirectory = Recording.resolvedApplicationDirectory(
            arguments: ["--open-super-whisper-ui-test"],
            environment: environment,
            bundleIdentifier: bundleIdentifier
        )
        let realApplicationDirectory = Recording.applicationDirectory

        XCTAssertEqual(
            applicationDirectory.standardizedFileURL,
            isolatedRoot
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertNotEqual(
            applicationDirectory.standardizedFileURL,
            realApplicationDirectory.standardizedFileURL,
            "UI tests must never resolve to the user's Application Support history."
        )
        XCTAssertNotEqual(
            applicationDirectory
                .appendingPathComponent("recordings", isDirectory: true)
                .standardizedFileURL,
            realApplicationDirectory
                .appendingPathComponent("recordings", isDirectory: true)
                .standardizedFileURL
        )
    }

    func testOverrideRequiresTheExplicitUIOptIn() throws {
        let isolatedRoot = try TestFixture.temporaryDirectory(prefix: "OpenSuperWhisperUITestStorage")
        defer { try? FileManager.default.removeItem(at: isolatedRoot) }

        let productionSupport = isolatedRoot.appendingPathComponent(
            "application-support",
            isDirectory: true
        )
        let environment = [
            "OPEN_SUPER_WHISPER_UI_TEST": "1",
            Recording.uiTestStorageRootEnvironmentKey: isolatedRoot.path
        ]

        let withoutLaunchArgument = Recording.resolvedApplicationDirectory(
            arguments: [],
            environment: environment,
            applicationSupportDirectory: productionSupport,
            bundleIdentifier: "ru.starmel.OpenSuperWhisper"
        )
        let expectedProductionDirectory = productionSupport.appendingPathComponent(
            "ru.starmel.OpenSuperWhisper",
            isDirectory: true
        )
        XCTAssertEqual(
            withoutLaunchArgument.standardizedFileURL,
            expectedProductionDirectory.standardizedFileURL
        )

        let withoutMarker = Recording.resolvedApplicationDirectory(
            arguments: ["--open-super-whisper-ui-test"],
            environment: [Recording.uiTestStorageRootEnvironmentKey: isolatedRoot.path],
            applicationSupportDirectory: productionSupport,
            bundleIdentifier: "ru.starmel.OpenSuperWhisper"
        )
        XCTAssertEqual(
            withoutMarker.standardizedFileURL,
            expectedProductionDirectory.standardizedFileURL
        )
    }
}
