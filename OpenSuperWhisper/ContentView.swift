//
//  ContentView.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import Combine
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class ContentViewModel: ObservableObject {
    let sessionController: DictationSessionController
    @Published var recordingStore: RecordingStore

    private var controllerCancellable: AnyCancellable?

    init(sessionController: DictationSessionController? = nil) {
        let resolvedController = sessionController ?? DictationSessionController.shared
        self.sessionController = resolvedController
        self.recordingStore = RecordingStore.shared
        controllerCancellable = resolvedController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var state: DictationSessionController.State { sessionController.state }
    var isRecording: Bool { sessionController.state == .recording }
    var isPreparing: Bool { sessionController.state == .preparing }
    var isProcessing: Bool { sessionController.state.isBusy && !isRecording }
    var recordingDuration: TimeInterval { sessionController.recordingDuration }
    var interimText: String { sessionController.interimText }
    var errorMessage: String? { sessionController.errorMessage }
    var isShowingError: Bool {
        if case .failed = sessionController.state { return true }
        return sessionController.errorMessage != nil
    }

    func startRecording() {
        sessionController.startRecording()
    }

    func startDecoding() {
        sessionController.stopRecording()
    }

    /// Handles the main record control without ever starting a new operation
    /// while an existing finalization or transcription is in flight.
    func handleRecordButtonTap() {
        switch sessionController.state {
        case .recording:
            startDecoding()
        case .preparing:
            sessionController.cancelRecording()
        case .finalizing, .transcribing:
            break
        case .idle, .succeeded, .failed(_), .cancelled:
            startRecording()
        }
    }

    func dismissError() {
        sessionController.dismissError()
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @StateObject private var permissionsManager = PermissionsManager()
    @State private var isSettingsPresented = false
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false

    private var filteredRecordings: [Recording] {
        if searchText.isEmpty {
            return viewModel.recordingStore.recordings
        } else {
            return viewModel.recordingStore.searchRecordings(query: searchText)
        }
    }

    var body: some View {
        VStack {
            if !permissionsManager.isMicrophonePermissionGranted
                || !permissionsManager.isAccessibilityPermissionGranted
            {
                PermissionsView(permissionsManager: permissionsManager)
            } else {
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)

                        TextField("Search in transcriptions", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())

                        if !searchText.isEmpty {
                            Button(action: {
                                searchText = ""
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .imageScale(.medium)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(20)
                    .padding([.horizontal, .top])

                    ScrollView(showsIndicators: false) {
                        if filteredRecordings.isEmpty {
                            VStack(spacing: 16) {
                                if !searchText.isEmpty {
                                    // Show "no results" for search
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 40))
                                        .foregroundColor(.secondary)
                                        .padding(.top, 40)

                                    Text("No results found")
                                        .font(.headline)
                                        .foregroundColor(.secondary)

                                    Text("Try different search terms")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)
                                } else {
                                    // Show "start recording" tip
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: 40))
                                        .foregroundColor(.secondary)
                                        .padding(.top, 40)

                                    Text("No recordings yet")
                                        .font(.headline)
                                        .foregroundColor(.secondary)

                                    Text("Tap the record button below to get started")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)

                                    if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
                                        VStack(spacing: 8) {
                                            Text("Pro Tip:")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)

                                            HStack(spacing: 4) {
                                                Text("Press")
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)
                                                Text(shortcut.description)
                                                    .font(.system(size: 16, weight: .medium))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 3)
                                                    .background(Color.secondary.opacity(0.2))
                                                    .cornerRadius(6)
                                                Text("anywhere")
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)
                                            }

                                            Text("to quickly record and paste text")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.top, 16)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(filteredRecordings) { recording in
                                    RecordingRow(recording: recording)
                                        .transition(.asymmetric(
                                            insertion: .scale.combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.8))
                                        ))
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 16)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: filteredRecordings)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: searchText)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(NSColor.windowBackgroundColor).opacity(1),
                                        Color(NSColor.windowBackgroundColor).opacity(0)
                                    ]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 20)
                    }

                    VStack(spacing: 16) {
                        // Кнопка записи по центру
                        Button(action: {
                            viewModel.handleRecordButtonTap()
                        }) {
                            if viewModel.isPreparing {
                                MainRecordButton(isRecording: false)
                                    .overlay {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                            } else if viewModel.isProcessing {
                                // Show progress indicator ONLY when transcribing
                                ProgressView()
                                    .scaleEffect(1.0) // Smaller size
                                    .frame(width: 48, height: 48)
                                    .contentTransition(.symbolEffect(.replace))
                            } else {
                                // Show regular record button for idle state AND recording
                                MainRecordButton(isRecording: viewModel.isRecording)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isProcessing && !viewModel.isPreparing)
                        .accessibilityLabel(
                            viewModel.isPreparing ? "Cancel preparation" : "Record"
                        )
                        .help(viewModel.isPreparing ? "Cancel preparation" : "Record")
                        .padding(.top, 24)
                        .padding(.bottom, 16)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isRecording)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.state)

                        // Нижняя панель с подсказкой и кнопками управления
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                // Подсказка о шорткате
                                HStack(spacing: 6) {
                                    if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
                                        Text(shortcut.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Text("to show mini recorder")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.leading, 4)

                                // Подсказка о drag-n-drop
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.doc.fill")
                                        .foregroundColor(.secondary)
                                        .imageScale(.medium)
                                    Text("Drop audio file here to transcribe")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.leading, 4)
                            }

                            Spacer()

                            // Кнопки управления
                            if !viewModel.recordingStore.recordings.isEmpty {
                                Button(action: {
                                    showDeleteConfirmation = true
                                }) {
                                    Text("Clear All")
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 16)
                                .confirmationDialog(
                                    "Delete All Recordings",
                                    isPresented: $showDeleteConfirmation,
                                    titleVisibility: .visible
                                ) {
                                    Button("Delete All", role: .destructive) {
                                        viewModel.recordingStore.deleteAllRecordings()
                                    }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("Are you sure you want to delete all recordings? This action cannot be undone.")
                                }
                                .interactiveDismissDisabled()

                            }
                            Button(action: {
                                isSettingsPresented.toggle()
                            }) {
                                Image(systemName: "gear")
                                    .font(.title2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 400, idealWidth: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay {
            let isPermissionsGranted = permissionsManager.isMicrophonePermissionGranted
                && permissionsManager.isAccessibilityPermissionGranted

            if viewModel.isProcessing && !viewModel.isPreparing && isPermissionsGranted {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Preparing transcription...")
                            .foregroundColor(.white)
                            .font(.headline)

                        if !viewModel.interimText.isEmpty {
                            Text(viewModel.interimText)
                                .foregroundColor(.white.opacity(0.9))
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .frame(maxWidth: 320)
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
        .fileDropHandler()
        .alert(
            "Transcription Error",
            isPresented: Binding(
                get: { viewModel.isShowingError },
                set: { presented in
                    if !presented {
                        viewModel.dismissError()
                    }
                }
            ),
            actions: {
                Button("OK", role: .cancel) {
                    viewModel.dismissError()
                }
            }, message: {
                Text(viewModel.errorMessage ?? "Something went wrong.")
            }
        )
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
    }
}

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
                action: {
                    permissionsManager.requestMicrophonePermissionOrOpenSystemPreferences()
                }
            )

            PermissionRow(
                isGranted: permissionsManager.isAccessibilityPermissionGranted,
                title: "Accessibility Access",
                description: "Required for global keyboard shortcuts",
                action: { permissionsManager.openSystemPreferences(for: .accessibility) }
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

                Text(title)
                    .font(.headline)

                Spacer()

                if !isGranted {
                    Button("Grant Access") {
                        action()
                    }
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

struct RecordingRow: View {
    let recording: Recording
    @StateObject private var audioRecorder = AudioRecorder.shared
    @StateObject private var recordingStore = RecordingStore.shared
    @State private var showTranscription = false
    @State private var showTimingDetails = false
    @State private var isHovered = false
    @AppStorage("showTimingDetailsInHistory") private var showTimingDetailsInHistory = false

    private var isPlaying: Bool {
        audioRecorder.isPlaying && audioRecorder.currentlyPlayingURL == recording.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TranscriptionView(
                transcribedText: recording.transcription, isExpanded: $showTranscription
            )
            .padding(.horizontal, 4)
            .padding(.top, 8)

            // Timing is history metadata, not transcript text.  Keep it
            // behind an explicit detail affordance and the user's preference
            // so timestamps never leak into copied or pasted text.
            if showTimingDetailsInHistory && !recording.transcriptSegments.isEmpty {
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
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)

                    if showTimingDetails {
                        VStack(alignment: .leading, spacing: 4) {
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
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

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

                HStack(spacing: 16) {
                    if isHovered || isPlaying {
                        Button(action: {
                            if isPlaying {
                                audioRecorder.stopPlaying()
                            } else {
                                audioRecorder.playRecording(url: recording.url)
                            }
                        }) {
                            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(isPlaying ? .red : .accentColor)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                recording.transcription, forType: .string
                            )
                        }) {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy entire text")

                        Button(action: {
                            if isPlaying {
                                audioRecorder.stopPlaying()
                            }
                            withAnimation(.easeInOut(duration: 0.3)) {
                                recordingStore.deleteRecording(recording)
                            }
                        }) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .padding(.vertical, 4)
        .transition(.scale.combined(with: .opacity))
    }

    private static func timeRangeDescription(for segment: TranscriptSegment) -> String {
        func format(_ seconds: TimeInterval) -> String {
            let safeSeconds = max(0, seconds)
            let minutes = Int(safeSeconds) / 60
            let remainingSeconds = safeSeconds - Double(minutes * 60)
            return String(format: "%02d:%04.1f", minutes, remainingSeconds)
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
            Group {
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
                        .onTapGesture {
                            if hasMoreLines {
                                isExpanded.toggle()
                            }
                        }
                }
            }
            .padding(8)

            if hasMoreLines {
                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Show less" : "Show more")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .foregroundColor(.blue)
                    .font(.footnote)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
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
                radius: 12,
                x: 0,
                y: 0
            )
            .overlay {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                isRecording ? .red.opacity(0.6) : buttonColor.opacity(0.6),
                                isRecording ? .red.opacity(0.3) : buttonColor.opacity(0.3)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .scaleEffect(isRecording ? 0.9 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRecording)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
