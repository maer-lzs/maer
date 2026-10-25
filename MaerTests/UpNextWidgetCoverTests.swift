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
    @Test("der Name eines Covers haengt nur an der Kennung, verschiedene Kennungen verschiedene Namen")
    func theNameFollowsTheId() {
        let name = PodcastQueueSnapshot.coverName(for: "rss:feed:ep-1")
        #expect(name == PodcastQueueSnapshot.coverName(for: "rss:feed:ep-1"))
        #expect(name.hasPrefix(PodcastQueueSnapshot.coverPrefix) && name.hasSuffix(".png"))
        #expect(name != PodcastQueueSnapshot.coverName(for: "rss:feed:ep-2"))
        #expect(!name.contains(":") && !name.contains("/"), "a file name, not a path")
    }

    @Test("weg gehen nur Cover der Vorschau, die der Schnappschuss nicht mehr nennt")
    func onlyStaleCoversGo() {
        let kept = PodcastQueueSnapshot.coverName(for: "a"), gone = PodcastQueueSnapshot.coverName(for: "b")
        let present = [kept, gone, "widget-cover.png", "podcast-queue-snapshot.json"]
        #expect(PodcastQueueSnapshot.staleCovers(in: present, keeping: [kept]) == [gone])
        #expect(PodcastQueueSnapshot.staleCovers(in: present, keeping: [kept, gone]).isEmpty)
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
        #expect(queue.contains("Task{awaitSelf.writeWidgetCovers(covered)}"))
        #expect(queue.contains("PlayerViewModel.downscaled(image,maxPixel:PodcastQueueSnapshot.coverPixel)"))
        let widget = try flat("LiveActivityWidget/PodcastUpNextWidget.swift")
        #expect(widget.contains("iffamily==.systemMedium{"))
        #expect(widget.contains("cover(it)"))
        #expect(widget.contains("PodcastQueueSnapshot.coverURL(named:name)"))
    }
}
#endif
