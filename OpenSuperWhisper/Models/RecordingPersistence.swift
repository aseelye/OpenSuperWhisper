import Foundation

/// The state of history storage.  A database error is deliberately kept
/// separate from an empty history so callers can keep the app usable while
/// offering a retry or recovery action.
enum RecordingHistoryStatus: Equatable, Sendable {
    case loading
    case available
    case staleWithError(String)
    case unavailable(String)

    var isAvailable: Bool {
        switch self {
        case .available, .staleWithError:
            return true
        case .loading, .unavailable:
            return false
        }
    }

    var diagnosticMessage: String? {
        switch self {
        case .staleWithError(let message), .unavailable(let message):
            return message
        case .loading, .available:
            return nil
        }
    }
}

/// Compatibility spelling for integrations that refer to the store rather
/// than the history projection.
typealias RecordingStoreStatus = RecordingHistoryStatus

/// Availability is checked without deleting or mutating a history row.  A
/// missing audio file never discards its transcript metadata.
enum RecordingAvailability: Equatable, Sendable {
    case playable(URL)
    case missing(URL)

    var url: URL {
        switch self {
        case .playable(let url), .missing(let url):
            return url
        }
    }

    var isPlayable: Bool {
        if case .playable = self { return true }
        return false
    }

    var isMissing: Bool { !isPlayable }
}

enum RecordingStoreError: LocalizedError, Equatable, Sendable {
    case initializationFailed(String)
    case databaseUnavailable(String)
    case databaseReadFailed(String)
    case databaseWriteFailed(String)
    case databaseDeleteFailed(String)
    case fileOperationFailed(operation: String, path: String, message: String)
    case recoveryFailed(String)
    case missingRecording(UUID)

    var errorDescription: String? {
        switch self {
        case .initializationFailed(let message):
            return "History storage could not be initialized: \(message)"
        case .databaseUnavailable(let message):
            return "History storage is unavailable: \(message)"
        case .databaseReadFailed(let message):
            return "History storage could not be read: \(message)"
        case .databaseWriteFailed(let message):
            return "History storage could not be written: \(message)"
        case .databaseDeleteFailed(let message):
            return "History storage could not be updated for deletion: \(message)"
        case let .fileOperationFailed(operation, path, message):
            return "Could not \(operation) recording file \(path): \(message)"
        case .recoveryFailed(let message):
            return "Recording recovery did not finish: \(message)"
        case .missingRecording(let id):
            return "Recording \(id.uuidString) is no longer in history."
        }
    }
}

/// Operation labels for the optional database fault seam. Production callers
/// leave the injector nil; tests can deterministically exercise compensation
/// without relying on filesystem permissions or timing.
enum RecordingDatabaseOperation: Equatable, Sendable {
    case migration
    case read
    case insert
    case delete
}

struct RecordingLoadResult: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case available
        case stale
        case unavailable
    }

    let state: State
    let recordings: [Recording]
    let error: RecordingStoreError?

    init(
        state: State,
        recordings: [Recording],
        error: RecordingStoreError? = nil
    ) {
        self.state = state
        self.recordings = recordings
        self.error = error
    }
}

struct RecordingSearchResult: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case available
        case stale
        case unavailable
    }

    let state: State
    let recordings: [Recording]
    let error: RecordingStoreError?

    init(
        state: State,
        recordings: [Recording],
        error: RecordingStoreError? = nil
    ) {
        self.state = state
        self.recordings = recordings
        self.error = error
    }
}

/// This value acknowledges only the durable database insertion.  History
/// publication is intentionally outside the acknowledgement boundary, so a
/// refresh failure cannot make the caller guess whether a row was committed.
struct RecordingCommitReceipt: Identifiable, Equatable, Sendable {
    let id: UUID
    let recordingID: UUID
    let databasePath: String
    let committedAt: Date

    init(
        recordingID: UUID,
        databasePath: String,
        committedAt: Date = Date()
    ) {
        self.id = recordingID
        self.recordingID = recordingID
        self.databasePath = databasePath
        self.committedAt = committedAt
    }

    var isDurable: Bool { true }
}

enum RecordingCommitOutcome: Equatable, Sendable {
    case committed(RecordingCommitReceipt)
    case failed(RecordingStoreError)

    var receipt: RecordingCommitReceipt? {
        guard case .committed(let receipt) = self else { return nil }
        return receipt
    }

    var isDurable: Bool { receipt != nil }
}

enum RecordingCompensationState: Equatable, Sendable {
    case removed
    case alreadyAbsent
    case failed
}

struct RecordingCompensationResult: Equatable, Sendable {
    let recordingID: UUID
    let state: RecordingCompensationState
    let error: RecordingStoreError?

    init(
        recordingID: UUID,
        state: RecordingCompensationState,
        error: RecordingStoreError? = nil
    ) {
        self.recordingID = recordingID
        self.state = state
        self.error = error
    }

    var requiresRepair: Bool { state == .failed }
}

enum RecordingDeletionState: Equatable, Sendable {
    case deleted
    case alreadyAbsent
    case failedBeforeDatabaseChange
    case databaseFailedFileRestored
    case databaseFailedRepairRequired
    case deletedWithCleanupPending
}

/// Deletion is an operation, not a fire-and-forget UI side effect.  The
/// result records both the row outcome and any file compensation requirement.
struct RecordingDeletionResult: Equatable, Sendable {
    let recordingID: UUID
    let state: RecordingDeletionState
    let originalFileURL: URL
    let quarantineURL: URL?
    let rowRemoved: Bool
    let audioRemoved: Bool
    let error: RecordingStoreError?

    init(
        recordingID: UUID,
        state: RecordingDeletionState,
        originalFileURL: URL,
        quarantineURL: URL? = nil,
        rowRemoved: Bool,
        audioRemoved: Bool,
        error: RecordingStoreError? = nil
    ) {
        self.recordingID = recordingID
        self.state = state
        self.originalFileURL = originalFileURL
        self.quarantineURL = quarantineURL
        self.rowRemoved = rowRemoved
        self.audioRemoved = audioRemoved
        self.error = error
    }

    var succeeded: Bool {
        switch state {
        case .deleted, .alreadyAbsent, .deletedWithCleanupPending:
            return true
        case .failedBeforeDatabaseChange,
             .databaseFailedFileRestored,
             .databaseFailedRepairRequired:
            return false
        }
    }

    var requiresRepair: Bool {
        switch state {
        case .databaseFailedRepairRequired, .deletedWithCleanupPending:
            return true
        case .deleted, .alreadyAbsent, .failedBeforeDatabaseChange,
             .databaseFailedFileRestored:
            return false
        }
    }
}

struct RecordingBulkDeletionResult: Equatable, Sendable {
    let results: [RecordingDeletionResult]
    let error: RecordingStoreError?

    init(results: [RecordingDeletionResult], error: RecordingStoreError? = nil) {
        self.results = results
        self.error = error
    }

    var succeeded: Bool {
        error == nil && results.allSatisfy { $0.succeeded }
    }

    var repairRequired: [RecordingDeletionResult] {
        results.filter(\.requiresRepair)
    }
}

enum RecordingRecoveryKind: String, Codable, Sendable {
    case orphanAudio
    case temporaryCapture
    case pendingDeletion
    case preservedAfterPersistenceFailure
}

struct RecordingRecoveryArtifact: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let kind: RecordingRecoveryKind
    let originalURL: URL
    let recoveryURL: URL?
    let transcriptURL: URL?
    let recordingID: UUID?

    init(
        id: UUID = UUID(),
        kind: RecordingRecoveryKind,
        originalURL: URL,
        recoveryURL: URL?,
        transcriptURL: URL? = nil,
        recordingID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.originalURL = originalURL
        self.recoveryURL = recoveryURL
        self.transcriptURL = transcriptURL
        self.recordingID = recordingID
    }
}

struct RecordingReconciliationReport: Equatable, Sendable {
    let missingRecordings: [Recording]
    let recoveredArtifacts: [RecordingRecoveryArtifact]
    let errors: [String]

    init(
        missingRecordings: [Recording] = [],
        recoveredArtifacts: [RecordingRecoveryArtifact] = [],
        errors: [String] = []
    ) {
        self.missingRecordings = missingRecordings
        self.recoveredArtifacts = recoveredArtifacts
        self.errors = errors
    }

    var hasRepairItems: Bool {
        !missingRecordings.isEmpty || !recoveredArtifacts.isEmpty || !errors.isEmpty
    }

    var orphanedAudio: [RecordingRecoveryArtifact] {
        recoveredArtifacts.filter { $0.kind == .orphanAudio }
    }

    var temporaryCaptures: [RecordingRecoveryArtifact] {
        recoveredArtifacts.filter { $0.kind == .temporaryCapture }
    }
}

enum RecordingRecoveryDisposition: Sendable {
    case copy
    case move
}

struct RecordingRecoveryRequest: Sendable {
    let sourceURL: URL
    let recording: Recording
    let disposition: RecordingRecoveryDisposition

    init(
        sourceURL: URL,
        recording: Recording,
        disposition: RecordingRecoveryDisposition = .move
    ) {
        self.sourceURL = sourceURL
        self.recording = recording
        self.disposition = disposition
    }
}

enum RecordingRecoveryError: LocalizedError, Equatable, Sendable {
    case audioSourceMissing(URL)
    case audioTransferFailed(String)
    case transcriptWriteFailed(String)
    case metadataWriteFailed(String)
    case recoveryDirectoryFailed(String)

    var errorDescription: String? {
        switch self {
        case .audioSourceMissing(let url):
            return "The audio source is missing: \(url.path)"
        case .audioTransferFailed(let message):
            return "Audio could not be placed in Recovery: \(message)"
        case .transcriptWriteFailed(let message):
            return "The recovery transcript could not be written: \(message)"
        case .metadataWriteFailed(let message):
            return "Recovery metadata could not be written: \(message)"
        case .recoveryDirectoryFailed(let message):
            return "The Recovery directory could not be prepared: \(message)"
        }
    }
}

/// A nonthrowing result lets a cancelled/unavailable persistence path preserve
/// the audio and still report whether transcript preservation completed.
struct RecordingRecoveryResult: Equatable, Sendable {
    let receipt: RecordingRecoveryReceipt?
    let error: RecordingRecoveryError?

    init(receipt: RecordingRecoveryReceipt?, error: RecordingRecoveryError? = nil) {
        self.receipt = receipt
        self.error = error
    }

    var audioPreserved: Bool { receipt?.audioURL != nil }
    var transcriptPreserved: Bool { receipt?.transcriptURL != nil }
    var succeeded: Bool { receipt != nil && error == nil }
}

struct RecordingRecoveryReceipt: Identifiable, Equatable, Sendable {
    let id: UUID
    let recordingID: UUID
    let audioURL: URL?
    let transcriptURL: URL?
    let metadataURL: URL?

    init(
        recordingID: UUID,
        audioURL: URL?,
        transcriptURL: URL?,
        metadataURL: URL?
    ) {
        self.id = UUID()
        self.recordingID = recordingID
        self.audioURL = audioURL
        self.transcriptURL = transcriptURL
        self.metadataURL = metadataURL
    }
}

/// Small filesystem seam used by deletion/recovery tests.  The production
/// implementation below delegates directly to FileManager.
protocol RecordingFileSystem: AnyObject {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
    func write(_ data: Data, to url: URL) throws
}

final class LocalRecordingFileSystem: RecordingFileSystem, @unchecked Sendable {
    init() {}

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
