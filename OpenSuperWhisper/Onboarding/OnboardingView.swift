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
            cancelProgressObservation()
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
    private var statusTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    init(assetManager: (any AppleSpeechAssetManaging)? = nil) {
        let resolvedAssetManager = assetManager ?? AppleSpeechAssetManager.shared
        let prefs = AppPreferences.shared
        self.selectedLocaleIdentifier = prefs.localeIdentifier
        self.availableLocaleIdentifiers = LanguageUtil.availableLocaleIdentifiers
        self.assetManager = resolvedAssetManager
    }

    var selectedLocale: Locale { LanguageUtil.locale(for: selectedLocaleIdentifier) }
    var selectedLocaleDisplayName: String { LanguageUtil.displayName(for: selectedLocaleIdentifier) }
    var isReady: Bool { status?.isReady == true }

    func refresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let locales = await assetManager.refresh()
            if !locales.isEmpty {
                availableLocaleIdentifiers = LanguageUtil.localeIdentifiers(for: locales)
                if !availableLocaleIdentifiers.contains(where: { $0.caseInsensitiveCompare(self.selectedLocaleIdentifier) == .orderedSame }) {
                    selectedLocaleIdentifier = LanguageUtil.defaultLocaleIdentifier
                }
            }
            refreshAssetStatus()
        }
    }

    func refreshAssetStatus() {
        statusTask?.cancel()
        cancelProgressObservation()
        let locale = selectedLocale
        let requestedIdentifier = LanguageUtil.localeIdentifier(for: locale)
        let assetManager = self.assetManager
        statusTask = Task { @MainActor [weak self] in
            let refreshedStatus = await assetManager.status(for: locale)
            guard let self,
                  !Task.isCancelled,
                  requestedIdentifier.caseInsensitiveCompare(selectedLocaleIdentifier) == .orderedSame else {
                return
            }
            status = refreshedStatus
        }
    }

    func prepareAsset() {
        guard !isPreparing else { return }
        statusTask?.cancel()
        statusTask = nil
        cancelProgressObservation()
        let requestedLocale = selectedLocale
        let requestedIdentifier = LanguageUtil.localeIdentifier(for: requestedLocale)
        isPreparing = true
        errorMessage = nil
        status = AppleSpeechAssetStatus(locale: requestedLocale, state: .downloading, progress: 0)
        observePreparationProgress(for: requestedIdentifier)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                isPreparing = false
                cancelProgressObservation()
            }
            do {
                let resolvedLocale = try await assetManager.prepare(locale: requestedLocale)
                guard requestedIdentifier.caseInsensitiveCompare(selectedLocaleIdentifier) == .orderedSame else {
                    return
                }
                let identifier = LanguageUtil.localeIdentifier(for: resolvedLocale)
                if identifier.caseInsensitiveCompare(selectedLocaleIdentifier) != .orderedSame {
                    selectedLocaleIdentifier = identifier
                }
                AppPreferences.shared.localeIdentifier = identifier
                status = await assetManager.status(for: resolvedLocale)
            } catch is CancellationError {
                return
            } catch {
                guard requestedIdentifier.caseInsensitiveCompare(selectedLocaleIdentifier) == .orderedSame else {
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

    private func observePreparationProgress(for requestedIdentifier: String) {
        let assetManager = self.assetManager
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self {
                    guard self.isPreparing,
                          requestedIdentifier.caseInsensitiveCompare(self.selectedLocaleIdentifier) == .orderedSame else {
                        return
                    }

                    if let currentStatus = assetManager.currentStatus,
                       requestedIdentifier.caseInsensitiveCompare(
                           LanguageUtil.localeIdentifier(for: currentStatus.locale)
                       ) == .orderedSame {
                        self.status = currentStatus
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
