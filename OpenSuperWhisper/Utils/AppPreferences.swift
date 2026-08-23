import Foundation

/// The small portion of file management needed by the legacy migration. A
/// protocol keeps cleanup failure observable in tests without broadening the
/// migration's deletion scope.
protocol AppPreferencesFileOperations {
    func fileExists(atPath path: String) -> Bool
    func removeItem(at URL: URL) throws
}

extension FileManager: AppPreferencesFileOperations {}

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    let defaults: UserDefaults

    init(
        key: String,
        defaultValue: T,
        defaults: UserDefaults = .standard
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.defaults = defaults
    }

    var wrappedValue: T {
        get { defaults.object(forKey: key) as? T ?? defaultValue }
        set { defaults.set(newValue, forKey: key) }
    }
}

/// User-facing preferences. The migration is intentionally performed before
/// any property is read so new installations and upgrades share exactly the
/// same defaults.
final class AppPreferences {
    static let shared = AppPreferences()

    private enum Key {
        static let migrationCompleted = "appleSpeechPreferencesMigrationCompleted"
        static let transcriptionBackend = "transcriptionBackend"
        static let localeIdentifier = "localeIdentifier"
        static let recognitionContext = "recognitionContext"
        static let showTimingDetailsInHistory = "showTimingDetailsInHistory"
        static let debugMode = "debugMode"
        static let playSoundOnRecordStart = "playSoundOnRecordStart"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let openAIRetryCount = "openAIRetryCount"
        static let recordingRetentionDays = "recordingRetentionDays"
        static let recordingRetentionNeedsInitialConfirmation =
            "recordingRetentionNeedsInitialConfirmation"
        static let recordingRetentionLastSuccessfulSweep =
            "recordingRetentionLastSuccessfulSweep"
    }

    // These keys are intentionally stable. The identity migration uses the
    // exact confirmation key when it detects an existing installation.
    static let recordingRetentionDaysKey = Key.recordingRetentionDays
    static let recordingRetentionNeedsInitialConfirmationKey =
        Key.recordingRetentionNeedsInitialConfirmation
    static let recordingRetentionLastSuccessfulSweepKey =
        Key.recordingRetentionLastSuccessfulSweep

    /// This is deliberately the one exact path removed by the migration. Do
    /// not replace it with a recursive Application Support cleanup. The
    /// active application directory is used so the preference layer never
    /// embeds the pre-identity bundle identifier.
    static let legacyWhisperModelsDirectory = Recording.applicationDirectory
        .appendingPathComponent("whisper-models", isDirectory: true)

    private let defaults: UserDefaults

    @UserDefault(key: Key.transcriptionBackend, defaultValue: TranscriptionBackend.appleSpeech.rawValue)
    private var transcriptionBackendRawValue: String

    var transcriptionBackend: TranscriptionBackend {
        get {
            let backend = TranscriptionBackend(rawValue: transcriptionBackendRawValue) ?? .appleSpeech
            // Normalize the legacy `local` value (accepted by the enum for
            // callers that decode old settings) on its first read as well.
            if transcriptionBackendRawValue == "local" {
                transcriptionBackendRawValue = TranscriptionBackend.appleSpeech.rawValue
            }
            return backend
        }
        set { transcriptionBackendRawValue = newValue.rawValue }
    }

    /// One shared BCP-47 locale for Apple Speech and OpenAI hints.
    @UserDefault(key: Key.localeIdentifier, defaultValue: LanguageUtil.defaultLocaleIdentifier)
    private var storedLocaleIdentifier: String

    var localeIdentifier: String {
        get {
            let normalized = LanguageUtil.normalizedLocaleIdentifier(storedLocaleIdentifier)
            // Do not constrain persisted values to LanguageUtil's synchronous
            // compatibility list.  Apple Speech's supported locales are
            // discovered dynamically on macOS 26, and a newly advertised
            // locale must survive a Settings round trip before its asset is
            // prepared.  Only malformed/legacy auto-detect values need the
            // synchronous fallback here; the asset manager remains the source
            // of truth for actual Speech availability.
            let value = Self.isPersistableLocaleIdentifier(normalized)
                ? normalized
                : LanguageUtil.defaultLocaleIdentifier
            if value != storedLocaleIdentifier {
                storedLocaleIdentifier = value
            }
            return value
        }
        set {
            let normalized = LanguageUtil.normalizedLocaleIdentifier(newValue)
            storedLocaleIdentifier = Self.isPersistableLocaleIdentifier(normalized)
                ? normalized
                : LanguageUtil.defaultLocaleIdentifier
        }
    }

    var locale: Locale { LanguageUtil.locale(for: localeIdentifier) }

    @UserDefault(key: Key.recognitionContext, defaultValue: "")
    var recognitionContext: String

    @UserDefault(key: Key.showTimingDetailsInHistory, defaultValue: false)
    var showTimingDetailsInHistory: Bool

    @UserDefault(key: Key.debugMode, defaultValue: false)
    var debugMode: Bool

    @UserDefault(key: Key.playSoundOnRecordStart, defaultValue: false)
    var playSoundOnRecordStart: Bool

    @UserDefault(key: Key.hasCompletedOnboarding, defaultValue: false)
    var hasCompletedOnboarding: Bool

    @UserDefault(key: Key.openAIRetryCount, defaultValue: 1)
    var openAIRetryCount: Int

    @UserDefault(key: Key.recordingRetentionDays, defaultValue: 7)
    private var recordingRetentionDaysRawValue: Int

    /// The selected policy. `0` is the on-disk sentinel for Forever; a
    /// missing key intentionally resolves to the seven-day default.
    var recordingRetentionPolicy: RecordingRetentionPolicy {
        get {
            let rawValue = recordingRetentionDaysRawValue
            guard rawValue != 0 else { return .forever }
            let normalized = RecordingRetentionPolicy(days: rawValue).normalized
            if case let .days(days) = normalized, days != rawValue {
                recordingRetentionDaysRawValue = days
            }
            return normalized
        }
        set {
            let normalized = newValue.normalized
            recordingRetentionDaysRawValue = normalized.dayCount ?? 0
        }
    }

    /// Raw integer form retained for migration/tests and for callers that
    /// need to inspect the Forever sentinel without decoding the enum.
    var recordingRetentionDays: Int {
        get {
            if case .forever = recordingRetentionPolicy { return 0 }
            return recordingRetentionPolicy.dayCount ?? RecordingRetentionPolicy.minimumDays
        }
        set {
            if newValue == 0 {
                recordingRetentionPolicy = .forever
            } else {
                recordingRetentionPolicy = .days(newValue)
            }
        }
    }

    @UserDefault(key: Key.recordingRetentionNeedsInitialConfirmation, defaultValue: false)
    var recordingRetentionNeedsInitialConfirmation: Bool

    /// `nil` means the retention coordinator has not completed a successful
    /// sweep yet. Dates are stored directly in UserDefaults for portability.
    var recordingRetentionLastSuccessfulSweep: Date? {
        get { defaults.object(forKey: Key.recordingRetentionLastSuccessfulSweep) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.recordingRetentionLastSuccessfulSweep)
            } else {
                defaults.removeObject(forKey: Key.recordingRetentionLastSuccessfulSweep)
            }
        }
    }

    /// A production instance uses `.standard`; tests may pass an isolated
    /// suite and skip migration when they only exercise preference behavior.
    init(
        defaults: UserDefaults = .standard,
        performLegacyMigration: Bool = true
    ) {
        self.defaults = defaults

        _transcriptionBackendRawValue = UserDefault(
            key: Key.transcriptionBackend,
            defaultValue: TranscriptionBackend.appleSpeech.rawValue,
            defaults: defaults
        )
        _storedLocaleIdentifier = UserDefault(
            key: Key.localeIdentifier,
            defaultValue: LanguageUtil.defaultLocaleIdentifier,
            defaults: defaults
        )
        _recognitionContext = UserDefault(
            key: Key.recognitionContext,
            defaultValue: "",
            defaults: defaults
        )
        _showTimingDetailsInHistory = UserDefault(
            key: Key.showTimingDetailsInHistory,
            defaultValue: false,
            defaults: defaults
        )
        _debugMode = UserDefault(key: Key.debugMode, defaultValue: false, defaults: defaults)
        _playSoundOnRecordStart = UserDefault(
            key: Key.playSoundOnRecordStart,
            defaultValue: false,
            defaults: defaults
        )
        _hasCompletedOnboarding = UserDefault(
            key: Key.hasCompletedOnboarding,
            defaultValue: false,
            defaults: defaults
        )
        _openAIRetryCount = UserDefault(key: Key.openAIRetryCount, defaultValue: 1, defaults: defaults)
        _recordingRetentionDaysRawValue = UserDefault(
            key: Key.recordingRetentionDays,
            defaultValue: 7,
            defaults: defaults
        )
        _recordingRetentionNeedsInitialConfirmation = UserDefault(
            key: Key.recordingRetentionNeedsInitialConfirmation,
            defaultValue: false,
            defaults: defaults
        )

        if performLegacyMigration {
            Self.performLegacyMigration(defaults: defaults)
        }
    }

    /// Performs the one-time migration from whisper.cpp preferences and
    /// storage. It is intentionally idempotent and records completion only
    /// after the old directory is absent or has been removed successfully.
    /// The legacy keys are user-data compatibility, not runtime adapters;
    /// their removal is gated on the versioned 1.0 upgrade decision.
    @discardableResult
    static func migrateLegacyPreferencesIfNeeded(
        defaults: UserDefaults = .standard,
        fileManager: AppPreferencesFileOperations = FileManager.default,
        legacyDirectory: URL = legacyWhisperModelsDirectory
    ) -> Bool {
        guard !defaults.bool(forKey: Key.migrationCompleted) else { return false }

        let oldBackend = defaults.string(forKey: Key.transcriptionBackend)
        switch oldBackend {
        case "local":
            defaults.set(TranscriptionBackend.appleSpeech.rawValue, forKey: Key.transcriptionBackend)
        case "openAI":
            // Explicitly preserve an existing OpenAI selection.
            defaults.set(TranscriptionBackend.openAI.rawValue, forKey: Key.transcriptionBackend)
        case "appleSpeech":
            break
        case .none:
            break
        default:
            defaults.set(TranscriptionBackend.appleSpeech.rawValue, forKey: Key.transcriptionBackend)
        }

        // Migrate the old generic Whisper language to the closest supported
        // regional locale before deleting the obsolete key.
        if defaults.object(forKey: Key.localeIdentifier) == nil {
            let legacyLanguage = defaults.string(forKey: "whisperLanguage")
            defaults.set(
                LanguageUtil.localeIdentifier(forLegacyWhisperLanguage: legacyLanguage),
                forKey: Key.localeIdentifier
            )
        } else if let stored = defaults.string(forKey: Key.localeIdentifier) {
            defaults.set(LanguageUtil.normalizedLocaleIdentifier(stored), forKey: Key.localeIdentifier)
        }

        // Preserve the useful parts of old settings under provider-neutral
        // names. Whisper decoding controls themselves are intentionally not
        // carried forward.
        if defaults.object(forKey: Key.recognitionContext) == nil,
           let oldPrompt = defaults.string(forKey: "initialPrompt") {
            defaults.set(oldPrompt, forKey: Key.recognitionContext)
        }
        if defaults.object(forKey: Key.showTimingDetailsInHistory) == nil,
           let oldShowTimestamps = defaults.object(forKey: "showTimestamps") as? Bool {
            defaults.set(oldShowTimestamps, forKey: Key.showTimingDetailsInHistory)
        }

        // Remove only known whisper/model/autocorrect keys. Keeping this list
        // explicit protects unrelated application data during upgrades.
        let obsoleteKeys = [
            "selectedModelPath",
            "whisperLanguage",
            "translateToEnglish",
            "suppressBlankAudio",
            "showTimestamps",
            "temperature",
            "noSpeechThreshold",
            "initialPrompt",
            "useBeamSearch",
            "beamSize",
            "useAsianAutocorrect"
        ]
        obsoleteKeys.forEach(defaults.removeObject(forKey:))

        let legacyCleanupSucceeded: Bool
        if fileManager.fileExists(atPath: legacyDirectory.path) {
            do {
                try fileManager.removeItem(at: legacyDirectory)
                legacyCleanupSucceeded = true
            } catch {
                legacyCleanupSucceeded = false
            }
        } else {
            legacyCleanupSucceeded = true
        }

        if legacyCleanupSucceeded {
            defaults.set(true, forKey: Key.migrationCompleted)
        }
        return true
    }

    private static func performLegacyMigration(defaults: UserDefaults) {
        _ = migrateLegacyPreferencesIfNeeded(defaults: defaults)
    }

    private static func isPersistableLocaleIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: "-")
        guard let language = parts.first,
              (2...3).contains(language.count),
              language.allSatisfy({ $0.isLetter })
        else { return false }
        return identifier.caseInsensitiveCompare("auto") != .orderedSame
    }
}
