// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The medium widget Up Next shows its cover for each entry. The widget
/// loads nothing from the network, so the app puts a small image for the first entries
/// into the shared storage; the name depends only on the id,
/// and what the preview no longer names goes.
struct UpNextWidgetCoverTests {
    private let store = WidgetCoverStore.upNext

    @Test("the name of a cover depends only on the id, different ids different names")
    func theNameFollowsTheId() {
        let name = store.name(for: "rss:feed:ep-1")
        #expect(name == store.name(for: "rss:feed:ep-1"))
        #expect(name.hasPrefix("upnext-cover-") && name.hasSuffix(".png"), "the files of the queue keep their names")
        #expect(name != store.name(for: "rss:feed:ep-2"))
        #expect(!name.contains(":") && !name.contains("/"), "a file name, not a path")
    }

    @Test("only covers of the preview that the snapshot no longer names go away")
    func onlyStaleCoversGo() {
        let kept = store.name(for: "a"), gone = store.name(for: "b")
        let present = [kept, gone, "widget-cover.png", "podcast-queue-snapshot.json"]
        #expect(store.stale(in: present, keeping: [kept]) == [gone])
        #expect(store.stale(in: present, keeping: [kept, gone]).isEmpty)
    }

    @Test("the storage is shared: each widget clears only its own covers, the same title has one file per widget")
    func eachWidgetCleansItsOwnCovers() {
        let other = WidgetCoverStore(prefix: "other-cover-", pixel: 120)
        let queueCover = store.name(for: "a"), otherCover = other.name(for: "a")
        #expect(queueCover != otherCover)
        let present = [queueCover, otherCover, "widget-cover.png"]
        #expect(store.stale(in: present, keeping: []) == [queueCover])
        #expect(other.stale(in: present, keeping: []) == [otherCover])
    }

    @Test("a snapshot without covers and placeholders still reads")
    func anOlderSnapshotStillReads() throws {
        let old = Data(#"{"items":[{"title":"Folge","show":"Sendung"}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(PodcastQueueSnapshot.self, from: old)
        #expect(snapshot.items.first?.title == "Folge")
        #expect(snapshot.items.first?.cover == nil && snapshot.items.first?.placeholder == nil)
    }

    @Test("the queue stores the covers of the first entries, the widget shows them only at medium size", .needsTheSources)
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
