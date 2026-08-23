import AppKit
import Carbon
import Combine
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    static let escape = Self("escape", default: .init(.escape))
}

private final class ShortcutCallbackSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

/// Owns global shortcut callbacks on MainActor. Delayed hold work carries the
/// operation token and generation that armed it, so a stale timer or key-up
/// cannot stop a replacement operation.
@MainActor
final class ShortcutManager {
    static let shared = ShortcutManager()

    typealias HoldScheduler = (
        @escaping () -> Void,
        TimeInterval
    ) -> AnyCancellable

    private static let callbackSequence = ShortcutCallbackSequence()

    private let sessionController: DictationSessionController
    private let indicatorManager: IndicatorWindowManager
    private let holdThreshold: TimeInterval
    private let holdScheduler: HoldScheduler
    private var holdCancellable: AnyCancellable?
    private var holdGeneration: UUID?
    private var activeToken: SessionOperationToken?
    private weak var activeVm: IndicatorViewModel?
    private var holdMode = false
    private var keyDownSequence: UInt64?
    private var lastHandledSequence: UInt64 = 0

    var operationToken: SessionOperationToken? { activeToken }

    init(
        sessionController: DictationSessionController? = nil,
        indicatorManager: IndicatorWindowManager? = nil,
        holdThreshold: TimeInterval = 0.3,
        holdScheduler: HoldScheduler? = nil,
        registerShortcuts: Bool = true
    ) {
        self.sessionController = sessionController ?? .shared
        self.indicatorManager = indicatorManager ?? .shared
        self.holdThreshold = holdThreshold
        self.holdScheduler = holdScheduler ?? Self.defaultHoldScheduler

        guard registerShortcuts else { return }
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            let sequence = Self.callbackSequence.next()
            Task { @MainActor [weak self] in
                self?.handleKeyDown(sequence: sequence)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            let sequence = Self.callbackSequence.next()
            Task { @MainActor [weak self] in
                self?.handleKeyUp(sequence: sequence)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .escape) { [weak self] in
            let sequence = Self.callbackSequence.next()
            Task { @MainActor [weak self] in
                self?.handleEscape(sequence: sequence)
            }
        }
        KeyboardShortcuts.disable(.escape)
    }

    deinit {
        holdCancellable?.cancel()
    }

    // MARK: Callback state machine

    private func handleKeyDown(sequence: UInt64) {
        guard accept(sequence) else { return }
        cancelHold()
        holdMode = false

        if let token = activeToken {
            // A quick second press toggles only the operation this indicator
            // admitted. Processing phases use the same surface's cancel
            // action instead of becoming a dead, disabled button.
            guard sessionController.isReservationActive(token),
                  activeVm?.operationToken == token
            else { return }
            keyDownSequence = sequence
            indicatorManager.stopRecording(token: token)
            return
        }

        // Reserve synchronously before showing the indicator or arming a
        // timer. A rejected shortcut creates no timer, VM, or callback.
        guard let token = sessionController.reserve(
            source: .shortcut,
            pasteOnCompletion: true
        ) else {
            keyDownSequence = nil
            return
        }

        let point = indicatorPoint()
        let viewModel = indicatorManager.show(
            nearPoint: point,
            sessionController: sessionController
        )
        activeToken = token
        activeVm = viewModel
        keyDownSequence = sequence
        viewModel.startRecording(token: token)

        let generation = UUID()
        holdGeneration = generation
        holdCancellable = holdScheduler({ [weak self] in
            Task { @MainActor [weak self] in
                self?.handleHoldTimer(token: token, generation: generation)
            }
        }, holdThreshold)
    }

    private func handleKeyUp(sequence: UInt64) {
        guard accept(sequence),
              let token = activeToken,
              let downSequence = keyDownSequence,
              sequence > downSequence,
              sessionController.isReservationActive(token),
              activeVm?.operationToken == token
        else { return }

        cancelHold()
        keyDownSequence = nil
        if holdMode {
            holdMode = false
            indicatorManager.stopRecording(token: token)
        }
        // Tap-mode already stopped on key-down. The operation remains owned
        // by the token while finalizing/transcribing so Escape can cancel it.
    }

    private func handleEscape(sequence: UInt64) {
        guard accept(sequence),
              let token = activeToken,
              sessionController.isReservationActive(token),
              activeVm?.operationToken == token
        else { return }
        indicatorManager.stopForce(token: token)
    }

    private func handleHoldTimer(
        token: SessionOperationToken,
        generation: UUID
    ) {
        guard holdGeneration == generation,
              activeToken == token,
              sessionController.isReservationActive(token),
              activeVm?.operationToken == token
        else { return }
        holdMode = true
        holdCancellable = nil
    }

    private func accept(_ sequence: UInt64) -> Bool {
        guard sequence > lastHandledSequence else { return false }
        lastHandledSequence = sequence
        return true
    }

    // MARK: Indicator lifecycle

    func indicatorDidFinish(_ viewModel: IndicatorViewModel) {
        guard activeVm === viewModel else { return }
        guard activeToken == viewModel.operationToken else { return }
        cancelHold()
        holdMode = false
        keyDownSequence = nil
        holdGeneration = nil
        activeToken = nil
        activeVm = nil
    }

    // Deterministic seams used by the input unit tests. They still exercise
    // the production state machine and do not register global shortcuts.
    func handleKeyDownForTesting(sequence: UInt64) {
        handleKeyDown(sequence: sequence)
    }

    func handleKeyUpForTesting(sequence: UInt64) {
        handleKeyUp(sequence: sequence)
    }

    func fireHoldForTesting() {
        holdCancellable = nil
        guard let token = activeToken, let generation = holdGeneration else { return }
        handleHoldTimer(token: token, generation: generation)
    }

    private func cancelHold() {
        holdCancellable?.cancel()
        holdCancellable = nil
        holdGeneration = nil
    }

    private func indicatorPoint() -> NSPoint? {
        let cursorPosition = FocusUtils.getCurrentCursorPosition()
        if let caret = FocusUtils.getCaretRect(),
           let screen = FocusUtils.getFocusedWindowScreen() {
            return NSPoint(
                x: caret.origin.x,
                y: screen.frame.height - caret.origin.y
            )
        }
        return cursorPosition
    }

    private static let defaultHoldScheduler: HoldScheduler = { callback, duration in
        let workItem = DispatchWorkItem(block: callback)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + duration,
            execute: workItem
        )
        return AnyCancellable { workItem.cancel() }
    }
}
