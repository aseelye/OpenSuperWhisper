import Foundation

/// The amount of history retained by an automatic recording sweep.
///
/// The enum case remains available for source compatibility with callers that
/// construct policies as `.days(value)`.  Callers should use `normalized` (or
/// the labelled initializer) when they need the bounded value that the store
/// will apply.  The store always normalizes before doing any date arithmetic.
enum RecordingRetentionPolicy: Equatable, Sendable {
    case forever
    case days(Int)

    static let minimumDays = 1
    static let maximumDays = 3650
    static let defaultDays = 7

    /// The default retention period used by the app when no preference has
    /// been saved yet.
    static let `default`: Self = .days(defaultDays)

    init() {
        self = .default
    }

    /// Constructs a bounded day policy.  Direct `.days(Int)` construction is
    /// also accepted and normalized by `normalized` and by the store APIs.
    init(days: Int) {
        self = .days(Self.clamp(days))
    }

    /// The policy with an out-of-range day value clamped to the supported
    /// one-to-ten-year range.
    var normalized: Self {
        switch self {
        case .forever:
            return .forever
        case .days(let value):
            return .days(Self.clamp(value))
        }
    }

    var dayCount: Int? {
        guard case .days(let value) = normalized else { return nil }
        return value
    }

    var isForever: Bool {
        if case .forever = self { return true }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.normalized, rhs.normalized) {
        case (.forever, .forever):
            return true
        case (.days(let lhsDays), .days(let rhsDays)):
            return lhsDays == rhsDays
        default:
            return false
        }
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, minimumDays), maximumDays)
    }
}

/// The read-only result of evaluating a retention policy against the
/// authoritative database snapshot at a particular instant.
struct RecordingRetentionPreview: Equatable, Sendable {
    let policy: RecordingRetentionPolicy
    /// `nil` means the policy is `.forever`, which has no expiry boundary.
    let cutoff: Date?
    let eligibleEntryCount: Int
    let totalManagedAudioBytes: Int64
    let error: RecordingStoreError?

    init(
        policy: RecordingRetentionPolicy = .default,
        cutoff: Date? = nil,
        eligibleEntryCount: Int = 0,
        totalManagedAudioBytes: Int64 = 0,
        error: RecordingStoreError? = nil
    ) {
        self.policy = policy.normalized
        self.cutoff = cutoff
        self.eligibleEntryCount = eligibleEntryCount
        self.totalManagedAudioBytes = totalManagedAudioBytes
        self.error = error
    }

}

/// The outcome of applying a retention policy.  Individual deletion results
/// are retained even when one item fails so a caller can present repair
/// guidance while the sweep continues through the remaining eligible rows.
struct RecordingRetentionResult: Equatable, Sendable {
    let preview: RecordingRetentionPreview
    let deletionResults: [RecordingDeletionResult]
    let error: RecordingStoreError?

    init(
        preview: RecordingRetentionPreview,
        deletionResults: [RecordingDeletionResult] = [],
        error: RecordingStoreError? = nil
    ) {
        self.preview = preview
        self.deletionResults = deletionResults
        self.error = error
    }

    var failures: [RecordingDeletionResult] {
        deletionResults.filter { !$0.succeeded || $0.requiresRepair }
    }
    var succeededResults: [RecordingDeletionResult] {
        deletionResults.filter { $0.succeeded && !$0.requiresRepair }
    }

    var deletedCount: Int {
        deletionResults.filter { $0.rowRemoved && $0.succeeded }.count
    }

    var failedCount: Int { failures.count }
    var succeededCount: Int { succeededResults.count }
    var repairRequired: [RecordingDeletionResult] {
        deletionResults.filter(\.requiresRepair)
    }

    var succeeded: Bool {
        error == nil && failures.isEmpty
    }

}

/// A small actor-backed mutex.  Main-actor methods can suspend while an
/// operation performs database and file work; waiting calls are queued rather
/// than relying on a boolean flag that async reentrancy could bypass.
actor RecordingMutationGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            held = false
            return
        }

        // Keep the gate held while handing ownership to the next waiter.
        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}
