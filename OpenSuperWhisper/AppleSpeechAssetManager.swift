import Combine
import Foundation
import Speech

/// User-facing state for one Apple Speech language asset.
public enum AppleSpeechAssetState: String, Codable, Equatable, Sendable {
    case unsupported
    case supported
    case downloading
    case installed
    case failed
}

public struct AppleSpeechAssetStatus: Equatable, Sendable {
    public let locale: Locale
    public let state: AppleSpeechAssetState
    public let progress: Double
    public let errorMessage: String?

    public init(
        locale: Locale,
        state: AppleSpeechAssetState,
        progress: Double = 0,
        errorMessage: String? = nil
    ) {
        self.locale = locale
        self.state = state
        self.progress = min(max(progress, 0), 1)
        self.errorMessage = errorMessage
    }

    public var isReady: Bool { state == .installed }
    public var localeIdentifier: String { locale.identifier }
}

/// Injectable boundary for engine and settings tests. The concrete manager
/// below talks to Apple's AssetInventory; tests can provide a deterministic
/// implementation without downloading system language assets.
@MainActor
public protocol AppleSpeechAssetManaging: AnyObject {
    var supportedLocales: [Locale] { get }
    var installedLocales: [Locale] { get }
    var activeLocale: Locale? { get }
    var currentStatus: AppleSpeechAssetStatus? { get }

    func refresh() async -> [Locale]
    func supportedLocale(equivalentTo locale: Locale) async -> Locale?
    func status(for locale: Locale) async -> AppleSpeechAssetStatus
    func prepare(locale: Locale) async throws -> Locale
    func release(locale: Locale?) async
}

/// The asset manager owns Speech reservations for the process. Preparations
/// are single-flight, and each successfully returned locale remains reserved
/// until an explicit `release(locale:)` call (or process termination), so a
/// locale switch cannot invalidate an analyzer that is still being built.
@MainActor
public final class AppleSpeechAssetManager: ObservableObject, AppleSpeechAssetManaging {
    public static let shared = AppleSpeechAssetManager()

    /// The manager is deliberately the only owner of Speech reservations. A
    /// preparation can suspend at any of the Speech framework calls below,
    /// so `prepare` uses a single-flight operation and the completed
    /// reservation ledger keeps every locale returned to a caller alive.
    ///
    /// These hooks keep the reservation policy deterministic in tests without
    /// making the production manager depend on a second Speech implementation.
    internal struct TestHooks {
        let supportedLocales: @MainActor () async -> [Locale]
        let installedLocales: @MainActor () async -> [Locale]
        let supportedLocale: @MainActor (Locale) async -> Locale?
        let status: @MainActor (Locale) async -> AppleSpeechAssetState
        let install: @MainActor (Locale) async throws -> Void
        let reserve: @MainActor (Locale) async -> Bool
        let release: @MainActor (Locale) async -> Bool
        let waiterRegistered: (@MainActor () -> Void)?
        let progressSource: TestProgressSource?

        init(
            supportedLocales: @escaping @MainActor () async -> [Locale],
            installedLocales: @escaping @MainActor () async -> [Locale],
            supportedLocale: @escaping @MainActor (Locale) async -> Locale?,
            status: @escaping @MainActor (Locale) async -> AppleSpeechAssetState,
            install: @escaping @MainActor (Locale) async throws -> Void,
            reserve: @escaping @MainActor (Locale) async -> Bool,
            release: @escaping @MainActor (Locale) async -> Bool,
            waiterRegistered: (@MainActor () -> Void)? = nil,
            progressSource: TestProgressSource? = nil
        ) {
            self.supportedLocales = supportedLocales
            self.installedLocales = installedLocales
            self.supportedLocale = supportedLocale
            self.status = status
            self.install = install
            self.reserve = reserve
            self.release = release
            self.waiterRegistered = waiterRegistered
            self.progressSource = progressSource
        }
    }

    /// Deterministic progress callback seam for tests. Production progress
    /// callbacks are delivered asynchronously by `Progress`; retaining the
    /// callbacks here lets tests deliver an old callback after a replacement
    /// preparation has become current.
    @MainActor
    internal final class TestProgressSource {
        typealias Callback = @MainActor (Double) -> Void

        private var callbacks: [Callback] = []

        var callbackCount: Int { callbacks.count }

        func register(_ callback: @escaping Callback) {
            callbacks.append(callback)
        }

        func emit(index: Int, progress: Double) {
            callbacks[index](progress)
        }
    }

    private final class PreparationOperation {
        let requestedIdentifier: String
        let generation: UInt64
        let identity: PreparationIdentity
        let task: Task<Locale, Error>
        var waiterCount = 0

        init(
            requestedIdentifier: String,
            generation: UInt64,
            identity: PreparationIdentity,
            task: Task<Locale, Error>
        ) {
            self.requestedIdentifier = requestedIdentifier
            self.generation = generation
            self.identity = identity
            self.task = task
        }
    }

    private final class PreparationIdentity: @unchecked Sendable {}

    private final class RefreshIdentity {}

    /// A caller waits through its own continuation instead of awaiting the
    /// shared preparation task directly. This lets one canceled caller return
    /// immediately without canceling work that another caller still needs.
    private final class PreparationWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Locale, Error>?
        private var result: Result<Locale, Error>?

        func install(_ continuation: CheckedContinuation<Locale, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func cancel() {
            complete(.failure(CoreTranscriptionError.cancelled))
        }

        func complete(_ result: Result<Locale, Error>) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    @Published public private(set) var supportedLocales: [Locale] = []
    @Published public private(set) var installedLocales: [Locale] = []
    @Published public private(set) var activeLocale: Locale?
    @Published public private(set) var currentStatus: AppleSpeechAssetStatus?

    private var statusByIdentifier: [String: AppleSpeechAssetStatus] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshIdentity: RefreshIdentity?
    private var refreshGeneration: UInt64 = 0
    private var preparationOperation: PreparationOperation?
    private var latestPreparationGeneration: UInt64 = 0
    private var latestRequestedIdentifier: String?
    private var retainedReservations: [String: Locale] = [:]
    private let testHooks: TestHooks?

    public init() {
        self.testHooks = nil
    }

    internal init(testHooks: TestHooks) {
        self.testHooks = testHooks
    }

    deinit {
        refreshTask?.cancel()
        // Deliberately do not release retainedReservations here. Speech
        // analyzers use process-lifetime model retention, and reservations are
        // intentionally kept for the lifetime of this app process.
    }

    /// Enumerates locales supplied by the current OS instead of maintaining a
    /// hand-written language list that can drift from Speech's capabilities.
    @discardableResult
    public func refresh() async -> [Locale] {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let identity = RefreshIdentity()
        refreshIdentity = identity

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.finishRefresh(identity: identity, generation: generation)
            }

            let locales = await self.supportedLocalesFromInventory()
                .sorted { $0.identifier < $1.identifier }
            guard self.isCurrentRefresh(identity: identity, generation: generation) else { return }
            self.supportedLocales = locales
            self.installedLocales = await self.installedLocalesFromInventory()
                .sorted { $0.identifier < $1.identifier }
            guard self.isCurrentRefresh(identity: identity, generation: generation) else { return }
            for locale in locales {
                guard self.isCurrentRefresh(identity: identity, generation: generation) else { return }
                await self.updateStatus(
                    for: locale,
                    stateOnly: true,
                    refreshIdentity: identity,
                    refreshGeneration: generation
                )
            }
        }
        refreshTask = task
        await task.value
        finishRefresh(identity: identity, generation: generation)
        return supportedLocales
    }

    private func isCurrentRefresh(identity: RefreshIdentity, generation: UInt64) -> Bool {
        refreshGeneration == generation && refreshIdentity === identity
    }

    private func finishRefresh(identity: RefreshIdentity, generation: UInt64) {
        guard isCurrentRefresh(identity: identity, generation: generation) else { return }
        refreshTask = nil
        refreshIdentity = nil
    }

    /// Resolves a requested locale to Apple's closest supported regional
    /// locale. A caller can persist the returned identifier and use it for
    /// future starts without repeating fallback logic.
    public func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        if supportedLocales.isEmpty {
            _ = await refresh()
        }
        if let testHooks {
            return await testHooks.supportedLocale(locale)
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    public func status(for locale: Locale) async -> AppleSpeechAssetStatus {
        let resolved = await supportedLocale(equivalentTo: locale) ?? locale
        return await updateStatus(for: resolved, stateOnly: false)
    }

    /// Downloads and reserves the requested locale. Calls for one locale
    /// coalesce onto the same operation. A request for a different locale
    /// supersedes an in-flight operation; the old operation is cancelled and
    /// waits for its Speech call to unwind before the replacement starts.
    ///
    /// A completed reservation is retained in `retainedReservations` instead
    /// of being released as soon as another locale is selected. The caller
    /// receives only a `Locale`, so there is no later analyzer-construction
    /// acknowledgement that could make releasing the previous reservation
    /// safe. Keeping the lease for the process lifetime guarantees that every
    /// successful return still names a reserved asset.
    @discardableResult
    public func prepare(locale requestedLocale: Locale) async throws -> Locale {
        let requestedIdentifier = localeKey(requestedLocale)

        if latestRequestedIdentifier != requestedIdentifier {
            latestPreparationGeneration &+= 1
            latestRequestedIdentifier = requestedIdentifier
        }
        let requestGeneration = latestPreparationGeneration

        while true {
            if let operation = preparationOperation {
                if operation.requestedIdentifier == requestedIdentifier,
                   operation.generation == requestGeneration {
                    // A canceled waiter can leave its shared operation
                    // installed briefly while the operation unwinds. Do not
                    // attach a retry to that doomed task: wait for it to
                    // finish and let the loop create a fresh operation.
                    if operation.task.isCancelled || operation.waiterCount == 0 {
                        operation.task.cancel()
                        _ = try? await waitForPreparation(operation)
                        if preparationOperation === operation {
                            preparationOperation = nil
                        }
                        try ensureCallerIsNotCancelled()
                        continue
                    }
                    return try await waitForPreparation(operation)
                }

                // Do not let two installs/reservations overlap. Cancellation
                // is cooperative, so await the old task before retrying the
                // loop and starting the newest request.
                operation.task.cancel()
                _ = try? await waitForPreparation(operation)
                try ensureCallerIsNotCancelled()
                continue
            }

            guard requestGeneration == latestPreparationGeneration else {
                throw CoreTranscriptionError.cancelled
            }

            let identity = PreparationIdentity()
            let task = Task { @MainActor [weak self] in
                guard let self else { throw CoreTranscriptionError.cancelled }
                defer {
                    if let operation = self.preparationOperation,
                       operation.identity === identity,
                       operation.requestedIdentifier == requestedIdentifier,
                       operation.generation == requestGeneration {
                        self.preparationOperation = nil
                    }
                }
                do {
                    return try await self.performPreparation(
                        requestedLocale: requestedLocale,
                        generation: requestGeneration,
                        identity: identity
                    )
                } catch is CancellationError {
                    throw CoreTranscriptionError.cancelled
                } catch {
                    throw error
                }
            }
            let operation = PreparationOperation(
                requestedIdentifier: requestedIdentifier,
                generation: requestGeneration,
                identity: identity,
                task: task
            )
            preparationOperation = operation
            return try await waitForPreparation(operation)
        }
    }

    private func ensureCallerIsNotCancelled() throws {
        if Task.isCancelled {
            throw CoreTranscriptionError.cancelled
        }
    }

    private func waitForPreparation(_ operation: PreparationOperation) async throws -> Locale {
        operation.waiterCount += 1
        testHooks?.waiterRegistered?()
        defer {
            operation.waiterCount -= 1
            if operation.waiterCount == 0 {
                // A canceled/abandoned waiter must not leave an unneeded
                // download alive. This is harmless after normal completion.
                operation.task.cancel()
            }
        }

        let waiter = PreparationWaiter()
        Task { [operation, waiter] in
            do {
                waiter.complete(.success(try await operation.task.value))
            } catch {
                waiter.complete(.failure(error))
            }
        }

        let locale = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
            }
        }, onCancel: {
            waiter.cancel()
        })
        try ensureCallerIsNotCancelled()
        return locale
    }

    private func performPreparation(
        requestedLocale: Locale,
        generation: UInt64,
        identity: PreparationIdentity
    ) async throws -> Locale {
        let locale = try await resolveSupportedLocale(requestedLocale)
        try ensurePreparationIsCurrent(generation: generation, identity: identity)
        let key = localeKey(locale)

        if retainedReservations[key] != nil {
            // This locale was already successfully reserved by this manager.
            // Re-selecting it must not download or reserve it again.
            activeLocale = locale
            currentStatus = AppleSpeechAssetStatus(locale: locale, state: .installed, progress: 1)
            statusByIdentifier[key] = currentStatus
            return locale
        }

        var status = await updateStatus(
            for: locale,
            stateOnly: false,
            preparationIdentity: identity,
            preparationGeneration: generation
        )
        try ensurePreparationIsCurrent(generation: generation, identity: identity)

        switch status.state {
        case .unsupported:
            throw CoreTranscriptionError.unsupportedLocale(locale)
        case .installed:
            break
        case .supported, .downloading, .failed:
            do {
                try await install(locale: locale, generation: generation, identity: identity)
            } catch is CancellationError {
                throw CoreTranscriptionError.cancelled
            } catch let error as CoreTranscriptionError {
                guard error != .cancelled else { throw error }
                guard isCurrentPreparation(generation: generation, identity: identity) else {
                    throw CoreTranscriptionError.cancelled
                }
                setFailedStatus(for: locale, message: error.localizedDescription)
                throw error
            } catch {
                guard isCurrentPreparation(generation: generation, identity: identity) else {
                    throw CoreTranscriptionError.cancelled
                }
                let message = error.localizedDescription
                setFailedStatus(for: locale, message: message)
                throw CoreTranscriptionError.preparationFailed(message)
            }
            try ensurePreparationIsCurrent(generation: generation, identity: identity)
            status = await updateStatus(
                for: locale,
                stateOnly: false,
                preparationIdentity: identity,
                preparationGeneration: generation
            )
            try ensurePreparationIsCurrent(generation: generation, identity: identity)
            guard status.state == .installed else {
                throw CoreTranscriptionError.assetsUnavailable(locale)
            }
        }

        // Refresh this UI-facing value before the reservation commit. There
        // must be no suspension between the final cancellation check and the
        // state mutation that makes a reservation visible to the caller.
        let refreshedInstalledLocales = await installedLocalesFromInventory()
            .sorted { $0.identifier < $1.identifier }
        try ensurePreparationIsCurrent(generation: generation, identity: identity)

        let alreadyRetained = retainedReservations[key] != nil
        if !alreadyRetained {
            let reserved = try await reserve(locale: locale)
            guard reserved else {
                throw CoreTranscriptionError.preparationFailed(
                    "Apple Speech could not reserve \(locale.identifier)."
                )
            }

            // A reserve call may ignore Task cancellation. If a newer locale
            // arrived while it was suspended, release this unclaimed lease
            // before reporting cancellation; it was never returned to a
            // caller and therefore must not be kept in the ledger.
            do {
                try ensurePreparationIsCurrent(generation: generation, identity: identity)
            } catch {
                _ = await releaseReservedAsset(locale: locale)
                throw error
            }
        }

        // Keep this section synchronous. Once the locale is inserted in the
        // ledger, this invocation is allowed to return it: its reservation
        // cannot be released by a later locale switch.
        if !alreadyRetained {
            retainedReservations[key] = locale
        }
        activeLocale = locale
        currentStatus = AppleSpeechAssetStatus(locale: locale, state: .installed, progress: 1)
        statusByIdentifier[key] = currentStatus
        installedLocales = refreshedInstalledLocales
        return locale
    }

    /// Releases a reservation explicitly when a caller is intentionally
    /// shutting down its speech subsystem. Normal app usage should not call
    /// this; successful preparations are otherwise retained for process
    /// lifetime so an analyzer can be constructed after a locale switch.
    public func release(locale: Locale? = nil) async {
        guard let target = locale ?? activeLocale else { return }
        let key = localeKey(target)
        guard let retained = retainedReservations.removeValue(forKey: key) else {
            if localeKeysEqual(activeLocale, target) {
                activeLocale = nil
                currentStatus = nil
            }
            return
        }
        _ = await releaseReservedAsset(locale: retained)
        if localeKeysEqual(activeLocale, target) {
            activeLocale = nil
            currentStatus = nil
        }
    }

    private func isCurrentPreparation(generation: UInt64, identity: PreparationIdentity) -> Bool {
        guard let operation = preparationOperation else { return false }
        return operation.identity === identity
            && operation.generation == generation
            && latestPreparationGeneration == generation
    }

    private func ensurePreparationIsCurrent(
        generation: UInt64,
        identity: PreparationIdentity
    ) throws {
        if Task.isCancelled || !isCurrentPreparation(generation: generation, identity: identity) {
            throw CoreTranscriptionError.cancelled
        }
    }

    private func localeKey(_ locale: Locale) -> String {
        locale.identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    private func localeKeysEqual(_ lhs: Locale?, _ rhs: Locale) -> Bool {
        guard let lhs else { return false }
        return localeKey(lhs) == localeKey(rhs)
    }

    private func supportedLocalesFromInventory() async -> [Locale] {
        if let testHooks {
            return await testHooks.supportedLocales()
        }
        return await SpeechTranscriber.supportedLocales
    }

    private func installedLocalesFromInventory() async -> [Locale] {
        if let testHooks {
            return await testHooks.installedLocales()
        }
        return await SpeechTranscriber.installedLocales
    }

    private func reserve(locale: Locale) async throws -> Bool {
        if let testHooks {
            return await testHooks.reserve(locale)
        }
        return try await AssetInventory.reserve(locale: locale)
    }

    private func releaseReservedAsset(locale: Locale) async -> Bool {
        if let testHooks {
            return await testHooks.release(locale)
        }
        return await AssetInventory.release(reservedLocale: locale)
    }

    private func setFailedStatus(for locale: Locale, message: String) {
        let key = localeKey(locale)
        let status = AppleSpeechAssetStatus(
            locale: locale,
            state: .failed,
            progress: statusByIdentifier[key]?.progress ?? currentStatus?.progress ?? 0,
            errorMessage: message
        )
        currentStatus = status
        statusByIdentifier[key] = status
    }

    private func resolveSupportedLocale(_ requested: Locale) async throws -> Locale {
        if supportedLocales.isEmpty {
            _ = await refresh()
        }
        let resolved: Locale?
        if let testHooks {
            resolved = await testHooks.supportedLocale(requested)
        } else {
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        }
        guard let resolved else {
            let exact = supportedLocales.first { localeKey($0) == localeKey(requested) }
            guard let exact else { throw CoreTranscriptionError.unsupportedLocale(requested) }
            return exact
        }
        return resolved
    }

    private func install(
        locale: Locale,
        generation: UInt64,
        identity: PreparationIdentity
    ) async throws {
        try ensurePreparationIsCurrent(generation: generation, identity: identity)
        if let testHooks {
            let status = AppleSpeechAssetStatus(locale: locale, state: .downloading, progress: 0)
            currentStatus = status
            statusByIdentifier[localeKey(locale)] = status
            testHooks.progressSource?.register { [weak self] progress in
                guard let self,
                      self.isCurrentPreparation(generation: generation, identity: identity) else {
                    return
                }
                let progressStatus = AppleSpeechAssetStatus(
                    locale: locale,
                    state: .downloading,
                    progress: progress
                )
                self.currentStatus = progressStatus
                self.statusByIdentifier[self.localeKey(locale)] = progressStatus
            }
            try await testHooks.install(locale)
            try ensurePreparationIsCurrent(generation: generation, identity: identity)
            let installed = AppleSpeechAssetStatus(locale: locale, state: .installed, progress: 1)
            currentStatus = installed
            statusByIdentifier[localeKey(locale)] = installed
            return
        }

        let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
        try ensurePreparationIsCurrent(generation: generation, identity: identity)

        // A nil request means no download is necessary on this OS. Re-check
        // inventory below to keep the state machine correct for that case.
        if let request {
            let progress = request.progress
            currentStatus = AppleSpeechAssetStatus(
                locale: locale,
                state: .downloading,
                progress: progress.fractionCompleted
            )
            statusByIdentifier[localeKey(locale)] = currentStatus

            let observation = progress.observe(\Progress.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isCurrentPreparation(generation: generation, identity: identity) else {
                        return
                    }
                    let status = AppleSpeechAssetStatus(
                        locale: locale,
                        state: .downloading,
                        progress: progress.fractionCompleted
                    )
                    self.currentStatus = status
                    self.statusByIdentifier[self.localeKey(locale)] = status
                }
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
            try ensurePreparationIsCurrent(generation: generation, identity: identity)
        }

        let finalStatus = await AssetInventory.status(forModules: [module])
        try ensurePreparationIsCurrent(generation: generation, identity: identity)
        guard finalStatus == .installed else {
            let state: AppleSpeechAssetState = finalStatus == .downloading ? .downloading : .failed
            currentStatus = AppleSpeechAssetStatus(
                locale: locale,
                state: state,
                progress: 0,
                errorMessage: state == .failed ? "Apple did not finish installing the language asset." : nil
            )
            statusByIdentifier[localeKey(locale)] = currentStatus
            if state == .failed {
                throw CoreTranscriptionError.assetsUnavailable(locale)
            }
            return
        }
        currentStatus = AppleSpeechAssetStatus(locale: locale, state: .installed, progress: 1)
        statusByIdentifier[localeKey(locale)] = currentStatus
    }

    @discardableResult
    private func updateStatus(
        for locale: Locale,
        stateOnly: Bool,
        refreshIdentity: RefreshIdentity? = nil,
        refreshGeneration: UInt64? = nil,
        preparationIdentity: PreparationIdentity? = nil,
        preparationGeneration: UInt64? = nil
    ) async -> AppleSpeechAssetStatus {
        let state: AppleSpeechAssetState
        if let testHooks {
            state = await testHooks.status(locale)
        } else {
            let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            let inventoryStatus = await AssetInventory.status(forModules: [module])
            switch inventoryStatus {
            case .unsupported: state = .unsupported
            case .supported: state = .supported
            case .downloading: state = .downloading
            case .installed: state = .installed
            @unknown default: state = .supported
            }
        }
        let key = localeKey(locale)
        let previous = statusByIdentifier[key]
        let status = AppleSpeechAssetStatus(
            locale: locale,
            state: state,
            progress: state == .installed ? 1 : (stateOnly ? previous?.progress ?? 0 : 0),
            errorMessage: state == .failed ? previous?.errorMessage : nil
        )
        if let preparationIdentity,
           let preparationGeneration,
           !isCurrentPreparation(generation: preparationGeneration, identity: preparationIdentity) {
            return status
        }
        if let refreshIdentity,
           let refreshGeneration,
           !isCurrentRefresh(identity: refreshIdentity, generation: refreshGeneration) {
            return status
        }
        statusByIdentifier[key] = status
        if localeKeysEqual(activeLocale, locale) || currentStatus == nil {
            currentStatus = status
        }
        return status
    }
}
