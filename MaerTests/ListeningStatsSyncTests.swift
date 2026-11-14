// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Statistics across a person's own devices: one pot per device, summed on
/// READ. The tests below are ordered by what would hurt most if it broke.
/// Double counting first, because it is the failure that looks like a working
/// app with slightly wrong numbers.
struct ListeningStatsSyncTests {

    private let phone = "device-phone"
    private let pad = "device-pad"

    // MARK: - The trap that justifies the design

    @Test("the own device is NOT counted twice")
    func ownDeviceIsNotCountedTwice() {
        let local = ListeningStatsData(secondsPerDay: ["2026-08-19": 100])
        // The own pot in the cloud is a MIRROR of the local file.
        // Whoever adds both gets a number that is simply too big.
        // And nobody notices why.
        let merged = ListeningStatsSync.merged(
            local: local, ownDeviceId: phone,
            foreign: [phone: ListeningStatsData(secondsPerDay: ["2026-08-19": 100]),
                      pad: ListeningStatsData(secondsPerDay: ["2026-08-19": 40])])
        #expect(merged.secondsPerDay["2026-08-19"] == 140)
    }

    @Test("foreign devices add up, per day and per title")
    func foreignDevicesAddUp() {
        let merged = ListeningStatsSync.merged(
            local: ListeningStatsData(secondsPerDay: ["2026-08-19": 60],
                                      secondsPerItem: ["radio:rb:a": 60]),
            ownDeviceId: phone,
            foreign: [pad: ListeningStatsData(secondsPerDay: ["2026-08-19": 30,
                                                             "2026-08-18": 90],
                                              secondsPerItem: ["radio:rb:a": 30,
                                                               "radio:rb:b": 10])])
        #expect(merged.secondsPerDay == ["2026-08-19": 90, "2026-08-18": 90])
        #expect(merged.secondsPerItem == ["radio:rb:a": 90, "radio:rb:b": 10])
    }

    @Test("without foreign devices the sum is the own file")
    func singleDeviceIsUnchanged() {
        let local = ListeningStatsData(secondsPerDay: ["2026-08-19": 42],
                                       secondsPerItem: ["radio:rb:a": 42])
        #expect(ListeningStatsSync.merged(local: local, ownDeviceId: phone, foreign: [:]) == local)
    }

    // MARK: - What travels and what does not (the budget dividing line)

    @Test("only what has NO position travels along")
    func onlyPositionlessItemsTravel() {
        let data = ListeningStatsData(
            secondsPerDay: ["2026-08-19": 1000],
            secondsPerItem: ["radio:rb:a": 400,       // no position -> travels
                             "rss:feed:episode": 300,  // position travels already
                             "lva:some-work": 200,     // ditto
                             "abs-book-id": 100])      // ditto, via the server
        let out = ListeningStatsSync.publishable(data)
        #expect(out.secondsPerDay == ["2026-08-19": 1000], "der Tages-Topf reist ganz")
        #expect(out.secondsPerItem == ["radio:rb:a": 400],
                "Folgen und Buecher tragen ihre Zeit laengst in einem Kanal, der synchronisiert")
    }

    // MARK: - Key

    @Test("the device id is in the KEY, not in the value")
    func deviceIdIsPartOfTheKey() {
        let key = ListeningStatsSync.key(forDeviceId: phone)
        #expect(key == "listeningStats.device-phone")
        #expect(ListeningStatsSync.deviceId(fromKey: key) == phone)
        #expect(ListeningStatsSync.deviceId(fromKey: "podcastProgress") == nil)
        #expect(ListeningStatsSync.deviceId(fromKey: "listeningStats.") == nil)
    }

    // MARK: - Cap of the item pot

    @Test("the item pot keeps the longest, not the newest")
    func itemPotKeepsTheLongest() {
        let items = ["a": 10, "b": 500, "c": 300, "d": 1]
        let out = ListeningStatsSync.cappedItems(items, limit: 2)
        #expect(out == ["b": 500, "c": 300])
        #expect(ListeningStatsSync.cappedItems(items, limit: 10) == items,
                "unter der Kappe bleibt alles unangetastet")
    }

    @Test("a tie caps stably so that two devices keep the same")
    func capIsStableOnTies() {
        let items = ["b": 100, "a": 100, "c": 50]
        #expect(ListeningStatsSync.cappedItems(items, limit: 2) == ["a": 100, "b": 100])
    }

    // MARK: - The Often Played row ranks by TIME

    private func station(_ id: String) -> RadioStation {
        RadioStation(id: "radio:rb:\(id)", name: id.uppercased(), streamURL: "https://s/\(id)")
    }

    @Test("Time beats start count: two hours win against many taps")
    func timeBeatsStarts() {
        let stations = [station("a"), station("b")]
        // a was tapped twenty times and never played, b once for two hours.
        let ranked = RadioRanking.mostPlayed(
            stations: stations,
            counts: ["radio:rb:a": 20, "radio:rb:b": 1],
            seconds: ["radio:rb:a": 30, "radio:rb:b": 7200],
            limit: 8)
        #expect(ranked.map(\.id) == ["radio:rb:b", "radio:rb:a"],
                "genau der Fall, wegen dem das Mass gewechselt wurde")
    }

    @Test("Transition phase: without measured time the start counter carries")
    func fallbackCarriesTheTransition() {
        let stations = [station("a"), station("b")]
        // Right after the update nobody knows seconds. The row must not
        // be empty because of that.
        let ranked = RadioRanking.mostPlayed(
            stations: stations, counts: ["radio:rb:a": 3, "radio:rb:b": 9],
            seconds: [:], limit: 8)
        #expect(ranked.map(\.id) == ["radio:rb:b", "radio:rb:a"])
    }

    @Test("measured time beats the fallback, however big its number is")
    func measuredOutranksTheFallback() {
        let stations = [station("a"), station("b")]
        // a has 99 starts and no time, b a single measured minute.
        let ranked = RadioRanking.mostPlayed(
            stations: stations, counts: ["radio:rb:a": 99, "radio:rb:b": 0],
            seconds: ["radio:rb:b": 60], limit: 8)
        #expect(ranked.map(\.id) == ["radio:rb:b", "radio:rb:a"],
                "der Rueckfall verschwindet fuer einen Sender, sobald Zeit da ist")
    }

    @Test("a station with neither is in no row")
    func unknownStationsStayOut() {
        #expect(RadioRanking.mostPlayed(stations: [station("a")], counts: [:],
                                        seconds: [:], limit: 8).isEmpty)
    }

    // MARK: - The adoption of the own pot

    /// The day table could not be read, the item table was: the start holds
    /// the read items. The own pot carries one live item. No adoption, so no
    /// read item is removed by the next write.
    @Test("Days unreadable, titles read, own pot with a live title: no adoption, no read title goes")
    func aReadTableIsNeverReplacedByThePot() {
        let read = ListeningStatsData(secondsPerDay: [:], secondsPerItem: ["abs:book": 900, "radio:rb:x": 60])
        let base = RowBase<ListeningStatsData>.unknown(seen: read)
        let pot = ListeningStatsData(secondsPerDay: ["2026-10-04": 120], secondsPerItem: ["radio:rb:x": 60])
        #expect(ListeningStatsSync.adoptedOwnPot(takesBack: ListeningStatsSync.takesOwnPotBack(base), own: read, pot: pot) == nil,
                "the pot replaced a read table")
        // What the next write would remove with the stock it keeps: nothing.
        #expect(base.map(\.secondsPerItem).previous(for: read.secondsPerItem).isEmpty)
        #expect(ListeningStatsSync.adoptedOwnPot(takesBack: ListeningStatsSync.takesOwnPotBack(.known(read)),
                                                 own: read, pot: pot) == nil)
    }

    /// Nothing could be read (a fresh file after a reset, or the read failed
    /// as a whole): the own pot comes back, merged into what this run already
    /// counted, per key the larger value.
    @Test("nothing read: the own pot comes back, merged with what was already counted")
    func nothingReadMergesThePot() {
        let pot = ListeningStatsData(secondsPerDay: ["2026-10-03": 3600, "2026-10-04": 120],
                                     secondsPerItem: ["radio:rb:x": 60])
        let counted = ListeningStatsData(secondsPerDay: ["2026-10-04": 300], secondsPerItem: [:])
        #expect(ListeningStatsSync.takesOwnPotBack(.unknown(seen: nil)))
        #expect(ListeningStatsSync.takesOwnPotBack(.fresh))
        let merged = ListeningStatsSync.adoptedOwnPot(takesBack: true, own: counted, pot: pot)
        #expect(merged == ListeningStatsData(secondsPerDay: ["2026-10-03": 3600, "2026-10-04": 300],
                                             secondsPerItem: ["radio:rb:x": 60]))
        #expect(ListeningStatsSync.adoptedOwnPot(takesBack: true, own: ListeningStatsData(), pot: pot) == pot)
        #expect(ListeningStatsSync.adoptedOwnPot(takesBack: true, own: ListeningStatsData(), pot: nil) == nil)
        #expect(ListeningStatsSync.adoptedOwnPot(takesBack: true, own: pot, pot: pot) == nil, "a second run changes nothing")
    }

    /// The measured loss, with real rows in a database of its own: at the
    /// start no table could be read, on disk the row holds 2400 (a save
    /// after the last publish), the own pot 1200. The pot is shown; sixty
    /// seconds of listening and a save later the row stands at 2460, not at
    /// the pot plus the session and not at the session alone.
    @Test("Tables unreadable at start, 2400 on disk, pot 1200, 60 s played: after the save the row is not below 2400")
    func aSaveOverUnreadRowsNeverLowersThem() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("w80b-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let database = MaerDatabase(path: path)
        let item = "radio:rb:w80b-\(UUID().uuidString)"
        _ = try await KeyedRowStore<Int>(connection: try database.connection(), table: .statsDay)
        let items = try await KeyedRowStore<Int>(connection: try database.connection(), table: .statsItem)
        _ = try await items.apply(previous: [:], current: [item: 2400])
        let carrier = KeyValueStatsCarrier(store: InMemoryCloudStore())
        carrier.publish(ListeningStatsData(secondsPerDay: [:], secondsPerItem: [item: 1200]),
                        deviceId: SyncHistoryStore.deviceId, by: "witness")
        let restore = SyncSwitchProbe.armOn()
        defer { restore() }
        let stats = ListeningStatsStore.testFailingStart(carrier: carrier, database: database, history: RecordingHistory())
        stats.start()
        #expect(stats.seconds(forItemId: item) == 1200, "the precondition: the pot was adopted for the display")
        stats.addSeconds(60, itemId: item)
        await stats.awaitPendingWrites()
        let reader = try #require(try database.readerNow())
        let rows = try KeyedRowStore<Int>.loadNow(table: .statsItem, reader: reader).rows
        #expect(rows[item] == 2460, "the save over the unread row wrote \(rows[item] ?? -1) instead of 2460")
        #expect(stats.seconds(forItemId: item) == 2460, "the display did not take the rows read on save")
        #expect(!ListeningStatsSync.adoptionWrites(.unknown(seen: nil)))
        #expect(ListeningStatsSync.adoptionWrites(.fresh), "a fresh file takes the pot as a write")
    }

    /// A sync history that keeps what it is told, for the witnesses.
    @MainActor
    final class RecordingHistory: SyncHistoryStoring {
        var entries: [SyncHistoryEntry] = []
        var lastChecked: [String: Date] = [:]
        func append(_ entry: SyncHistoryEntry) { entries.append(entry) }
        func noteChecked(_ service: SyncHistoryEntry.Service, at date: Date) { lastChecked[service.rawValue] = date }
    }

    /// A table that stays unread holds every write; this run's listening is
    /// then in memory only. Said once per run in the sync history, and on
    /// the statistics page while it lasts; a read that succeeds takes the
    /// line away.
    @Test("an unreadable table: one entry in the sync history per run, the row stays until reading succeeds")
    @MainActor
    func aHeldWriteIsSaidOnce() async throws {
        let directory = try NavidromeRekeyTests.temporaryDirectory("stats-held")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await NavidromeRekeyTests.unreadableDatabase(
            ["stats_item"], at: directory.appendingPathComponent("maer.sqlite").path)
        let history = RecordingHistory()
        let stats = ListeningStatsStore(carrier: KeyValueStatsCarrier(store: InMemoryCloudStore()),
                                        database: database, history: history)
        #expect(!stats.rowsHeld, "the precondition: nothing held before a save")
        stats.addSeconds(5, itemId: "radio:rb:held")
        await stats.awaitPendingWrites()
        #expect(stats.rowsHeld, "the page says nothing while the write is held")
        stats.flush()
        await stats.awaitPendingWrites()
        #expect(history.entries.count == 1, "one entry per run, not one per held save: \(history.entries.count)")
        #expect(history.entries.first?.service == .statistics)
        #expect(history.entries.first?.error != nil, "the entry is a failed run")

        let connection = try database.connection()
        try await connection.execute("DROP TABLE stats_item")
        _ = try await connection.checkpoint()
        stats.flush()
        await stats.awaitPendingWrites()
        #expect(!stats.rowsHeld, "a read that succeeded leaves the line standing")
        #expect(history.entries.count == 1)
    }

    /// The rebuild after the read: per unread table its rows plus what the
    /// run counted above the held pot; a table read at the start stays.
    @Test("after reading: rows plus what was counted above the pot, a read table stays")
    func theRebuildAddsOnlyWhatTheRunCounted() {
        let held = ListeningStatsData(secondsPerDay: ["d": 1200], secondsPerItem: ["x": 1200])
        let own = ListeningStatsData(secondsPerDay: ["d": 1260, "e": 30], secondsPerItem: ["x": 1260])
        let both = ListeningStatsSync.rebuilt(own: own, held: held, readDays: ["d": 2400], readItems: ["x": 2400, "y": 5])
        #expect(both == ListeningStatsData(secondsPerDay: ["d": 2460, "e": 30], secondsPerItem: ["x": 2460, "y": 5]))
        let itemsOnly = ListeningStatsSync.rebuilt(own: own, held: nil, readDays: nil, readItems: ["x": 100])
        #expect(itemsOnly == ListeningStatsData(secondsPerDay: own.secondsPerDay, secondsPerItem: ["x": 1360]))
    }

    /// What lies above the held part, per key; nothing at or below it.
    @Test("above the held part only the remainder stays per key, nothing below")
    func aboveKeepsOnlyTheRest() {
        let held = ListeningStatsData(secondsPerDay: ["a": 100, "b": 50], secondsPerItem: ["x": 10])
        let stock = ListeningStatsData(secondsPerDay: ["a": 130, "b": 50, "c": 7], secondsPerItem: ["x": 5, "y": 3])
        #expect(ListeningStatsSync.above(held, in: stock)
                == ListeningStatsData(secondsPerDay: ["a": 30, "c": 7], secondsPerItem: ["y": 3]))
        #expect(ListeningStatsSync.above(ListeningStatsData(), in: stock) == stock)
    }
}
/// The shared derivation "how much did I listen to this show". One place, two
/// callers (recommendation seed and statistics). Two derivations of the same
/// number would disagree on screen, which is worse than either being wrong.
struct ListeningByClassTests {

    private func showId(_ episodeId: String) -> String? {
        AppStorageKeys.podcastShowId(forEpisodeId: episodeId)
    }

    @Test("Episodes add up to their show")
    func episodesSumIntoTheirShow() {
        let defaults: [String: Any] = [
            "localPosition.rss:feedA:ep1": [600.0, 1.7e12],
            "localPosition.rss:feedA:ep2": [300.0, 1.7e12],
            "localPosition.rss:feedB:ep1": [100.0, 1.7e12],
            "localPosition.abspod:show1:ep1": [900.0, 1.7e12],
        ]
        let out = ListeningByClass.shows(in: defaults, showId: showId)
        #expect(out["rss:feedA"] == 900)
        #expect(out["rss:feedB"] == 100)
        #expect(out["abspod:show1"] == 900)
    }

    @Test("what is no show does not count")
    func nonPodcastEntriesAreIgnored() {
        let defaults: [String: Any] = [
            "localPosition.radio:rb:a": [600.0, 1.7e12],   // Live-Strom
            "localPosition.lva:work": [600.0, 1.7e12],     // Katalog
            "localPosition.abs-book": [600.0, 1.7e12],     // Server-Buch
            "somethingElse": [600.0, 1.7e12],
        ]
        #expect(ListeningByClass.shows(in: defaults, showId: showId).isEmpty)
    }

    @Test("a negative or broken position invents no time")
    func brokenEntriesContributeNothing() {
        let defaults: [String: Any] = [
            "localPosition.rss:feedA:ep1": [-50.0, 1.7e12],
            "localPosition.rss:feedA:ep2": [10.0],            // too short
            "localPosition.rss:feedA:ep3": "kein Array",
        ]
        #expect(ListeningByClass.shows(in: defaults, showId: showId)["rss:feedA"] == 0)
    }

    @Test("Top-N sorts by time, ties stable")
    func topIsStable() {
        let out = ListeningByClass.top(["b": 100, "a": 100, "c": 500, "d": 0], limit: 3)
        #expect(out.map(\.id) == ["c", "a", "b"], "0 faellt raus, Gleichstand alphabetisch")
    }
}

/// The logo diagnosis. Its value hangs on ONE distinction: a chain
/// that found nothing and one that never finished look the same on the
/// screen (letters), but are different causes with
/// different fixes.
struct RadioLogoReportTests {

    @Test("never finished is something other than no hit")
    func unfinishedIsNotTheSameAsNoHit() {
        let rows = RadioLogoReport.rows(
            stations: [(id: "a", name: "A", faviconURL: "https://a/f.png"),
                       (id: "b", name: "B", faviconURL: nil),
                       (id: "c", name: "C", faviconURL: nil)],
            chainResults: ["a": (hasLogo: true, attempted: true, resolvedAt: 1000),
                           "b": (hasLogo: false, attempted: true, resolvedAt: 1000)],
            now: 1200)
        #expect(rows.first { $0.id == "a" }?.chainResolved == true)
        #expect(rows.first { $0.id == "b" }?.chainAttempted == true)
        #expect(rows.first { $0.id == "b" }?.chainResolved == false)
        // c is missing from the results. Exactly the case that carries the suspicion.
        #expect(rows.first { $0.id == "c" }?.chainAttempted == false)
    }

    @Test("the header line names the number that matters")
    func summaryNamesTheDecidingNumber() {
        let rows = RadioLogoReport.rows(
            stations: [(id: "a", name: "A", faviconURL: "https://a/f.png"),
                       (id: "b", name: "B", faviconURL: nil)],
            chainResults: ["a": (hasLogo: true, attempted: true, resolvedAt: 1000)],
            now: 1200)
        let text = RadioLogoReport.text(rows)
        #expect(text.contains("OHNE ERGEBNIS:        1"))
        #expect(text.contains("Kette mit Logo:       1"))
        #expect(text.contains("mit Favicon-Adresse:  1"))
    }

    @Test("an empty stock reports zeros instead of disappearing")
    func emptyStateReportsZeros() {
        let text = RadioLogoReport.text(RadioLogoReport.rows(stations: [], chainResults: [:], now: 0))
        #expect(text.contains("Sender in den Reihen: 0"))
    }

    /// "OHNE ERGEBNIS" is one of THREE causes, and the report must
    /// name which. Queued, transport-failed, or given up. They look the same
    /// on screen and need different fixes.
    @Test("„OHNE ERGEBNIS“ separates queue, failure and giving up")
    func noResultNamesItsCause() {
        let stations: [(id: String, name: String, faviconURL: String?)] = [
            (id: "w", name: "W", faviconURL: nil),
            (id: "f", name: "F", faviconURL: nil),
            (id: "g", name: "G", faviconURL: nil),
            (id: "n", name: "N", faviconURL: nil)]
        let text = RadioLogoReport.text(RadioLogoReport.rows(
            stations: stations, chainResults: [:], now: 0,
            waiting: ["w"], sessionFailed: ["f", "g"], gaveUp: ["g"]))
        #expect(text.contains("W · Favicon nein · Kette OHNE ERGEBNIS — in Arbeit (Warteschlange)"))
        #expect(text.contains("F · Favicon nein · Kette OHNE ERGEBNIS — versucht, nichts gebucht (Transport scheiterte)"))
        #expect(text.contains("G · Favicon nein · Kette OHNE ERGEBNIS — aufgegeben (2 Fehlversuche diese Sitzung)"))
        #expect(text.contains("N · Favicon nein · Kette OHNE ERGEBNIS — nie versucht"))
    }

    /// Ids shorten to the FIRST characters after the
    /// prefix. The v1-UUID tail is an import batch's shared node field, six
    /// different stations can end identically there.
    @Test("Short id takes the start after the prefix, never the end")
    func shortIDTakesTheHead() {
        #expect(RadioLogoReport.shortID("radio:rb:9606f727-0601-11e8-ae97-52543be04c81")
                == "9606f727-0601…")
        #expect(RadioLogoReport.shortID("kurz") == "kurz")
    }
}
#endif

/// The mini player offers nothing that is finished by its own
/// knowledge. Judged by the NUMBERS, and only on evidence.
@Suite struct StandbyFinishedTests {

    @Test("finished by the numbers is unloaded; open stays")
    func finishedByNumbersClears() {
        let done = ListeningStore.mark(from: [3599, 1_000, 3600], source: .backup)
        #expect(PlayerCoordinator.standbyCountsAsFinished(done))
        let open = ListeningStore.mark(from: [1200, 1_000, 3600], source: .backup)
        #expect(!PlayerCoordinator.standbyCountsAsFinished(open))
    }

    @Test("without a duration or without an entry NEVER unloaded, only on evidence")
    func noEvidenceKeepsTheStandby() {
        #expect(!PlayerCoordinator.standbyCountsAsFinished(nil))
        let durationless = ListeningStore.mark(from: [1200, 1_000], source: .flushed)
        #expect(!PlayerCoordinator.standbyCountsAsFinished(durationless))
    }
}

/// The diagnosis pot list never reports the own device as foreign. Measured
/// on both real devices ("fremde Töpfe: 2" with exactly two devices): the
/// merge rule skipped the own mirror, the overview did not.
@Suite struct ForeignPotOverviewTests {

    @Test("the own pot never appears in the foreign list")
    func ownPotIsSkipped() {
        let pots = [
            "device-phone": ListeningStatsData(secondsPerDay: ["2026-08-22": 100],
                                               secondsPerItem: ["radio:rb:x": 60]),
            "device-pad": ListeningStatsData(secondsPerDay: ["2026-08-22": 200]),
        ]
        let list = ListeningStatsSync.overview(pots: pots, ownDeviceId: "device-phone")
        #expect(list.map(\.device) == ["device-pad"])
        #expect(list.first?.daySeconds == 200)
        #expect(list.first?.radioSeconds == 0)
    }

    @Test("a genuinely foreign orphan pot stays visible")
    func orphanStaysVisible() {
        let pots = ["device-old": ListeningStatsData(secondsPerDay: ["2026-01-01": 50])]
        let list = ListeningStatsSync.overview(pots: pots, ownDeviceId: "device-new")
        #expect(list.map(\.device) == ["device-old"])
    }
}
