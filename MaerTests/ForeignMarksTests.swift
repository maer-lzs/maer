// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The marks an import leaves beside a position: imported states are
/// no listening time until heard here, archived travels back out, and
/// the tombstone forgets both. Measured on a real account: 1517
/// imported finished marks became 430 hours "listened" next to a total
/// of 0 minutes.
@MainActor
struct ForeignMarksTests {
    private let defaults = UserDefaults(suiteName: "foreign-marks-\(UUID().uuidString)")!
    private let guid = "rss:feedkey1:episode-1"
    private let showId: (String) -> String? = AppStorageKeys.podcastShowId(forEpisodeId:)

    @Test("ein importierter Gehoert-Eintrag erhoeht keine Statistik-Summe, ein echtes Hoeren tut es")
    func importedIsNoListeningTime() {
        ListeningStore.store(guid, entry: [3_600, 1_000, 3_600], in: defaults)
        ForeignMarks.markImported(guid, in: defaults)
        let before = ListeningByClass.shows(in: defaults.dictionaryRepresentation(), showId: showId,
                                            excluding: ForeignMarks.importedIDs(in: defaults))
        #expect(before["rss:feedkey1"] == nil)
        // Without the exclusion the same entry would count: the mark is the difference.
        #expect(ListeningByClass.shows(in: defaults.dictionaryRepresentation(), showId: showId)["rss:feedkey1"] == 3_600)
        // A real listen on this device clears the mark and the time counts,
        // at the position the listen reached.
        ListeningStore.record(guid, position: 1_200, duration: 3_600, atMs: 2_000, in: defaults)
        let after = ListeningByClass.shows(in: defaults.dictionaryRepresentation(), showId: showId,
                                           excluding: ForeignMarks.importedIDs(in: defaults))
        #expect(after["rss:feedkey1"] == 1_200)
    }

    @Test("archiviert bleibt erhalten und faellt mit dem Grabstein")
    func archivedSurvivesUntilTombstone() {
        ForeignMarks.markArchived(guid, in: defaults)
        ForeignMarks.markImported(guid, in: defaults)
        #expect(ForeignMarks.isArchived(guid, in: defaults))
        // Listening does not un-archive; only the person's reset does.
        ListeningStore.record(guid, position: 100, duration: 3_600, atMs: 2_000, in: defaults)
        #expect(ForeignMarks.isArchived(guid, in: defaults))
        #expect(!ForeignMarks.importedIDs(in: defaults).contains(guid))
        ListeningStore.store(guid, entry: [0, 3_000], in: defaults)
        #expect(!ForeignMarks.isArchived(guid, in: defaults))
        #expect(ForeignMarks.archivedIDs(in: defaults).isEmpty)
    }

    @Test("archiviert geht mit der Ausfuhr hinaus und kommt als archiviert und gehoert zurueck")
    func archivedRoundTrip() throws {
        let state = try #require(OPMLExport.exportedState(
            entry: [ProgressMark.playedSentinel, 1_000], feedURL: "https://f.example/rss", guid: "g",
            enclosureURL: nil, link: nil, title: "T", duration: 0, archived: true))
        #expect(state.archived && state.finished)
        let doc = OPMLExport.document(shows: [(title: "F", feedURL: "https://f.example/rss")], states: [state],
                                      generatedAt: Date(timeIntervalSince1970: 0))
        let back = try #require(OvercastOPML.parse(Data(doc.utf8)))
        #expect(back.states.first?.archived == true)
        #expect(back.states.first?.finished == true)
    }

    @Test("die Statistik findet die Sendung hinter dem gefalteten Schluessel")
    func statisticsKeyFindsTheShow() {
        let key = PodcastSubscriptions.feedKey("https://f.example/rss")
        let show = PodcastShow(id: "feed:\(key)", title: "Found", author: nil, artworkURL: nil,
                               description: nil, feedURL: "https://f.example/rss", episodes: [])
        let folded = AppStorageKeys.podcastShowId(forEpisodeId: "rss:\(key):ep-1")
        #expect(folded == "rss:\(key)")
        #expect(PodcastSubscriptions.showTitle(for: folded!, in: [show]) == "Found")
        #expect(PodcastSubscriptions.showTitle(for: "rss:unknown", in: [show]) == nil)
        #expect(PodcastSubscriptions.showTitle(for: "feed:\(key)", in: [show]) == "Found")
    }

    @Test("S2b I2: ein Wiedergabe-Tick liest die Markenliste nicht und schreibt nur, wenn die Folge markiert war")
    func aTickReadsNoList() {
        ForeignMarks.markImported((0..<500).map { "rss:marks:\($0)" }, in: defaults)
        #expect(ForeignMarks.importedIDs(in: defaults).count == 500)
        _ = ForeignMarks.isArchived("rss:marks:1", in: defaults)
        let reads = ForeignMarks.listReads
        let writes = ForeignMarks.listWrites
        // A hundred ticks of an episode that came from nowhere else, and
        // the questions the export and the statistics ask.
        for tick in 0..<100 {
            ListeningStore.record("rss:marks:other", position: Double(tick), duration: 3_600,
                                  atMs: Double(1_000 + tick), in: defaults)
            _ = ForeignMarks.isArchived("rss:marks:\(tick)", in: defaults)
        }
        #expect(ForeignMarks.listReads == reads, "no whole list read after the first: \(ForeignMarks.listReads - reads)")
        #expect(ForeignMarks.listWrites == writes, "an unmarked episode writes nothing")
        // A real listen of an imported episode: one write, still no read.
        ListeningStore.record("rss:marks:7", position: 10, duration: 3_600, atMs: 5_000, in: defaults)
        #expect(ForeignMarks.listWrites == writes + 1 && ForeignMarks.listReads == reads)
        let left = ForeignMarks.importedIDs(in: defaults)
        #expect(left.count == 499 && !left.contains("rss:marks:7"))
    }

    @Test("S2b I4: eine Markenliste von vor dem Stempel wird gelesen, wie sie liegt, und nichts geht verloren")
    func aListFromBeforeTheStampIsReadAsItLies() {
        let earlier = (0..<22_000).map { "rss:earlier:\($0)" }.sorted()
        defaults.set(earlier, forKey: ForeignMarks.importedKey)
        #expect(defaults.string(forKey: ForeignMarks.stampKey(ForeignMarks.importedKey)) == nil,
                "the list lies as a build before this one left it")
        #expect(ForeignMarks.importedIDs(in: defaults).count == 22_000)
        #expect(defaults.stringArray(forKey: ForeignMarks.importedKey) == earlier, "reading leaves the list as it lies")
        ForeignMarks.markImported(["rss:new:1"], in: defaults)
        ForeignMarks.clearImported("rss:earlier:5", in: defaults)
        let stored = Set(defaults.stringArray(forKey: ForeignMarks.importedKey) ?? [])
        #expect(stored.count == 22_000 && stored.contains("rss:new:1") && !stored.contains("rss:earlier:5"))
        // Someone removes the list: the held copy does not outlive it.
        defaults.removeObject(forKey: ForeignMarks.importedKey)
        defaults.removeObject(forKey: ForeignMarks.stampKey(ForeignMarks.importedKey))
        #expect(ForeignMarks.importedIDs(in: defaults).isEmpty)
    }
}
#endif
