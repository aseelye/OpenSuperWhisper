import Foundation
import XCTest
@testable import OpenSuperWhisper

final class RecordingRetentionPreferencesTests: XCTestCase {
    func testDefaultRoundTripAndClampingUseStableIntegerStorage() throws {
        let (defaults, suiteName) = try TestFixture.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(
            defaults: defaults,
            performLegacyMigration: false
        )

        XCTAssertNil(defaults.object(forKey: AppPreferences.recordingRetentionDaysKey))
        XCTAssertEqual(preferences.recordingRetentionPolicy, .days(7))

        preferences.recordingRetentionPolicy = .forever
        XCTAssertEqual(defaults.integer(forKey: AppPreferences.recordingRetentionDaysKey), 0)
        XCTAssertEqual(preferences.recordingRetentionPolicy, .forever)

        preferences.recordingRetentionDays = 10_000
        XCTAssertEqual(preferences.recordingRetentionPolicy, .days(3650))
        XCTAssertEqual(preferences.recordingRetentionDays, 3650)

        preferences.recordingRetentionDays = -20
        XCTAssertEqual(preferences.recordingRetentionPolicy, .days(1))
        XCTAssertEqual(preferences.recordingRetentionDays, 1)

        preferences.recordingRetentionNeedsInitialConfirmation = true
        XCTAssertTrue(defaults.bool(forKey: AppPreferences.recordingRetentionNeedsInitialConfirmationKey))

        let sweepDate = Date(timeIntervalSince1970: 1234)
        preferences.recordingRetentionLastSuccessfulSweep = sweepDate
        XCTAssertEqual(preferences.recordingRetentionLastSuccessfulSweep, sweepDate)
        preferences.recordingRetentionLastSuccessfulSweep = nil
        XCTAssertNil(preferences.recordingRetentionLastSuccessfulSweep)
    }

    func testSelectionMappingDistinguishesPresetsAndCustomDays() {
        XCTAssertEqual(RecordingRetentionOption.option(for: .forever), .forever)
        XCTAssertEqual(RecordingRetentionOption.option(for: .days(1)), .oneDay)
        XCTAssertEqual(RecordingRetentionOption.option(for: .days(7)), .sevenDays)
        XCTAssertEqual(RecordingRetentionOption.option(for: .days(30)), .thirtyDays)
        XCTAssertEqual(RecordingRetentionOption.option(for: .days(90)), .ninetyDays)
        XCTAssertEqual(RecordingRetentionOption.option(for: .days(31)), .custom)
        XCTAssertEqual(RecordingRetentionOption.customDays(for: .days(31)), 31)
        XCTAssertNil(RecordingRetentionOption.customDays(for: .days(30)))
        XCTAssertEqual(RecordingRetentionOption.custom.policy(customDays: 0), .days(1))
        XCTAssertEqual(RecordingRetentionOption.custom.policy(customDays: 10_000), .days(3650))
    }
}

@MainActor
final class RecordingRetentionCoordinatorTests: XCTestCase {
    func testInitialConfirmationGateApproveAndDecline() async throws {
        let (preferences, defaults, suiteName) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = try CoordinatorStoreFixture()
        let store = fixture.store
        preferences.recordingRetentionPolicy = .days(7)
        preferences.recordingRetentionNeedsInitialConfirmation = true

        let coordinator = RecordingRetentionCoordinator(
            recordingStore: store,
            preferences: preferences
        )
        let initialSweep = await coordinator.runAfterHistoryLoad(now: Date(timeIntervalSince1970: 10))
        XCTAssertNil(initialSweep)
        XCTAssertTrue(preferences.recordingRetentionNeedsInitialConfirmation)
        coordinator.cancelInitialConfirmation()
        XCTAssertTrue(preferences.recordingRetentionNeedsInitialConfirmation)
        XCTAssertEqual(preferences.recordingRetentionPolicy, .days(7))

        let approved = await coordinator.approveInitialConfirmation(
            now: Date(timeIntervalSince1970: 20)
        )
        XCTAssertNotNil(approved)
        XCTAssertFalse(preferences.recordingRetentionNeedsInitialConfirmation)
        XCTAssertEqual(preferences.recordingRetentionPolicy, .days(7))
        XCTAssertEqual(
            preferences.recordingRetentionLastSuccessfulSweep,
            Date(timeIntervalSince1970: 20)
        )

        preferences.recordingRetentionNeedsInitialConfirmation = true
        let declined = await coordinator.declineInitialConfirmation(
            now: Date(timeIntervalSince1970: 30)
        )
        XCTAssertNotNil(declined)
        XCTAssertFalse(preferences.recordingRetentionNeedsInitialConfirmation)
        XCTAssertEqual(preferences.recordingRetentionPolicy, .forever)
    }

    func testScheduleRunsOncePerIntervalAndDoesNotCreateTimerByDefault() async throws {
        let (preferences, defaults, suiteName) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = try CoordinatorStoreFixture()
        let store = fixture.store
        let coordinator = RecordingRetentionCoordinator(
            recordingStore: store,
            preferences: preferences
        )
        XCTAssertFalse(coordinator.isStarted)

        let first = Date(timeIntervalSince1970: 100)
        let firstSweep = await coordinator.runAfterHistoryLoad(now: first)
        XCTAssertNotNil(firstSweep)
        let tooSoonSweep = await coordinator.runScheduledSweep(
            now: first.addingTimeInterval(60 * 60)
        )
        XCTAssertNil(tooSoonSweep)
        let scheduledSweep = await coordinator.runScheduledSweep(
            now: first.addingTimeInterval(25 * 60 * 60)
        )
        XCTAssertNotNil(scheduledSweep)
    }

    func testPreviewAndApplyErrorsArePublishedAndRetriedLater() async throws {
        let (preferences, defaults, suiteName) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = RecordingStoreError.databaseReadFailed("retention test")
        let root = try TestFixture.temporaryDirectory(prefix: "RetentionErrorStore")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(
            databasePath: root.appendingPathComponent("recordings.sqlite"),
            automaticallyLoad: false,
            recordingsDirectory: root.appendingPathComponent("recordings"),
            databaseFailureInjector: { operation in
                operation == .read ? expected : nil
            }
        )
        let coordinator = RecordingRetentionCoordinator(
            recordingStore: store,
            preferences: preferences
        )

        let preview = await coordinator.preview(policy: .days(7), now: Date())
        XCTAssertEqual(preview.error, expected)
        XCTAssertEqual(coordinator.lastError, expected)

        let result = await coordinator.runAfterHistoryLoad(now: Date())
        XCTAssertEqual(result?.error, expected)
        XCTAssertNil(preferences.recordingRetentionLastSuccessfulSweep)
    }

    private func makePreferences() throws -> (AppPreferences, UserDefaults, String) {
        let (defaults, suiteName) = try TestFixture.isolatedDefaults()
        return (
            AppPreferences(defaults: defaults, performLegacyMigration: false),
            defaults,
            suiteName
        )
    }

}

@MainActor
private final class CoordinatorStoreFixture {
    let root: URL
    let store: RecordingStore

    init() throws {
        root = try TestFixture.temporaryDirectory(prefix: "RetentionCoordinatorStore")
        store = RecordingStore(
            databasePath: root.appendingPathComponent("recordings.sqlite"),
            automaticallyLoad: false,
            recordingsDirectory: root.appendingPathComponent("recordings")
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
