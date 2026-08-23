import AVFoundation
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

// MARK: - One session presentation mapping

/// The main window, file-drop overlay, and shortcut indicator all consume
/// this mapping.  No surface invents a phase label, action, or progress mode
/// independently from the controller snapshot.
struct DictationSessionPresentation: Equatable {
    let phaseText: String
    let action: DictationSessionControlAction
    let accessibilityLabel: String
    let helpText: String
    let progress: Double?
    let isIndeterminate: Bool
    let durationText: String?
    let interimText: String
    let warning: String?
    let isBusy: Bool
    let canCancel: Bool

    init(_ snapshot: DictationSessionSnapshot) {
        let terminalOutcome = snapshot.outcome
        action = terminalOutcome == nil ? snapshot.controlAction : .none
        accessibilityLabel = terminalOutcome.map(Self.terminalAccessibilityLabel)
            ?? snapshot.accessibilityLabel
        interimText = snapshot.interimText
        warning = snapshot.warning
        isBusy = snapshot.isBusy
        canCancel = snapshot.canCancel

        if let terminalOutcome {
            switch terminalOutcome {
            case .succeeded:
                phaseText = "Completed"
            case .succeededWithHistoryWarning:
                phaseText = "Completed with warning"
            case .failed:
                phaseText = "Failed"
            case .cancelled:
                phaseText = "Cancelled"
            }
        } else {
            switch snapshot.phase {
            case nil:
                phaseText = "Ready"
            case .preparing:
                phaseText = "Preparing"
            case .recording:
                phaseText = "Recording"
            case .finalizingAudio:
                phaseText = "Finalizing audio"
            case .exporting:
                phaseText = "Exporting audio"
            case let .uploading(part, total, _):
                if let part, let total {
                    phaseText = "Uploading part \(part) of \(total)"
                } else {
                    phaseText = "Uploading"
                }
            case let .retrying(attempt, maximum):
                phaseText = "Retrying (\(attempt) of \(maximum))"
            case .transcribing:
                phaseText = "Transcribing"
            case .saving:
                phaseText = "Saving"
            case .cancelling:
                phaseText = "Cancelling"
            }
        }

        // A provider's upload fraction or retry count is exact.  For an
        // imported file with no provider fraction, 0 is not “0% complete”;
        // it is an honest indeterminate state.
        switch terminalOutcome == nil ? snapshot.phase : nil {
        case let .uploading(part, total, fraction):
            if let fraction {
                progress = min(max(fraction, 0), 1)
                isIndeterminate = false
            } else if let part, let total, total > 0 {
                progress = min(max(Double(part) / Double(total), 0), 1)
                isIndeterminate = false
            } else {
                progress = nil
                isIndeterminate = true
            }
        case let .retrying(attempt, maximum):
            progress = maximum > 0
                ? min(max(Double(max(attempt - 1, 0)) / Double(maximum), 0), 1)
                : nil
            isIndeterminate = maximum <= 0
        case .transcribing:
            progress = snapshot.progress > 0 ? snapshot.progress : nil
            isIndeterminate = progress == nil
        case .preparing, .finalizingAudio, .exporting, .saving:
            progress = nil
            isIndeterminate = snapshot.phase != nil
        case .recording, .cancelling, nil:
            progress = nil
            isIndeterminate = false
        }

        durationText = snapshot.phase == .recording && snapshot.duration > 0
            ? Self.formatDuration(snapshot.duration)
            : nil

        switch action {
        case .start:
            helpText = "Start recording"
        case .stop:
            helpText = "Stop recording"
        case .cancel:
            helpText = "Cancel \(phaseText.lowercased())"
        case .none:
        helpText = phaseText
        }
    }

    private static func terminalAccessibilityLabel(
        _ outcome: DictationSessionTerminalOutcome
    ) -> String {
        switch outcome {
        case .succeeded:
            return "Transcription completed"
        case .succeededWithHistoryWarning:
            return "Transcription completed with a history warning"
        case .failed:
            return "Transcription failed"
        case .cancelled:
            return "Transcription cancelled"
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let safeDuration = max(0, duration)
        let minutes = Int(safeDuration) / 60
        let seconds = Int(safeDuration.rounded(.down)) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

typealias SessionPresentation = DictationSessionPresentation

struct DictationProgressView: View {
    let presentation: DictationSessionPresentation

    var body: some View {
        if presentation.isIndeterminate || presentation.progress == nil {
            ProgressView()
                .controlSize(.small)
        } else {
            ProgressView(value: presentation.progress ?? 0)
                .progressViewStyle(.linear)
        }
    }
}

// MARK: - Main window model

@MainActor
final class ContentViewModel: ObservableObject {
    let sessionController: DictationSessionController
    let recordingStore: RecordingStore

    init(
        sessionController: DictationSessionController? = nil,
        recordingStore: RecordingStore? = nil
    ) {
        self.sessionController = sessionController ?? .shared
        self.recordingStore = recordingStore ?? .shared
    }

    var snapshot: DictationSessionSnapshot { sessionController.snapshot }
    var presentation: DictationSessionPresentation { .init(snapshot) }
    var state: DictationSessionController.State { sessionController.state }
    var errorMessage: String? { sessionController.errorMessage }

    func handleRecordButtonTap() {
        let snapshot = sessionController.snapshot
        switch snapshot.controlAction {
        case .start:
            _ = sessionController.startRecording(source: .mainWindow)
        case .stop:
            if snapshot.token != nil {
                sessionController.stopRecording()
            }
        case .cancel:
            if let token = snapshot.token {
                _ = sessionController.cancelRecording(token: token)
            }
        case .none:
            break
        }
    }

    func dismissError() { sessionController.dismissError() }

    @discardableResult
    func retryHistory() async -> RecordingHistoryStatus {
        await recordingStore.retry()
    }

    @discardableResult
    func deleteAllRecordings() async -> RecordingBulkDeletionResult {
        await recordingStore.deleteAllRecordingsAndAwait()
    }
}

// MARK: - Main window

struct ContentView: View {
    @StateObject private var viewModel: ContentViewModel
    @StateObject private var fileDropHandler: FileDropHandler
    @ObservedObject private var sessionController: DictationSessionController
    @ObservedObject private var recordingStore: RecordingStore
    @StateObject private var permissionsManager = PermissionsManager()
    @StateObject private var retentionCoordinator: RecordingRetentionCoordinator
    @State private var isSettingsPresented = false
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false
    @State private var isDeletingAll = false
    @State private var showDeleteAllRecoveryConfirmation = false
    @State private var isDeletingAllRecovery = false
    @State private var historyActionMessage: String?
    @State private var initialRetentionPreview: RecordingRetentionPreview?
    @State private var showInitialRetentionConfirmation = false
    @State private var isPreparingInitialRetentionConfirmation = false

    init(
        sessionController: DictationSessionController? = nil,
        recordingStore: RecordingStore? = nil
    ) {
        let model = ContentViewModel(
            sessionController: sessionController,
            recordingStore: recordingStore
        )
        _viewModel = StateObject(wrappedValue: model)
        _fileDropHandler = StateObject(
            wrappedValue: FileDropHandler(sessionController: model.sessionController)
        )
        _sessionController = ObservedObject(wrappedValue: model.sessionController)
        _recordingStore = ObservedObject(wrappedValue: model.recordingStore)
        _retentionCoordinator = StateObject(
            wrappedValue: RecordingRetentionCoordinator(recordingStore: model.recordingStore)
        )
    }

    private var filteredRecordings: [Recording] {
        searchText.isEmpty
            ? recordingStore.recordings
            : recordingStore.searchRecordings(query: searchText)
    }

    private var permissionsGranted: Bool {
        if ProcessInfo.processInfo.arguments.contains("--open-super-whisper-ui-test") {
            return true
        }
        return permissionsManager.isMicrophonePermissionGranted
            && permissionsManager.isAccessibilityPermissionGranted
    }

    var body: some View {
        VStack(spacing: 0) {
            if !permissionsGranted {
                PermissionsView(permissionsManager: permissionsManager)
            } else {
                mainContent
            }
        }
        .frame(minWidth: 400, idealWidth: 450)
        .background(Color(NSColor.windowBackgroundColor))
        .modifier(
            FileDropOverlay(
                handler: fileDropHandler,
                sessionController: sessionController
            )
        )
        .alert(
            "Transcription Error",
            isPresented: Binding(
                get: { sessionController.errorMessage != nil },
                set: { if !$0 { viewModel.dismissError() } }
            ),
            actions: {
                Button("OK", role: .cancel) { viewModel.dismissError() }
            },
            message: { Text(sessionController.errorMessage ?? "Something went wrong.") }
        )
        .alert(
            "History action failed",
            isPresented: Binding(
                get: { historyActionMessage != nil },
                set: { if !$0 { historyActionMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(historyActionMessage ?? "History needs repair.") }
        )
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(
                recordingStore: recordingStore,
                retentionCoordinator: retentionCoordinator
            )
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            searchBar
            historyContent
            recordControls
        }
        .overlay {
            let presentation = viewModel.presentation
            if presentation.isBusy,
               sessionController.snapshot.presentationOwner != .fileDrop {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 14) {
                        DictationProgressView(presentation: presentation)
                            .frame(width: 240)
                        Text(presentation.phaseText)
                            .foregroundColor(.white)
                            .font(.headline)
                        if let duration = presentation.durationText {
                            Text(duration)
                                .foregroundColor(.white.opacity(0.9))
                                .font(.system(.body, design: .monospaced))
                        }
                        if !presentation.interimText.isEmpty {
                            Text(presentation.interimText)
                                .foregroundColor(.white.opacity(0.9))
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .frame(maxWidth: 320)
                        }
                        if presentation.canCancel {
                            Button(presentation.accessibilityLabel) {
                                viewModel.handleRecordButtonTap()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        } else if sessionController.snapshot.phase == .cancelling {
                            Text("Cancelling…")
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }
                    .padding(24)
                }
                .ignoresSafeArea()
            }
        }
        .onAppear {
            retentionCoordinator.start()
            handleHistoryBecameUsable()
        }
        .onDisappear {
            retentionCoordinator.stop()
        }
        .onChange(of: recordingStore.status) { _, status in
            guard status.isAvailable else { return }
            handleHistoryBecameUsable()
        }
        .alert(
            "Review recording retention",
            isPresented: $showInitialRetentionConfirmation
        ) {
            Button("Keep current policy", role: .destructive) {
                let now = Date()
                Task { @MainActor in
                    _ = await retentionCoordinator.approveInitialConfirmation(now: now)
                    initialRetentionPreview = nil
                }
            }
            Button("Keep Forever") {
                let now = Date()
                Task { @MainActor in
                    _ = await retentionCoordinator.declineInitialConfirmation(now: now)
                    initialRetentionPreview = nil
                }
            }
            Button("Later", role: .cancel) {
                retentionCoordinator.cancelInitialConfirmation()
            }
        } message: {
            Text(initialRetentionConfirmationMessage)
        }
    }

    private var initialRetentionConfirmationMessage: String {
        let policy = AppPreferences.shared.recordingRetentionPolicy
        guard let preview = initialRetentionPreview else {
            return "Review how long recordings are kept. Audio, transcript, and the history entry are deleted together when a recording expires. Future recordings will be deleted after the selected retention period, even when none are eligible today."
        }
        let currentMessage = RecordingRetentionCoordinator.confirmationMessage(
            preview: preview,
            policy: policy
        )
        return "\(currentMessage) This setting applies to future recordings too."
    }

    private func handleHistoryBecameUsable() {
        guard recordingStore.status.isAvailable else { return }
        retentionCoordinator.historyDidLoad()
        guard AppPreferences.shared.recordingRetentionNeedsInitialConfirmation,
              !showInitialRetentionConfirmation,
              !isPreparingInitialRetentionConfirmation else { return }

        isPreparingInitialRetentionConfirmation = true
        let policy = AppPreferences.shared.recordingRetentionPolicy
        Task { @MainActor in
            let preview = await retentionCoordinator.preview(policy: policy)
            isPreparingInitialRetentionConfirmation = false
            initialRetentionPreview = preview.error == nil ? preview : nil
            showInitialRetentionConfirmation = true
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search in transcriptions", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(20)
        .padding([.horizontal, .top])
    }

    private var historyContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                recoveryStatusView
                historyStatusView

                if filteredRecordings.isEmpty {
                    emptyHistoryView
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredRecordings) { recording in
                            RecordingRow(recording: recording, recordingStore: recordingStore)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(NSColor.windowBackgroundColor),
                    Color(NSColor.windowBackgroundColor).opacity(0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 20)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var recoveryStatusView: some View {
        let artifacts = recordingStore.recoveryItems
        let reconciliationErrors = recordingStore.reconciliationReport.errors
        if !artifacts.isEmpty || !reconciliationErrors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Recovery needs attention", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.headline)
                if !artifacts.isEmpty {
                    Text("\(artifacts.count) preserved recording\(artifacts.count == 1 ? "" : "s") need review.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(artifacts) { artifact in
                            RecoveryArtifactRow(
                                artifact: artifact,
                                recordingStore: recordingStore
                            )
                        }
                    }
                }
                if !reconciliationErrors.isEmpty {
                    Text(reconciliationErrors.joined(separator: "; "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Open Recovery Folder") {
                        NSWorkspace.shared.open(recordingStore.recoveryDirectory)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Open Recovery folder")

                    if !artifacts.isEmpty {
                        Button {
                            showDeleteAllRecoveryConfirmation = true
                        } label: {
                            if isDeletingAllRecovery {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Delete All Recovered…")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDeletingAllRecovery)
                        .confirmationDialog(
                            "Delete all recovered recordings?",
                            isPresented: $showDeleteAllRecoveryConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button(
                                "Delete \(artifacts.count) Recovered Recordings",
                                role: .destructive
                            ) {
                                isDeletingAllRecovery = true
                                Task { @MainActor in
                                    let results = await recordingStore
                                        .deleteAllRecoveryArtifactsAndAwait()
                                    isDeletingAllRecovery = false
                                    let failures = results.filter { !$0.succeeded }
                                    if !failures.isEmpty {
                                        historyActionMessage = "\(failures.count) recovered recording\(failures.count == 1 ? "" : "s") could not be deleted."
                                    }
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This permanently removes all preserved audio and Recovery sidecars. This action cannot be undone.")
                        }
                        .accessibilityLabel("Delete all recovered recordings")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(10)
            .padding(.horizontal)
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var historyStatusView: some View {
        switch recordingStore.status {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading history…")
            }
            .foregroundColor(.secondary)
            .padding(.top, 24)
        case let .staleWithError(message):
            HistoryStatusBanner(
                title: "History may be stale",
                message: message,
                retry: viewModel.retryHistory
            )
        case let .unavailable(message):
            HistoryStatusBanner(
                title: "History unavailable",
                message: message,
                retry: viewModel.retryHistory
            )
        case .available:
            EmptyView()
        }
    }

    @ViewBuilder
    private var emptyHistoryView: some View {
        if !searchText.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("No results found").font(.headline).foregroundColor(.secondary)
                Text("Try different search terms")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("No recordings yet")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Press the record button below to get started")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
                    Text("Shortcut: \(shortcut.description)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 10)
                }
            }
            .padding(.top, 40)
        }
    }

    private var recordControls: some View {
        let presentation = viewModel.presentation
        return VStack(spacing: 14) {
            Button {
                viewModel.handleRecordButtonTap()
            } label: {
                switch presentation.action {
                case .start, .stop:
                    MainRecordButton(isRecording: presentation.action == .stop)
                case .cancel, .none:
                    VStack(spacing: 5) {
                        DictationProgressView(presentation: presentation)
                            .frame(width: 48, height: 48)
                        Text(presentation.phaseText)
                            .font(.caption.weight(.semibold))
                    }
                    .frame(minWidth: 90, minHeight: 64)
                }
            }
            .buttonStyle(.plain)
            .disabled(presentation.action == .none)
            .accessibilityLabel(presentation.accessibilityLabel)
            .help(presentation.helpText)

            if let duration = presentation.durationText {
                Text(duration)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Recording duration \(duration)")
            }

            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
                        Label("\(shortcut.description) to show mini recorder", systemImage: "command")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Label("Drop audio file to transcribe", systemImage: "arrow.down.doc.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !recordingStore.recordings.isEmpty {
                    Button("Clear History") { showDeleteConfirmation = true }
                        .buttonStyle(.plain)
                        .disabled(isDeletingAll)
                        .confirmationDialog(
                            "Delete All History",
                            isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Delete All", role: .destructive) {
                                isDeletingAll = true
                                Task { @MainActor in
                                    let result = await viewModel.deleteAllRecordings()
                                    isDeletingAll = false
                                    if let error = result.error {
                                        historyActionMessage = error.localizedDescription
                                    } else if let repair = result.results.first(where: \.requiresRepair) {
                                        historyActionMessage = repair.error?.localizedDescription
                                            ?? "Some recording files need repair."
                                    }
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This removes the selected history and its managed audio files.")
                        }
                        .accessibilityLabel("Delete all history recordings")
                }

                Button {
                    isSettingsPresented.toggle()
                } label: {
                    Image(systemName: "gear")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
        }
        .padding()
    }
}

/// A single Recovery item is independently actionable. Deleting one item
/// must not hide the other artifacts or require users to manage the folder in
/// Finder, while all destructive filesystem work remains owned by the store.
struct RecoveryArtifactRow: View {
    let artifact: RecordingRecoveryArtifact
    @ObservedObject var recordingStore: RecordingStore
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var actionError: String?

    private var displayURL: URL? {
        artifact.recoveryURL ?? artifact.transcriptURL ?? artifact.metadataURL
    }

    private var displayName: String {
        displayURL?.lastPathComponent
            ?? artifact.originalURL.lastPathComponent
    }

    private var kindDescription: String {
        switch artifact.kind {
        case .orphanAudio:
            return "Orphaned audio"
        case .temporaryCapture:
            return "Unfinished capture"
        case .pendingDeletion:
            return "Pending deletion"
        case .preservedAfterPersistenceFailure:
            return "Preserved after history failure"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "waveform.badge.exclamationmark")
                .foregroundColor(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kindDescription)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            if let displayURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([displayURL])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Reveal recovered file")
                .accessibilityLabel("Reveal recovered file \(displayName)")
            }

            Button {
                showDeleteConfirmation = true
            } label: {
                if isDeleting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(isDeleting)
            .help("Delete recovered artifact")
            .accessibilityLabel("Delete recovered artifact \(displayName)")
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Delete recovered artifact?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteArtifact()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the preserved audio and any Recovery sidecars. This action cannot be undone.")
        }
        .alert(
            "Recovery action failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(actionError ?? "The Recovery artifact could not be removed.") }
        )
    }

    private func deleteArtifact() {
        guard !isDeleting else { return }
        isDeleting = true
        Task { @MainActor in
            let result = await recordingStore.deleteRecoveryArtifactAndAwait(artifact)
            isDeleting = false
            if !result.succeeded {
                actionError = result.error?.localizedDescription
                    ?? "The Recovery artifact could not be removed."
            }
        }
    }
}

struct HistoryStatusBanner: View {
    let title: String
    let message: String
    let retry: () async -> RecordingHistoryStatus
    @State private var isRetrying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            Button {
                isRetrying = true
                Task { @MainActor in
                    _ = await retry()
                    isRetrying = false
                }
            } label: {
                if isRetrying {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Retry")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(10)
        .padding(.horizontal)
        .padding(.top, 12)
    }
}

// MARK: - Permissions

struct PermissionsView: View {
    @ObservedObject var permissionsManager: PermissionsManager

    var body: some View {
        VStack(spacing: 20) {
            Text("Required Permissions")
                .font(.title)
                .padding()
            PermissionRow(
                isGranted: permissionsManager.isMicrophonePermissionGranted,
                title: "Microphone Access",
                description: "Required for audio recording",
                action: { permissionsManager.requestMicrophonePermissionOrOpenSystemPreferences() }
            )
            PermissionRow(
                isGranted: permissionsManager.isAccessibilityPermissionGranted,
                title: "Accessibility Access",
                description: "Required for global keyboard shortcuts",
                action: { permissionsManager.requestAccessibilityPermission() }
            )
            Spacer()
        }
        .padding()
    }
}

struct PermissionRow: View {
    let isGranted: Bool
    let title: String
    let description: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isGranted ? .green : .red)
                Text(title).font(.headline)
                Spacer()
                if !isGranted {
                    Button("Grant Access", action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

// MARK: - History rows

struct RecordingRow: View {
    let recording: Recording
    @ObservedObject var recordingStore: RecordingStore
    @StateObject private var audioRecorder = AudioRecorder.shared
    @State private var showTranscription = false
    @State private var showTimingDetails = false
    @State private var isHovered = false
    @State private var isDeleting = false
    @State private var isRepairingAudio = false
    @State private var actionError: String?
    @AppStorage("showTimingDetailsInHistory") private var showTimingDetailsInHistory = false

    private var availability: RecordingAvailability {
        recordingStore.availability(for: recording)
    }

    private var isPlaying: Bool {
        audioRecorder.isPlaying
            && audioRecorder.currentlyPlayingURL == availability.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TranscriptionView(
                transcribedText: recording.transcription,
                isExpanded: $showTranscription
            )
            .padding(.horizontal, 4)
            .padding(.top, 8)

            if !recording.transcriptSegments.isEmpty && showTimingDetailsInHistory {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showTimingDetails.toggle()
                        }
                    } label: {
                        Label(
                            showTimingDetails ? "Hide timing details" : "Show timing details",
                            systemImage: showTimingDetails ? "clock.badge.xmark" : "clock"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    if showTimingDetails {
                        ForEach(Array(recording.transcriptSegments.enumerated()), id: \.offset) { _, segment in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Self.timeRangeDescription(for: segment))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 92, alignment: .leading)
                                Text(segment.text)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }

            Divider().padding(.horizontal, 12).padding(.vertical, 8)

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.timestamp, style: .date)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(recording.timestamp, style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if availability.isMissing {
                    Label("Audio unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button {
                        chooseReplacementAudio()
                    } label: {
                        if isRepairingAudio {
                            ProgressView()
                                .controlSize(.small)
                            Text("Repairing…")
                        } else {
                            Text("Locate Audio…")
                        }
                    }
                        .buttonStyle(.plain)
                        .disabled(isRepairingAudio)
                        .accessibilityLabel(
                            isRepairingAudio ? "Repairing missing audio" : "Locate missing audio"
                        )
                }
                if isHovered || isPlaying || availability.isMissing {
                    HStack(spacing: 14) {
                        if availability.isPlayable {
                            Button {
                                isPlaying
                                    ? audioRecorder.stopPlaying()
                                    : audioRecorder.playRecording(url: availability.url)
                            } label: {
                                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(isPlaying ? .red : .accentColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isPlaying ? "Stop playback" : "Play recording")
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(recording.transcription, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy entire text")
                        .accessibilityLabel("Copy transcription")

                        Button {
                            if isPlaying { audioRecorder.stopPlaying() }
                            isDeleting = true
                            Task { @MainActor in
                                let result = await recordingStore.deleteRecordingAndAwait(recording)
                                isDeleting = false
                                if !result.succeeded {
                                    actionError = result.error?.localizedDescription
                                        ?? "The recording could not be removed."
                                } else if result.requiresRepair {
                                    actionError = result.error?.localizedDescription
                                        ?? "The recording was removed, but cleanup needs repair."
                                }
                            }
                        } label: {
                            if isDeleting {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting)
                        .accessibilityLabel("Delete recording")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) { isHovered = hovering }
        }
        .padding(.vertical, 4)
        .alert(
            "Recording action failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(actionError ?? "The recording needs repair.") }
        )
    }

    private func chooseReplacementAudio() {
        guard !isRepairingAudio else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.title = "Locate Recording Audio"
        panel.message = "Choose the original audio file for this recording."

        panel.begin { response in
            guard response == .OK, let sourceURL = panel.url else { return }
            Task { @MainActor in
                await repairAudio(from: sourceURL)
            }
        }
    }

    private func repairAudio(from sourceURL: URL) async {
        guard !isRepairingAudio else { return }
        isRepairingAudio = true
        let result = await recordingStore.restoreMissingAudio(
            for: recording,
            from: sourceURL
        )
        isRepairingAudio = false

        if result.succeeded {
            _ = await recordingStore.loadRecordings()
        } else {
            actionError = result.error?.localizedDescription
                ?? "The missing audio could not be restored."
        }
    }

    private static func timeRangeDescription(for segment: TranscriptSegment) -> String {
        func format(_ seconds: TimeInterval) -> String {
            let safeSeconds = max(0, seconds)
            let minutes = Int(safeSeconds) / 60
            let remainder = safeSeconds - Double(minutes * 60)
            return String(format: "%02d:%04.1f", minutes, remainder)
        }
        return "\(format(segment.startTime)) – \(format(segment.endTime))"
    }
}

struct TranscriptionView: View {
    let transcribedText: String
    @Binding var isExpanded: Bool

    private var hasMoreLines: Bool {
        !transcribedText.isEmpty && transcribedText.count > 150
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isExpanded {
                TextEditor(text: .constant(transcribedText))
                    .font(.body)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 100, maxHeight: 200)
                    .scrollContentBackground(.hidden)
            } else {
                Text(transcribedText)
                    .font(.body)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .contentShape(Rectangle())
                    .onTapGesture { if hasMoreLines { isExpanded.toggle() } }
            }
            if hasMoreLines {
                Button { isExpanded.toggle() } label: {
                    Label(isExpanded ? "Show less" : "Show more", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.blue)
                        .font(.footnote)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
    }
}

struct MainRecordButton: View {
    let isRecording: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var buttonColor: Color {
        colorScheme == .dark ? .white : .gray
    }

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        isRecording ? Color.red.opacity(0.8) : buttonColor.opacity(0.8),
                        isRecording ? Color.red : buttonColor.opacity(0.9)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 48, height: 48)
            .shadow(
                color: isRecording ? .red.opacity(0.5) : buttonColor.opacity(0.3),
                radius: 12
            )
            .overlay {
                Circle().stroke(
                    isRecording ? Color.red.opacity(0.55) : buttonColor.opacity(0.55),
                    lineWidth: 1
                )
            }
            .scaleEffect(isRecording ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRecording)
    }
}

#Preview {
    ContentView()
}
