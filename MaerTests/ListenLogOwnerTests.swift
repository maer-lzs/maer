// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The listen log follows the account like every family on the shelf:
/// what this device heard before any account goes to the first one; a sign
/// out changes nothing; another account sees nothing of the one before,
/// whose entries rest and come back with it; nothing is deleted.
@MainActor
@Suite(.serialized)
struct ListenLogOwnerTests {
    private struct Rig {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        var shelf: RestingShelf { database.restingShelf! }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private func rig() throws -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("listen-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Rig(directory: directory)
    }

    /// A play-through noted the way the player notes it, with the stand it
    /// just wrote (position at the end, its moment, the duration).
    private func hear(_ log: PodcastListenLog, _ guid: String, at moment: Double) {
        log.noteIfPlayed(guid: guid, duration: 1800, episodeTitle: "Ep \(guid)", showTitle: "Show",
                         feedURL: "https://listen.example/feed", written: [1800, moment, 1800])
    }

    private func heard(_ log: PodcastListenLog) -> Set<String> {
        Set(log.history(resolve: { _ in nil }).map(\.guid))
    }

    @Test("played without an account, the first account A sees everything; A signed out and played on, A again sees everything; B sees nothing of A; back to A, then B: B's entries are back, none of A's; across a restart")
    func theLogFollowsTheAccount() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        var signedIn: String?
        let log = PodcastListenLog(database: rig.database, identity: { signedIn })
        let run = UUID().uuidString.prefix(6)
        let device = "rss:owner:\(run):device", whileOut = "rss:owner:\(run):out"
        let ofB = "rss:owner:\(run):b", both = "rss:owner:\(run):both"

        hear(log, device, at: 1_700_000_000_000)
        #expect(heard(log) == [device], "the precondition: the device heard it before any account")

        signedIn = "account-a"
        #expect(log.follow(owner: "account-a", previous: nil))
        await log.awaitPendingWrites()
        #expect(heard(log) == [device], "the first account does not take what this device heard")

        signedIn = nil
        hear(log, whileOut, at: 1_700_000_100_000)
        signedIn = "account-a"
        #expect(log.follow(owner: "account-a", previous: "account-a"))
        #expect(heard(log) == [device, whileOut], "a sign out and A again lost what was heard")

        signedIn = "account-b"
        #expect(log.follow(owner: "account-b", previous: "account-a"))
        await log.awaitPendingWrites()
        #expect(heard(log).isEmpty, "B sees what A heard: \(heard(log))")
        hear(log, ofB, at: 1_700_000_200_000)
        hear(log, both, at: 1_700_000_300_000)

        signedIn = "account-a"
        #expect(log.follow(owner: "account-a", previous: "account-b"))
        await log.awaitPendingWrites()
        #expect(heard(log) == [device, whileOut], "A's own entries did not come back as they were: \(heard(log))")
        // The same episode under A: the case one owner field per entry
        // could not carry.
        hear(log, both, at: 1_700_000_400_000)

        signedIn = "account-b"
        #expect(log.follow(owner: "account-b", previous: "account-a"))
        await log.awaitPendingWrites()
        #expect(heard(log) == [ofB, both], "B's entries did not come back, or A's came along: \(heard(log))")
        let bothUnderB = log.entries[both]?.playedAt
        #expect(bothUnderB == 1_700_000_300_000, "the episode both heard carries A's play under B")

        // A restart reads B's rows and keeps them.
        let again = PodcastListenLog(database: rig.database, identity: { signedIn })
        #expect(again.follow(owner: "account-b", previous: "account-b"))
        #expect(heard(again) == [ofB, both], "a restart under B shows another stock: \(heard(again))")
        let resting = try rig.shelf.rest(PodcastListenLog.Resting.self, of: PodcastListenLog.shelfFamily, owner: "account-a")
        let restingGuids = Set(resting?.entries.keys.map { $0 } ?? [])
        #expect(restingGuids == [device, whileOut, both], "A's entries do not rest under A: \(restingGuids)")
    }

    /// The start could not read the rows and they are still unreadable when
    /// B comes (no rights on the file): the switch holds, so A's entries are
    /// neither laid down empty nor replaced. The rows become readable, and
    /// B hears an episode: the held switch is tried again first, so B's
    /// entry stands with B and none with A, also after a restart.
    @Test("a switch while the played rows are unread holds and is repeated before the next episode: B's episode with B, none with A, across a restart")
    func aSwitchOverUnreadRowsHolds() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let run = UUID().uuidString.prefix(6)
        let ofA = "rss:unread:\(run):a", ofB = "rss:unread:\(run):b"
        let before = PodcastListenLog(database: rig.database, identity: { "account-a" })
        #expect(before.follow(owner: "account-a", previous: nil))
        hear(before, ofA, at: 1_700_000_000_000)
        await before.awaitPendingWrites()

        // The next start cannot read the rows, nor can the switch.
        let file = rig.directory.appendingPathComponent("maer.sqlite").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file)
        let log = PodcastListenLog(database: rig.database, identity: { "account-b" })
        let seen = heard(log)
        let handed = log.follow(owner: "account-b", previous: "account-a")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        #expect(seen.isEmpty, "the precondition: the start read nothing")
        #expect(!handed, "a switch over unread rows went on")
        let restOfA = try rig.shelf.rest(PodcastListenLog.Resting.self, of: PodcastListenLog.shelfFamily, owner: "account-a")
        #expect(restOfA == nil, "a rest was laid for A from rows nobody read")
        let holder = try rig.shelf.holding(of: PodcastListenLog.shelfFamily)?.owner
        #expect(holder == "account-a", "the holder moved over unread rows: \(String(describing: holder))")

        // Readable again; B hears an episode.
        hear(log, ofB, at: 1_700_000_100_000)
        await log.awaitPendingWrites()
        #expect(heard(log) == [ofB], "B's episode joined A's log, or A's came along: \(heard(log))")
        let moved = try rig.shelf.holding(of: PodcastListenLog.shelfFamily)?.owner
        #expect(moved == "account-b", "the held switch was not tried again: \(String(describing: moved))")

        // A restart under B keeps B's episode; A's rests whole, without B's.
        let later = PodcastListenLog(database: rig.database, identity: { "account-b" })
        #expect(later.follow(owner: "account-b", previous: "account-b"))
        #expect(heard(later) == [ofB], "a restart under B shows another stock: \(heard(later))")
        let laid = try rig.shelf.rest(PodcastListenLog.Resting.self, of: PodcastListenLog.shelfFamily, owner: "account-a")
        let restingGuids = Set(laid?.entries.keys.map { $0 } ?? [])
        #expect(restingGuids == [ofA], "B's episode rests under A, or A's was lost: \(restingGuids)")
    }

    @Test("if an episode waits under B and the switch to C then succeeds, it does not stand with C")
    func anEpisodeWaitingForBNeverLandsAtC() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let run = UUID().uuidString.prefix(6)
        let ofB = "rss:held:\(run):b"
        let before = PodcastListenLog(database: rig.database, identity: { "account-a" })
        #expect(before.follow(owner: "account-a", previous: nil))
        await before.awaitPendingWrites()

        var signedIn = "account-b"
        let file = rig.directory.appendingPathComponent("maer.sqlite").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file)
        let log = PodcastListenLog(database: rig.database, identity: { signedIn })
        let handed = log.follow(owner: "account-b", previous: "account-a")
        hear(log, ofB, at: 1_700_000_100_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        #expect(!handed, "the precondition: the switch to B held over unread rows")

        signedIn = "account-c"
        #expect(log.follow(owner: "account-c", previous: "account-a"))
        await log.awaitPendingWrites()
        #expect(!heard(log).contains(ofB), "what B heard stands at C: \(heard(log))")
    }

    /// A switch held over unreadable rows, as above: A holds, the next start
    /// cannot read the rows. Returns the log of that start and whether its
    /// switch to B went on; the rows stay unreadable while `during` runs.
    private func heldSwitch(_ rig: Rig, during: (PodcastListenLog) -> Void) async throws -> (PodcastListenLog, Bool) {
        let before = PodcastListenLog(database: rig.database, identity: { "account-a" })
        #expect(before.follow(owner: "account-a", previous: nil))
        await before.awaitPendingWrites()
        let file = rig.directory.appendingPathComponent("maer.sqlite").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file)
        let log = PodcastListenLog(database: rig.database, identity: { "account-b" })
        let handed = log.follow(owner: "account-b", previous: "account-a")
        during(log)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        return (log, handed)
    }

    /// Notes heard while the switch holds wait in memory; after it they are
    /// written in chunks and once, not one write per note.
    @Test("many episodes waiting for a held hand-over are written bundled afterwards: all are there, one write")
    func waitingNotesAreWrittenOnce() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let run = UUID().uuidString.prefix(6)
        let guids = (0..<250).map { "rss:batch:\(run):\($0)" }
        let (log, handed) = try await heldSwitch(rig) { log in
            for (index, guid) in guids.enumerated() { hear(log, guid, at: 1_700_000_000_000 + Double(index)) }
        }
        #expect(!handed, "the precondition: the switch held")
        #expect(heard(log).isEmpty, "the precondition: the notes waited")
        let writes = log.rowWrites
        #expect(log.follow(owner: "account-b", previous: "account-a"))
        await log.awaitPendingWrites()
        let written = log.rowWrites - writes
        #expect(heard(log) == Set(guids), "waiting notes were lost: \(heard(log).count) of \(guids.count)")
        #expect(written == 1, "the waiting notes were written one by one: \(written) writes")
        let later = PodcastListenLog(database: rig.database, identity: { "account-b" })
        #expect(later.follow(owner: "account-b", previous: "account-b"))
        #expect(heard(later) == Set(guids), "the notes did not land: \(heard(later).count)")
    }

    /// The one-time backfill under a held switch waits in memory. A restart
    /// before the hand-over loses that, so the flag must not stand yet: the
    /// next start runs the backfill again, after its hand-over.
    @Test("the one-time backfill under a held hand-over does not set its mark; after a restart without a hand-over it runs after the hand-over, the history is there")
    func theBackfillWaitsForTheHandOver() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let key = AppStorageKeys.listenLogBackfilled
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(false, forKey: key)
        let run = UUID().uuidString.prefix(6)
        let guids = ["rss:fill:\(run):1", "rss:fill:\(run):2"]
        let show = PodcastShow(id: "rss:fill:\(run)", title: "Fill", author: nil, artworkURL: nil, description: nil,
                               feedURL: "https://fill.example/\(run)",
                               episodes: guids.map { PodcastEpisode(guid: $0, title: $0, audioURL: "https://fill.example/\($0).mp3",
                                                                    pubDate: 1, duration: 1800) })
        let stand: (String) -> [Double]? = { guids.contains($0) ? [1800, 1_700_000_000_000, 1800] : nil }
        let (_, handed) = try await heldSwitch(rig) { log in log.backfillIfNeeded(shows: [show], stand: stand) }
        #expect(!handed, "the precondition: the switch held")
        let flagged = AppStorageKeys.bool(key)
        #expect(!flagged, "the flag stands over a backfill that only waits in memory")
        // A restart without the hand-over: the waiting backfill is gone.
        let later = PodcastListenLog(database: rig.database, identity: { "account-b" })
        #expect(later.follow(owner: "account-b", previous: "account-a"))
        later.backfillIfNeeded(shows: [show], stand: stand)
        await later.awaitPendingWrites()
        #expect(heard(later) == Set(guids), "the backfill was lost to the restart: \(heard(later))")
        let flaggedLater = AppStorageKeys.bool(key)
        #expect(flaggedLater, "the flag did not follow the pass")
    }

    @Test("the played log registers itself as a runner and follows at start", .needsTheSources)
    func theLogIsEnrolledAndFollowsAtStart() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        #expect(try code("Sources/Storage/PodcastListenLog.swift")
            .contains("static let shared = AccessFollowers.enrolled(PodcastListenLog(upNext: PlayQueue.shared))"),
                "the log hears no change of account")
        #expect(try code("Sources/ViewModels/AppHousekeeping.swift").contains("PodcastListenLog.shared.followAtStart()"),
                "the log is not built and followed at start")
    }
}
#endif
