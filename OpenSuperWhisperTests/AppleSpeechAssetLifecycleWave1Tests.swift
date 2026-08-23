import Foundation
import XCTest
@testable import OpenSuperWhisper

/// Wave 1 contract tests for caller identities, cancellation, stale
/// completion guards, progress projection, and process-lifetime reservations.
@MainActor
final class AppleSpeechAssetLifecycleWave1Tests: XCTestCase {
    func testSupersededLocaleCannotCommitAStalePreparation() async throws {
        let firstLocale = Locale(identifier: "en-US")
        let secondLocale = Locale(identifier: "fr-FR")
        let inventory = Wave1AssetInventory(locales: [firstLocale, secondLocale], gatedLocale: firstLocale)
        let manager = makeManager(inventory: inventory)
        let firstRequest = AppleSpeechAssetRequestID()
        let secondRequest = AppleSpeechAssetRequestID()

        let first = Task { @MainActor in
            try await manager.prepare(locale: firstLocale, requestID: firstRequest)
        }
        await inventory.waitForInstallStart(of: firstLocale)
        let second = Task { @MainActor in
            try await manager.prepare(locale: secondLocale, requestID: secondRequest)
        }

        await inventory.openInstall(of: firstLocale)
        let firstResult = await first.result
        guard case let .failure(error) = firstResult else {
            return XCTFail("A superseded locale must not report a successful preparation.")
        }
        XCTAssertEqual(error as? CoreTranscriptionError, .cancelled)
        let resolvedSecond = try await second.value
        XCTAssertEqual(resolvedSecond, secondLocale)

        let reservations = await inventory.reservationCalls
        XCTAssertEqual(reservations.map(\.identifier), [secondLocale.identifier])
    }

    func testRequestCancellationStopsPreparationBeforeReservation() async throws {
        let locale = Locale(identifier: "en-US")
        let inventory = Wave1AssetInventory(locales: [locale], gatedLocale: locale)
        let manager = makeManager(inventory: inventory)
        let requestID = AppleSpeechAssetRequestID()

        let preparation = Task { @MainActor in
            try await manager.prepare(locale: locale, requestID: requestID)
        }
        await inventory.waitForInstallStart(of: locale)

        manager.cancelPreparation(requestID: requestID)
        let result = await preparation.result
        guard case let .failure(error) = result else {
            return XCTFail("An explicitly canceled request must not succeed.")
        }
        XCTAssertEqual(error as? CoreTranscriptionError, .cancelled)

        // The fake install deliberately ignores task cancellation until its
        // gate opens, matching framework calls that unwind cooperatively.
        await inventory.openInstall(of: locale)
        await inventory.waitForInstallUnwind(of: locale)
        let reservations = await inventory.reservationCalls
        XCTAssertTrue(reservations.isEmpty)
    }

    func testStaleStatusCompletionCannotReplaceNewerLocale() async throws {
        let firstLocale = Locale(identifier: "en-US")
        let secondLocale = Locale(identifier: "fr-FR")
        let statusGate = Wave1StatusGate(locales: [firstLocale, secondLocale])
        let manager = makeManager(statusGate: statusGate)
        let firstRequest = AppleSpeechAssetRequestID()
        let secondRequest = AppleSpeechAssetRequestID()

        let first = Task { @MainActor in
            await manager.status(for: firstLocale, requestID: firstRequest)
        }
        await statusGate.waitForStart(of: firstLocale)

        let second = Task { @MainActor in
            await manager.status(for: secondLocale, requestID: secondRequest)
        }
        await statusGate.waitForStart(of: secondLocale)

        await statusGate.open(secondLocale)
        _ = await second.value
        XCTAssertEqual(manager.currentStatus?.localeIdentifier, secondLocale.identifier)

        await statusGate.open(firstLocale)
        _ = await first.value
        XCTAssertEqual(
            manager.currentStatus?.localeIdentifier,
            secondLocale.identifier,
            "The older status response must not roll the active projection back."
        )
    }

    func testStatusQueryPreservesLiveMonotonicDownloadProgress() async throws {
        let locale = Locale(identifier: "en-US")
        let inventory = Wave1AssetInventory(locales: [locale], gatedLocale: locale)
        let progressSource = AppleSpeechAssetManager.TestProgressSource()
        let manager = makeManager(inventory: inventory, progressSource: progressSource)
        let preparationRequest = AppleSpeechAssetRequestID()

        let preparation = Task { @MainActor in
            try await manager.prepare(locale: locale, requestID: preparationRequest)
        }
        await inventory.waitForInstallStart(of: locale)
        XCTAssertEqual(progressSource.callbackCount, 1)
        progressSource.emit(index: 0, progress: 0.72)

        let status = await manager.status(
            for: locale,
            requestID: AppleSpeechAssetRequestID()
        )
        XCTAssertEqual(status.state, .downloading)
        XCTAssertEqual(status.progress, 0.72, accuracy: 0.0001)

        // A late lower callback cannot regress the active request.
        progressSource.emit(index: 0, progress: 0.21)
        XCTAssertEqual(manager.currentStatus?.progress ?? -1, 0.72, accuracy: 0.0001)

        await inventory.openInstall(of: locale)
        _ = try await preparation.value
        XCTAssertEqual(manager.currentStatus?.progress, 1)
    }

    func testReservationsRemainProcessOwnedAcrossLocaleSwitch() async throws {
        let firstLocale = Locale(identifier: "en-US")
        let secondLocale = Locale(identifier: "fr-FR")
        let inventory = Wave1AssetInventory(locales: [firstLocale, secondLocale])
        let manager = makeManager(inventory: inventory)

        _ = try await manager.prepare(
            locale: firstLocale,
            requestID: AppleSpeechAssetRequestID()
        )
        _ = try await manager.prepare(
            locale: secondLocale,
            requestID: AppleSpeechAssetRequestID()
        )

        let recordedReservations = await inventory.reservationCalls
        let reservations = recordedReservations.map(\.identifier)
        XCTAssertEqual(reservations, [
            firstLocale.identifier,
            secondLocale.identifier
        ])
        let releases = await inventory.releaseCalls
        XCTAssertTrue(
            releases.isEmpty,
            "Returned reservations belong to the process manager and are not released on locale switch."
        )
    }

    private func makeManager(
        inventory: Wave1AssetInventory,
        progressSource: AppleSpeechAssetManager.TestProgressSource? = nil
    ) -> AppleSpeechAssetManager {
        AppleSpeechAssetManager(testHooks: .init(
            supportedLocales: { await inventory.supportedLocales },
            installedLocales: { await inventory.installedLocales },
            supportedLocale: { locale in await inventory.supportedLocale(equivalentTo: locale) },
            status: { locale in await inventory.status(for: locale) },
            install: { locale in await inventory.install(locale: locale) },
            reserve: { locale in await inventory.reserve(locale: locale) },
            release: { locale in await inventory.release(locale: locale) },
            progressSource: progressSource
        ))
    }

    private func makeManager(statusGate: Wave1StatusGate) -> AppleSpeechAssetManager {
        AppleSpeechAssetManager(testHooks: .init(
            supportedLocales: { [] },
            installedLocales: { [] },
            supportedLocale: { locale in await statusGate.supportedLocale(equivalentTo: locale) },
            status: { locale in await statusGate.status(for: locale) },
            install: { _ in },
            reserve: { _ in true },
            release: { _ in true }
        ))
    }
}

private actor Wave1AssetInventory {
    let locales: [Locale]
    let gatedLocaleIdentifier: String?

    private var installedIdentifiers = Set<String>()
    private(set) var reservationCalls: [Locale] = []
    private(set) var releaseCalls: [Locale] = []
    private var installContinuation: CheckedContinuation<Void, Never>?
    private var installStarted = false
    private var installUnwound = false
    private var installStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var installUnwindWaiters: [CheckedContinuation<Void, Never>] = []

    init(locales: [Locale], gatedLocale: Locale? = nil) {
        self.locales = locales
        self.gatedLocaleIdentifier = gatedLocale.map(Self.key)
    }

    var supportedLocales: [Locale] { locales }
    var installedLocales: [Locale] {
        locales.filter { installedIdentifiers.contains(Self.key($0)) }
    }

    func supportedLocale(equivalentTo locale: Locale) -> Locale? {
        locales.first { Self.key($0) == Self.key(locale) }
    }

    func status(for locale: Locale) -> AppleSpeechAssetState {
        if installedIdentifiers.contains(Self.key(locale)) { return .installed }
        return .downloading
    }

    func install(locale: Locale) async {
        installStarted = true
        installStartWaiters.forEach { $0.resume() }
        installStartWaiters.removeAll()
        if Self.key(locale) == gatedLocaleIdentifier {
            await withCheckedContinuation { continuation in
                installContinuation = continuation
            }
        }
        installedIdentifiers.insert(Self.key(locale))
        installUnwound = true
        installUnwindWaiters.forEach { $0.resume() }
        installUnwindWaiters.removeAll()
    }

    func reserve(locale: Locale) -> Bool {
        reservationCalls.append(locale)
        return true
    }

    func release(locale: Locale) -> Bool {
        releaseCalls.append(locale)
        return true
    }

    func waitForInstallStart(of locale: Locale) async {
        guard !installStarted else { return }
        await withCheckedContinuation { continuation in
            installStartWaiters.append(continuation)
        }
    }

    func openInstall(of locale: Locale) {
        installContinuation?.resume()
        installContinuation = nil
    }

    func waitForInstallUnwind(of locale: Locale) async {
        guard !installUnwound else { return }
        await withCheckedContinuation { continuation in
            installUnwindWaiters.append(continuation)
        }
    }

    private static func key(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

private actor Wave1StatusGate {
    let locales: [Locale]
    private var started: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]

    init(locales: [Locale]) {
        self.locales = locales
    }

    func supportedLocale(equivalentTo locale: Locale) -> Locale? {
        locales.first { Self.key($0) == Self.key(locale) }
    }

    func status(for locale: Locale) async -> AppleSpeechAssetState {
        let key = Self.key(locale)
        started.insert(key)
        startWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            gates[key] = continuation
        }
        return .supported
    }

    func waitForStart(of locale: Locale) async {
        let key = Self.key(locale)
        guard !started.contains(key) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[key, default: []].append(continuation)
        }
    }

    func open(_ locale: Locale) {
        gates.removeValue(forKey: Self.key(locale))?.resume()
    }

    private static func key(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
