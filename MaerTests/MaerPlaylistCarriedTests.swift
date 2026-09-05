// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A list with one entry per source travels to a device that knows none of
/// them: every entry keeps its name, the catalogue ones play, the others
/// say why not. The snapshots ride the blob and the merge; a rescue copy
/// names its device and its moment; a new list never takes a taken name.
struct MaerPlaylistCarriedTests {
    private let carried: [String: CarriedItem] = [
        "lva:netlabel-album#2": CarriedItem(id: "lva:netlabel-album#2", title: "Track Two", subtitle: "A Netlabel",
                                            duration: 210, coverURL: "https://archive.org/services/img/netlabel-album"),
        "lv:123": CarriedItem(id: "lv:123", title: "A LibriVox Book", subtitle: "An Author", duration: 3600),
        "sub:song:7": CarriedItem(id: "sub:song:7", title: "A Server Song", subtitle: "A Band", duration: 200),
        "jf:9": CarriedItem(id: "jf:9", title: "A Jellyfin Song", subtitle: "Another Band"),
        "local:/Music/file.mp3": CarriedItem(id: "local:/Music/file.mp3", title: "A Local File"),
        "rss:feed:ep-1": CarriedItem(id: "rss:feed:ep-1", title: "An Episode", subtitle: "A Show", duration: 1800),
        "li_abc": CarriedItem(id: "li_abc", title: "A Server Audiobook", subtitle: "A Narrator"),
    ]

    @Test("Auf Geraet B: jeder Eintrag behaelt seinen Namen, Katalog spielt, der Rest nennt den Grund")
    func everyEntryArrivesNamedAndExplained() {
        let ids = Array(carried.keys).sorted()
        var playable: [String] = []
        var reasons: [String: UnavailableReason] = [:]
        for id in ids {
            // Device B knows nothing locally and has no server of any kind.
            switch SyncCarried.resolve(itemId: id, carried: carried[id], known: nil, sourceConfigured: false) {
            case .playable(let item):
                playable.append(id)
                #expect(item.title == carried[id]?.title, "the stub is named by its snapshot")
            case .unavailable(let reason):
                reasons[id] = reason
            }
        }
        #expect(playable == ["lv:123", "lva:netlabel-album#2"], "catalogue ids play from themselves")
        #expect(reasons["sub:song:7"] == .sourceNotConfigured(source: "sub:"))
        #expect(reasons["jf:9"] == .sourceNotConfigured(source: "jf:"))
        #expect(reasons["local:/Music/file.mp3"] == .fileNotOnDevice)
        #expect(reasons["rss:feed:ep-1"] == .showNotFollowed)
        #expect(reasons["li_abc"] == .sourceNotConfigured(source: "library"))
        #expect(playable.count + reasons.count == ids.count, "nothing vanishes silently")
    }

    @Test("Die Schnappschuesse reisen im Blob hin und zurueck, und der Merge ergaenzt sie wie die Titel")
    func snapshotsTravelInTheBlobAndTheMerge() {
        let blob = MaerPlaylistCloudSync.blob(snapshots: carried)
        #expect(MaerPlaylistCloudSync.snapshots(fromBlob: blob) == carried)
        #expect(MaerPlaylistCloudSync.snapshots(fromBlob: nil).isEmpty)
        // The winner lacks a snapshot the loser knew: it is supplemented,
        // but only for ids the winner still carries.
        let mine = MaerPlaylistMerge.Entry(name: "L", updatedAt: 10, itemIds: ["lv:123", "sub:song:7"],
                                           snapshots: ["lv:123": carried["lv:123"]!])
        let theirs = MaerPlaylistMerge.Entry(name: "L", updatedAt: 5, itemIds: ["lv:123", "sub:song:7", "jf:9"],
                                             snapshots: ["sub:song:7": carried["sub:song:7"]!, "jf:9": carried["jf:9"]!])
        let outcome = MaerPlaylistMerge.merge(local: .init(lists: ["a": mine]), cloud: .init(lists: ["a": theirs]))
        #expect(outcome.lists["a"]?.snapshots.keys.sorted() == ["lv:123", "sub:song:7"])
    }

    @Test("Gleicher Inhalt ist nie eine Kopie; eine Kopie nennt Geraet und Moment; ein neuer Name ist nie ein vergebener")
    func rescueAndNaming() {
        let same = MaerPlaylistMerge.Entry(name: "L", updatedAt: 3, itemIds: ["a", "b"])
        #expect(!MaerPlaylistMerge.needsRescue(same, existing: [["a", "b"]]))
        #expect(MaerPlaylistMerge.needsRescue(same, existing: [["a"]]))
        #expect(!MaerPlaylistMerge.needsRescue(.init(name: "L", updatedAt: 3, itemIds: []), existing: []), "an empty loser is nothing to keep")
        let loser = MaerPlaylistMerge.Entry(name: "Roadtrip", updatedAt: 1_700_000_000, itemIds: ["a"], device: "iPad")
        let name = MaerPlaylistCloudSync.rescueName(loser)
        #expect(name.hasPrefix("Copy of Roadtrip (iPad, ") || name.hasPrefix("Kopie von Roadtrip (iPad, "))
        #expect(!MaerPlaylistCloudSync.rescueReason(loser).isEmpty)
        #expect(MaerPlaylists.uniqueName("New Playlist", among: []) == "New Playlist")
        #expect(MaerPlaylists.uniqueName("New Playlist", among: ["new playlist"]) == "New Playlist 2")
        #expect(MaerPlaylists.uniqueName("New Playlist", among: ["New Playlist", "New Playlist 2"]) == "New Playlist 3")
    }
}
#endif
