import SwiftUI

/// First-run setup asks for one language and prepares its Apple Speech asset.
/// The completed-onboarding flag is owned by `AppState` and is never reset by
/// locale migration, so existing users go straight back to the main app.
@MainActor
final class OnboardingViewModel: ObservableObject {
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
            status = nil
            errorMessage = nil
            refreshAssetStatus()
        }
    }

    @Published private(set) var availableLocaleIdentifiers: [String]
    @Published private(set) var status: AppleSpeechAssetStatus?
    @Published private(set) var isPreparing = false
    @Published var errorMessage: String?

    private let assetManager: any AppleSpeechAssetManaging
    private var refreshTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var refreshRequestID: AppleSpeechAssetRequestID?
    private var statusRequestID: AppleSpeechAssetRequestID?
    private var preparationRequestID: AppleSpeechAssetRequestID?
    private var applyingResolvedLocale = false

    init(assetManager: (any AppleSpeechAssetManaging)? = nil) {
        let resolvedAssetManager = assetManager ?? AppleSpeechAssetManager.shared
        let prefs = AppPreferences.shared
        self.selectedLocaleIdentifier = prefs.localeIdentifier
        self.availableLocaleIdentifiers = LanguageUtil.availableLocaleIdentifiers
        self.assetManager = resolvedAssetManager
    }

    deinit {
        refreshTask?.cancel()
        statusTask?.cancel()
        progressTask?.cancel()
        preparationTask?.cancel()
    }

    var selectedLocale: Locale { LanguageUtil.locale(for: selectedLocaleIdentifier) }
    var selectedLocaleDisplayName: String { LanguageUtil.displayName(for: selectedLocaleIdentifier) }
    var isReady: Bool { status?.isReady == true }

    func refresh() {
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
                availableLocaleIdentifiers = LanguageUtil.localeIdentifiers(for: locales)
                if !availableLocaleIdentifiers.contains(where: { $0.caseInsensitiveCompare(self.selectedLocaleIdentifier) == .orderedSame }) {
                    selectedLocaleIdentifier = LanguageUtil.defaultLocaleIdentifier
                }
            }
            guard self.refreshRequestID == requestID else { return }
            refreshAssetStatus()
        }
    }

    func refreshAssetStatus() {
        statusTask?.cancel()
        cancelProgressObservation()
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
            let refreshedStatus = await assetManager.status(for: locale, requestID: requestID)
            guard let self,
                  !Task.isCancelled,
                  self.statusRequestID == requestID,
                  requestedIdentifier.caseInsensitiveCompare(self.selectedLocaleIdentifier) == .orderedSame else {
                return
            }
            self.status = refreshedStatus
        }
    }

    func prepareAsset() {
        guard !isPreparing else { return }
        statusTask?.cancel()
        statusTask = nil
        statusRequestID = nil
        cancelProgressObservation()
        preparationTask?.cancel()
        if let oldRequestID = preparationRequestID {
            assetManager.cancelPreparation(requestID: oldRequestID)
        }
        let requestedLocale = selectedLocale
        let requestedIdentifier = LanguageUtil.localeIdentifier(for: requestedLocale)
        let requestID = AppleSpeechAssetRequestID()
        preparationRequestID = requestID
        isPreparing = true
        errorMessage = nil
        status = AppleSpeechAssetStatus(locale: requestedLocale, state: .downloading, progress: 0)
        observePreparationProgress(for: requestedIdentifier, requestID: requestID)

        let assetManager = self.assetManager
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.preparationRequestID == requestID {
                    self.isPreparing = false
                    self.preparationRequestID = nil
                    self.preparationTask = nil
                    self.cancelProgressObservation()
                }
            }
            do {
                let resolvedLocale = try await assetManager.prepare(
                    locale: requestedLocale,
                    requestID: requestID
                )
                guard !Task.isCancelled,
                      self.preparationRequestID == requestID,
                      requestedIdentifier.caseInsensitiveCompare(selectedLocaleIdentifier) == .orderedSame else {
                    return
                }
                let identifier = LanguageUtil.localeIdentifier(for: resolvedLocale)
                if identifier.caseInsensitiveCompare(selectedLocaleIdentifier) != .orderedSame {
                    self.applyingResolvedLocale = true
                    selectedLocaleIdentifier = identifier
                    self.applyingResolvedLocale = false
                }
                AppPreferences.shared.localeIdentifier = identifier
                let resolvedStatus = await assetManager.status(
                    for: resolvedLocale,
                    requestID: requestID
                )
                guard !Task.isCancelled, self.preparationRequestID == requestID else { return }
                status = resolvedStatus
            } catch is CancellationError {
                return
            } catch {
                guard self.preparationRequestID == requestID,
                      !Task.isCancelled,
                      requestedIdentifier.caseInsensitiveCompare(selectedLocaleIdentifier) == .orderedSame else {
                    return
                }
                errorMessage = error.localizedDescription
                status = AppleSpeechAssetStatus(
                    locale: requestedLocale,
                    state: .failed,
                    progress: 0,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private func observePreparationProgress(
        for requestedIdentifier: String,
        requestID: AppleSpeechAssetRequestID
    ) {
        let assetManager = self.assetManager
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self {
                    guard self.isPreparing,
                          self.preparationRequestID == requestID,
                          requestedIdentifier.caseInsensitiveCompare(self.selectedLocaleIdentifier) == .orderedSame else {
                        return
                    }

                    if let currentStatus = assetManager.currentStatus,
                       requestedIdentifier.caseInsensitiveCompare(
                           LanguageUtil.localeIdentifier(for: currentStatus.locale)
                       ) == .orderedSame {
                        // The manager is monotonic for an active request; the
                        // view model repeats the guard so an old polling task
                        // cannot project a late lower fraction.
                        if self.status?.localeIdentifier.caseInsensitiveCompare(currentStatus.localeIdentifier) != .orderedSame
                            || currentStatus.progress >= (self.status?.progress ?? 0) {
                            self.status = currentStatus
                        }
                    }
                } else {
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func cancelProgressObservation() {
        progressTask?.cancel()
        progressTask = nil
    }

    /// Cancels every asset task owned by the view model. The request ID is
    /// sent to the manager before the slot is cleared so a Speech install that
    /// is suspended in framework code cannot later commit as this view's work.
    func cancelAssetWork() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequestID = nil
        statusTask?.cancel()
        statusTask = nil
        statusRequestID = nil
        cancelProgressObservation()
        preparationTask?.cancel()
        if let preparationRequestID {
            assetManager.cancelPreparation(requestID: preparationRequestID)
        }
        preparationTask = nil
        preparationRequestID = nil
        isPreparing = false
    }
}

struct OnboardingView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("A private voice, ready when you are.")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("OpenSuperWhisper uses Apple Speech on your Mac so your words can stay on-device.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 12) {
                Text("Choose your speech language")
                    .font(.headline)
                Picker("Speech language", selection: $viewModel.selectedLocaleIdentifier) {
                    ForEach(viewModel.availableLocaleIdentifiers, id: \.self) { identifier in
                        Text(LanguageUtil.displayName(for: identifier))
                            .tag(identifier)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Speech language")
                Text("Apple Speech will use the closest supported regional voice for this locale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle)
                            .font(.headline)
                        Text(statusSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let status = viewModel.status, status.state == .downloading {
                    ProgressView(value: status.progress)
                        .progressViewStyle(.linear)
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.top, 14)

            Spacer(minLength: 20)

            HStack {
                Text("You can change this later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(buttonTitle) {
                    if viewModel.isReady {
                        appState.hasCompletedOnboarding = true
                    } else {
                        viewModel.prepareAsset()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isPreparing || isUnavailable)
            }
        }
        .padding(28)
        .frame(width: 450, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { viewModel.refresh() }
        .onDisappear { viewModel.cancelAssetWork() }
    }

    private var statusSymbol: String {
        switch viewModel.status?.state {
        case .installed: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .unsupported: return "nosign"
        case .supported, .none: return "icloud.and.arrow.down"
        }
    }

    private var statusColor: Color {
        switch viewModel.status?.state {
        case .installed: return .green
        case .downloading: return .accentColor
        case .failed, .unsupported: return .red
        case .supported, .none: return .secondary
        }
    }

    private var statusTitle: String {
        switch viewModel.status?.state {
        case .installed: return "Apple Speech is ready"
        case .downloading: return "Preparing \(viewModel.selectedLocaleDisplayName)…"
        case .failed: return "Could not prepare the language"
        case .unsupported: return "This locale is unavailable"
        case .supported: return "Ready to prepare Apple Speech"
        case .none: return "Checking Apple Speech availability…"
        }
    }

    private var statusSubtitle: String {
        switch viewModel.status?.state {
        case .installed: return "Your first dictation will work offline."
        case .downloading: return "This may take a moment; keep this window open."
        case .failed: return "Check your connection, then try again."
        case .unsupported: return "Choose another supported language."
        case .supported: return "Download the on-device language asset to continue."
        case .none: return "Checking the languages installed on this Mac."
        }
    }

    private var buttonTitle: String {
        if viewModel.isReady { return "Start dictating" }
        if viewModel.status?.state == .failed { return "Retry" }
        return "Prepare Apple Speech"
    }

    private var isUnavailable: Bool {
        viewModel.status?.state == .unsupported
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppState())
}
