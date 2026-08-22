import Cocoa
import Combine
import SwiftUI

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    func didFinishDecoding(_ viewModel: IndicatorViewModel)
}

@MainActor
class IndicatorViewModel: ObservableObject {
    let sessionController: DictationSessionController
    @Published var isBlinking = false
    @Published var isVisible = false

    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var controllerCancellable: AnyCancellable?
    private var stateCancellable: AnyCancellable?

    init(sessionController: DictationSessionController? = nil) {
        let resolvedController = sessionController ?? DictationSessionController.shared
        self.sessionController = resolvedController
        controllerCancellable = resolvedController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        stateCancellable = resolvedController.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.updateBlinking(for: state)
                switch state {
                case .succeeded, .failed, .cancelled:
                    self.delegate?.didFinishDecoding(self)
                case .idle, .preparing, .recording, .finalizing, .transcribing:
                    break
                }
            }
    }

    var state: DictationSessionController.State {
        sessionController.state
    }

    var interimText: String {
        sessionController.interimText
    }

    var progress: Double {
        sessionController.progress
    }

    func startRecording() {
        sessionController.startRecording(pasteOnCompletion: true)
        startBlinking()
    }

    func startDecoding() {
        sessionController.stopRecording()
        stopBlinking()
    }

    func insertTextUsingPasteboard(_ text: String) {
        ClipboardUtil.insertTextUsingPasteboard(text)
    }
    
    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            // Update UI on the main thread
            Task { @MainActor in
                guard let self = self else { return }
                self.isBlinking.toggle()
            }
        }
    }
    
    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }

    func cancelRecording() {
        sessionController.cancelRecording()
        stopBlinking()
    }

    private func updateBlinking(for state: DictationSessionController.State) {
        if state == .recording {
            startBlinking()
        } else {
            stopBlinking()
        }
    }

    @MainActor
    func hideWithAnimation() async {
        await withCheckedContinuation { continuation in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.isVisible = false
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
            .fill(
                LinearGradient(
                    colors: [
                        Color.red.opacity(0.8),
                        Color.red
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 8, height: 8)
            .shadow(color: .red.opacity(0.5), radius: 4)
            .opacity(isBlinking ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.4), value: isBlinking)
    }
}

struct IndicatorWindow: View {
    @ObservedObject var viewModel: IndicatorViewModel
    @Environment(\.colorScheme) private var colorScheme
    
    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.24)
            : Color.white.opacity(0.24)
    }
    
    var body: some View {

        let rect = RoundedRectangle(cornerRadius: 24)
        
        VStack(spacing: 8) {
            switch viewModel.state {
            case .recording:
                HStack(spacing: 8) {
                    RecordingIndicator(isBlinking: viewModel.isBlinking)
                        .frame(width: 24)
                    
                    if viewModel.interimText.isEmpty {
                        Text("Recording...")
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Text(viewModel.interimText)
                            .font(.system(size: 13))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .finalizing, .transcribing:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24)

                    Text(viewModel.interimText.isEmpty ? "Transcribing..." : viewModel.interimText)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .succeeded:
                Text(viewModel.interimText)
                    .font(.system(size: 13))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

            case .preparing:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24)
                    Text("Preparing…")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .idle, .failed(_), .cancelled:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .background {
            rect
                .fill(backgroundColor)
                .background {
                    rect
                        .fill(Material.thinMaterial)
                }
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        }
        .clipShape(rect)
        .frame(width: viewModel.interimText.isEmpty ? 200 : 340)
        .scaleEffect(viewModel.isVisible ? 1 : 0.5)
        .offset(y: viewModel.isVisible ? 0 : 20)
        .opacity(viewModel.isVisible ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isVisible)
        .onAppear {
            viewModel.isVisible = true
        }
    }
}

struct IndicatorWindowPreview: View {
    @StateObject private var recordingVM = {
        let vm = IndicatorViewModel()
//        vm.startRecording()
        return vm
    }()
    
    @StateObject private var decodingVM = {
        let vm = IndicatorViewModel()
        vm.startDecoding()
        return vm
    }()
    
    var body: some View {
        VStack(spacing: 20) {
            IndicatorWindow(viewModel: recordingVM)
            IndicatorWindow(viewModel: decodingVM)
        }
        .padding()
        .frame(height: 200)
        .background(Color(.windowBackgroundColor))
    }
}

#Preview {
    IndicatorWindowPreview()
}
