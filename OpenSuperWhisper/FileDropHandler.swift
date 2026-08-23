import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Owns the Finder/drop presentation, while admission and terminal lifecycle
/// remain owned by `DictationSessionController`.
///
/// The important boundary here is synchronous: a valid drop reserves a
/// controller token before loading the `NSItemProvider` or probing its
/// duration. A second input surface therefore loses at reservation time,
/// rather than after one of the two operations has already suspended.
@MainActor
final class FileDropHandler: ObservableObject {
    typealias ProviderLoader = (
        NSItemProvider,
        @escaping (Result<URL?, Error>) -> Void
    ) -> Void
    typealias ExpiryScheduler = (
        @escaping () -> Void,
        TimeInterval
    ) -> AnyCancellable

    static let shared = FileDropHandler()

    @Published var isDragging = false
    @Published private(set) var fileDuration: TimeInterval = 0
    /// Only errors that happen before a controller reservation are rendered
    /// here. Once a token exists, the controller is the sole terminal error
    /// presenter.
    @Published private(set) var errorMessage: String?

    fileprivate let sessionController: DictationSessionController
    private let providerLoader: ProviderLoader
    private let durationLoader: (URL) async throws -> TimeInterval
    private let expiryScheduler: ExpiryScheduler
    private var activeToken: SessionOperationToken?
    private var expiryCancellable: AnyCancellable?
    private var errorGeneration: UUID?
    private var controllerCancellable: AnyCancellable?

    /// `isTranscribing` is retained as a presentation spelling for existing
    /// callers, but its value is derived from token identity rather than
    /// maintained as a second operation state machine.
    var isTranscribing: Bool { activeToken != nil }

    var operationToken: SessionOperationToken? { activeToken }

    var isLongFile: Bool { fileDuration > 10 }

    init(
        sessionController: DictationSessionController? = nil,
        providerLoader: ProviderLoader? = nil,
        durationLoader: @escaping (URL) async throws -> TimeInterval = { url in
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        },
        expiryScheduler: ExpiryScheduler? = nil
    ) {
        self.sessionController = sessionController ?? .shared
        self.providerLoader = providerLoader ?? Self.defaultProviderLoader
        self.durationLoader = durationLoader
        self.expiryScheduler = expiryScheduler ?? Self.defaultExpiryScheduler

        controllerCancellable = self.sessionController.objectWillChange.sink {
            [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        expiryCancellable?.cancel()
        controllerCancellable?.cancel()
    }

    /// Presents an admission rejection before any new token is created.
    func showProcessingError() {
        presentLocalError("Already processing an operation. Please wait.", duration: 3)
    }

    /// Requests cancellation through the token that this drop actually
    /// reserved. The token remains active until controller teardown has
    /// completed, so a replacement cannot slip in while the UI says
    /// “Cancelling”.
    @discardableResult
    func cancelTranscription() -> Bool {
        guard let token = activeToken else { return false }
        return sessionController.cancelRecording(token: token)
    }

    /// Handles one drop. This method is MainActor-isolated, so `reserve` is
    /// executed synchronously before the first `await`.
    func handleDrop(of providers: [NSItemProvider]) async {
        guard let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
        else {
            presentLocalError("Drop an audio file to transcribe.", duration: 4)
            return
        }

        guard let token = sessionController.reserve(source: .fileDrop) else {
            // Admission rejection is intentionally quiet. The winner's
            // authoritative snapshot already exposes the busy/cancelling
            // state; a losing drop must not create a second error presenter.
            return
        }

        // Install the identity before any asynchronous provider callback.
        clearLocalError()
        activeToken = token
        fileDuration = 0
        objectWillChange.send()
        defer { finish(token: token) }

        do {
            try await withTaskCancellationHandler(operation: {
                let loadedURL = try await loadURL(from: provider)
                guard let url = loadedURL else {
                    throw FileDropError.itemWasNotAFile
                }
                guard isActive(token) else { return }

                let needsAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if needsAccess { url.stopAccessingSecurityScopedResource() }
                }

                // A duration probe is useful presentation metadata, not a
                // reason to fail a valid imported file. If it cannot be read,
                // let the controller continue and derive duration from the
                // owned audio.
                let duration = try? await durationLoader(url)
                guard isActive(token) else { return }
                fileDuration = duration ?? 0

                // This is the tokenized imported-file API. Any provider/
                // export/persistence error after this point is presented by
                // the controller; the drop handler intentionally does not
                // duplicate that terminal ownership.
                _ = try await sessionController.transcribeFile(
                    at: url,
                    duration: duration,
                    token: token
                )
            }, onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.activeToken == token else { return }
                    _ = self.sessionController.cancelRecording(token: token)
                }
            })
        } catch {
            guard isActive(token) else { return }
            if Self.isCancellation(error)
                || sessionController.snapshot.outcome == .cancelled {
                return
            }

            // The provider callback happens after admission but before the
            // controller can create a file operation. Let the controller
            // claim and drain this reserved window so it publishes the one
            // terminal failure and releases the token. A stale callback is
            // rejected without creating a local banner or cancellation side
            // effect.
            _ = await sessionController.failReservedOperation(error, token: token)
        }
    }

    private func loadURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            providerLoader(provider) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func isActive(_ token: SessionOperationToken) -> Bool {
        activeToken == token
            && sessionController.isReservationActive(token)
            && sessionController.snapshot.phase != .cancelling
    }

    private func finish(token: SessionOperationToken) {
        guard activeToken == token else { return }
        activeToken = nil
        fileDuration = 0
        objectWillChange.send()
    }

    private func presentLocalError(_ message: String, duration: TimeInterval) {
        expiryCancellable?.cancel()
        let generation = UUID()
        errorGeneration = generation
        errorMessage = message
        expiryCancellable = expiryScheduler({ [weak self] in
            guard let self, self.errorGeneration == generation else { return }
            self.errorMessage = nil
            self.errorGeneration = nil
            self.expiryCancellable = nil
        }, duration)
    }

    private func clearLocalError() {
        expiryCancellable?.cancel()
        expiryCancellable = nil
        errorGeneration = nil
        errorMessage = nil
    }

    private static let defaultProviderLoader: ProviderLoader = { provider, completion in
        provider.loadItem(forTypeIdentifier: UTType.audio.identifier) { item, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(item as? URL))
            }
        }
    }

    private static let defaultExpiryScheduler: ExpiryScheduler = { callback, duration in
        let workItem = DispatchWorkItem(block: callback)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + duration,
            execute: workItem
        )
        return AnyCancellable { workItem.cancel() }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? CoreTranscriptionError {
            return error == .cancelled
        }
        if let error = error as? AudioCaptureError {
            return error == .cancelled
        }
        if let error = error as? TranscriptionLiveInputError {
            return error == .cancelled
        }
        if let error = error as? URLError {
            return error.code == .cancelled
        }
        return false
    }
}

private enum FileDropError: LocalizedError {
    case itemWasNotAFile

    var errorDescription: String? {
        switch self {
        case .itemWasNotAFile:
            return "The dropped item could not be opened as an audio file."
        }
    }
}

struct FileDropOverlay: ViewModifier {
    @ObservedObject private var handler: FileDropHandler
    @ObservedObject private var sessionController: DictationSessionController

    init(
        handler: FileDropHandler? = nil,
        sessionController: DictationSessionController? = nil
    ) {
        let resolvedHandler = handler ?? FileDropHandler.shared
        self.handler = resolvedHandler
        self.sessionController = sessionController ?? resolvedHandler.sessionController
    }

    func body(content: Content) -> some View {
        let snapshot = sessionController.snapshot
        // The controller snapshot is the only source-of-truth for which
        // operation owns this overlay. A late drop task may still retain its
        // local token while a replacement has already been admitted.
        let ownsDrop = snapshot.presentationOwner == .fileDrop

        return content
            .overlay {
                if handler.isDragging {
                    ZStack {
                        Color(NSColor.windowBackgroundColor).opacity(0.95)
                        VStack(spacing: 16) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 48))
                                .foregroundColor(.accentColor)
                                .symbolEffect(.bounce, value: handler.isDragging)
                            Text("Drop audio file to transcribe")
                                .font(.headline)
                        }
                    }
                    .ignoresSafeArea()
                }

                if ownsDrop, let phase = snapshot.phase,
                   snapshot.isBusy || phase == .cancelling {
                    ZStack {
                        Color(NSColor.windowBackgroundColor)
                            .opacity(0.72)
                            .blur(radius: 10)

                        VStack(spacing: 14) {
                            DictationProgressView(presentation: .init(snapshot))
                                .frame(width: 220)

                            Text(DictationSessionPresentation(snapshot).phaseText)
                                .font(.headline)

                            if !snapshot.interimText.isEmpty {
                                Text(snapshot.interimText)
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 320)
                                    .lineLimit(3)
                            }

                            if snapshot.canCancel {
                                Button {
                                    _ = handler.cancelTranscription()
                                } label: {
                                    Label("Cancel", systemImage: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .accessibilityLabel(snapshot.accessibilityLabel)
                            } else if phase == .cancelling {
                                Text("Cancelling…")
                                    .foregroundColor(.secondary)
                                    .accessibilityLabel("Cancelling")
                            }
                        }
                        .padding(22)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(NSColor.controlBackgroundColor))
                                .shadow(color: .black.opacity(0.2), radius: 10)
                        )
                    }
                    .ignoresSafeArea()
                }

                if let errorMessage = handler.errorMessage {
                    VStack {
                        Text(errorMessage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.red.opacity(0.88))
                            .cornerRadius(8)
                            .padding(.top, 20)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                    .animation(.easeInOut, value: handler.errorMessage != nil)
                    .zIndex(100)
                }
            }
            .onDrop(of: [.audio], isTargeted: $handler.isDragging) { providers in
                Task { @MainActor in
                    await handler.handleDrop(of: providers)
                }
                return true
            }
    }
}

extension View {
    func fileDropHandler() -> some View {
        modifier(FileDropOverlay())
    }
}
