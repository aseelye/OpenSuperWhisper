import AppKit
import KeyboardShortcuts
import SwiftUI

/// Owns the one floating shortcut indicator and rejects stale VM callbacks.
@MainActor
final class IndicatorWindowManager: IndicatorViewDelegate {
    static let shared = IndicatorWindowManager()

    private(set) var window: NSWindow?
    private(set) var viewModel: IndicatorViewModel?

    init() {}

    @discardableResult
    func show(
        nearPoint point: NSPoint? = nil,
        sessionController: DictationSessionController? = nil
    ) -> IndicatorViewModel {
        KeyboardShortcuts.enable(.escape)

        let newViewModel = IndicatorViewModel(sessionController: sessionController)
        newViewModel.delegate = self
        viewModel = newViewModel

        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            window = panel
        }

        if let window, let screen = NSScreen.main {
            let frame = window.frame
            let screenFrame = screen.frame
            let rawPoint = point ?? NSPoint(
                x: screenFrame.midX,
                y: screenFrame.maxY - frame.height - 100
            )
            let x = max(screenFrame.minX, min(rawPoint.x - frame.width / 2, screenFrame.maxX - frame.width))
            let y = max(screenFrame.minY, min(rawPoint.y + 20, screenFrame.maxY - frame.height))
            window.setFrameOrigin(NSPoint(x: x, y: y))
            window.contentView = NSHostingView(rootView: IndicatorWindow(viewModel: newViewModel))
            window.orderFrontRegardless()
        }
        return newViewModel
    }

    func stopRecording(token: SessionOperationToken? = nil) {
        guard let viewModel,
              token == nil || token == viewModel.operationToken
        else { return }
        guard let operationToken = viewModel.operationToken else { return }
        viewModel.startDecoding(token: operationToken)
    }

    func stopForce(token: SessionOperationToken? = nil) {
        guard let viewModel,
              token == nil || token == viewModel.operationToken
        else { return }
        if let token = viewModel.operationToken {
            _ = viewModel.cancelRecording(token: token)
            // Keep the indicator visible while the controller tears down.
            // The terminal snapshot invokes `didFinishDecoding`, which then
            // hides this exact VM after cancellation has quiesced.
            return
        }
        hide(viewModel)
    }

    /// Hiding is identity-guarded so an old animation cannot order out a new
    /// indicator window that has already been shown for another operation.
    func hide(_ targetViewModel: IndicatorViewModel? = nil) {
        guard let hidingViewModel = targetViewModel ?? viewModel,
              viewModel === hidingViewModel
        else { return }
        KeyboardShortcuts.disable(.escape)

        Task { @MainActor [weak self, weak hidingViewModel] in
            guard let self, let hidingViewModel else { return }
            await hidingViewModel.hideWithAnimation()
            guard self.viewModel === hidingViewModel else { return }
            self.window?.orderOut(nil)
            self.viewModel = nil
        }
    }

    func didFinishDecoding(_ viewModel: IndicatorViewModel) {
        guard self.viewModel === viewModel else { return }
        ShortcutManager.shared.indicatorDidFinish(viewModel)
        hide(viewModel)
    }
}
