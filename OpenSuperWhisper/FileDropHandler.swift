import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

@MainActor
class FileDropHandler: ObservableObject {
    static let shared = FileDropHandler()
    
    @Published var isDragging = false
    @Published var isTranscribing = false
    @Published var fileDuration: TimeInterval = 0
    @Published var errorMessage: String? = nil
    
    private let sessionController: DictationSessionController
    private var activeDropOperationID: UUID?
    private var intentionallyCancelledDropOperationIDs = Set<UUID>()
    private var errorMessageToken: UUID?
    private let durationLoader: (URL) async throws -> TimeInterval

    var isLongFile: Bool {
        fileDuration > 10.0
    }

    init(
        sessionController: DictationSessionController? = nil,
        durationLoader: @escaping (URL) async throws -> TimeInterval = { url in
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        }
    ) {
        self.sessionController = sessionController ?? .shared
        self.durationLoader = durationLoader
    }
    
    func showProcessingError() {
        presentTransientError("Already processing a file. Please wait.", duration: 3)
    }
    
    func cancelTranscription() {
        if let operationID = activeDropOperationID {
            intentionallyCancelledDropOperationIDs.insert(operationID)
        }
        sessionController.cancelRecording()
        
        // Reset state
        isTranscribing = false
        fileDuration = 0
    }
    
    func handleDrop(of providers: [NSItemProvider]) async {
        guard let provider = providers.first else { return }

        // Double-check we're not already processing
        if isTranscribing || sessionController.state.isBusy {
            showProcessingError()
            return
        }

        guard provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) else {
            return
        }

        // Keep this identity alive until every suspended part of the drop has
        // returned. Cancellation resets the visible state immediately, so a
        // boolean alone cannot tell a late cancellation from a newer drop.
        if let activeDropOperationID,
           !intentionallyCancelledDropOperationIDs.contains(activeDropOperationID) {
            showProcessingError()
            return
        }
        let operationID = UUID()
        activeDropOperationID = operationID
        isTranscribing = true
        defer { finishDropOperation(operationID) }

        do {
            // Create a continuation to handle the non-Sendable NSItemProvider
            let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
                provider.loadItem(forTypeIdentifier: UTType.audio.identifier) { item, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: item as? URL)
                }
            }

            guard let url = url else {
                print("Error loading item: not a URL")
                return
            }

            guard isDropOperationActive(operationID) else { return }

            let needsAccess = url.startAccessingSecurityScopedResource()
            defer {
                if needsAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            print("url: \(url)")

            // Get audio duration
            let durationInSeconds = try await durationLoader(url)

            guard isDropOperationActive(operationID) else { return }

            self.fileDuration = durationInSeconds

            _ = try await sessionController.transcribeFile(
                at: url,
                duration: durationInSeconds
            )
        } catch {
            let wasIntentionalCancellation = intentionallyCancelledDropOperationIDs.contains(operationID)
            if !(wasIntentionalCancellation && Self.isCancellation(error)) {
                // This method is MainActor-isolated already. Presenting here
                // preserves the operation identity instead of scheduling a
                // task that may run after a new drop has started.
                present(error: error, for: operationID)
            }
            print("Error processing dropped audio file: \(error)")
        }
    }

    private func finishDropOperation(_ operationID: UUID) {
        intentionallyCancelledDropOperationIDs.remove(operationID)
        guard activeDropOperationID == operationID else { return }
        activeDropOperationID = nil
        isTranscribing = false
        fileDuration = 0
    }

    private func isDropOperationActive(_ operationID: UUID) -> Bool {
        activeDropOperationID == operationID
            && !intentionallyCancelledDropOperationIDs.contains(operationID)
    }

    private func present(error: Error, for operationID: UUID) {
        guard activeDropOperationID == operationID else { return }
        presentTransientError(error.localizedDescription, duration: 5)
    }

    private func presentTransientError(_ message: String, duration: TimeInterval) {
        let token = UUID()
        errorMessageToken = token
        errorMessage = message

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.errorMessageToken == token else { return }
            self.errorMessage = nil
            self.errorMessageToken = nil
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let error = error as? CoreTranscriptionError {
            return error == .cancelled
        }
        if let error = error as? OpenAITranscriptionEngineError {
            return error == .cancelled
        }
        if let error = error as? AudioCaptureError {
            return error == .cancelled
        }
        if let error = error as? URLError {
            return error.code == .cancelled
        }
        return false
    }
}

// View modifier for adding drag-and-drop functionality
struct FileDropOverlay: ViewModifier {
    @ObservedObject private var handler: FileDropHandler
    @ObservedObject private var sessionController: DictationSessionController

    init() {
        self.handler = FileDropHandler.shared
        self.sessionController = DictationSessionController.shared
    }
    
    func body(content: Content) -> some View {
        content
            .overlay {
                if handler.isDragging {
                    ZStack {
                        Color(NSColor.windowBackgroundColor)
                            .opacity(0.95)
                        VStack(spacing: 16) {
                            if handler.isTranscribing {
                                // Show warning when trying to drop while already processing
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 48))
                                    .foregroundColor(.orange)
                                Text("Please wait until current file is processed")
                                    .font(.headline)
                                    .foregroundColor(.orange)
                            } else {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 48))
                                    .foregroundColor(.accentColor)
                                    .symbolEffect(.bounce, value: handler.isDragging)
                                Text("Drop audio file to transcribe")
                                    .font(.headline)
                            }
                        }
                    }
                    .ignoresSafeArea()
                }
                
                // Show transcription status for dropped files
                if handler.isTranscribing && handler.isLongFile {
                    ZStack {
                        // Add blur background effect
                        Color(NSColor.windowBackgroundColor)
                            .opacity(0.7)
                            .blur(radius: 10)
                        
                        VStack(spacing: 16) {
                            ProgressView()
                                .frame(width: 200)
                            
                            Text("Transcribing audio...")
                                .foregroundColor(.primary)
                                .font(.headline)
                            
                            if !sessionController.interimText.isEmpty {
                                Text(sessionController.interimText)
                                    .foregroundColor(.primary.opacity(0.8))
                                    .font(.subheadline)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 300)
                                    .lineLimit(2)
                            }
                            
                            Button(action: {
                                handler.cancelTranscription()
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("Cancel")
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.8))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .padding(.top, 8)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(NSColor.controlBackgroundColor))
                                .shadow(color: Color.black.opacity(0.2), radius: 10)
                        )
                    }
                    .ignoresSafeArea()
                }
                
                // Show error message if present - now at the top
                if let errorMessage = handler.errorMessage {
                    VStack {
                        Text(errorMessage)
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(8)
                            .padding(.top, 20)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                    .animation(.easeInOut, value: handler.errorMessage != nil)
                    .zIndex(100) // Ensure it's above other overlays
                }
            }
            .onDrop(of: [.audio], isTargeted: $handler.isDragging) { providers in
                // Only process the drop if we're not already transcribing
                if !handler.isTranscribing {
                    Task {
                        await handler.handleDrop(of: providers)
                    }
                    return true
                } else {
                    // Show error message when trying to drop while processing
                    handler.showProcessingError()
                    // Return true to indicate the drop was handled, even though we're ignoring it
                    // This prevents the OS from trying to handle the drop in other ways
                    return true
                }
            }
    }
}

extension View {
    func fileDropHandler() -> some View {
        modifier(FileDropOverlay())
    }
}
