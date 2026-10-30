// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Das mittlere Widget Als Naechstes zeigt je Eintrag sein Cover. Das Widget
/// laedt nichts aus dem Netz, also legt die App fuer die ersten Eintraege ein
/// kleines Bild in die geteilte Ablage; der Name haengt nur an der Kennung,
/// und was die Vorschau nicht mehr nennt, geht.
struct UpNextWidgetCoverTests {
    private let store = WidgetCoverStore.upNext

    @Test("der Name eines Covers haengt nur an der Kennung, verschiedene Kennungen verschiedene Namen")
    func theNameFollowsTheId() {
        let name = store.name(for: "rss:feed:ep-1")
        #expect(name == store.name(for: "rss:feed:ep-1"))
        #expect(name.hasPrefix("upnext-cover-") && name.hasSuffix(".png"), "the files of the queue keep their names")
        #expect(name != store.name(for: "rss:feed:ep-2"))
        #expect(!name.contains(":") && !name.contains("/"), "a file name, not a path")
    }

    @Test("weg gehen nur Cover der Vorschau, die der Schnappschuss nicht mehr nennt")
    func onlyStaleCoversGo() {
        let kept = store.name(for: "a"), gone = store.name(for: "b")
        let present = [kept, gone, "widget-cover.png", "podcast-queue-snapshot.json"]
        #expect(store.stale(in: present, keeping: [kept]) == [gone])
        #expect(store.stale(in: present, keeping: [kept, gone]).isEmpty)
    }

    @Test("die Ablage ist geteilt: jedes Widget raeumt nur seine eigenen Cover, derselbe Titel hat je Widget eine Datei")
    func eachWidgetCleansItsOwnCovers() {
        let other = WidgetCoverStore(prefix: "other-cover-", pixel: 120)
        let queueCover = store.name(for: "a"), otherCover = other.name(for: "a")
        #expect(queueCover != otherCover)
        let present = [queueCover, otherCover, "widget-cover.png"]
        #expect(store.stale(in: present, keeping: []) == [queueCover])
        #expect(other.stale(in: present, keeping: []) == [otherCover])
    }

    @Test("ein Schnappschuss ohne Cover und Platzhalter liest sich weiter")
    func anOlderSnapshotStillReads() throws {
        let old = Data(#"{"items":[{"title":"Folge","show":"Sendung"}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(PodcastQueueSnapshot.self, from: old)
        #expect(snapshot.items.first?.title == "Folge")
        #expect(snapshot.items.first?.cover == nil && snapshot.items.first?.placeholder == nil)
    }

    @Test("die Warteschlange legt die Cover der ersten Eintraege ab, das Widget zeigt sie nur mittel", .needsTheSources)
    func theQueueLeavesTheCovers() throws {
        func flat(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
                .components(separatedBy: .whitespacesAndNewlines).joined()
        }
        let queue = try flat("Sources/Providers/PlayQueue.swift")
        #expect(queue.contains("ifcovered.count<PodcastQueueSnapshot.coveredCount{"))
        #expect(queue.contains("letname=WidgetCoverStore.upNext.name(for:id)"))
        #expect(queue.contains("awaitWidgetCoverWriter.write(covered,into:.upNext){"))
        let writer = try flat("Sources/Providers/WidgetCoverWriter.swift")
        #expect(writer.contains("PlayerViewModel.downscaled(image,maxPixel:store.pixel)"))
        #expect(writer.contains("store.stale(in:present,keeping:named())"))
        let widget = try flat("LiveActivityWidget/PodcastUpNextWidget.swift")
        #expect(widget.contains("iffamily==.systemMedium{"))
        #expect(widget.contains("cover(it)"))
        #expect(widget.contains("WidgetCoverStore.upNext.url(named:name)"))
    }
}
#endif
