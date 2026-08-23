import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var transcriptionBackend: TranscriptionBackend {
        didSet {
            AppPreferences.shared.transcriptionBackend = transcriptionBackend
            if transcriptionBackend != .appleSpeech {
                cancelAssetWork()
            }
        }
    }

    @Published var selectedLocaleIdentifier: String {
        didSet {
            let normalized = LanguageUtil.normalizedLocaleIdentifier(selectedLocaleIdentifier)
            if normalized != selectedLocaleIdentifier {
                selectedLocaleIdentifier = normalized
                return
            }
            AppPreferences.shared.localeIdentifier = normalized
            guard !applyingResolvedLocale else { return }
            cancelAssetWork()
            if transcriptionBackend == .appleSpeech {
                refreshAppleSpeechAssets()
            }
        }
    }

    @Published private(set) var availableLocaleIdentifiers: [String]

    @Published var recognitionContext: String {
        didSet { AppPreferences.shared.recognitionContext = recognitionContext }
    }

    @Published var showTimingDetailsInHistory: Bool {
        didSet { AppPreferences.shared.showTimingDetailsInHistory = showTimingDetailsInHistory }
    }

    @Published var playSoundOnRecordStart: Bool {
        didSet { AppPreferences.shared.playSoundOnRecordStart = playSoundOnRecordStart }
    }

    @Published var debugMode: Bool {
        didSet { AppPreferences.shared.debugMode = debugMode }
    }

    @Published var openAIAPIKey: String = ""
    @Published var apiKeyStatusMessage: String?
    @Published var apiKeyStatusIsError = false

    @Published var openAIRetryCount: Int {
        didSet {
            let clamped = min(max(openAIRetryCount, 0), 5)
            if openAIRetryCount != clamped {
                openAIRetryCount = clamped
            } else {
                AppPreferences.shared.openAIRetryCount = clamped
            }
        }
    }

    @Published private(set) var appleSpeechAssetStatus: AppleSpeechAssetStatus?

    private let apiKeyStore = OpenAIAPIKeyStore.shared
    private let assetManager: any AppleSpeechAssetManaging
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var refreshRequestID: AppleSpeechAssetRequestID?
    private var statusRequestID: AppleSpeechAssetRequestID?
    private var preparationRequestID: AppleSpeechAssetRequestID?
    private var applyingResolvedLocale = false

    init(assetManager: (any AppleSpeechAssetManaging)? = nil) {
        let resolvedAssetManager = assetManager ?? AppleSpeechAssetManager.shared
        let prefs = AppPreferences.shared
        self.transcriptionBackend = prefs.transcriptionBackend
        self.selectedLocaleIdentifier = prefs.localeIdentifier
        self.availableLocaleIdentifiers = LanguageUtil.availableLocaleIdentifiers
        self.recognitionContext = prefs.recognitionContext
        self.showTimingDetailsInHistory = prefs.showTimingDetailsInHistory
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.debugMode = prefs.debugMode
        self.openAIRetryCount = min(max(prefs.openAIRetryCount, 0), 5)
        self.assetManager = resolvedAssetManager
        self.appleSpeechAssetStatus = nil
        self.openAIAPIKey = (try? apiKeyStore.loadKey()) ?? ""

        if let concreteManager = resolvedAssetManager as? AppleSpeechAssetManager {
            concreteManager.$currentStatus
                .receive(on: RunLoop.main)
                .sink { [weak self] status in
                    guard let self, let status else { return }
                    guard status.localeIdentifier.caseInsensitiveCompare(self.selectedLocaleIdentifier) == .orderedSame else {
                        return
                    }
                    self.appleSpeechAssetStatus = status
                }
                .store(in: &cancellables)
        }
    }

    deinit {
        refreshTask?.cancel()
        statusTask?.cancel()
        preparationTask?.cancel()
    }

    var selectedLocale: Locale { LanguageUtil.locale(for: selectedLocaleIdentifier) }

    var selectedLocaleDisplayName: String {
        LanguageUtil.displayName(for: selectedLocaleIdentifier)
    }

    func refreshAppleSpeechAssets() {
        refreshTask?.cancel()
        let requestID = AppleSpeechAssetRequestID()
        refreshRequestID = requestID
        let requestedIdentifier = selectedLocaleIdentifier
        let assetManager = self.assetManager
        refreshTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.refreshRequestID == requestID {
                    self.refreshTask = nil
                    self.refreshRequestID = nil
                }
            }
            guard let self else { return }
            let locales = await assetManager.refresh(requestID: requestID)
            guard !Task.isCancelled,
                  self.refreshRequestID == requestID,
                  requestedIdentifier.caseInsensitiveCompare(self.selectedLocaleIdentifier) == .orderedSame else {
                return
            }
            if !locales.isEmpty {
                let identifiers = LanguageUtil.localeIdentifiers(for: locales)
                availableLocaleIdentifiers = identifiers
                if !identifiers.contains(where: { $0.caseInsensitiveCompare(self.selectedLocaleIdentifier) == .orderedSame }) {
                    selectedLocaleIdentifier = LanguageUtil.defaultLocaleIdentifier
                }
            }
            guard self.refreshRequestID == requestID else { return }
            refreshAppleSpeechAssetStatus()
        }
    }

    func prepareAppleSpeechAsset() {
        statusTask?.cancel()
        statusTask = nil
        statusRequestID = nil
        preparationTask?.cancel()
        if let oldRequestID = preparationRequestID {
            assetManager.cancelPreparation(requestID: oldRequestID)
        }
        let requestedLocale = selectedLocale
        let requestedIdentifier = LanguageUtil.localeIdentifier(for: requestedLocale)
        let requestID = AppleSpeechAssetRequestID()
        preparationRequestID = requestID
        appleSpeechAssetStatus = AppleSpeechAssetStatus(
            locale: requestedLocale,
            state: .downloading,
            progress: 0
        )

        let assetManager = self.assetManager
        preparationTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.preparationRequestID == requestID {
                    self.preparationTask = nil
                    self.preparationRequestID = nil
                }
            }
            guard let self else { return }
            do {
                let resolved = try await assetManager.prepare(
                    locale: requestedLocale,
                    requestID: requestID
                )
                guard !Task.isCancelled,
                      self.preparationRequestID == requestID,
                      requestedIdentifier.caseInsensitiveCompare(selectedLocaleIdentifier) == .orderedSame else {
                    return
                }
                let identifier = LanguageUtil.localeIdentifier(for: resolved)
                if identifier.caseInsensitiveCompare(selectedLocaleIdentifier) != .orderedSame {
                    self.applyingResolvedLocale = true
                    selectedLocaleIdentifier = identifier
                    self.applyingResolvedLocale = false
                }
                let status = await assetManager.status(
                    for: resolved,
                    requestID: requestID
                )
                guard !Task.isCancelled,
                      self.preparationRequestID == requestID,
                      identifier.caseInsensitiveCompare(selectedLocaleIdentifier) == .orderedSame else {
                    return
                }
                appleSpeechAssetStatus = status
            } catch is CancellationError {
                // A cancelled preparation is not a failure; the next view
                // appearance can request it again.
            } catch {
                guard self.preparationRequestID == requestID,
                      !Task.isCancelled,
                      requestedIdentifier.caseInsensitiveCompare(selectedLocaleIdentifier) == .orderedSame else {
                    return
                }
                appleSpeechAssetStatus = AppleSpeechAssetStatus(
                    locale: requestedLocale,
                    state: .failed,
                    progress: 0,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    func persistOpenAIAPIKey() {
        let trimmed = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try apiKeyStore.deleteKey()
                openAIAPIKey = ""
                apiKeyStatusMessage = "Removed saved API key."
            } else {
                try apiKeyStore.saveKey(trimmed)
                openAIAPIKey = trimmed
                apiKeyStatusMessage = "API key saved securely."
            }
            apiKeyStatusIsError = false
        } catch {
            apiKeyStatusMessage = "Could not update API key (\(error.localizedDescription))."
            apiKeyStatusIsError = true
        }
    }

    func reloadOpenAIAPIKeyFromStore() {
        do {
            openAIAPIKey = try apiKeyStore.loadKey() ?? ""
            apiKeyStatusMessage = nil
            apiKeyStatusIsError = false
        } catch {
            apiKeyStatusMessage = "Could not read API key (\(error.localizedDescription))."
            apiKeyStatusIsError = true
        }
    }

    func clearAPIKeyStatus() {
        apiKeyStatusMessage = nil
        apiKeyStatusIsError = false
    }

    private func refreshAppleSpeechAssetStatus() {
        statusTask?.cancel()
        let requestID = AppleSpeechAssetRequestID()
        statusRequestID = requestID
        let locale = selectedLocale
        let requestedIdentifier = LanguageUtil.localeIdentifier(for: locale)
        let assetManager = self.assetManager
        statusTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.statusRequestID == requestID {
                    self.statusTask = nil
                    self.statusRequestID = nil
                }
            }
            let status = await assetManager.status(for: locale, requestID: requestID)
            guard let self,
                  !Task.isCancelled,
                  self.statusRequestID == requestID,
                  requestedIdentifier.caseInsensitiveCompare(self.selectedLocaleIdentifier) == .orderedSame else {
                return
            }
            self.appleSpeechAssetStatus = status
        }
    }

    /// Cancels all asset work started by this settings sheet. Explicitly
    /// notifying the manager closes the request even if Speech is suspended in
    /// an installation call that does not immediately observe task cancel.
    func cancelAssetWork() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequestID = nil
        statusTask?.cancel()
        statusTask = nil
        statusRequestID = nil
        preparationTask?.cancel()
        if let preparationRequestID {
            assetManager.cancelPreparation(requestID: preparationRequestID)
        }
        preparationTask = nil
        preparationRequestID = nil
    }
}

/// Configuration passed to transcription clients. It intentionally contains
/// provider-neutral values only; provider-specific model controls no longer
/// belong in user preferences.
struct Settings {
    var transcriptionBackend: TranscriptionBackend
    var localeIdentifier: String
    var recognitionContext: String
    var showTimingDetailsInHistory: Bool
    var debugMode: Bool
    var playSoundOnRecordStart: Bool
    var openAIRetryCount: Int

    init() {
        let prefs = AppPreferences.shared
        self.transcriptionBackend = prefs.transcriptionBackend
        self.localeIdentifier = prefs.localeIdentifier
        self.recognitionContext = prefs.recognitionContext
        self.showTimingDetailsInHistory = prefs.showTimingDetailsInHistory
        self.debugMode = prefs.debugMode
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.openAIRetryCount = min(max(prefs.openAIRetryCount, 0), 5)
    }

    var locale: Locale { LanguageUtil.locale(for: localeIdentifier) }
    var context: String? {
        let value = recognitionContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Expected terms are entered one per line in the shared context field.
    /// The engine can pass these through to either provider's vocabulary hint.
    var expectedTerms: [String] {
        recognitionContext
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            transcriptionSettings
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .tag(0)

            shortcutSettings
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag(1)

            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(2)
        }
        .padding(20)
        .frame(width: 620, height: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            viewModel.refreshAppleSpeechAssets()
            if viewModel.transcriptionBackend == .openAI {
                viewModel.reloadOpenAIAPIKeyFromStore()
            }
        }
        .onChange(of: viewModel.transcriptionBackend) { _, backend in
            if backend == .openAI {
                viewModel.reloadOpenAIAPIKeyFromStore()
            } else {
                viewModel.clearAPIKeyStatus()
                viewModel.refreshAppleSpeechAssets()
            }
        }
        .onDisappear { viewModel.cancelAssetWork() }
    }

    private var transcriptionSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsSection("Backend", caption: "Choose where completed recordings are transcribed.") {
                    Picker("Backend", selection: $viewModel.transcriptionBackend) {
                        ForEach(TranscriptionBackend.allCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(viewModel.transcriptionBackend.helpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsSection("Language", caption: "Apple Speech and OpenAI use this same BCP-47 locale.") {
                    Picker("Speech language", selection: $viewModel.selectedLocaleIdentifier) {
                        ForEach(viewModel.availableLocaleIdentifiers, id: \.self) { identifier in
                            Text(LanguageUtil.displayName(for: identifier))
                                .tag(identifier)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Speech language")
                }

                if viewModel.transcriptionBackend == .appleSpeech {
                    appleSpeechAssetSection
                } else {
                    openAISection
                }

                settingsSection("Expected vocabulary & context", caption: "Optional hints shared with the selected transcription provider. Put important terms on separate lines.") {
                    TextEditor(text: $viewModel.recognitionContext)
                        .font(.body)
                        .frame(minHeight: 96)
                        .padding(6)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25))
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var appleSpeechAssetSection: some View {
        settingsSection("Apple Speech language asset", caption: "The asset is downloaded once by macOS and then remains available for on-device transcription.") {
            HStack(spacing: 10) {
                Image(systemName: assetStatusSymbol)
                    .foregroundStyle(assetStatusColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(assetStatusTitle)
                        .font(.subheadline.weight(.medium))
                    if let message = viewModel.appleSpeechAssetStatus?.errorMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let status = viewModel.appleSpeechAssetStatus,
                              status.state == .downloading {
                        ProgressView(value: status.progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 250)
                    }
                }
                Spacer()
            }

            HStack {
                Text(viewModel.selectedLocaleDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if assetNeedsAction {
                    Button(assetActionTitle) {
                        if viewModel.appleSpeechAssetStatus?.state == .failed {
                            viewModel.prepareAppleSpeechAsset()
                        } else {
                            viewModel.prepareAppleSpeechAsset()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.appleSpeechAssetStatus?.state == .downloading)
                }
            }
        }
    }

    private var openAISection: some View {
        settingsSection("OpenAI API key", caption: "The key is stored in the macOS Keychain and used only for OpenAI uploads.") {
            SecureField("sk-…", text: $viewModel.openAIAPIKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: viewModel.openAIAPIKey) { _, _ in viewModel.clearAPIKeyStatus() }

            HStack {
                Button("Save key") { viewModel.persistOpenAIAPIKey() }
                    .buttonStyle(.borderedProminent)
                Button("Clear") {
                    viewModel.openAIAPIKey = ""
                    viewModel.persistOpenAIAPIKey()
                }
                .buttonStyle(.bordered)
                Spacer()
                Link("Manage keys", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.caption)
            }

            if let message = viewModel.apiKeyStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(viewModel.apiKeyStatusIsError ? .red : .secondary)
            }

            HStack {
                Text("Retry failed uploads")
                Spacer()
                Stepper(value: $viewModel.openAIRetryCount, in: 0...5) {
                    Text("\(viewModel.openAIRetryCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 125)
            }
        }
    }

    private var shortcutSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsSection("Recording shortcut", caption: "This shortcut works while OpenSuperWhisper is in the background.") {
                    HStack {
                        Text("Toggle recording")
                        Spacer()
                        KeyboardShortcuts.Recorder("", name: .toggleRecord)
                            .frame(width: 150)
                    }
                }

                settingsSection("Start behavior") {
                    Toggle("Play a sound when recording starts", isOn: $viewModel.playSoundOnRecordStart)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsSection("History", caption: "Timing details stay out of copied and pasted transcript text.") {
                    Toggle("Show timing details in history", isOn: $viewModel.showTimingDetailsInHistory)
                }

                settingsSection("Diagnostics") {
                    Toggle("Enable debug logging", isOn: $viewModel.debugMode)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ title: String,
        caption: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var assetStatusSymbol: String {
        switch viewModel.appleSpeechAssetStatus?.state {
        case .installed: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .unsupported: return "nosign"
        case .supported, .none: return "questionmark.circle"
        }
    }

    private var assetStatusColor: Color {
        switch viewModel.appleSpeechAssetStatus?.state {
        case .installed: return .green
        case .failed, .unsupported: return .red
        case .downloading: return .accentColor
        case .supported, .none: return .secondary
        }
    }

    private var assetStatusTitle: String {
        switch viewModel.appleSpeechAssetStatus?.state {
        case .installed: return "Ready on this Mac"
        case .downloading: return "Preparing language asset…"
        case .failed: return "Preparation failed"
        case .unsupported: return "Locale unavailable"
        case .supported: return "Ready to download"
        case .none: return "Checking availability…"
        }
    }

    private var assetActionTitle: String {
        viewModel.appleSpeechAssetStatus?.state == .failed ? "Retry" : "Prepare"
    }

    private var assetNeedsAction: Bool {
        switch viewModel.appleSpeechAssetStatus?.state {
        case .installed, .downloading, .unsupported: return false
        case .supported, .failed, .none: return true
        }
    }
}
