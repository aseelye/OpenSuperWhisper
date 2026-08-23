import Combine
import Foundation
import XCTest
@testable import OpenSuperWhisper

/// A one-shot event channel for test doubles.  Tests wait for an explicit
/// lifecycle event instead of polling shared state on a wall clock.
final class TestEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingEvents = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var cancelledWaiters = Set<UUID>()

    func record() {
        let waiter = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard let id = waiters.keys.first,
                  let waiter = waiters.removeValue(forKey: id) else {
                pendingEvents += 1
                return nil
            }
            return waiter
        }
        waiter?.resume(returning: true)
    }

    func wait() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock { () -> Bool in
                    if cancelledWaiters.remove(id) != nil {
                        return true
                    }
                    if pendingEvents > 0 {
                        pendingEvents -= 1
                        return true
                    }
                    waiters[id] = continuation
                    return false
                }
                if resumeImmediately {
                    continuation.resume(returning: !Task.isCancelled)
                }
            }
        }, onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                if let waiter = waiters.removeValue(forKey: id) {
                    return waiter
                }
                cancelledWaiters.insert(id)
                return nil
            }
            waiter?.resume(returning: false)
        })
    }

    private func waitForEvent() async -> Bool {
        await wait()
    }

    /// Returns false only when the event did not arrive before the diagnostic
    /// deadline. The timeout is a failure guard, never synchronization.
    func wait(timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForEvent()
            }
            group.addTask {
                let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

@MainActor
extension XCTestCase {
    func waitForTestEvent(
        _ event: TestEventRecorder,
        description: String,
        timeout: TimeInterval = 5
    ) async {
        guard await event.wait(timeout: timeout) else {
            XCTFail("Timed out waiting for \(description)")
            return
        }
    }

    /// Waits for a published controller mutation.  The publisher emits before
    /// the property assignment, so the condition is checked on the next main
    /// actor turn after each event.
    func waitForController(
        _ controller: DictationSessionController,
        description: String,
        timeout: TimeInterval = 5,
        condition: @escaping @MainActor () -> Bool
    ) async {
        if condition() { return }

        let event = TestEventRecorder()
        let cancellable = controller.objectWillChange.sink { _ in
            Task { @MainActor in
                await Task.yield()
                if condition() {
                    event.record()
                }
            }
        }
        defer { cancellable.cancel() }
        await waitForTestEvent(event, description: description, timeout: timeout)
    }

    func waitForOnboarding(
        _ viewModel: OnboardingViewModel,
        description: String,
        timeout: TimeInterval = 5,
        condition: @escaping @MainActor () -> Bool
    ) async {
        if condition() { return }

        let event = TestEventRecorder()
        let cancellable = viewModel.objectWillChange.sink { _ in
            Task { @MainActor in
                await Task.yield()
                if condition() {
                    event.record()
                }
            }
        }
        defer { cancellable.cancel() }
        await waitForTestEvent(event, description: description, timeout: timeout)
    }
}

enum TestFixture {
    static func temporaryDirectory(prefix: String = "OpenSuperWhisperTests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func temporaryFile(
        contents: Data = Data(),
        fileExtension: String = ""
    ) throws -> URL {
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisperTests-\(UUID().uuidString)\(suffix)")
        try contents.write(to: url)
        return url
    }

    static func isolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "OpenSuperWhisperTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "OpenSuperWhisperTests", code: 1)
        }
        return (defaults, suiteName)
    }
}
