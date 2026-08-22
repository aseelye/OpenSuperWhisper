import Foundation
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    func testPreparationForwardsMatchingLocaleProgressBeforeCompletion() async throws {
        let originalLocale = AppPreferences.shared.localeIdentifier
        defer { AppPreferences.shared.localeIdentifier = originalLocale }
        AppPreferences.shared.localeIdentifier = "en-US"

        let locale = Locale(identifier: "en-US")
        let manager = ProgressAssetManager(locale: locale)
        let viewModel = OnboardingViewModel(assetManager: manager)

        viewModel.prepareAsset()
        try await waitUntil { manager.prepareStarted }

        manager.currentStatus = AppleSpeechAssetStatus(
            locale: locale,
            state: .downloading,
            progress: 0.42
        )
        try await waitUntil { viewModel.status?.progress == 0.42 }
        XCTAssertTrue(viewModel.isPreparing)

        manager.currentStatus = AppleSpeechAssetStatus(
            locale: locale,
            state: .installed,
            progress: 1
        )
        manager.resumePreparation()
        try await waitUntil { !viewModel.isPreparing }

        XCTAssertEqual(viewModel.status?.state, .installed)
        XCTAssertEqual(viewModel.status?.progress, 1)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for onboarding state")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
private final class ProgressAssetManager: AppleSpeechAssetManaging {
    let locale: Locale
    var supportedLocales: [Locale]
    var installedLocales: [Locale] = []
    var activeLocale: Locale?
    var currentStatus: AppleSpeechAssetStatus?
    private(set) var prepareStarted = false
    private var preparationContinuation: CheckedContinuation<Locale, Error>?

    init(locale: Locale) {
        self.locale = locale
        self.supportedLocales = [locale]
    }

    func refresh() async -> [Locale] { supportedLocales }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? { self.locale }

    func status(for locale: Locale) async -> AppleSpeechAssetStatus {
        currentStatus ?? AppleSpeechAssetStatus(locale: locale, state: .supported)
    }

    func prepare(locale: Locale) async throws -> Locale {
        prepareStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            preparationContinuation = continuation
        }
    }

    func resumePreparation() {
        preparationContinuation?.resume(returning: locale)
        preparationContinuation = nil
    }

    func release(locale: Locale?) async {}
}
