import Foundation
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    func testPreparationForwardsMatchingLocaleProgressBeforeCompletion() async throws {
        // Read the app's current locale but never change the shared defaults
        // from a unit test.  The manager is entirely fixture-backed.
        let manager = ProgressAssetManager()
        let viewModel = OnboardingViewModel(assetManager: manager)
        let locale = viewModel.selectedLocale
        manager.locale = locale
        manager.supportedLocales = [locale]

        viewModel.prepareAsset()
        await waitForTestEvent(
            manager.prepareStartedEvent,
            description: "onboarding preparation to start"
        )

        manager.currentStatus = AppleSpeechAssetStatus(
            locale: locale,
            state: .downloading,
            progress: 0.42
        )
        await waitForViewModel(viewModel, description: "onboarding progress update") {
            viewModel.status?.progress == 0.42
        }
        XCTAssertTrue(viewModel.isPreparing)

        // Cancellation exercises the completion path without having the
        // production view model write AppPreferences.shared on behalf of the
        // test process.
        manager.cancelPreparation()
        await waitForViewModel(viewModel, description: "onboarding cancellation") {
            !viewModel.isPreparing
        }
        XCTAssertEqual(viewModel.status?.state, .downloading)
    }

    private func waitForViewModel(
        _ viewModel: OnboardingViewModel,
        description: String,
        condition: @escaping @MainActor () -> Bool
    ) async {
        if condition() { return }
        let event = TestEventRecorder()
        let cancellable = viewModel.objectWillChange.sink { _ in
            Task { @MainActor in
                await Task.yield()
                if condition() { event.record() }
            }
        }
        defer { cancellable.cancel() }
        await waitForTestEvent(event, description: description)
    }
}

@MainActor
private final class ProgressAssetManager: AppleSpeechAssetManaging {
    var locale: Locale
    var supportedLocales: [Locale]
    var installedLocales: [Locale] = []
    var activeLocale: Locale?
    var currentStatus: AppleSpeechAssetStatus?
    private(set) var prepareStarted = false
    private var preparationContinuation: CheckedContinuation<Locale, Error>?
    let prepareStartedEvent = TestEventRecorder()

    init(locale: Locale = Locale(identifier: LanguageUtil.defaultLocaleIdentifier)) {
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
            prepareStartedEvent.record()
        }
    }

    func resumePreparation() {
        preparationContinuation?.resume(returning: locale)
        preparationContinuation = nil
    }

    func cancelPreparation() {
        preparationContinuation?.resume(throwing: CancellationError())
        preparationContinuation = nil
    }

    func release(locale: Locale?) async {}
}
