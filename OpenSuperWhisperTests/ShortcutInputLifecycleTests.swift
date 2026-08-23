import Combine
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class ShortcutInputLifecycleTests: XCTestCase {
    func testRejectedShortcutArmsNoHoldAndCannotCancelOtherSource() {
        let controller = DictationSessionController()
        let mainToken = controller.reserve(source: .mainWindow)
        XCTAssertNotNil(mainToken)

        var scheduled = false
        let manager = ShortcutManager(
            sessionController: controller,
            holdScheduler: { _, _ in
                scheduled = true
                return AnyCancellable {}
            },
            registerShortcuts: false
        )

        manager.handleKeyDownForTesting(sequence: 1)
        manager.handleKeyUpForTesting(sequence: 2)

        XCTAssertFalse(scheduled)
        XCTAssertNil(manager.operationToken)
        XCTAssertEqual(controller.operationToken, mainToken)
    }

    func testOlderKeyUpSequenceCannotReachCurrentShortcutOperation() {
        let controller = DictationSessionController()
        var holdCallback: (() -> Void)?
        let manager = ShortcutManager(
            sessionController: controller,
            holdScheduler: { callback, _ in
                holdCallback = callback
                return AnyCancellable {}
            },
            registerShortcuts: false
        )

        manager.handleKeyDownForTesting(sequence: 1)
        guard let token = manager.operationToken else {
            XCTFail("shortcut should reserve a token")
            return
        }
        holdCallback?()
        manager.handleKeyDownForTesting(sequence: 3)
        manager.handleKeyUpForTesting(sequence: 2)

        XCTAssertEqual(manager.operationToken, token)
        XCTAssertEqual(controller.operationToken, token)
    }
}
