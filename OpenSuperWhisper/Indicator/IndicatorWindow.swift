import Cocoa
import Combine
import SwiftUI

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    func didFinishDecoding(_ viewModel: IndicatorViewModel)
}

/// The shortcut indicator is a projection of the controller snapshot. Its
/// token is the identity of the operation it is allowed to stop/cancel; a
/// stale indicator can never affect a newer operation.
@MainActor
final class IndicatorViewModel: ObservableObject {
    let sessionController: DictationSessionController
    private(set) var operationToken: SessionOperationToken?
    @Published private(set) var isBlinking = false
    @Published var isVisible = false

    weak var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var snapshotCancellable: AnyCancellable?
    private var terminalToken: SessionOperationToken?

    init(sessionController: DictationSessionController? = nil) {
        let resolvedController = sessionController ?? .shared
        self.sessionController = resolvedController
        snapshotCancellable = resolvedController.$snapshot
            .removeDuplicates()
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.objectWillChange.send()
                self.updateBlinking(for: snapshot)
                guard let token = snapshot.token,
                      token == self.operationToken,
                      snapshot.outcome != nil,
                      self.terminalToken != token
                else { return }
                self.terminalToken = token
                self.delegate?.didFinishDecoding(self)
            }
    }

    deinit {
        blinkTimer?.invalidate()
        snapshotCancellable?.cancel()
    }

    var snapshot: DictationSessionSnapshot { sessionController.snapshot }
    var state: DictationSessionController.State { sessionController.state }
    var interimText: String { snapshot.interimText }
    var progress: Double { snapshot.progress }

    /// Compatibility helper for previews and older call sites. Production
    /// shortcut input reserves explicitly before constructing the indicator.
    @discardableResult
    func startRecording() -> SessionOperationToken? {
        guard let token = sessionController.reserve(
            source: .shortcut,
            pasteOnCompletion: true
        ) else { return nil }
        startRecording(token: token)
        return token
    }

    func startRecording(token: SessionOperationToken) {
        guard sessionController.isReservationActive(token) else { return }
        operationToken = token
        terminalToken = nil
        sessionController.startRecording(token: token)
        updateBlinking(for: sessionController.snapshot)
    }

    func startDecoding() {
        guard let token = operationToken else { return }
        startDecoding(token: token)
    }

    func startDecoding(token: SessionOperationToken) {
        guard token == operationToken,
              sessionController.isReservationActive(token)
        else { return }
        switch sessionController.snapshot.controlAction {
        case .stop:
            sessionController.stopRecording()
        case .cancel:
            _ = sessionController.cancelRecording(token: token)
        case .start, .none:
            break
        }
        updateBlinking(for: sessionController.snapshot)
    }

    func cancelRecording() {
        guard let token = operationToken else { return }
        cancelRecording(token: token)
    }

    @discardableResult
    func cancelRecording(token: SessionOperationToken) -> Bool {
        guard token == operationToken else { return false }
        let cancelled = sessionController.cancelRecording(token: token)
        updateBlinking(for: sessionController.snapshot)
        return cancelled
    }

    func insertTextUsingPasteboard(_ text: String) {
        ClipboardUtil.insertTextUsingPasteboard(text)
    }

    private func updateBlinking(for snapshot: DictationSessionSnapshot) {
        if snapshot.token == operationToken, snapshot.phase == .recording {
            startBlinking()
        } else {
            stopBlinking()
        }
    }

    private func startBlinking() {
        guard blinkTimer == nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isBlinking.toggle()
            }
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }

    @MainActor
    func hideWithAnimation() async {
        await withCheckedContinuation { continuation in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isVisible = false
            } completion: {
                continuation.resume()
            }
        }
    }
}

struct RecordingIndicator: View {
    let isBlinking: Bool

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .shadow(color: .red.opacity(0.5), radius: 4)
            .opacity(isBlinking ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.4), value: isBlinking)
    }
}

struct IndicatorWindow: View {
    @ObservedObject var viewModel: IndicatorViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.24)
    }

    var body: some View {
        let presentation = DictationSessionPresentation(viewModel.snapshot)
        let rect = RoundedRectangle(cornerRadius: 24)

        VStack(spacing: 8) {
            switch viewModel.snapshot.phase {
            case .recording:
                HStack(spacing: 8) {
                    RecordingIndicator(isBlinking: viewModel.isBlinking)
                        .frame(width: 24)
                    Text(viewModel.interimText.isEmpty ? "Recording…" : viewModel.interimText)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    if let duration = presentation.durationText {
                        Text(duration)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .cancelling:
                statusRow(presentation: presentation, text: "Cancelling…")

            case .preparing, .finalizingAudio, .exporting,
                 .transcribing, .saving, .uploading(_, _, _), .retrying(_, _):
                statusRow(
                    presentation: presentation,
                    text: viewModel.interimText.isEmpty
                        ? presentation.phaseText + "…"
                        : viewModel.interimText
                )

            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .background {
            rect
                .fill(backgroundColor)
                .background(rect.fill(Material.thinMaterial))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        }
        .clipShape(rect)
        .frame(width: viewModel.interimText.isEmpty ? 200 : 340)
        .scaleEffect(viewModel.isVisible ? 1 : 0.5)
        .offset(y: viewModel.isVisible ? 0 : 20)
        .opacity(viewModel.isVisible ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isVisible)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .onAppear { viewModel.isVisible = true }
    }

    @ViewBuilder
    private func statusRow(
        presentation: DictationSessionPresentation,
        text: String
    ) -> some View {
        HStack(spacing: 8) {
            DictationProgressView(presentation: presentation)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 13))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IndicatorWindowPreview: View {
    @StateObject private var recordingVM = IndicatorViewModel()

    var body: some View {
        IndicatorWindow(viewModel: recordingVM)
            .padding()
            .frame(height: 100)
            .background(Color(.windowBackgroundColor))
    }
}

#Preview {
    IndicatorWindowPreview()
}
