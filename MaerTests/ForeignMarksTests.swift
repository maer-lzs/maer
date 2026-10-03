// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Synchronization
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
        let before = ListeningByClass.shows(positions: ListeningStore.positions(in: defaults), showId: showId,
                                            excluding: ForeignMarks.importedIDs(in: defaults))
        #expect(before["rss:feedkey1"] == nil)
        // Without the exclusion the same entry would count: the mark is the difference.
        #expect(ListeningByClass.shows(positions: ListeningStore.positions(in: defaults), showId: showId)["rss:feedkey1"] == 3_600)
        // A real listen on this device clears the mark and the time counts,
        // at the position the listen reached.
        ListeningStore.record(guid, position: 1_200, duration: 3_600, atMs: 2_000, in: defaults)
        let after = ListeningByClass.shows(positions: ListeningStore.positions(in: defaults), showId: showId,
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

    // MARK: - Reads after writes

    /// Defaults that write down every key they are asked for.
    nonisolated final class CountingDefaults: UserDefaults {
        let asked = Mutex<[String]>([])
        override func object(forKey defaultName: String) -> Any? {
            asked.withLock { $0.append(defaultName) }
            return super.object(forKey: defaultName)
        }
    }

    @Test("TF-11 I1: ein Wiedergabe-Tick liest nach dem ersten Laden keinen Marken-Schluessel, auch keinen Stempel")
    func aTickReadsNoMarkKeyAtAll() throws {
        let suite = "tf11-counting-\(UUID().uuidString)"
        let counting = try #require(CountingDefaults(suiteName: suite))
        defer { counting.removePersistentDomain(forName: suite) }
        ForeignMarks.markImported((0..<50).map { "rss:counted:\($0)" }, in: counting)
        _ = ForeignMarks.isArchived("rss:counted:0", in: counting)
        counting.asked.withLock { $0.removeAll() }
        for tick in 0..<100 {
            ListeningStore.record("rss:counted:other", position: Double(tick), duration: 3_600,
                                  atMs: Double(1_000 + tick), in: counting)
            _ = ForeignMarks.isArchived("rss:counted:\(tick)", in: counting)
        }
        _ = counting.object(forKey: "instrument.check")
        let asked = counting.asked.withLock { $0 }
        #expect(asked.contains("instrument.check"), "the counter hears a read at all")
        let markReads = asked.filter { $0.lowercased().hasPrefix("foreignmarks") }
        #expect(markReads.isEmpty, "no mark key read after the first load: \(markReads.prefix(5))")
    }

    @Test("TF-11 I2: eine Aenderung von aussen und entfernte Marken werden gesehen")
    func anOutsideChangeIsSeen() throws {
        let suite = "tf11-outside-\(UUID().uuidString)"
        let own = try #require(UserDefaults(suiteName: suite))
        defer { own.removePersistentDomain(forName: suite) }
        ForeignMarks.markImported(["rss:outside:a", "rss:outside:b"], in: own)
        #expect(ForeignMarks.importedIDs(in: own) == ["rss:outside:a", "rss:outside:b"])
        let reads = ForeignMarks.listReads
        // Unchanged: the held copy answers.
        _ = ForeignMarks.importedIDs(in: own)
        #expect(ForeignMarks.listReads == reads)
        // From outside this type: another list and a new stamp.
        own.set(["rss:outside:c"], forKey: ForeignMarks.importedKey)
        own.set("outside", forKey: ForeignMarks.stampKey(ForeignMarks.importedKey))
        #expect(ForeignMarks.importedIDs(in: own) == ["rss:outside:c"], "the next question reads again")
        #expect(ForeignMarks.listReads == reads + 1)
        // List and stamp removed from outside.
        own.removeObject(forKey: ForeignMarks.importedKey)
        own.removeObject(forKey: ForeignMarks.stampKey(ForeignMarks.importedKey))
        #expect(ForeignMarks.importedIDs(in: own).isEmpty, "removed marks leave no held copy")
    }

    /// Removing a whole domain does not reach the stamp's observation
    /// (measured: the held copy survived it). The app never removes one,
    /// and this keeps it so; a new place that does would need the held
    /// lists to hear it first.
    @Test("TF-11 I2: die App loescht keine ganze Domaene, die die gehaltenen Marken nicht hoeren", .needsTheSources)
    func theAppRemovesNoDomain() throws {
        let files = ProjectFileIntegrityTests.sourceFiles()
        try #require(files.contains { $0.lastPathComponent == "ForeignMarks.swift" },
                     "the finder sees the file whose held lists this protects")
        var hits: [String] = []
        for file in files {
            let source = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            for form in ["removePersistentDomain", "setPersistentDomain", "resetStandardUserDefaults"]
            where source.contains(form) {
                hits.append("\(file.lastPathComponent): \(form)")
            }
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    @Test("TF-11 I3: viele Grabsteine in einem Abgleich schreiben jede Liste einmal")
    func tombstonesInMassWriteEachListOnce() {
        let ids = (0..<300).map { "rss:tomb:\($0)" }
        ForeignMarks.markImported(ids, in: defaults)
        ForeignMarks.markArchived(ids.prefix(100), in: defaults)
        let writes = ForeignMarks.listWrites
        ForeignMarks.clearingTogether {
            for id in ids { ListeningStore.store(id, entry: [0, 5_000], in: defaults) }
            #expect(ForeignMarks.importedIDs(in: defaults).count == 300, "inside, the marks still stand")
        }
        #expect(ForeignMarks.listWrites - writes == 2, "one write per list: \(ForeignMarks.listWrites - writes)")
        #expect(ForeignMarks.importedIDs(in: defaults).isEmpty)
        #expect(ids.filter { ForeignMarks.isArchived($0, in: defaults) }.isEmpty)
    }

    @Test("TF-11 I3: der Abgleich und Alle-markieren raeumen in einem Zug", .needsTheSources)
    func theMassPathsClearTogether() throws {
        for path in ["Sources/Networking/PodcastCloudSync.swift", "Sources/Views/Podcasts/PodcastShowView.swift"] {
            let source = SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
            #expect(source.components(separatedBy: "ForeignMarks.clearingTogether {").count - 1 == 1, "\(path)")
        }
    }
}
#endif
