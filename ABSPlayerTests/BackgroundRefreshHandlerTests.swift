// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// The BGTask launch handler runs on the scheduler queue (NOT the main
/// actor). The testable core must be callable from an arbitrary executor
/// without tripping isolation, hop its work to the main actor, and always
/// complete.
struct BackgroundRefreshHandlerTests {
    @Test("launchWork is safe off-main, runs on the main actor and completes")
    func offMainLaunch() async {
        let ranOnMain = LockedBox(false)
        let completed = LockedBox(false)

        // Simulate the scheduler queue: call from a detached (non-main) task.
        let work = await Task.detached {
            dispatchPrecondition(condition: .notOnQueue(.main))
            return PodcastRefreshService.launchWork(
                run: { @MainActor in
                    // Being ON the main actor here IS the assertion.
                    MainActor.assertIsolated()
                    ranOnMain.set(true)
                },
                complete: { success in completed.set(success) })
        }.value
        await work.value

        #expect(ranOnMain.get())
        #expect(completed.get())
    }

    @Test("an expired (cancelled) work task still completes — BGTask contract")
    func cancelStillCompletes() async {
        let completed = LockedBox(false)
        let work = PodcastRefreshService.launchWork(
            run: { try? await Task.sleep(for: .seconds(5)) },
            complete: { _ in completed.set(true) })
        work.cancel()   // expiration handler semantics
        await work.value
        #expect(completed.get())
    }
}

/// Tiny lock box so the @Sendable closures can record across executors.
/// `@unchecked Sendable`: all access goes through the NSLock below.
private nonisolated final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
