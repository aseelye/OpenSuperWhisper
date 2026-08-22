import Foundation
import GRDB

struct Recording: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable {
    let id: UUID
    let timestamp: Date
    let fileName: String
    let transcription: String
    let duration: TimeInterval
    /// Nullable so rows written before the metadata migration remain valid.
    let backend: String?
    /// The locale used by the selected transcription backend, if known.
    let locale: String?
    /// JSON encoded `[TranscriptSegment]`, if the backend supplied
    /// timed segments.  OpenAI's general-purpose model intentionally leaves
    /// this nil.
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
        return lhs.id == rhs.id
    }

    static var recordingsDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let appDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!)
        return appDirectory.appendingPathComponent("recordings")
    }

    var url: URL {
        Self.recordingsDirectory.appendingPathComponent(fileName)
    }

    /// Decoded timing metadata for history details.  A malformed payload is
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
    /// engine module.  Callers can map their provider-neutral segments to this
    /// shape at the session boundary.
    static func encodeTranscriptSegments(
        _ segments: [TranscriptSegment]
    ) -> Data? {
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

@MainActor
class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    @Published private(set) var recordings: [Recording] = []
    private let dbQueue: DatabaseQueue

    /// Creates a store at the app's normal database path.  A path can be
    /// supplied by tests (or another app composition root) so schema
    /// migration can be exercised without touching the user's history.
    init(databasePath: URL? = nil, automaticallyLoad: Bool = true) {
        // Setup database
        let dbPath: URL
        let appDirectory: URL
        if let databasePath {
            dbPath = databasePath
            appDirectory = databasePath.deletingLastPathComponent()
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            appDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!)
            dbPath = appDirectory.appendingPathComponent("recordings.sqlite")
        }

        print("Database path: \(dbPath.path)")

        do {
            try FileManager.default.createDirectory(
                at: appDirectory, withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: dbPath.path)
            try setupDatabase()
            if automaticallyLoad {
                Task {
                    await loadRecordings()
                }
            }
        } catch {
            fatalError("Failed to setup database: \(error)")
        }
    }

    private nonisolated func setupDatabase() throws {
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

            // `ifNotExists` does not alter an existing table.  Add each field
            // independently so partially migrated databases are recoverable.
            let existingColumns = try db.columns(in: Recording.databaseTableName)
                .map(\.name)
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

    func loadRecordings() async {
        do {
            let loadedRecordings = try await fetchAllRecordings()
            await MainActor.run {
                self.recordings = loadedRecordings
            }
        } catch {
            print("Failed to load recordings: \(error)")
        }
    }
    
    private nonisolated func fetchAllRecordings() async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .order(Recording.Columns.timestamp.desc)
                .fetchAll(db)
        }
    }

    /// Inserts a history row and refreshes the published list before
    /// returning. Callers that moved/copied an audio file can therefore wait
    /// for the database result and roll the file back if insertion fails.
    func addRecording(_ recording: Recording) async throws {
        try await insertRecording(recording)
        await loadRecordings()
    }

    /// Removes a history row and refreshes the published list before
    /// returning. This is used to compensate a persistence operation when
    /// cancellation arrives after insertion but before the session can report
    /// success.
    func removeRecording(_ recording: Recording) async throws {
        try await deleteRecordingFromDB(recording)
        await loadRecordings()
    }
    
    private nonisolated func insertRecording(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            try recording.insert(db)
        }
    }

    func deleteRecording(_ recording: Recording) {
        Task {
            do {
                try await deleteRecordingFromDB(recording)
                try FileManager.default.removeItem(at: recording.url)
                await loadRecordings()
            } catch {
                print("Failed to delete recording: \(error)")
                await loadRecordings()
            }
        }
    }
    
    private nonisolated func deleteRecordingFromDB(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            _ = try recording.delete(db)
        }
    }

    func deleteAllRecordings() {
        Task {
            do {
                // Delete all files first
                for recording in recordings {
                    try? FileManager.default.removeItem(at: recording.url)
                }

                // Then clear the database
                try await deleteAllRecordingsFromDB()
                await loadRecordings()
            } catch {
                print("Failed to delete all recordings: \(error)")
            }
        }
    }
    
    private nonisolated func deleteAllRecordingsFromDB() async throws {
        try await dbQueue.write { db in
            _ = try Recording.deleteAll(db)
        }
    }

    func searchRecordings(query: String) -> [Recording] {
        // For search, we'll keep it synchronous since it's used directly in UI
        // and we want immediate results
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter(Recording.Columns.transcription.like("%\(query)%").collating(.nocase))
                    .order(Recording.Columns.timestamp.desc)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to search recordings: \(error)")
            return []
        }
    }
}
