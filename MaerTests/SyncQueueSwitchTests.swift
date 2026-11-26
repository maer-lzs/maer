// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Another user at the same server: no stand the user before queued goes
/// out with the new user's token, neither in the window of the sign-in,
/// nor after a late read of the queue, nor after the app was ended in
/// between. The hold and an owed forget stand on the device.
@MainActor
struct SyncQueueSwitchTests {
    static let server = "https://abs.example.com"

    final class Storage: SyncQueueStorage {
        var dict: [String: SyncQueue.PendingUpdate] = [:]
        var unread = false
        func load() -> [String: SyncQueue.PendingUpdate] { unread ? [:] : dict }
        func save(_ pending: [String: SyncQueue.PendingUpdate]) { dict = pending }
        func awaitPendingWrites() async {}
        var startReadFailed: Bool { unread }
        func readAgainNow() -> Bool { !unread }
    }

    final class API: ProgressSyncAPI {
        var written: [String] = []
        var onFetch: (() async -> Void)?
        func fetchAllProgress() async throws -> [String: BookProgress] { await onFetch?(); return [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
            written.append(itemId)
        }
    }

    /// Runs the body with the signed-in server set and a defaults suite of
    /// its own for the hold, and puts both back.
    func withServer(_ body: (UserDefaults) async throws -> Void) async throws {
        let before = AppStorageKeys.string(AppStorageKeys.absSignedInServer)
        AppStorageKeys.set(Self.server, for: AppStorageKeys.absSignedInServer)
        let name = "switch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer {
            AppStorageKeys.set(before, for: AppStorageKeys.absSignedInServer)
            defaults.removePersistentDomain(forName: name)
        }
        try await body(defaults)
    }

    static func entry(_ server: String?) -> SyncQueue.PendingUpdate {
        SyncQueue.PendingUpdate(currentTime: 10, duration: 100, isFinished: false, queuedAt: 1, server: server)
    }

    func flush(_ queue: SyncQueue, _ api: API) async {
        await queue.flush { _ in ProgressTarget(key: "main", client: api) }
    }

    @Test("1: a held server sends nothing; released, its stands go")
    func held() async throws {
        try await withServer { defaults in
            let storage = Storage()
            storage.dict = ["a": Self.entry(Self.server), "b": Self.entry(Self.server)]
            let queue = SyncQueue(storage: storage, defaults: defaults)
            let api = API()
            queue.holdForSwitch(server: Self.server)
            await flush(queue, api)
            #expect(api.written.isEmpty, "a stand of the user before went out")
            queue.release(server: Self.server)
            await flush(queue, api)
            #expect(Set(api.written) == ["a", "b"])
        }
    }

    @Test("2: a flush that waited for the server while the sign-in held it sends nothing of it")
    func flushInTheWindow() async throws {
        try await withServer { defaults in
            let storage = Storage()
            storage.dict = ["a": Self.entry(Self.server)]
            let queue = SyncQueue(storage: storage, defaults: defaults)
            let api = API()
            api.onFetch = { queue.holdForSwitch(server: Self.server) }
            await flush(queue, api)
            #expect(api.written.isEmpty, "the flush sent with the new token")
        }
    }

    @Test("3 and 4: a start that did not read owes the forget; unread, nothing of the server goes; read late, its stands are gone before any send")
    func lateRead() async throws {
        try await withServer { defaults in
            let storage = Storage()
            storage.unread = true
            let queue = SyncQueue(storage: storage, defaults: defaults)
            let api = API()
            #expect(await queue.forgetPending(onServer: Self.server) == 0)
            #expect(queue.owedForgets == [Self.server])
            await flush(queue, api)
            #expect(api.written.isEmpty)
            // The rows come late, two of the server, one without one.
            storage.dict = ["a": Self.entry(Self.server), "b": Self.entry(Self.server), "c": Self.entry(nil)]
            storage.unread = false
            await flush(queue, api)
            #expect(api.written == ["c"], "a stand of the user before went out after the late read")
            #expect(storage.dict["a"] == nil && storage.dict["b"] == nil)
            #expect(queue.owedForgets.isEmpty)
        }
    }

    @Test("5: after the forget and the release a stand the new user queues goes out")
    func afterTheRelease() async throws {
        try await withServer { defaults in
            let storage = Storage()
            storage.dict = ["a": Self.entry(Self.server)]
            let queue = SyncQueue(storage: storage, defaults: defaults)
            let api = API()
            queue.holdForSwitch(server: Self.server)
            await queue.forgetPending(onServer: Self.server)
            queue.release(server: Self.server)
            await queue.enqueue(itemId: "new", currentTime: 5, duration: 100, isFinished: false)
            await flush(queue, api)
            #expect(api.written == ["new"])
        }
    }

    @Test("6: a sign-in that failed before the token releases, and the stands of the user before go with that user's token")
    func failedBeforeTheToken() async throws {
        try await withServer { defaults in
            let storage = Storage()
            storage.dict = ["a": Self.entry(Self.server)]
            let queue = SyncQueue(storage: storage, defaults: defaults)
            let api = API()
            queue.holdForSwitch(server: Self.server)
            queue.release(server: Self.server)
            await flush(queue, api)
            #expect(api.written == ["a"])
        }
    }

    @Test("9: ended after the hold and before the forget: after the start nothing of the server goes and the forget is made up")
    func endedInTheWindow() async throws {
        try await withServer { defaults in
            let storage = Storage()
            storage.dict = ["a": Self.entry(Self.server), "c": Self.entry(nil)]
            SyncQueue(storage: storage, defaults: defaults).holdForSwitch(server: Self.server)
            // The app ends; a new start reads the same rows and the same device.
            let again = SyncQueue(storage: storage, defaults: defaults)
            let api = API()
            await flush(again, api)
            #expect(api.written == ["c"], "the first flush after the start sent the user before")
            await again.forgetPending(onServer: Self.server)
            again.release(server: Self.server)
            #expect(storage.dict["a"] == nil)
        }
    }

    @Test("10: the same with a start that did not read and rows that come after the restart")
    func endedWithAnUnreadStart() async throws {
        try await withServer { defaults in
            let storage = Storage()
            storage.unread = true
            let first = SyncQueue(storage: storage, defaults: defaults)
            first.holdForSwitch(server: Self.server)
            await first.forgetPending(onServer: Self.server)
            first.release(server: Self.server)
            let again = SyncQueue(storage: storage, defaults: defaults)
            #expect(again.owedForgets == [Self.server], "the owed forget did not survive the restart")
            storage.dict = ["a": Self.entry(Self.server), "c": Self.entry(nil)]
            storage.unread = false
            let api = API()
            await flush(again, api)
            #expect(api.written == ["c"])
            #expect(storage.dict["a"] == nil)
        }
    }

    @Test("7, 8 and 11, Fence: the sign-in holds before the token without a wait between, only for another user at the same server, and nothing after the token can fail it", .needsTheSources)
    func signInOrder() throws {
        let auth = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/ViewModels/AuthViewModel.swift"), encoding: .utf8))
        let hold = try #require(auth.range(of: "if switched, !serverSwitched { queue.holdForSwitch(server: formerAddress) }"))
        let token = try #require(auth.range(of: "apiClient.updateToken(token)", range: hold.upperBound..<auth.endIndex))
        #expect(!auth[hold.upperBound..<token.lowerBound].contains("await"), "a wait between the hold and the token")
        let forget = try #require(auth.range(of: "await queue.forgetPending(onServer: formerAddress)", range: token.upperBound..<auth.endIndex))
        let release = try #require(auth.range(of: "queue.release(server: formerAddress)", range: forget.upperBound..<auth.endIndex))
        // Nothing between the token and the end of the sign-in can throw:
        // a sign-in that failed after the token would be a switch half done.
        #expect(!auth[token.upperBound..<release.upperBound].contains("try "), "a step after the token can fail the sign-in")
        // The music servers hold the same way, before their forget task.
        for file in ["SubsonicProvider.swift", "JellyfinProvider.swift"] {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
                .appendingPathComponent("Sources/Providers/\(file)"), encoding: .utf8))
            let held = try #require(code.range(of: "if userOnly { queue.holdForSwitch(server: former) }"), "\(file) does not hold")
            let task = try #require(code.range(of: "Task {", range: held.upperBound..<code.endIndex))
            #expect(code[task.upperBound...].prefix(300).contains("queue.release(server: former)"), "\(file) does not release after its forget")
        }
        let queue = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Networking/SyncQueue.swift"), encoding: .utf8))
        #expect(queue.contains("guard !isHeldOrOwed(update.server) else"), "the flush does not check before each send")
    }
}
#endif
