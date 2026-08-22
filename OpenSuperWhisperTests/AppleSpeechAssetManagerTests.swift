import Foundation
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class AppleSpeechAssetManagerTests: XCTestCase {
    func testSupersededPreparationCancelsBeforeItCanReserve() async throws {
        let firstLocale = Locale(identifier: "en-US")
        let secondLocale = Locale(identifier: "fr-FR")
        let inventory = TestInventory(locales: [firstLocale, secondLocale], gatedLocale: firstLocale)
        let manager = makeManager(inventory: inventory)

        let first = Task { @MainActor in
            try await manager.prepare(locale: firstLocale)
        }
        await inventory.waitForInstallStart(of: firstLocale)

        let secondStarted = Task { @MainActor in
            await inventory.markSecondRequestStarted()
            return try await manager.prepare(locale: secondLocale)
        }
        await inventory.waitForSecondRequestStart()
        // Give the second task a turn to cancel the first operation before
        // opening the first install's gate.
        await Task.yield()
        await inventory.openInstall(of: firstLocale)

        let firstResult = await first.result
        guard case let .failure(error) = firstResult else {
            return XCTFail("The superseded locale must not report success.")
        }
        XCTAssertEqual(error as? CoreTranscriptionError, .cancelled)
        let resolvedSecond = try await secondStarted.value
        XCTAssertEqual(resolvedSecond.identifier, secondLocale.identifier)

        let reservations = await inventory.reservationCalls
        let releases = await inventory.releaseCalls
        XCTAssertEqual(reservations.map(\.identifier), [secondLocale.identifier])
        XCTAssertTrue(releases.isEmpty)
    }

    func testReturnedReservationsStayRetainedAcrossLocaleSwitch() async throws {
        let firstLocale = Locale(identifier: "en-US")
        let secondLocale = Locale(identifier: "fr-FR")
        let inventory = TestInventory(locales: [firstLocale, secondLocale])
        let manager = makeManager(inventory: inventory)

        _ = try await manager.prepare(locale: firstLocale)
        _ = try await manager.prepare(locale: secondLocale)

        let releasesBeforeExplicitRelease = await inventory.releaseCalls
        XCTAssertTrue(releasesBeforeExplicitRelease.isEmpty)

        await manager.release(locale: firstLocale)
        let releasesAfterExplicitRelease = await inventory.releaseCalls
        XCTAssertEqual(
            releasesAfterExplicitRelease.map(\.identifier),
            [firstLocale.identifier]
        )
    }

    func testCanceledWaiterDoesNotCancelSharedPreparation() async throws {
        let locale = Locale(identifier: "en-US")
        let inventory = TestInventory(locales: [locale], gatedLocale: locale)
        let waiterRegistered = expectation(description: "both waiters registered")
        waiterRegistered.expectedFulfillmentCount = 2
        let manager = makeManager(inventory: inventory) {
            waiterRegistered.fulfill()
        }

        let first = Task { @MainActor in
            try await manager.prepare(locale: locale)
        }
        await inventory.waitForInstallStart(of: locale)

        let second = Task { @MainActor in
            try await manager.prepare(locale: locale)
        }
        await fulfillment(of: [waiterRegistered], timeout: 1)

        first.cancel()
        let firstResult = await first.result
        guard case let .failure(error) = firstResult else {
            return XCTFail("A canceled waiter must not receive a successful locale.")
        }
        XCTAssertEqual(error as? CoreTranscriptionError, .cancelled)

        // The second waiter is still interested in the same preparation, so
        // the shared install remains alive until its gate is opened.
        await inventory.openInstall(of: locale)
        let resolved = try await second.value
        XCTAssertEqual(resolved.identifier, locale.identifier)

        let reservations = await inventory.reservationCalls
        XCTAssertEqual(reservations.map(\.identifier), [locale.identifier])
    }

    func testRetryAfterCanceledPreparationStartsFreshOperation() async throws {
        let locale = Locale(identifier: "en-US")
        let inventory = TestInventory(
            locales: [locale],
            gatedLocale: locale,
            leaveFirstGatedInstallUninstalled: true
        )
        let oldOperationWaiter = expectation(description: "retry waits for canceled operation")
        let freshOperationWaiter = expectation(description: "retry starts fresh operation")
        var waiterCount = 0
        let manager = makeManager(inventory: inventory) {
            waiterCount += 1
            if waiterCount == 2 {
                oldOperationWaiter.fulfill()
            } else if waiterCount == 3 {
                freshOperationWaiter.fulfill()
            }
        }

        let first = Task { @MainActor in
            try await manager.prepare(locale: locale)
        }
        await inventory.waitForInstallStart(of: locale)
        first.cancel()
        let firstResult = await first.result
        guard case let .failure(error) = firstResult else {
            return XCTFail("The canceled preparation must not report success.")
        }
        XCTAssertEqual(error as? CoreTranscriptionError, .cancelled)

        let retry = Task { @MainActor in
            try await manager.prepare(locale: locale)
        }
        await fulfillment(of: [oldOperationWaiter], timeout: 1)
        // The retry has attached only to the canceled operation's unwind at
        // this point. Opening its gate lets the manager remove that operation
        // and create a new one for the same locale.
        await inventory.openInstall(of: locale)
        await fulfillment(of: [freshOperationWaiter], timeout: 1)

        let resolved = try await retry.value
        XCTAssertEqual(resolved.identifier, locale.identifier)
        let installs = await inventory.installCalls
        XCTAssertEqual(installs.map(\.identifier), [locale.identifier, locale.identifier])
        let reservations = await inventory.reservationCalls
        XCTAssertEqual(reservations.map(\.identifier), [locale.identifier])
    }

    func testStaleRefreshCannotOverwriteNewerRefresh() async throws {
        let firstLocale = Locale(identifier: "en-US")
        let secondLocale = Locale(identifier: "fr-FR")
        let thirdLocale = Locale(identifier: "de-DE")
        let inventory = RefreshInventory(
            firstLocales: [firstLocale],
            secondLocales: [secondLocale],
            thirdLocales: [thirdLocale]
        )
        let manager = makeManager(testHooks: .init(
            supportedLocales: { await inventory.supportedLocales() },
            installedLocales: { await inventory.installedLocales() },
            supportedLocale: { locale in await inventory.supportedLocale(equivalentTo: locale) },
            status: { locale in await inventory.status(for: locale) },
            install: { _ in },
            reserve: { _ in true },
            release: { _ in true }
        ))

        let first = Task { @MainActor in await manager.refresh() }
        await inventory.waitForFirstSupportedStart()

        let second = Task { @MainActor in await manager.refresh() }
        await inventory.waitForSecondInstalledStart()
        await inventory.openFirstSupported()
        _ = await first.value

        XCTAssertEqual(manager.supportedLocales.map(\.identifier), [secondLocale.identifier])

        await inventory.openSecondInstalled()
        await inventory.waitForSecondStatusStart()

        let third = Task { @MainActor in await manager.refresh() }
        await inventory.waitForThirdSupportedStart()
        let thirdResult = await third.value
        XCTAssertEqual(thirdResult.map(\.identifier), [thirdLocale.identifier])

        // Let the canceled second refresh unwind after the third has already
        // completed. Its stale status result and defer must not mutate the
        // third refresh's status/arrays or clear the third refresh task.
        await inventory.openSecondStatus()
        _ = await second.value
        XCTAssertEqual(manager.supportedLocales.map(\.identifier), [thirdLocale.identifier])
        XCTAssertEqual(manager.installedLocales, [])
        XCTAssertEqual(manager.currentStatus?.localeIdentifier, thirdLocale.identifier)
    }

    func testLateProgressFromSupersededPreparationIsIgnored() async throws {
        let firstLocale = Locale(identifier: "en-US")
        let secondLocale = Locale(identifier: "fr-FR")
        let inventory = TestInventory(locales: [firstLocale, secondLocale], gatedLocale: firstLocale)
        let progressSource = AppleSpeechAssetManager.TestProgressSource()
        let manager = makeManager(inventory: inventory, progressSource: progressSource)

        let first = Task { @MainActor in
            try await manager.prepare(locale: firstLocale)
        }
        await inventory.waitForInstallStart(of: firstLocale)
        XCTAssertEqual(progressSource.callbackCount, 1)

        let second = Task { @MainActor in
            try await manager.prepare(locale: secondLocale)
        }
        await Task.yield()
        await inventory.openInstall(of: firstLocale)

        let firstResult = await first.result
        guard case let .failure(error) = firstResult else {
            return XCTFail("The superseded preparation must be canceled.")
        }
        XCTAssertEqual(error as? CoreTranscriptionError, .cancelled)
        let resolved = try await second.value
        XCTAssertEqual(resolved.identifier, secondLocale.identifier)
        XCTAssertEqual(progressSource.callbackCount, 2)

        // The old callback is delivered after the replacement has completed.
        // It must not roll the current status back to the old locale or to a
        // stale downloading progress value.
        progressSource.emit(index: 0, progress: 0.99)
        XCTAssertEqual(manager.currentStatus?.localeIdentifier, secondLocale.identifier)
        XCTAssertEqual(manager.currentStatus?.state, .installed)
    }

    private func makeManager(
        inventory: TestInventory,
        waiterRegistered: (@MainActor () -> Void)? = nil,
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
            waiterRegistered: waiterRegistered,
            progressSource: progressSource
        ))
    }

    private func makeManager(testHooks: AppleSpeechAssetManager.TestHooks) -> AppleSpeechAssetManager {
        AppleSpeechAssetManager(testHooks: testHooks)
    }
}

private actor TestInventory {
    let locales: [Locale]
    let gatedLocaleIdentifier: String?
    let leaveFirstGatedInstallUninstalled: Bool

    private var installedIdentifiers = Set<String>()
    private(set) var installCalls: [Locale] = []
    private(set) var reservationCalls: [Locale] = []
    private(set) var releaseCalls: [Locale] = []
    private var installContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var installStartedIdentifiers = Set<String>()
    private var installStartWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var gatedInstallUsed = false
    private var secondRequestStarted = false
    private var secondRequestWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        locales: [Locale],
        gatedLocale: Locale? = nil,
        leaveFirstGatedInstallUninstalled: Bool = false
    ) {
        self.locales = locales
        self.gatedLocaleIdentifier = gatedLocale.map(Self.key)
        self.leaveFirstGatedInstallUninstalled = leaveFirstGatedInstallUninstalled
    }

    var supportedLocales: [Locale] { locales }

    var installedLocales: [Locale] {
        locales.filter { installedIdentifiers.contains(Self.key($0)) }
    }

    func supportedLocale(equivalentTo locale: Locale) -> Locale? {
        locales.first { Self.key($0) == Self.key(locale) }
    }

    func status(for locale: Locale) -> AppleSpeechAssetState {
        installedIdentifiers.contains(Self.key(locale)) ? .installed : .supported
    }

    func install(locale: Locale) async {
        let key = Self.key(locale)
        installCalls.append(locale)
        let shouldGate = key == gatedLocaleIdentifier && !gatedInstallUsed
        if shouldGate {
            gatedInstallUsed = true
            await withCheckedContinuation { continuation in
                installContinuations[key] = continuation
                installStartedIdentifiers.insert(key)
                installStartWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
            }
        } else {
            installStartedIdentifiers.insert(key)
            installStartWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
        }
        if !(shouldGate && leaveFirstGatedInstallUninstalled) {
            installedIdentifiers.insert(key)
        }
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
        let key = Self.key(locale)
        guard !installStartedIdentifiers.contains(key) else { return }
        await withCheckedContinuation { continuation in
            installStartWaiters[key, default: []].append(continuation)
        }
    }

    func openInstall(of locale: Locale) {
        installContinuations.removeValue(forKey: Self.key(locale))?.resume()
    }

    func markSecondRequestStarted() {
        secondRequestStarted = true
        secondRequestWaiters.forEach { $0.resume() }
        secondRequestWaiters.removeAll()
    }

    func waitForSecondRequestStart() async {
        guard !secondRequestStarted else { return }
        await withCheckedContinuation { continuation in
            secondRequestWaiters.append(continuation)
        }
    }

    private static func key(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

private actor RefreshInventory {
    private let first: [Locale]
    private let second: [Locale]
    private let third: [Locale]

    private var supportedCallCount = 0
    private var gateNextInstalledLocales = false
    private var firstSupportedStarted = false
    private var firstSupportedStartWaiter: CheckedContinuation<Void, Never>?
    private var firstSupportedGate: CheckedContinuation<Void, Never>?
    private var secondInstalledStarted = false
    private var secondInstalledStartWaiter: CheckedContinuation<Void, Never>?
    private var secondInstalledGate: CheckedContinuation<Void, Never>?
    private var secondStatusStarted = false
    private var secondStatusStartWaiter: CheckedContinuation<Void, Never>?
    private var secondStatusGate: CheckedContinuation<Void, Never>?
    private var secondStatusGateUsed = false
    private var thirdSupportedStarted = false
    private var thirdSupportedStartWaiter: CheckedContinuation<Void, Never>?

    init(firstLocales: [Locale], secondLocales: [Locale], thirdLocales: [Locale]) {
        self.first = firstLocales
        self.second = secondLocales
        self.third = thirdLocales
    }

    func supportedLocales() async -> [Locale] {
        supportedCallCount += 1
        switch supportedCallCount {
        case 1:
            firstSupportedStarted = true
            firstSupportedStartWaiter?.resume()
            firstSupportedStartWaiter = nil
            await withCheckedContinuation { continuation in
                firstSupportedGate = continuation
            }
            return first
        case 2:
            gateNextInstalledLocales = true
            return second
        default:
            thirdSupportedStarted = true
            thirdSupportedStartWaiter?.resume()
            thirdSupportedStartWaiter = nil
            return third
        }
    }

    func installedLocales() async -> [Locale] {
        guard gateNextInstalledLocales else { return [] }
        gateNextInstalledLocales = false
        secondInstalledStarted = true
        secondInstalledStartWaiter?.resume()
        secondInstalledStartWaiter = nil
        await withCheckedContinuation { continuation in
            secondInstalledGate = continuation
        }
        return []
    }

    func supportedLocale(equivalentTo locale: Locale) -> Locale? {
        (first + second + third).first {
            key($0) == key(locale)
        }
    }

    func status(for locale: Locale) async -> AppleSpeechAssetState {
        if !secondStatusGateUsed,
           second.contains(where: { key($0) == key(locale) }) {
            secondStatusGateUsed = true
            secondStatusStarted = true
            secondStatusStartWaiter?.resume()
            secondStatusStartWaiter = nil
            await withCheckedContinuation { continuation in
                secondStatusGate = continuation
            }
        }
        return .supported
    }

    func waitForFirstSupportedStart() async {
        guard !firstSupportedStarted else { return }
        await withCheckedContinuation { continuation in
            firstSupportedStartWaiter = continuation
        }
    }

    func waitForSecondInstalledStart() async {
        guard !secondInstalledStarted else { return }
        await withCheckedContinuation { continuation in
            secondInstalledStartWaiter = continuation
        }
    }

    func waitForThirdSupportedStart() async {
        guard !thirdSupportedStarted else { return }
        await withCheckedContinuation { continuation in
            thirdSupportedStartWaiter = continuation
        }
    }

    func waitForSecondStatusStart() async {
        guard !secondStatusStarted else { return }
        await withCheckedContinuation { continuation in
            secondStatusStartWaiter = continuation
        }
    }

    func openFirstSupported() {
        firstSupportedGate?.resume()
        firstSupportedGate = nil
    }

    func openSecondInstalled() {
        secondInstalledGate?.resume()
        secondInstalledGate = nil
    }

    func openSecondStatus() {
        secondStatusGate?.resume()
        secondStatusGate = nil
    }

    private func key(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
