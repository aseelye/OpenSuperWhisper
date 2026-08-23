import Foundation
import Combine
import OSLog

/// The choices shown in General > History. Custom is kept separate from the
/// fixed choices because its day value is entered in the adjacent field.
enum RecordingRetentionOption: String, CaseIterable, Identifiable, Sendable {
    case forever
    case oneDay
    case sevenDays
    case thirtyDays
    case ninetyDays
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forever: return "Forever"
        case .oneDay: return "1 day"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .custom: return "Custom"
        }
    }

    /// Fixed choices map directly to a policy. Custom is resolved by
    /// `policy(customDays:)` after the numeric field has been validated.
    var fixedPolicy: RecordingRetentionPolicy? {
        switch self {
        case .forever: return .forever
        case .oneDay: return .days(1)
        case .sevenDays: return .days(7)
        case .thirtyDays: return .days(30)
        case .ninetyDays: return .days(90)
        case .custom: return nil
        }
    }

    func policy(customDays: Int? = nil) -> RecordingRetentionPolicy? {
        if let fixedPolicy { return fixedPolicy }
        guard let customDays else { return nil }
        return .days(customDays)
    }

    static func option(for policy: RecordingRetentionPolicy) -> Self {
        switch policy.normalized {
        case .forever:
            return .forever
        case .days(let days):
            switch days {
            case 1: return .oneDay
            case 7: return .sevenDays
            case 30: return .thirtyDays
            case 90: return .ninetyDays
            default: return .custom
            }
        }
    }

    /// The value to display in the Custom field when the current policy is a
    /// non-preset day count. Preset choices display their own value instead.
    static func customDays(for policy: RecordingRetentionPolicy) -> Int? {
        guard case let .days(days) = policy.normalized else { return nil }
        return [1, 7, 30, 90].contains(days) ? nil : days
    }
}

enum RecordingRetentionSweepReason: Sendable {
    case historyLoaded
    case confirmedChange
    case scheduled
}

/// Coordinates retention sweeps without allowing a preference change to
/// delete data before the user has reviewed its preview. The coordinator is
/// deliberately explicit about starting and stopping its 24-hour loop so
/// unit tests can use it synchronously without creating an unowned timer.
@MainActor
final class RecordingRetentionCoordinator: ObservableObject {
    static let sweepInterval: TimeInterval = 24 * 60 * 60

    typealias SleepOperation = @Sendable (UInt64) async -> Void
    typealias DateProvider = @Sendable () -> Date

    @Published private(set) var isSweeping = false
    @Published private(set) var lastPreview: RecordingRetentionPreview?
    @Published private(set) var lastResult: RecordingRetentionResult?
    @Published private(set) var lastError: RecordingStoreError?

    let recordingStore: RecordingStore
    let preferences: AppPreferences
    let interval: TimeInterval

    private let sleepOperation: SleepOperation
    private let dateProvider: DateProvider
    private let logger = Logger(subsystem: "OpenSuperWhisper", category: "Retention")
    private var timerTask: Task<Void, Never>?
    private var hasStarted = false

    init(
        recordingStore: RecordingStore? = nil,
        preferences: AppPreferences = .shared,
        interval: TimeInterval? = nil,
        sleepOperation: @escaping SleepOperation = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        dateProvider: @escaping DateProvider = { Date() },
        automaticallyStart: Bool = false
    ) {
        // Keep actor-isolated singleton lookup inside this MainActor
        // initializer. A default argument is evaluated outside the actor and
        // would become a Swift 6 isolation error if it referenced
        // `RecordingStore.shared` directly.
        self.recordingStore = recordingStore ?? .shared
        self.preferences = preferences
        self.interval = max(1, interval ?? Self.sweepInterval)
        self.sleepOperation = sleepOperation
        self.dateProvider = dateProvider
        if automaticallyStart {
            start()
        }
    }

    deinit {
        timerTask?.cancel()
    }

    /// Starts only the recurring loop. The first sweep waits until history
    /// reports `.available` and the caller invokes `historyDidLoad()`.
    func start() {
        guard timerTask == nil else { return }
        hasStarted = true
        let interval = self.interval
        let sleep = self.sleepOperation
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let nanoseconds = UInt64(max(1, interval) * 1_000_000_000)
                await sleep(nanoseconds)
                guard !Task.isCancelled, let self else { return }
                await self.runScheduledSweep(now: self.dateProvider())
            }
        }
    }

    /// Cancels the loop and any future automatic work. An in-flight store
    /// operation is allowed to finish safely; the next coordinator instance
    /// will see the durable preference and last-sweep state.
    func stop() {
        timerTask?.cancel()
        timerTask = nil
        hasStarted = false
    }

    var isStarted: Bool { hasStarted }

    /// Called by the history surface once its first load/retry succeeds.
    /// Repeated calls while a sweep is active are coalesced by the actor.
    func historyDidLoad(now: Date? = nil) {
        guard hasStarted else { return }
        let instant = now ?? dateProvider()
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.runAfterHistoryLoad(now: instant)
        }
    }

    /// Synchronous-friendly request used by UI callbacks. Tests can call the
    /// async method below directly and await its result deterministically.
    func requestConfirmedChange(_ policy: RecordingRetentionPolicy, now: Date? = nil) {
        let instant = now ?? dateProvider()
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.runAfterConfirmedChange(policy: policy, now: instant)
        }
    }

    func requestInitialConfirmationApproval(now: Date? = nil) {
        let instant = now ?? dateProvider()
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.approveInitialConfirmation(now: instant)
        }
    }

    func requestInitialConfirmationDecline(now: Date? = nil) {
        let instant = now ?? dateProvider()
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.declineInitialConfirmation(now: instant)
        }
    }

    /// Read-only evaluation used before a finite policy is persisted.
    @discardableResult
    func preview(
        policy: RecordingRetentionPolicy,
        now: Date? = nil
    ) async -> RecordingRetentionPreview {
        let preview = await recordingStore.previewRetention(
            policy: policy.normalized,
            now: now ?? dateProvider()
        )
        lastPreview = preview
        if let error = preview.error {
            lastError = error
            logger.error("Retention preview failed: \(error.localizedDescription, privacy: .public)")
        } else {
            lastError = nil
        }
        return preview
    }

    /// Applies a policy after a user has accepted any destructive preview.
    /// Preference persistence happens before the sweep so a background error
    /// is retried on the next cycle with the policy the user selected.
    @discardableResult
    func runAfterConfirmedChange(
        policy: RecordingRetentionPolicy,
        now: Date? = nil
    ) async -> RecordingRetentionResult? {
        preferences.recordingRetentionPolicy = policy.normalized
        return await runSweep(
            reason: .confirmedChange,
            now: now ?? dateProvider(),
            force: true
        )
    }

    @discardableResult
    func runAfterHistoryLoad(now: Date? = nil) async -> RecordingRetentionResult? {
        let instant = now ?? dateProvider()
        // A successful apply publishes a fresh history snapshot, which can
        // emit the same `.available` status that triggered this call. Avoid a
        // second immediate batch while still allowing a later explicit load
        // (or a failed batch) to retry normally.
        if let previous = preferences.recordingRetentionLastSuccessfulSweep,
           abs(instant.timeIntervalSince(previous)) < 1 {
            return nil
        }
        return await runSweep(
            reason: .historyLoaded,
            now: instant,
            force: true
        )
    }

    @discardableResult
    func runScheduledSweep(now: Date? = nil) async -> RecordingRetentionResult? {
        let instant = now ?? dateProvider()
        guard let previous = preferences.recordingRetentionLastSuccessfulSweep,
              instant.timeIntervalSince(previous) < interval else {
            return await runSweep(reason: .scheduled, now: instant, force: false)
        }
        return nil
    }

    /// The migration gate is consumed exactly once by either action. Approval
    /// keeps the existing/default policy and applies it immediately; declining
    /// changes the policy to Forever before any sweep can run.
    @discardableResult
    func approveInitialConfirmation(now: Date? = nil) async -> RecordingRetentionResult? {
        guard preferences.recordingRetentionNeedsInitialConfirmation else { return nil }
        preferences.recordingRetentionNeedsInitialConfirmation = false
        return await runAfterConfirmedChange(
            policy: preferences.recordingRetentionPolicy,
            now: now ?? dateProvider()
        )
    }

    @discardableResult
    func declineInitialConfirmation(now: Date? = nil) async -> RecordingRetentionResult? {
        guard preferences.recordingRetentionNeedsInitialConfirmation else { return nil }
        preferences.recordingRetentionNeedsInitialConfirmation = false
        preferences.recordingRetentionPolicy = .forever
        return await runAfterConfirmedChange(policy: .forever, now: now ?? dateProvider())
    }

    /// Cancellation intentionally has no side effects. Keeping the migration
    /// gate set prevents the automatic sweep and allows the prompt to appear
    /// again when the history surface is usable on the next launch.
    func cancelInitialConfirmation() {
        // Deliberately empty: the persisted gate and policy remain unchanged.
    }

    private func runSweep(
        reason: RecordingRetentionSweepReason,
        now: Date,
        force: Bool
    ) async -> RecordingRetentionResult? {
        guard recordingStore.status.isAvailable else { return nil }
        guard !preferences.recordingRetentionNeedsInitialConfirmation else { return nil }
        if !force,
           let previous = preferences.recordingRetentionLastSuccessfulSweep,
           now.timeIntervalSince(previous) < interval {
            return nil
        }
        guard !isSweeping else { return nil }

        isSweeping = true
        defer { isSweeping = false }
        let policy = preferences.recordingRetentionPolicy
        let result = await recordingStore.applyRetention(policy: policy, now: now)
        lastResult = result

        if let error = result.error {
            lastError = error
            logger.error(
                "Retention \(String(describing: reason), privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        } else if !result.failures.isEmpty {
            lastError = result.failures.first?.error
            logger.error(
                "Retention \(String(describing: reason), privacy: .public) left \(result.failures.count) failed deletion(s)"
            )
        } else {
            lastError = nil
            preferences.recordingRetentionLastSuccessfulSweep = now
        }
        return result
    }

    static func formattedByteSize(_ byteCount: Int64) -> String {
        guard byteCount > 0 else { return "0 bytes" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }

    static func confirmationMessage(
        preview: RecordingRetentionPreview,
        policy: RecordingRetentionPolicy
    ) -> String {
        let count = preview.eligibleEntryCount
        let entries = count == 1 ? "entry" : "entries"
        let size = formattedByteSize(preview.totalManagedAudioBytes)
        let daysDescription: String
        if let days = policy.dayCount {
            daysDescription = "after \(days) day\(days == 1 ? "" : "s")"
        } else {
            daysDescription = "under this policy"
        }
        return "\(count) \(entries) (\(size)) would be deleted now. Future recordings and their audio, transcript, and history entry will be deleted \(daysDescription)."
    }
}
