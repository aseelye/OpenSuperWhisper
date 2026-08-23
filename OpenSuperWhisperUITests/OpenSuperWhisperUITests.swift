import Foundation
import XCTest

/// These tests intentionally use the opt-in UI launch mode. They do not
/// request microphone/accessibility permissions and do not touch the user's
/// normal defaults or history from the unit-test lane.
final class OpenSuperWhisperUITests: XCTestCase {
    private var launchedApps: [XCUIApplication] = []
    private var isolatedRoots: [URL] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        launchedApps.forEach { app in
            if app.state != .notRunning { app.terminate() }
        }
        launchedApps.removeAll()
        isolatedRoots.forEach { try? FileManager.default.removeItem(at: $0) }
        isolatedRoots.removeAll()
    }

    @MainActor
    func testLaunchShowsMainRecordingSurface() {
        let app = launchIsolatedApp()

        XCTAssertTrue(app.textFields["Search in transcriptions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Drop audio file to transcribe"].exists)
    }

    @MainActor
    func testHistoryAndRecoverySurfaceHasActionableState() {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.textFields["Search in transcriptions"].waitForExistence(timeout: 5))

        let historyState = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'history'")
        )
        let emptyState = app.staticTexts["No recordings yet"]
        XCTAssertTrue(historyState.count > 0 || emptyState.waitForExistence(timeout: 3))
    }

    @MainActor
    func testWindowCanBeReopenedInFreshLaunchMode() {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.buttons["Start recording"].waitForExistence(timeout: 5))

        app.terminate()
        let reopened = launchIsolatedApp()
        XCTAssertTrue(reopened.buttons["Start recording"].waitForExistence(timeout: 5))
    }

    private func launchIsolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        let root = isolatedRoot()
        app.launchArguments = [
            "--open-super-whisper-ui-test",
            "-ApplePersistenceIgnoreState",
            "YES"
        ]
        app.launchEnvironment = [
            "OPEN_SUPER_WHISPER_UI_TEST": "1",
            "OPEN_SUPER_WHISPER_UI_TEST_ID": UUID().uuidString,
            "OPEN_SUPER_WHISPER_UI_TEST_STORAGE_ROOT": root.path,
            "HOME": root.path
        ]
        app.launch()
        launchedApps.append(app)
        return app
    }

    private func isolatedRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisperUITest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        isolatedRoots.append(root)
        return root
    }
}
