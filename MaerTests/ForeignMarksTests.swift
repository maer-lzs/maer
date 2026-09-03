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
}
#endif
