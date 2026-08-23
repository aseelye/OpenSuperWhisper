import Foundation
import XCTest

final class OpenSuperWhisperUITestsLaunchTests: XCTestCase {
    private var launchedApps: [XCUIApplication] = []
    private var isolatedRoots: [URL] = []
    override class var runsForEachTargetApplicationUIConfiguration: Bool { false }

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
    func testLaunchSmokeScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--open-super-whisper-ui-test",
            "-ApplePersistenceIgnoreState",
            "YES"
        ]
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisperUILaunch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        isolatedRoots.append(root)
        app.launchEnvironment = [
            "OPEN_SUPER_WHISPER_UI_TEST": "1",
            "OPEN_SUPER_WHISPER_UI_TEST_ID": UUID().uuidString,
            "HOME": root.path
        ]
        app.launch()
        launchedApps.append(app)

        XCTAssertTrue(app.buttons["Start recording"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Main recording surface"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
