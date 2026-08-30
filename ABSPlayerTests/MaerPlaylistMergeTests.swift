// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// What happens when the same list was changed on two devices.
struct MaerPlaylistMergeTests {
    private func entry(_ name: String, _ at: Double, _ ids: [String]) -> MaerPlaylistMerge.Entry {
        .init(name: name, updatedAt: at, itemIds: ids)
    }

    @Test("the newer version wins — per LIST, never per entry")
    func newerWinsWholeList() {
        let local = MaerPlaylistMerge.Snapshot(lists: ["a": entry("Abend", 100, ["x", "y"])])
        let cloud = MaerPlaylistMerge.Snapshot(lists: ["a": entry("Abend", 200, ["x"])])
        let out = MaerPlaylistMerge.merge(local: local, cloud: cloud)
        #expect(out.lists["a"]?.itemIds == ["x"],
                "a removed title must NOT rise again — that is why there is no entry-level union")
    }

    @Test("the losing version is kept, not dropped")
    func loserIsRescued() {
        let local = MaerPlaylistMerge.Snapshot(lists: ["a": entry("Abend", 100, ["x", "y"])])
        let cloud = MaerPlaylistMerge.Snapshot(lists: ["a": entry("Abend", 200, ["x"])])
        let out = MaerPlaylistMerge.merge(local: local, cloud: cloud)
        #expect(out.rescued.count == 1)
        #expect(out.rescued.first?.itemIds == ["x", "y"])
    }

    @Test("identical content produces no rescue copy")
    func noRescueWithoutDifference() {
        let local = MaerPlaylistMerge.Snapshot(lists: ["a": entry("Abend", 100, ["x"])])
        let cloud = MaerPlaylistMerge.Snapshot(lists: ["a": entry("Abend", 200, ["x"])])
        #expect(MaerPlaylistMerge.merge(local: local, cloud: cloud).rescued.isEmpty)
    }

    @Test("a deleted list stays deleted — and can be created again")
    func deletionSticksButDoesNotBlockForever() {
        let cloud = MaerPlaylistMerge.Snapshot(lists: ["a": entry("Abend", 100, ["x"])])
        let deleted = MaerPlaylistMerge.Snapshot(tombstones: ["a": 150])
        #expect(MaerPlaylistMerge.merge(local: deleted, cloud: cloud).lists["a"] == nil,
                "without the mark the list would come back from iCloud")
        // Someone made a new list under that id AFTER the deletion.
        let recreated = MaerPlaylistMerge.Snapshot(lists: ["a": entry("Abend", 300, ["z"])])
        let out = MaerPlaylistMerge.merge(local: deleted, cloud: recreated)
        #expect(out.lists["a"]?.itemIds == ["z"], "a deletion must not silence a list forever")
    }

    @Test("a list that exists on one side only simply arrives")
    func oneSidedListsTravel() {
        let local = MaerPlaylistMerge.Snapshot(lists: ["a": entry("Hier", 100, ["x"])])
        let cloud = MaerPlaylistMerge.Snapshot(lists: ["b": entry("Dort", 100, ["y"])])
        let out = MaerPlaylistMerge.merge(local: local, cloud: cloud)
        #expect(Set(out.lists.keys) == ["a", "b"])
        #expect(out.rescued.isEmpty)
    }

    /// Title snapshots are what a device shows for an entry it cannot resolve.
    /// Knowledge only one side has must not die because the other side wins.
    @Test("a title the loser knew supplements the winner")
    func loserTitleSupplementsWinner() {
        var mine = entry("Abend", 200, ["x", "y"])
        mine.titles = ["x": "Mondlicht"]
        var theirs = entry("Abend", 100, ["x", "y"])
        theirs.titles = ["x": "ANDERS", "y": "Nebel"]
        let out = MaerPlaylistMerge.merge(
            local: .init(lists: ["a": mine]), cloud: .init(lists: ["a": theirs]))
        // The winner's own titles stay; only the missing one arrives.
        #expect(out.lists["a"]?.titles == ["x": "Mondlicht", "y": "Nebel"])
    }

    @Test("supplemented titles stay within the winner's list")
    func titlesFollowTheList() {
        var mine = entry("Abend", 200, ["x"])
        mine.titles = ["x": "Mondlicht"]
        var theirs = entry("Abend", 100, ["x", "gone"])
        theirs.titles = ["gone": "Geloescht"]
        let out = MaerPlaylistMerge.merge(
            local: .init(lists: ["a": mine]), cloud: .init(lists: ["a": theirs]))
        // A title for an entry the winner no longer carries does not ride
        // along. The list decides, titles only describe it.
        #expect(out.lists["a"]?.titles == ["x": "Mondlicht"])
        #expect(out.rescued.count == 1)
    }

    @Test("the same rescue is not created twice")
    func rescueDoesNotMultiply() {
        let candidate = entry("Abend", 100, ["x", "y"])
        #expect(MaerPlaylistMerge.needsRescue(candidate, existing: [["a"], ["x"]]))
        #expect(!MaerPlaylistMerge.needsRescue(candidate, existing: [["x", "y"]]),
                "compared by CONTENT — the name carries a date and would differ every run")
        #expect(!MaerPlaylistMerge.needsRescue(entry("Leer", 100, []), existing: []),
                "an empty version is nothing worth rescuing")
    }

    /// Der Name hat seine eigene Uhr. Vorher starb eine Umbenennung auf der
    /// Seite, die die Liste am Inhalt verlor, still, und wurde nicht einmal
    /// gerettet, weil die Rettungskopie am INHALT feuert.
    @Test("eine Umbenennung ueberlebt, auch wenn ihre Seite die Liste verliert")
    func aRenameSurvivesLosingTheList() {
        let a = MaerPlaylistMerge.Entry(name: "Abendrunde", updatedAt: 100,
                                        itemIds: ["x"], nameUpdatedAt: 100)
        let b = MaerPlaylistMerge.Entry(name: "Playlist 1", updatedAt: 200,
                                        itemIds: ["x", "y"], nameUpdatedAt: nil)
        let ausgang = MaerPlaylistMerge.merge(
            local: .init(lists: ["l": a]), cloud: .init(lists: ["l": b]))
        #expect(ausgang.lists["l"]?.itemIds == ["x", "y"],
                "der Inhalt des Gewinners ist gefallen")
        #expect(ausgang.lists["l"]?.name == "Abendrunde",
                "die Umbenennung ist wieder still gestorben")
        #expect(ausgang.lists["l"]?.nameUpdatedAt == 100,
                "ohne die mitreisende Uhr stirbt der Name im naechsten Lauf")
    }

    /// Rot-Probe in die Gegenrichtung, und der Alt-Bestand bleibt sich treu.
    @Test("die juengere Namens-Uhr gewinnt, und ohne Uhren gilt das Alte")
    func theYoungerNameClockWins() {
        let alt = MaerPlaylistMerge.Entry(name: "Alt", updatedAt: 100,
                                          itemIds: ["x"], nameUpdatedAt: 50)
        let neu = MaerPlaylistMerge.Entry(name: "Neu", updatedAt: 200,
                                          itemIds: ["x", "y"], nameUpdatedAt: 150)
        let ausgang = MaerPlaylistMerge.merge(
            local: .init(lists: ["l": alt]), cloud: .init(lists: ["l": neu]))
        #expect(ausgang.lists["l"]?.name == "Neu",
                "die aeltere Namens-Uhr hat die juengere geschlagen")

        let a = MaerPlaylistMerge.Entry(name: "A", updatedAt: 100, itemIds: ["x"])
        let b = MaerPlaylistMerge.Entry(name: "B", updatedAt: 200, itemIds: ["y"])
        let legacy = MaerPlaylistMerge.merge(
            local: .init(lists: ["l": a]), cloud: .init(lists: ["l": b]))
        #expect(legacy.lists["l"]?.name == "B",
                "zwei Seiten ohne Uhr verhalten sich nicht mehr wie vor dem Feld")
    }
}
#endif
