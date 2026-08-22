import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    static let escape = Self("escape", default: .init(.escape))
}

class ShortcutManager {
    static let shared = ShortcutManager()

    // Current recording indicator view and state
    private var activeVm: IndicatorViewModel?
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false

    private init() {
        print("ShortcutManager init")

        // Handle key down for recording shortcut: start or toggle and detect hold
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) {
            // Cancel any pending hold detection
            self.holdWorkItem?.cancel()
            self.holdMode = false
            // Perform UI actions on the main actor
            Task { @MainActor in
                if self.activeVm == nil {
                    // FileDropHandler claims a drop before the shared
                    // controller starts, so guard both ownership markers
                    // before creating an indicator. This prevents a shortcut
                    // press from later canceling work it did not start. The
                    // checks and claim below are serialized on the main actor.
                    guard !FileDropHandler.shared.isTranscribing,
                          !DictationSessionController.shared.state.isBusy else { return }

                    // First press: show indicator and start recording immediately
                    let cursorPosition = FocusUtils.getCurrentCursorPosition()
                    let indicatorPoint: NSPoint?
                    if let caret = FocusUtils.getCaretRect(), let screen = FocusUtils.getFocusedWindowScreen() {
                        let screenHeight = screen.frame.height
                        indicatorPoint = NSPoint(x: caret.origin.x, y: screenHeight - caret.origin.y)
                    } else {
                        indicatorPoint = cursorPosition
                    }
                    let vm = IndicatorWindowManager.shared.show(nearPoint: indicatorPoint)
                    // Keep the operation identity installed before starting
                    // the controller. A preparation failure can transition
                    // to a terminal state synchronously, and the delegate
                    // callback must be able to clear this same VM.
                    self.activeVm = vm
                    vm.startRecording()
                } else if !self.holdMode {
                    // Second quick press: toggle off recording
                    IndicatorWindowManager.shared.stopRecording()
                    // Keep activeVm until indicatorDidFinish. The controller
                    // may still be finalizing, transcribing, or uploading;
                    // Escape must remain able to cancel that work.
                }
            }
            // Schedule hold-mode flag after threshold
            let workItem = DispatchWorkItem {
                self.holdMode = true
            }
            self.holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + self.holdThreshold, execute: workItem)
        }

        // Handle key up for recording shortcut: end hold if in hold mode
        KeyboardShortcuts.onKeyUp(for: .toggleRecord) {
            // Cancel hold detection
            self.holdWorkItem?.cancel()
            self.holdWorkItem = nil
            // Perform UI actions on the main actor
            Task { @MainActor in
                if self.holdMode {
                    // End hold-to-record
                    IndicatorWindowManager.shared.stopRecording()
                    self.holdMode = false
                }
                // Tap-mode toggle off handled on keyDown
            }
        }

        KeyboardShortcuts.onKeyUp(for: .escape) {
            // Run on the main actor to safely interact with actor-isolated methods
            Task { @MainActor in
                if self.activeVm != nil {
                    IndicatorWindowManager.shared.stopForce()
                }
            }
        }
        KeyboardShortcuts.disable(.escape)
    }

    @MainActor
    func indicatorDidFinish(_ viewModel: IndicatorViewModel) {
        guard activeVm === viewModel else { return }
        holdWorkItem?.cancel()
        holdWorkItem = nil
        holdMode = false
        activeVm = nil
    }

}
