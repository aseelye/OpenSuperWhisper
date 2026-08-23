import AVFoundation
import Foundation
import XCTest
@testable import OpenSuperWhisper

final class AudioRecorderObserverLifecycleTests: XCTestCase {
    @MainActor
    func testBothDeviceObserversAreOwnedAndRecorderCanDeallocate() {
        let notificationCenter = NotificationCenter()
        weak var weakRecorder: AudioRecorder?

        do {
            let recorder = AudioRecorder(
                notificationCenter: notificationCenter,
                deviceAvailability: { true }
            )
            weakRecorder = recorder
            XCTAssertTrue(recorder.canRecord)

            notificationCenter.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
            notificationCenter.post(name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
            XCTAssertTrue(recorder.canRecord)
        }

        XCTAssertNil(weakRecorder)
        // Posting after deallocation exercises both removal paths. A retained
        // observer would keep a callback alive or crash on a replaced owner.
        notificationCenter.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
        notificationCenter.post(name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
    }
}
