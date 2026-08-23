import Foundation

/// The file operations needed by the fork identity migration. Keeping this
/// surface small makes the migration deterministic to test, including the
/// failure path where an atomic move is rejected by the filesystem.
protocol ForkIdentityFileManaging {
    func fileExists(atPath path: String) -> Bool
    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL]
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func removeItem(at URL: URL) throws
}

extension FileManager: ForkIdentityFileManaging {}

/// A reason startup must remain blocked until the user retries or resolves a
/// pair of folders. The paths are carried in the issue so the UI can reveal
/// exactly the locations that need attention.
struct ForkIdentityMigrationIssue: LocalizedError, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case conflict
        case fileOperation
    }

    let kind: Kind
    let message: String
    let legacyDirectory: URL
    let currentDirectory: URL

    var errorDescription: String? { message }

    var isConflict: Bool { kind == .conflict }
}

struct ForkIdentityMigrationReport: Equatable, Sendable {
    let storageMigrated: Bool
    let preferencesMigrated: Bool
    let retentionConfirmationRequired: Bool
    let wasAlreadyComplete: Bool

    init(
        storageMigrated: Bool = false,
        preferencesMigrated: Bool = false,
        retentionConfirmationRequired: Bool = false,
        wasAlreadyComplete: Bool = false
    ) {
        self.storageMigrated = storageMigrated
        self.preferencesMigrated = preferencesMigrated
        self.retentionConfirmationRequired = retentionConfirmationRequired
        self.wasAlreadyComplete = wasAlreadyComplete
    }
}

/// The result of the one-time fork identity migration.
///
/// `conflict` and `failure` are deliberately different outcomes, but both
/// are blocking: normal app managers and stores must not be constructed while
/// either condition remains unresolved.
enum ForkIdentityMigrationOutcome: Equatable, Sendable {
    case skippedForUITest
    case success(ForkIdentityMigrationReport)
    case conflict(ForkIdentityMigrationIssue)
    case failure(ForkIdentityMigrationIssue)

    var canStartApplication: Bool {
        switch self {
        case .success, .skippedForUITest:
            return true
        case .conflict, .failure:
            return false
        }
    }

    var isBlocking: Bool { !canStartApplication }

    var report: ForkIdentityMigrationReport? {
        guard case .success(let report) = self else { return nil }
        return report
    }

    var issue: ForkIdentityMigrationIssue? {
        switch self {
        case .conflict(let issue), .failure(let issue):
            return issue
        case .success, .skippedForUITest:
            return nil
        }
    }
}

/// Migrates data from the original bundle identity to the current fork
/// identity. The migration is versioned, idempotent, and intentionally owns
/// only the two app support directories and two persistent UserDefaults
/// domains named below. Keychain items are outside this migration and are
/// never read, copied, or deleted.
final class ForkIdentityMigrator {
    static let migrationVersion = 1
    static let migrationVersionKey = "forkIdentityMigrationVersion"
    static let recordingRetentionNeedsInitialConfirmationKey =
        "recordingRetentionNeedsInitialConfirmation"

    /// Migration-only compatibility identity. Do not use this for active
    /// storage, bundle, dispatch, or signing configuration.
    static let legacyBundleIdentifier = "ru.starmel.OpenSuperWhisper"
    static let currentBundleIdentifier = "net.mdo.OpenSuperWhisper"

    static let uiTestLaunchArgument = "--open-super-whisper-ui-test"
    static let uiTestEnvironmentKey = "OPEN_SUPER_WHISPER_UI_TEST"

    /// Convenience entry point for callers that do not need to retain the
    /// migrator instance. The initializer remains the preferred seam when a
    /// caller will retry with the same injected dependencies.
    @discardableResult
    static func migrate(
        fileManager: any ForkIdentityFileManaging = FileManager.default,
        applicationSupportDirectory: URL? = nil,
        legacyUserDefaults: UserDefaults? = nil,
        currentUserDefaults: UserDefaults? = nil,
        legacyDomainName: String = ForkIdentityMigrator.legacyBundleIdentifier,
        currentDomainName: String = ForkIdentityMigrator.currentBundleIdentifier,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ForkIdentityMigrationOutcome {
        ForkIdentityMigrator(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory,
            legacyUserDefaults: legacyUserDefaults,
            currentUserDefaults: currentUserDefaults,
            legacyDomainName: legacyDomainName,
            currentDomainName: currentDomainName,
            arguments: arguments,
            environment: environment
        ).migrate()
    }

    let fileManager: any ForkIdentityFileManaging
    let applicationSupportDirectory: URL
    let legacyUserDefaults: UserDefaults
    let currentUserDefaults: UserDefaults
    let legacyDomainName: String
    let currentDomainName: String
    let arguments: [String]
    let environment: [String: String]

    init(
        fileManager: any ForkIdentityFileManaging = FileManager.default,
        applicationSupportDirectory: URL? = nil,
        legacyUserDefaults: UserDefaults? = nil,
        currentUserDefaults: UserDefaults? = nil,
        legacyDomainName: String = ForkIdentityMigrator.legacyBundleIdentifier,
        currentDomainName: String = ForkIdentityMigrator.currentBundleIdentifier,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.temporaryDirectory
        self.legacyDomainName = legacyDomainName
        self.currentDomainName = currentDomainName
        self.legacyUserDefaults = legacyUserDefaults
            ?? UserDefaults(suiteName: legacyDomainName)
            ?? .standard
        // The production app reads UserDefaults.standard. Keep the injected
        // test-suite seam, but use that same standard instance for the active
        // production domain so copied values are immediately visible to
        // AppPreferences and KeyboardShortcuts.
        self.currentUserDefaults = currentUserDefaults
            ?? (currentDomainName == Self.currentBundleIdentifier
                ? .standard
                : (UserDefaults(suiteName: currentDomainName) ?? .standard))
        self.arguments = arguments
        self.environment = environment
    }

    /// Compatibility spelling for tests and integrations that refer to the
    /// domains as simply old/new. It intentionally delegates to the primary
    /// initializer so production behavior has one implementation path.
    convenience init(
        fileManager: any ForkIdentityFileManaging = FileManager.default,
        applicationSupportDirectory: URL? = nil,
        oldDefaults: UserDefaults,
        newDefaults: UserDefaults,
        oldDomainName: String = ForkIdentityMigrator.legacyBundleIdentifier,
        newDomainName: String = ForkIdentityMigrator.currentBundleIdentifier,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory,
            legacyUserDefaults: oldDefaults,
            currentUserDefaults: newDefaults,
            legacyDomainName: oldDomainName,
            currentDomainName: newDomainName,
            arguments: arguments,
            environment: environment
        )
    }

    var legacyApplicationDirectory: URL {
        applicationSupportDirectory.appendingPathComponent(
            Self.legacyBundleIdentifier,
            isDirectory: true
        )
    }

    var currentApplicationDirectory: URL {
        applicationSupportDirectory.appendingPathComponent(
            Self.currentBundleIdentifier,
            isDirectory: true
        )
    }

    var isUITestLaunch: Bool {
        // The explicit launch argument is the authoritative opt-in. The
        // environment marker is retained for callers that want to pass the
        // same launch context through subprocesses, but is not required: a
        // UI-test runner must never risk touching production migration data.
        arguments.contains(Self.uiTestLaunchArgument)
    }

    /// Performs the complete migration. A successful result is the only
    /// result that permits normal app composition to proceed. In particular,
    /// an unsuccessful move never falls back to a newly-created blank path.
    @discardableResult
    func migrate() -> ForkIdentityMigrationOutcome {
        if isUITestLaunch {
            return .skippedForUITest
        }

        let currentDomain = persistentDomain(
            from: currentUserDefaults,
            name: currentDomainName
        )
        let alreadyComplete = migrationVersion(in: currentDomain) == Self.migrationVersion

        let legacyDirectory = legacyApplicationDirectory.standardizedFileURL
        let currentDirectory = currentApplicationDirectory.standardizedFileURL
        let legacyExists = fileManager.fileExists(atPath: legacyDirectory.path)
        let currentExists = fileManager.fileExists(atPath: currentDirectory.path)

        var storageMigrated = false
        var actualLegacyStorageData = false

        let existingCurrentEntries: [URL]?
        if currentExists {
            do {
                existingCurrentEntries = try directoryEntries(at: currentDirectory)
            } catch {
                return .failure(
                    issue(
                        kind: .fileOperation,
                        operation: "inspect current storage",
                        error: error,
                        legacyDirectory: legacyDirectory,
                        currentDirectory: currentDirectory
                    )
                )
            }
        } else {
            existingCurrentEntries = nil
        }

        // A completion marker is trusted only when no legacy storage remains
        // and the current path was successfully inspected. If a prior crash
        // left legacy data behind, continue through the conflict-safe path
        // instead of silently starting with a split installation.
        if alreadyComplete && !legacyExists {
            return .success(ForkIdentityMigrationReport(wasAlreadyComplete: true))
        }

        if legacyExists {
            let legacyEntries: [URL]
            do {
                legacyEntries = try directoryEntries(at: legacyDirectory)
            } catch {
                return .failure(
                    issue(
                        kind: .fileOperation,
                        operation: "inspect legacy storage",
                        error: error,
                        legacyDirectory: legacyDirectory,
                        currentDirectory: currentDirectory
                    )
                )
            }
            actualLegacyStorageData = !legacyEntries.isEmpty

            if currentExists {
                let currentEntries = existingCurrentEntries ?? []

                if !legacyEntries.isEmpty && !currentEntries.isEmpty {
                    return .conflict(
                        issue(
                            kind: .conflict,
                            operation: "migrate recording storage",
                            error: nil,
                            legacyDirectory: legacyDirectory,
                            currentDirectory: currentDirectory
                        )
                    )
                }

                // A truly empty new scaffold is safe to remove. No merge is
                // attempted; the complete legacy directory (including an
                // empty one) moves into its place atomically.
                if currentEntries.isEmpty {
                    do {
                        try fileManager.removeItem(at: currentDirectory)
                    } catch {
                        return .failure(
                            issue(
                                kind: .fileOperation,
                                operation: "remove the empty current storage scaffold",
                                error: error,
                                legacyDirectory: legacyDirectory,
                                currentDirectory: currentDirectory
                            )
                        )
                    }
                    do {
                        try fileManager.moveItem(at: legacyDirectory, to: currentDirectory)
                        storageMigrated = true
                    } catch {
                        return .failure(
                            issue(
                                kind: .fileOperation,
                                operation: "move legacy storage",
                                error: error,
                                legacyDirectory: legacyDirectory,
                                currentDirectory: currentDirectory
                            )
                        )
                    }
                } else if legacyEntries.isEmpty {
                    // There is no legacy data to merge into the populated
                    // current directory. Remove only the verified-empty
                    // obsolete scaffold so a successful upgrade cannot leave
                    // two competing storage roots behind.
                    do {
                        try fileManager.removeItem(at: legacyDirectory)
                    } catch {
                        return .failure(
                            issue(
                                kind: .fileOperation,
                                operation: "remove the empty legacy storage scaffold",
                                error: error,
                                legacyDirectory: legacyDirectory,
                                currentDirectory: currentDirectory
                            )
                        )
                    }
                }
            } else {
                do {
                    try fileManager.moveItem(at: legacyDirectory, to: currentDirectory)
                    storageMigrated = true
                } catch {
                    return .failure(
                        issue(
                            kind: .fileOperation,
                            operation: "move legacy storage",
                            error: error,
                            legacyDirectory: legacyDirectory,
                            currentDirectory: currentDirectory
                        )
                    )
                }
            }
        }

        // Storage is now either migrated or known not to require migration.
        // Only at this point are preferences copied and the old domain
        // retired. If storage was blocked above, no preference domain is
        // changed and a retry sees the same complete legacy state.
        let legacyDomain = persistentDomain(
            from: legacyUserDefaults,
            name: legacyDomainName
        )
        var mergedDomain = currentDomain
        var preferencesMigrated = false
        for (key, value) in legacyDomain where mergedDomain[key] == nil {
            mergedDomain[key] = value
            preferencesMigrated = true
        }

        let actualLegacyDataMigrated = actualLegacyStorageData || !legacyDomain.isEmpty
        if actualLegacyDataMigrated {
            mergedDomain[Self.recordingRetentionNeedsInitialConfirmationKey] = true
        }
        mergedDomain[Self.migrationVersionKey] = Self.migrationVersion

        currentUserDefaults.setPersistentDomain(mergedDomain, forName: currentDomainName)
        // Retire the legacy suite even when it was an explicitly-created
        // empty domain. A successful migration must not leave a second
        // identity behind for a future launch to rediscover.
        legacyUserDefaults.removePersistentDomain(forName: legacyDomainName)

        return .success(
            ForkIdentityMigrationReport(
                storageMigrated: storageMigrated,
                preferencesMigrated: preferencesMigrated,
                retentionConfirmationRequired: actualLegacyDataMigrated,
                wasAlreadyComplete: false
            )
        )
    }

    private func directoryEntries(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )
    }

    private func persistentDomain(
        from defaults: UserDefaults,
        name: String
    ) -> [String: Any] {
        defaults.persistentDomain(forName: name) ?? [:]
    }

    private func migrationVersion(in domain: [String: Any]) -> Int? {
        if let value = domain[Self.migrationVersionKey] as? Int {
            return value
        }
        if let value = domain[Self.migrationVersionKey] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private func issue(
        kind: ForkIdentityMigrationIssue.Kind,
        operation: String,
        error: Error?,
        legacyDirectory: URL,
        currentDirectory: URL
    ) -> ForkIdentityMigrationIssue {
        let suffix = error.map { ": \($0.localizedDescription)" } ?? ""
        let message: String
        if kind == .conflict {
            message = "Both recording folders contain data. Resolve the conflict before continuing. "
                + "Legacy: \(legacyDirectory.path). Current: \(currentDirectory.path)."
        } else {
            message = "Could not \(operation) (legacy: \(legacyDirectory.path), current: \(currentDirectory.path))\(suffix)"
        }
        return ForkIdentityMigrationIssue(
            kind: kind,
            message: message,
            legacyDirectory: legacyDirectory,
            currentDirectory: currentDirectory
        )
    }
}
