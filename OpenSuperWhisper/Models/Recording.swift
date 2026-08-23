import Combine
import Foundation
import GRDB

struct Recording: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let fileName: String
    let transcription: String
    let duration: TimeInterval
    /// Nullable so rows written before the metadata migration remain valid.
    let backend: String?
    /// The locale used by the selected transcription backend, if known.
    let locale: String?
    /// JSON encoded `[TranscriptSegment]`, if the backend supplied timed
    /// segments. OpenAI's general-purpose model intentionally leaves this nil.
    let encodedTranscriptSegments: Data?

    init(
        id: UUID,
        timestamp: Date,
        fileName: String,
        transcription: String,
        duration: TimeInterval,
        backend: String? = nil,
        locale: String? = nil,
        encodedTranscriptSegments: Data? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.fileName = fileName
        self.transcription = transcription
        self.duration = duration
        self.backend = backend
        self.locale = locale
        self.encodedTranscriptSegments = encodedTranscriptSegments
    }

    static func == (lhs: Recording, rhs: Recording) -> Bool {
        lhs.id == rhs.id
    }

    /// The UI-test lane supplies a storage root explicitly at process launch.
    /// Requiring both the opt-in launch argument and marker keeps an arbitrary
    /// environment variable from changing normal application persistence.
    static let uiTestStorageRootEnvironmentKey = "OPEN_SUPER_WHISPER_UI_TEST_STORAGE_ROOT"

    private static let uiTestLaunchArgument = "--open-super-whisper-ui-test"
    private static let uiTestEnvironmentKey = "OPEN_SUPER_WHISPER_UI_TEST"

    static var applicationDirectory: URL {
        resolvedApplicationDirectory(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Resolves the app-owned persistence directory without reading or
    /// creating anything on disk. The injectable inputs make the UI-test
    /// boundary deterministic while keeping the production fallback identical
    /// to the historical Application Support location.
    static func resolvedApplicationDirectory(
        arguments: [String],
        environment: [String: String],
        applicationSupportDirectory: URL? = nil,
        bundleIdentifier: String? = nil
    ) -> URL {
        let resolvedBundleIdentifier = bundleIdentifier
            ?? Bundle.main.bundleIdentifier
            ?? "OpenSuperWhisper"

        if let storageRoot = uiTestStorageRoot(
            arguments: arguments,
            environment: environment
        ) {
            return storageRoot.appendingPathComponent(
                resolvedBundleIdentifier,
                isDirectory: true
            )
        }

        let applicationSupport = applicationSupportDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.temporaryDirectory
        return applicationSupport.appendingPathComponent(
            resolvedBundleIdentifier,
            isDirectory: true
        )
    }

    /// Captures temporary files under the same isolated root for UI tests so
    /// startup reconciliation cannot scan the shared process temp directory.
    /// Production keeps its existing shared temporary location.
    static var temporaryCaptureDirectory: URL {
        if uiTestStorageRoot(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        ) != nil {
            return applicationDirectory.appendingPathComponent(
                "temporary-captures",
                isDirectory: true
            )
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisper", isDirectory: true)
    }

    private static func uiTestStorageRoot(
        arguments: [String],
        environment: [String: String]
    ) -> URL? {
        guard arguments.contains(uiTestLaunchArgument),
              environment[uiTestEnvironmentKey] == "1",
              let rawRoot = environment[uiTestStorageRootEnvironmentKey]?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !rawRoot.isEmpty else {
            return nil
        }

        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        guard root.isFileURL, root.path != "/" else { return nil }
        return root
    }

    static var recordingsDirectory: URL {
        applicationDirectory.appendingPathComponent("recordings", isDirectory: true)
    }

    static var recoveryDirectory: URL {
        applicationDirectory.appendingPathComponent("Recovery", isDirectory: true)
    }

    /// The default-location URL retained for existing UI and controller
    /// callers. A store configured with another root should use
    /// `RecordingStore.url(for:)` instead.
    var url: URL {
        Self.recordingsDirectory.appendingPathComponent(fileName)
    }

    /// A lightweight, non-destructive check for the default recording root.
    var availability: RecordingAvailability {
        Self.availability(for: url)
    }

    func availability(in recordingsDirectory: URL) -> RecordingAvailability {
        Self.availability(for: recordingsDirectory.appendingPathComponent(fileName))
    }

    static func availability(for url: URL) -> RecordingAvailability {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue ? .playable(url) : .missing(url)
    }

    /// Decoded timing metadata for history details. A malformed payload is
    /// treated as absent rather than making an otherwise playable recording
    /// unreadable.
    var transcriptSegments: [TranscriptSegment] {
        guard let encodedTranscriptSegments else { return [] }
        return (try? JSONDecoder().decode(
            [TranscriptSegment].self,
            from: encodedTranscriptSegments
        )) ?? []
    }

    /// Encodes engine segments without coupling the database model to an
    /// engine module. Callers can map their provider-neutral segments to this
    /// shape at the session boundary.
    static func encodeTranscriptSegments(_ segments: [TranscriptSegment]) -> Data? {
        guard !segments.isEmpty else { return nil }
        return try? JSONEncoder().encode(segments)
    }

    // MARK: - Database Table Definition

    static let databaseTableName = "recordings"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let timestamp = Column(CodingKeys.timestamp)
        static let fileName = Column(CodingKeys.fileName)
        static let transcription = Column(CodingKeys.transcription)
        static let duration = Column(CodingKeys.duration)
        static let backend = Column(CodingKeys.backend)
        static let locale = Column(CodingKeys.locale)
        static let encodedTranscriptSegments = Column(CodingKeys.encodedTranscriptSegments)
    }
}

/// Main-actor history store. The database is optional by design: startup,
/// migration, and later read failures degrade history without terminating the
/// application or preventing a caller from preserving audio in Recovery.
@MainActor
final class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var historyStatus: RecordingHistoryStatus
    @Published private(set) var recoveryInventory: [RecordingRecoveryArtifact] = []
    @Published private(set) var missingRecordings: [Recording] = []
    @Published private(set) var reconciliationReport = RecordingReconciliationReport()

    var status: RecordingHistoryStatus { historyStatus }
    var recoveryItems: [RecordingRecoveryArtifact] { recoveryInventory }
    var isPersistenceAvailable: Bool { historyStatus.isAvailable }
    var initializationError: RecordingStoreError? { initializationFailure }

    let databaseURL: URL
    let recordingsDirectory: URL
    let recoveryDirectory: URL
    let temporaryCaptureDirectory: URL
    let quarantineDirectory: URL

    private let fileSystem: any RecordingFileSystem
    private let databaseFactory: (URL) throws -> DatabaseQueue
    private let databaseFailureInjector: ((RecordingDatabaseOperation) -> RecordingStoreError?)?
    private var dbQueue: DatabaseQueue?
    private var initializationFailure: RecordingStoreError?

    /// Creates a store at the app's normal database path. All storage roots
    /// and the database factory can be injected for deterministic tests and a
    /// future composition root.
    init(
        databasePath: URL? = nil,
        automaticallyLoad: Bool = true,
        recordingsDirectory: URL? = nil,
        recoveryDirectory: URL? = nil,
        temporaryCaptureDirectory: URL? = nil,
        quarantineDirectory: URL? = nil,
        fileSystem: any RecordingFileSystem = LocalRecordingFileSystem(),
        databaseFactory: ((URL) throws -> DatabaseQueue)? = nil,
        databaseFailureInjector: ((RecordingDatabaseOperation) -> RecordingStoreError?)? = nil
    ) {
        let defaultApplicationDirectory = Recording.applicationDirectory
        let resolvedDatabaseURL = databasePath
            ?? defaultApplicationDirectory.appendingPathComponent("recordings.sqlite")
        let resolvedRecordingsDirectory = recordingsDirectory
            ?? defaultApplicationDirectory.appendingPathComponent("recordings", isDirectory: true)
        let resolvedRecoveryDirectory = recoveryDirectory
            ?? defaultApplicationDirectory.appendingPathComponent("Recovery", isDirectory: true)
        let resolvedTemporaryDirectory = temporaryCaptureDirectory
            ?? Recording.temporaryCaptureDirectory
        let resolvedQuarantineDirectory = quarantineDirectory
            ?? resolvedRecordingsDirectory.appendingPathComponent(
                ".pending-deletions",
                isDirectory: true
            )

        self.databaseURL = resolvedDatabaseURL
        self.recordingsDirectory = resolvedRecordingsDirectory
        self.recoveryDirectory = resolvedRecoveryDirectory
        self.temporaryCaptureDirectory = resolvedTemporaryDirectory
        self.quarantineDirectory = resolvedQuarantineDirectory
        self.fileSystem = fileSystem
        self.databaseFactory = databaseFactory ?? { try DatabaseQueue(path: $0.path) }
        self.databaseFailureInjector = databaseFailureInjector
        self.historyStatus = .loading

        do {
            try fileSystem.createDirectory(at: resolvedDatabaseURL.deletingLastPathComponent())
            let queue = try self.databaseFactory(resolvedDatabaseURL)
            if let failure = self.databaseFailureInjector?(.migration) {
                throw failure
            }
            try Self.setupDatabase(queue)
            self.dbQueue = queue
            self.historyStatus = automaticallyLoad ? .loading : .available
        } catch {
            let failure = Self.storeError(
                error,
                default: .initializationFailed(error.localizedDescription)
            )
            self.initializationFailure = failure
            self.historyStatus = .unavailable(failure.localizedDescription)
            self.dbQueue = nil
        }

        if automaticallyLoad, self.dbQueue != nil {
            Task { @MainActor [weak self] in
                _ = await self?.loadRecordings()
            }
        }
    }

    // MARK: - Setup and availability

    private static func setupDatabase(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: Recording.databaseTableName, ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("fileName", .text).notNull()
                t.column("transcription", .text).notNull().indexed().collate(.nocase)
                t.column("duration", .double).notNull()
                // Metadata is nullable by design: rows from older versions
                // have no backend, locale, or timed segments.
                t.column("backend", .text)
                t.column("locale", .text)
                t.column("encodedTranscriptSegments", .blob)
            }

            // `ifNotExists` does not alter an existing table. Add each field
            // independently so partially migrated databases are recoverable.
            let existingColumns = try db.columns(in: Recording.databaseTableName).map(\.name)
            if !existingColumns.contains("backend") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "backend", .text)
                }
            }
            if !existingColumns.contains("locale") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "locale", .text)
                }
            }
            if !existingColumns.contains("encodedTranscriptSegments") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "encodedTranscriptSegments", .blob)
                }
            }
        }
    }

    /// Retries a failed setup after the caller has repaired the path or
    /// permissions. Existing history is never deleted or replaced.
    @discardableResult
    func retryInitialization(automaticallyLoad: Bool = true) async -> RecordingHistoryStatus {
        guard dbQueue == nil else {
            if automaticallyLoad { _ = await loadRecordings() }
            return historyStatus
        }

        do {
            try fileSystem.createDirectory(at: databaseURL.deletingLastPathComponent())
            let queue = try databaseFactory(databaseURL)
            if let failure = databaseFailureInjector?(.migration) {
                throw failure
            }
            try Self.setupDatabase(queue)
            dbQueue = queue
            initializationFailure = nil
            historyStatus = automaticallyLoad ? .loading : .available
            if automaticallyLoad { _ = await loadRecordings() }
        } catch {
            let failure = Self.storeError(
                error,
                default: .initializationFailed(error.localizedDescription)
            )
            initializationFailure = failure
            historyStatus = .unavailable(failure.localizedDescription)
            dbQueue = nil
        }
        return historyStatus
    }

    @discardableResult
    func retry() async -> RecordingHistoryStatus {
        await retryInitialization()
    }

    // MARK: - Load and search

    @discardableResult
    func loadRecordings() async -> RecordingLoadResult {
        guard let dbQueue else {
            let error = initializationFailure
                ?? .databaseUnavailable("The history database is not open.")
            historyStatus = .unavailable(error.localizedDescription)
            return RecordingLoadResult(
                state: .unavailable,
                recordings: recordings,
                error: error
            )
        }

        do {
            try checkDatabaseOperation(.read)
            let loadedRecordings = try await Self.fetchAllRecordings(from: dbQueue)
            recordings = loadedRecordings
            let report = reconcileFiles(for: loadedRecordings)
            missingRecordings = report.missingRecordings
            if !report.errors.isEmpty {
                historyStatus = .staleWithError(report.errors.joined(separator: "; "))
            } else {
                historyStatus = .available
            }
            return RecordingLoadResult(
                state: report.errors.isEmpty ? .available : .stale,
                recordings: loadedRecordings,
                error: report.errors.isEmpty
                    ? nil
                    : .fileOperationFailed(
                        operation: "reconcile",
                        path: recoveryDirectory.path,
                        message: report.errors.joined(separator: "; ")
                    )
            )
        } catch {
            let failure = Self.storeError(
                error,
                default: .databaseReadFailed(error.localizedDescription)
            )
            historyStatus = recordings.isEmpty
                ? .unavailable(failure.localizedDescription)
                : .staleWithError(failure.localizedDescription)
            return RecordingLoadResult(
                state: recordings.isEmpty ? .unavailable : .stale,
                recordings: recordings,
                error: failure
            )
        }
    }

    @discardableResult
    func loadRecordingsResult() async -> RecordingLoadResult {
        await loadRecordings()
    }

    private static func fetchAllRecordings(from dbQueue: DatabaseQueue) async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .order(Recording.Columns.timestamp.desc)
                .fetchAll(db)
        }
    }

    /// The synchronous compatibility API returns the last-known snapshot on
    /// read failure instead of falsely presenting an empty history.
    func searchRecordings(query: String) -> [Recording] {
        guard let dbQueue else {
            let error = initializationFailure
                ?? .databaseUnavailable("The history database is not open.")
            historyStatus = .unavailable(error.localizedDescription)
            return recordings
        }

        do {
            try checkDatabaseOperation(.read)
            return try dbQueue.read { db in
                try Recording
                    .filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
                    .order(Recording.Columns.timestamp.desc)
                    .fetchAll(db)
            }
        } catch {
            let failure = Self.storeError(
                error,
                default: .databaseReadFailed(error.localizedDescription)
            )
            historyStatus = recordings.isEmpty
                ? .unavailable(failure.localizedDescription)
                : .staleWithError(failure.localizedDescription)
            return recordings
        }
    }

    @discardableResult
    func searchRecordingsResult(query: String) async -> RecordingSearchResult {
        guard let dbQueue else {
            let error = initializationFailure
                ?? .databaseUnavailable("The history database is not open.")
            historyStatus = .unavailable(error.localizedDescription)
            return RecordingSearchResult(
                state: .unavailable,
                recordings: recordings,
                error: error
            )
        }

        do {
            try checkDatabaseOperation(.read)
            let results = try await dbQueue.read { db in
                try Recording
                    .filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
                    .order(Recording.Columns.timestamp.desc)
                    .fetchAll(db)
            }
            return RecordingSearchResult(state: .available, recordings: results)
        } catch {
            let failure = Self.storeError(
                error,
                default: .databaseReadFailed(error.localizedDescription)
            )
            historyStatus = recordings.isEmpty
                ? .unavailable(failure.localizedDescription)
                : .staleWithError(failure.localizedDescription)
            return RecordingSearchResult(
                state: recordings.isEmpty ? .unavailable : .stale,
                recordings: recordings,
                error: failure
            )
        }
    }

    // MARK: - Commit and compensation

    /// Inserts a row and returns as soon as the database write is durable.
    /// The subsequent publication refresh is best-effort and updates
    /// `historyStatus` independently of this receipt.
    func commitRecording(_ recording: Recording) async throws -> RecordingCommitReceipt {
        guard let dbQueue else {
            throw initializationFailure
                ?? RecordingStoreError.databaseUnavailable("The history database is not open.")
        }

        do {
            try checkDatabaseOperation(.insert)
            try await dbQueue.write { db in
                try recording.insert(db)
            }
        } catch {
            throw Self.storeError(
                error,
                default: .databaseWriteFailed(error.localizedDescription)
            )
        }

        let receipt = RecordingCommitReceipt(
            recordingID: recording.id,
            databasePath: databaseURL.path
        )

        // Refresh after acknowledging the commit. A read/publication error
        // cannot turn a known durable insertion into an ambiguous failure.
        _ = await loadRecordings()
        return receipt
    }

    @discardableResult
    func commitRecordingResult(_ recording: Recording) async -> RecordingCommitOutcome {
        do {
            return .committed(try await commitRecording(recording))
        } catch let error as RecordingStoreError {
            return .failed(error)
        } catch {
            return .failed(.databaseWriteFailed(error.localizedDescription))
        }
    }

    /// Existing controller compatibility. The receipt-capable API above is
    /// the preferred boundary for cancellation-safe persistence.
    func addRecording(_ recording: Recording) async throws {
        _ = try await commitRecording(recording)
    }

    /// Removes only the row and intentionally leaves file ownership to the
    /// caller. This remains the narrow compensation method used by the
    /// current controller while `removeCommittedRecording` exposes a typed
    /// receipt-based variant.
    func removeRecording(_ recording: Recording) async throws {
        _ = try await removeRow(recordingID: recording.id)
        _ = await loadRecordings()
    }

    @discardableResult
    func removeCommittedRecording(_ receipt: RecordingCommitReceipt) async -> RecordingCompensationResult {
        do {
            let removed = try await removeRow(recordingID: receipt.recordingID)
            _ = await loadRecordings()
            return RecordingCompensationResult(
                recordingID: receipt.recordingID,
                state: removed ? .removed : .alreadyAbsent
            )
        } catch {
            let failure = Self.storeError(
                error,
                default: .databaseDeleteFailed(error.localizedDescription)
            )
            return RecordingCompensationResult(
                recordingID: receipt.recordingID,
                state: .failed,
                error: failure
            )
        }
    }

    private func removeRow(recordingID: UUID) async throws -> Bool {
        guard let dbQueue else {
            throw initializationFailure
                ?? RecordingStoreError.databaseUnavailable("The history database is not open.")
        }
        do {
            try checkDatabaseOperation(.delete)
            return try await dbQueue.write { db in
                let existing = try Recording
                    .filter(Recording.Columns.id == recordingID)
                    .fetchOne(db)
                guard existing != nil else { return false }
                _ = try Recording
                    .filter(Recording.Columns.id == recordingID)
                    .deleteAll(db)
                return true
            }
        } catch {
            throw Self.storeError(
                error,
                default: .databaseDeleteFailed(error.localizedDescription)
            )
        }
    }

    // MARK: - Awaitable deletion

    /// Async overload retained alongside the synchronous compatibility method
    /// below. Its result contains DB/file compensation outcomes explicitly.
    @discardableResult
    func deleteRecording(_ recording: Recording) async -> RecordingDeletionResult {
        await deleteRecordingAndAwait(recording)
    }

    /// Deletes from an authoritative row snapshot using same-volume
    /// quarantine. A database failure restores the file when possible; a
    /// failed restore is returned as repair-required rather than hidden.
    @discardableResult
    func deleteRecordingAndAwait(_ recording: Recording) async -> RecordingDeletionResult {
        guard let dbQueue else {
            let error = initializationFailure
                ?? .databaseUnavailable("The history database is not open.")
            return RecordingDeletionResult(
                recordingID: recording.id,
                state: .failedBeforeDatabaseChange,
                originalFileURL: url(for: recording),
                rowRemoved: false,
                audioRemoved: false,
                error: error
            )
        }

        let authoritative: Recording?
        do {
            try checkDatabaseOperation(.read)
            authoritative = try await dbQueue.read { db in
                try Recording
                    .filter(Recording.Columns.id == recording.id)
                    .fetchOne(db)
            }
        } catch {
            let failure = Self.storeError(
                error,
                default: .databaseReadFailed(error.localizedDescription)
            )
            return RecordingDeletionResult(
                recordingID: recording.id,
                state: .failedBeforeDatabaseChange,
                originalFileURL: url(for: recording),
                rowRemoved: false,
                audioRemoved: false,
                error: failure
            )
        }

        guard let authoritative else {
            let destination = url(for: recording)
            return RecordingDeletionResult(
                recordingID: recording.id,
                state: .alreadyAbsent,
                originalFileURL: destination,
                rowRemoved: false,
                audioRemoved: !fileSystem.fileExists(at: destination)
            )
        }

        let originalURL = url(for: authoritative)
        let hasAudio = fileSystem.fileExists(at: originalURL)
        var quarantineURL: URL?
        var movedToQuarantine = false

        if hasAudio {
            do {
                try fileSystem.createDirectory(at: quarantineDirectory)
                let destination = quarantineURLFor(authoritative)
                try fileSystem.moveItem(at: originalURL, to: destination)
                quarantineURL = destination
                movedToQuarantine = true
            } catch {
                let failure = Self.fileError(error, operation: "quarantine", url: originalURL)
                return RecordingDeletionResult(
                    recordingID: authoritative.id,
                    state: .failedBeforeDatabaseChange,
                    originalFileURL: originalURL,
                    rowRemoved: false,
                    audioRemoved: false,
                    error: failure
                )
            }
        }

        do {
            _ = try await removeRow(recordingID: authoritative.id)
        } catch {
            let databaseFailure = Self.storeError(
                error,
                default: .databaseDeleteFailed(error.localizedDescription)
            )
            guard movedToQuarantine, let quarantineURL else {
                return RecordingDeletionResult(
                    recordingID: authoritative.id,
                    state: .failedBeforeDatabaseChange,
                    originalFileURL: originalURL,
                    rowRemoved: false,
                    audioRemoved: false,
                    error: databaseFailure
                )
            }

            do {
                guard !fileSystem.fileExists(at: originalURL) else {
                    throw NSError(
                        domain: "RecordingStore",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The recording destination reappeared."]
                    )
                }
                try fileSystem.moveItem(at: quarantineURL, to: originalURL)
                return RecordingDeletionResult(
                    recordingID: authoritative.id,
                    state: .databaseFailedFileRestored,
                    originalFileURL: originalURL,
                    quarantineURL: nil,
                    rowRemoved: false,
                    audioRemoved: false,
                    error: databaseFailure
                )
            } catch {
                let restoreFailure = Self.fileError(
                    error,
                    operation: "restore quarantined",
                    url: originalURL
                )
                return RecordingDeletionResult(
                    recordingID: authoritative.id,
                    state: .databaseFailedRepairRequired,
                    originalFileURL: originalURL,
                    quarantineURL: quarantineURL,
                    rowRemoved: false,
                    audioRemoved: false,
                    error: .recoveryFailed(
                        "\(databaseFailure.localizedDescription); \(restoreFailure.localizedDescription)"
                    )
                )
            }
        }

        var cleanupError: RecordingStoreError?
        if let quarantineURL {
            do {
                try fileSystem.removeItem(at: quarantineURL)
            } catch {
                cleanupError = Self.fileError(error, operation: "remove quarantine", url: quarantineURL)
            }
        }

        _ = await loadRecordings()
        if let cleanupError {
            return RecordingDeletionResult(
                recordingID: authoritative.id,
                state: .deletedWithCleanupPending,
                originalFileURL: originalURL,
                quarantineURL: quarantineURL,
                rowRemoved: true,
                audioRemoved: false,
                error: cleanupError
            )
        }
        return RecordingDeletionResult(
            recordingID: authoritative.id,
            state: .deleted,
            originalFileURL: originalURL,
            quarantineURL: nil,
            rowRemoved: true,
            audioRemoved: !hasAudio || !fileSystem.fileExists(at: originalURL)
        )
    }

    /// The old UI invokes deletion without awaiting it. Keep that source
    /// compatibility while exposing `deleteRecordingAndAwait` for all new
    /// callers.
    func deleteRecording(_ recording: Recording) {
        Task { @MainActor [weak self] in
            _ = await self?.deleteRecordingAndAwait(recording)
        }
    }

    @discardableResult
    func deleteAllRecordingsAndAwait() async -> RecordingBulkDeletionResult {
        guard let dbQueue else {
            let error = initializationFailure
                ?? .databaseUnavailable("The history database is not open.")
            return RecordingBulkDeletionResult(results: [], error: error)
        }

        let authoritative: [Recording]
        do {
            try checkDatabaseOperation(.read)
            authoritative = try await Self.fetchAllRecordings(from: dbQueue)
        } catch {
            let failure = Self.storeError(
                error,
                default: .databaseReadFailed(error.localizedDescription)
            )
            historyStatus = .staleWithError(failure.localizedDescription)
            return RecordingBulkDeletionResult(results: [], error: failure)
        }

        var results: [RecordingDeletionResult] = []
        for recording in authoritative {
            results.append(await deleteRecordingAndAwait(recording))
        }
        _ = await loadRecordings()
        return RecordingBulkDeletionResult(results: results)
    }

    /// Async overload for callers that naturally use the legacy operation
    /// name. The synchronous overload below remains for the current UI.
    @discardableResult
    func deleteAllRecordings() async -> RecordingBulkDeletionResult {
        await deleteAllRecordingsAndAwait()
    }

    func deleteAllRecordings() {
        Task { @MainActor [weak self] in
            _ = await self?.deleteAllRecordingsAndAwait()
        }
    }

    // MARK: - Reconciliation and recovery

    /// Reconciles rows and app-owned audio paths without deleting unknown
    /// files. Recovered artifacts remain in the published inventory, making
    /// repeated calls idempotent and allowing the UI to surface repair work.
    @discardableResult
    func reconcile() async -> RecordingReconciliationReport {
        guard let dbQueue else {
            let error = initializationFailure
                ?? .databaseUnavailable("The history database is not open.")
            let report = RecordingReconciliationReport(
                missingRecordings: recordings,
                recoveredArtifacts: recoveryInventory,
                errors: [error.localizedDescription]
            )
            missingRecordings = recordings
            reconciliationReport = report
            return report
        }

        do {
            try checkDatabaseOperation(.read)
            let rows = try await Self.fetchAllRecordings(from: dbQueue)
            recordings = rows
            let report = reconcileFiles(for: rows)
            missingRecordings = report.missingRecordings
            historyStatus = report.errors.isEmpty
                ? .available
                : .staleWithError(report.errors.joined(separator: "; "))
            return report
        } catch {
            let failure = Self.storeError(
                error,
                default: .databaseReadFailed(error.localizedDescription)
            )
            historyStatus = recordings.isEmpty
                ? .unavailable(failure.localizedDescription)
                : .staleWithError(failure.localizedDescription)
            return RecordingReconciliationReport(
                missingRecordings: recordings,
                recoveredArtifacts: recoveryInventory,
                errors: [failure.localizedDescription]
            )
        }
    }

    /// Places an audio file and transcript sidecars in Recovery. This path
    /// intentionally does not require a healthy database and is safe to call
    /// while history is unavailable.
    @discardableResult
    func preserveForRecovery(_ request: RecordingRecoveryRequest) async -> RecordingRecoveryResult {
        let basename = safeBasename(request.recording.fileName, fallback: "recording.wav")
        let recoveryStem = "recovery-\(request.recording.id.uuidString)-\(basename)"
        let audioDestination = recoveryDirectory.appendingPathComponent(recoveryStem)
        let transcriptDestination = recoveryDirectory.appendingPathComponent("\(recoveryStem).txt")
        let metadataDestination = recoveryDirectory.appendingPathComponent("\(recoveryStem).json")

        do {
            try fileSystem.createDirectory(at: recoveryDirectory)
        } catch {
            return RecordingRecoveryResult(
                receipt: nil,
                error: .recoveryDirectoryFailed(error.localizedDescription)
            )
        }

        var transcriptURL: URL?
        do {
            try fileSystem.write(Data(request.recording.transcription.utf8), to: transcriptDestination)
            transcriptURL = transcriptDestination
        } catch {
            return RecordingRecoveryResult(
                receipt: nil,
                error: .transcriptWriteFailed(error.localizedDescription)
            )
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let metadata = try encoder.encode(request.recording)
            try fileSystem.write(metadata, to: metadataDestination)
        } catch {
            return RecordingRecoveryResult(
                receipt: RecordingRecoveryReceipt(
                    recordingID: request.recording.id,
                    audioURL: nil,
                    transcriptURL: transcriptURL,
                    metadataURL: nil
                ),
                error: .metadataWriteFailed(error.localizedDescription)
            )
        }

        guard fileSystem.fileExists(at: request.sourceURL) else {
            return RecordingRecoveryResult(
                receipt: RecordingRecoveryReceipt(
                    recordingID: request.recording.id,
                    audioURL: nil,
                    transcriptURL: transcriptURL,
                    metadataURL: metadataDestination
                ),
                error: .audioSourceMissing(request.sourceURL)
            )
        }

        do {
            switch request.disposition {
            case .copy:
                try fileSystem.copyItem(at: request.sourceURL, to: audioDestination)
            case .move:
                try fileSystem.moveItem(at: request.sourceURL, to: audioDestination)
            }
        } catch {
            return RecordingRecoveryResult(
                receipt: RecordingRecoveryReceipt(
                    recordingID: request.recording.id,
                    audioURL: nil,
                    transcriptURL: transcriptURL,
                    metadataURL: metadataDestination
                ),
                error: .audioTransferFailed(error.localizedDescription)
            )
        }

        let receipt = RecordingRecoveryReceipt(
            recordingID: request.recording.id,
            audioURL: audioDestination,
            transcriptURL: transcriptURL,
            metadataURL: metadataDestination
        )
        appendRecoveryArtifact(RecordingRecoveryArtifact(
            kind: .preservedAfterPersistenceFailure,
            originalURL: request.sourceURL,
            recoveryURL: audioDestination,
            transcriptURL: transcriptURL,
            recordingID: request.recording.id
        ))
        return RecordingRecoveryResult(receipt: receipt)
    }

    /// Throwing convenience for operation code that already models recovery
    /// as an error path.
    func preserveAudioForRecovery(
        from sourceURL: URL,
        recording: Recording,
        disposition: RecordingRecoveryDisposition = .move
    ) async throws -> RecordingRecoveryReceipt {
        let result = await preserveForRecovery(RecordingRecoveryRequest(
            sourceURL: sourceURL,
            recording: recording,
            disposition: disposition
        ))
        guard let receipt = result.receipt, result.error == nil else {
            throw RecordingStoreError.recoveryFailed(
                result.error?.localizedDescription ?? "Unknown recovery failure."
            )
        }
        return receipt
    }

    func url(for recording: Recording) -> URL {
        recordingsDirectory.appendingPathComponent(
            safeBasename(recording.fileName, fallback: recording.id.uuidString)
        )
    }

    func availability(for recording: Recording) -> RecordingAvailability {
        let destination = url(for: recording)
        return fileSystem.fileExists(at: destination) && !fileSystem.isDirectory(at: destination)
            ? .playable(destination)
            : .missing(destination)
    }

    // MARK: - File reconciliation helpers

    private func reconcileFiles(for rows: [Recording]) -> RecordingReconciliationReport {
        var errors: [String] = []
        let knownNames = Set(rows.map(\.fileName))
        var recovered = recoveryInventory

        func scan(_ directory: URL) -> [URL] {
            do {
                guard fileSystem.fileExists(at: directory) else { return [] }
                return try fileSystem.contentsOfDirectory(at: directory)
            } catch {
                errors.append("\(directory.path): \(error.localizedDescription)")
                return []
            }
        }

        // Snapshot existing Recovery entries before moving new candidates so
        // one reconciliation pass cannot report the same moved file twice.
        let preexistingRecoveryFiles = scan(recoveryDirectory)

        for candidate in scan(recordingsDirectory) {
            guard !fileSystem.isDirectory(at: candidate), isAudioFile(candidate) else { continue }
            guard !knownNames.contains(candidate.lastPathComponent) else { continue }
            if let artifact = moveToRecovery(candidate, kind: .orphanAudio, prefix: "orphan") {
                recovered = mergeRecoveryArtifact(artifact, into: recovered)
            } else {
                errors.append("Could not quarantine orphan audio at \(candidate.path).")
            }
        }

        for candidate in scan(temporaryCaptureDirectory) {
            guard !fileSystem.isDirectory(at: candidate), isTemporaryCapture(candidate) else { continue }
            if let artifact = moveToRecovery(candidate, kind: .temporaryCapture, prefix: "temporary") {
                recovered = mergeRecoveryArtifact(artifact, into: recovered)
            } else {
                errors.append("Could not preserve temporary capture at \(candidate.path).")
            }
        }

        for candidate in scan(quarantineDirectory) {
            guard !fileSystem.isDirectory(at: candidate), isAudioFile(candidate) else { continue }
            if let artifact = moveToRecovery(candidate, kind: .pendingDeletion, prefix: "pending") {
                recovered = mergeRecoveryArtifact(artifact, into: recovered)
            } else {
                errors.append("Could not preserve pending deletion at \(candidate.path).")
            }
        }

        // Recovery is intentionally not cleaned up by startup. Existing
        // artifacts are part of the repair inventory even after a restart.
        for candidate in preexistingRecoveryFiles {
            guard !fileSystem.isDirectory(at: candidate), isAudioFile(candidate) else { continue }
            let kind: RecordingRecoveryKind
            let name = candidate.lastPathComponent
            if name.hasPrefix("temporary-") {
                kind = .temporaryCapture
            } else if name.hasPrefix("pending-") {
                kind = .pendingDeletion
            } else if name.hasPrefix("recovery-") {
                kind = .preservedAfterPersistenceFailure
            } else {
                kind = .orphanAudio
            }
            recovered = mergeRecoveryArtifact(
                RecordingRecoveryArtifact(
                    kind: kind,
                    originalURL: candidate,
                    recoveryURL: candidate
                ),
                into: recovered
            )
        }

        let missing = rows.filter { !availability(for: $0).isPlayable }
        let report = RecordingReconciliationReport(
            missingRecordings: missing,
            recoveredArtifacts: recovered,
            errors: errors
        )
        recoveryInventory = recovered
        reconciliationReport = report
        return report
    }

    private func moveToRecovery(
        _ sourceURL: URL,
        kind: RecordingRecoveryKind,
        prefix: String
    ) -> RecordingRecoveryArtifact? {
        do {
            try fileSystem.createDirectory(at: recoveryDirectory)
            let destination = recoveryDirectory.appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)-\(safeBasename(sourceURL.lastPathComponent, fallback: "audio.wav"))"
            )
            try fileSystem.moveItem(at: sourceURL, to: destination)
            return RecordingRecoveryArtifact(
                kind: kind,
                originalURL: sourceURL,
                recoveryURL: destination
            )
        } catch {
            return nil
        }
    }

    private func appendRecoveryArtifact(_ artifact: RecordingRecoveryArtifact) {
        recoveryInventory = mergeRecoveryArtifact(artifact, into: recoveryInventory)
        reconciliationReport = RecordingReconciliationReport(
            missingRecordings: missingRecordings,
            recoveredArtifacts: recoveryInventory,
            errors: reconciliationReport.errors
        )
    }

    private func mergeRecoveryArtifact(
        _ artifact: RecordingRecoveryArtifact,
        into artifacts: [RecordingRecoveryArtifact]
    ) -> [RecordingRecoveryArtifact] {
        guard !artifacts.contains(where: {
            samePath($0.recoveryURL, artifact.recoveryURL)
                || samePath($0.originalURL, artifact.originalURL)
        }) else {
            return artifacts
        }
        return artifacts + [artifact]
    }

    private func samePath(_ lhs: URL?, _ rhs: URL?) -> Bool {
        lhs?.standardizedFileURL.path == rhs?.standardizedFileURL.path
    }

    private func quarantineURLFor(_ recording: Recording) -> URL {
        let basename = safeBasename(recording.fileName, fallback: recording.id.uuidString)
        return quarantineDirectory.appendingPathComponent(
            "pending-\(recording.id.uuidString)-\(basename)"
        )
    }

    private func isAudioFile(_ url: URL) -> Bool {
        let supportedExtensions: Set<String> = [
            "wav", "m4a", "mp3", "caf", "aiff", "aif", "flac", "ogg"
        ]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func isTemporaryCapture(_ url: URL) -> Bool {
        guard isAudioFile(url) else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        return name.hasPrefix("recording-")
            || name.hasPrefix("temporary-")
            || name.range(of: "^[0-9]{10,}$", options: .regularExpression) != nil
    }

    private func safeBasename(_ name: String, fallback: String) -> String {
        let basename = URL(fileURLWithPath: name).lastPathComponent
        guard !basename.isEmpty, basename != ".", basename != ".." else { return fallback }
        return basename.replacingOccurrences(of: ":", with: "-")
    }

    private static func storeError(_ error: Error, default fallback: RecordingStoreError) -> RecordingStoreError {
        if let error = error as? RecordingStoreError { return error }
        return fallback
    }

    private static func fileError(_ error: Error, operation: String, url: URL) -> RecordingStoreError {
        .fileOperationFailed(
            operation: operation,
            path: url.path,
            message: error.localizedDescription
        )
    }

    private func checkDatabaseOperation(_ operation: RecordingDatabaseOperation) throws {
        if let failure = databaseFailureInjector?(operation) {
            throw failure
        }
    }
}
