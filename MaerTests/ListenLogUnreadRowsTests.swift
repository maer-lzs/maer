// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Das Hoerprotokoll ueber Zeilen, die der Start nicht lesen konnte: kein
/// Schrieb ersetzt einen Grabstein, den niemand gelesen hat; gelesen gilt
/// die Regel des Protokolls (ein Grabstein weicht nur einem neueren Hoeren).
@MainActor
struct ListenLogUnreadRowsTests {
    private func entry(_ guid: String, playedAt: Double, unplayedAt: Double? = nil,
                       title: String = "") -> PodcastListenLog.Entry {
        .init(guid: guid, episodeTitle: title, showTitle: "", feedURL: "", duration: 0,
              playedAt: playedAt, unplayedAt: unplayedAt, synthesizedAt: false)
    }

    @Test("die Regel: das spaetere Hoeren und der spaetere Grabstein stehen beide, Leeres fuellt die andere Seite")
    func theMergeRule() {
        let row = entry("g", playedAt: 1_000, unplayedAt: 2_000, title: "Folge")
        let run = entry("g", playedAt: 1_500)
        let merged = PodcastListenLog.merged(read: row, run: run)
        #expect(merged.playedAt == 1_500 && merged.unplayedAt == 2_000)
        #expect(!merged.isPlayed, "an older play of this run flipped a tombstone nobody read")
        #expect(merged.episodeTitle == "Folge", "the title of the rows was lost")
        let newer = PodcastListenLog.merged(read: row, run: entry("g", playedAt: 3_000))
        #expect(newer.isPlayed, "a newer play yields no more to the tombstone")
        let tombOfRun = PodcastListenLog.merged(read: entry("g", playedAt: 1_000), run: entry("g", playedAt: 0, unplayedAt: 2_000))
        #expect(!tombOfRun.isPlayed && tombOfRun.playedAt == 1_000, "the run's tombstone over a read play")
        #expect(PodcastListenLog.adopted(read: ["a": row], run: ["b": run]).keys.sorted() == ["a", "b"])
    }

    /// The case from the order: a tombstone on disk, a start that cannot
    /// read, a reconcile that brings the guid as heard. After the rows are
    /// read the tombstone still stands.
    @Test("ein Grabstein auf der Platte, Start liest nicht, ein Abgleich bringt die guid: danach steht der Grabstein noch")
    func aTombstoneNobodyReadSurvives() async throws {
        let directory = try NavidromeRekeyTests.temporaryDirectory("listenlog-unread")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await NavidromeRekeyTests.unreadableDatabase(
            ["listen_log"], at: directory.appendingPathComponent("maer.sqlite").path)
        let log = PodcastListenLog(database: database)
        let guid = "listenlog-unread-\(UUID().uuidString)"
        let heard = 1_700_000_000_000.0, tombstone = 1_700_000_500_000.0
        log.noteIfPlayed(guid: guid, duration: 100, episodeTitle: "Folge", showTitle: "Sendung",
                         feedURL: "", written: [100, heard])
        await log.awaitPendingWrites()
        #expect(log.entries[guid]?.isPlayed == true, "the precondition: this run noted the guid as heard")

        let connection = try database.connection()
        try await connection.execute("DROP TABLE listen_log")
        let rows = try await KeyedRowStore<PodcastListenLog.Entry>(connection: connection, table: .listenLog)
        _ = try await rows.apply(previous: [:], current: [guid: entry(guid, playedAt: heard - 1_000, unplayedAt: tombstone)])
        log.noteIfPlayed(guid: "other-\(guid)", duration: 100, episodeTitle: "", showTitle: "", feedURL: "",
                         written: [100, heard])
        await log.awaitPendingWrites()

        let reader = try #require(try database.readerNow())
        let stored = try #require(try KeyedRowStore<PodcastListenLog.Entry>.loadNow(table: .listenLog, reader: reader).rows[guid])
        #expect(stored.unplayedAt == tombstone, "the tombstone was replaced: \(String(describing: stored.unplayedAt))")
        #expect(!stored.isPlayed, "an older play of this run brought the episode back as heard")
        #expect(log.entries[guid]?.isPlayed == false, "the memory did not take the tombstone")
    }

    /// "Mark unplayed" over unread rows was a silent no-op; now the choice
    /// is kept and survives the adoption.
    @Test("ungehoert markiert ueber ungelesenen Zeilen: die Wahl bleibt und ueberlebt das Lesen")
    func markingUnplayedOverUnreadRowsIsKept() async throws {
        let directory = try NavidromeRekeyTests.temporaryDirectory("listenlog-mark")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await NavidromeRekeyTests.unreadableDatabase(
            ["listen_log"], at: directory.appendingPathComponent("maer.sqlite").path)
        let log = PodcastListenLog(database: database)
        let guid = "listenlog-mark-\(UUID().uuidString)"
        let heard = 1_700_000_000_000.0, marked = 1_700_000_900_000.0
        log.markUnplayed(guid: guid, at: marked)
        await log.awaitPendingWrites()
        #expect(log.entries[guid]?.unplayedAt == marked, "the choice was dropped over unread rows")

        let connection = try database.connection()
        try await connection.execute("DROP TABLE listen_log")
        let rows = try await KeyedRowStore<PodcastListenLog.Entry>(connection: connection, table: .listenLog)
        _ = try await rows.apply(previous: [:], current: [guid: entry(guid, playedAt: heard, title: "Folge")])
        log.markUnplayed(guid: guid, at: marked)
        await log.awaitPendingWrites()

        let reader = try #require(try database.readerNow())
        let stored = try #require(try KeyedRowStore<PodcastListenLog.Entry>.loadNow(table: .listenLog, reader: reader).rows[guid])
        #expect(stored.unplayedAt == marked && !stored.isPlayed, "the mark did not survive the read")
        #expect(stored.episodeTitle == "Folge", "the entry of the rows lost its title")
    }

    /// Two notes in one go (a reconcile notes guid after guid) before the
    /// adoption, the rows readable by then: the second write takes the log
    /// after the adoption, so the tombstone row stays.
    @Test("zwei Notizen in einem Zug vor der Uebernahme: der Grabstein auf der Platte bleibt")
    func aNoteQueuedBeforeTheAdoptionKeepsTheTombstone() async throws {
        let directory = try NavidromeRekeyTests.temporaryDirectory("listenlog-queued")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await NavidromeRekeyTests.unreadableDatabase(
            ["listen_log"], at: directory.appendingPathComponent("maer.sqlite").path)
        let log = PodcastListenLog(database: database)
        let tag = UUID().uuidString
        let heard = 1_700_000_000_000.0, tombstone = 1_700_000_500_000.0
        log.markUnplayed(guid: "probe-\(tag)", at: tombstone)
        await log.awaitPendingWrites()
        let connection = try database.connection()
        try await connection.execute("DROP TABLE listen_log")
        let rows = try await KeyedRowStore<PodcastListenLog.Entry>(connection: connection, table: .listenLog)
        let marked = "marked-\(tag)"
        _ = try await rows.apply(previous: [:], current: [marked: entry(marked, playedAt: heard - 1_000, unplayedAt: tombstone)])
        log.noteIfPlayed(guid: "a-\(tag)", duration: 100, episodeTitle: "", showTitle: "", feedURL: "", written: [100, heard])
        log.noteIfPlayed(guid: "b-\(tag)", duration: 100, episodeTitle: "", showTitle: "", feedURL: "", written: [100, heard])
        await log.awaitPendingWrites()

        let reader = try #require(try database.readerNow())
        let stored = try KeyedRowStore<PodcastListenLog.Entry>.loadNow(table: .listenLog, reader: reader).rows
        #expect(stored[marked]?.unplayedAt == tombstone, "a note queued before the adoption removed the tombstone row")
        #expect(stored["a-\(tag)"] != nil && stored["b-\(tag)"] != nil, "rows: \(stored.keys.sorted())")
    }
}
#endif
