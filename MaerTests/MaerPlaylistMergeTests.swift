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

    @Test("zwei Ergaenzungen auf zwei Geraeten vereinigen sich, ohne Kopie")
    func twoAdditionsUnite() {
        // The list had [a, b]; A added x (at 200), B added y (at 300).
        let a = entry("Test2", 200, ["a", "b", "x"])
        let b = entry("Test2", 300, ["a", "b", "y"])
        let out = MaerPlaylistMerge.merge(local: .init(lists: ["l": a]), cloud: .init(lists: ["l": b]))
        #expect(out.lists["l"]?.itemIds == ["a", "b", "y", "x"],
                "the newer side's order, the other side's new entry appended")
        #expect(out.rescued.isEmpty, "two additions are not a conflict")
        #expect(out.lists["l"]?.updatedAt == 300)
        // The mirror image lands on the same list.
        let mirrored = MaerPlaylistMerge.merge(local: .init(lists: ["l": b]), cloud: .init(lists: ["l": a]))
        #expect(mirrored.lists["l"]?.itemIds == ["a", "b", "y", "x"])
    }

    @Test("ein Entfernen reist als Grabstein je Eintrag; der Titel kommt nicht zurueck")
    func aRemovalTravels() {
        // A removed z at 250; B (unchanged since 100) still carries z and added y at 300.
        var a = entry("Abend", 250, ["a", "b"])
        a.removed = ["z": 250]
        let bOld = entry("Abend", 100, ["a", "b", "z"])
        // The clocks of this case are small numbers; `now` sits beside them
        // so the ninety-day ageing does not take the mark away here.
        let outOld = MaerPlaylistMerge.merge(local: .init(lists: ["l": a]), cloud: .init(lists: ["l": bOld]), now: 1_000)
        #expect(outOld.lists["l"]?.itemIds == ["a", "b"], "z rose again from the side that never saw the removal")
        #expect(outOld.lists["l"]?.removed == ["z": 250], "the mark travels on")

        var bAdded = entry("Abend", 300, ["a", "b", "z", "y"])
        bAdded.added = ["y": 300]
        let out = MaerPlaylistMerge.merge(local: .init(lists: ["l": a]), cloud: .init(lists: ["l": bAdded]))
        #expect(out.lists["l"]?.itemIds == ["a", "b", "y"],
                "B added y after the removal but never re-added z: z stays out, y comes in")
    }

    @Test("ein Eintrag, den eine Seite NACH dem Entfernen wieder hinzufuegt, bleibt")
    func aReAddSpendsTheMark() {
        var a = entry("Abend", 250, ["a"])
        a.removed = ["z": 250]
        // B re-added z at 400, after the removal: the add moment is the witness.
        var b = entry("Abend", 400, ["a", "z"])
        b.added = ["z": 400]
        let out = MaerPlaylistMerge.merge(local: .init(lists: ["l": a]), cloud: .init(lists: ["l": b]))
        #expect(out.lists["l"]?.itemIds == ["a", "z"])
        #expect(out.lists["l"]?.removed.isEmpty == true, "a spent mark must not travel on")
        #expect(out.lists["l"]?.added == ["z": 400])
        // Without the add moment the mark wins: an old presence is not a re-add.
        let lingering = entry("Abend", 400, ["a", "z"])
        let kept = MaerPlaylistMerge.merge(local: .init(lists: ["l": a]), cloud: .init(lists: ["l": lingering]))
        #expect(kept.lists["l"]?.itemIds == ["a"])
    }

    @Test("Umbenennung auf A und Ergaenzung auf B ergeben neuen Namen mit Eintrag")
    func renameAndAdditionUnite() {
        let a = MaerPlaylistMerge.Entry(name: "Test2", updatedAt: 200, itemIds: ["a"], nameUpdatedAt: 200)
        let b = MaerPlaylistMerge.Entry(name: "Test", updatedAt: 300, itemIds: ["a", "y"], nameUpdatedAt: nil)
        let out = MaerPlaylistMerge.merge(local: .init(lists: ["l": a]), cloud: .init(lists: ["l": b]))
        #expect(out.lists["l"]?.name == "Test2")
        #expect(out.lists["l"]?.itemIds == ["a", "y"])
        #expect(out.rescued.isEmpty)
    }

    @Test("alte Blobs ohne Grabsteine lesen wie eine Vereinigung")
    func legacyBlobsUnite() {
        let local = entry("Alt", 100, ["x", "y"])
        let cloud = entry("Alt", 200, ["x"])
        let out = MaerPlaylistMerge.merge(local: .init(lists: ["l": local]), cloud: .init(lists: ["l": cloud]))
        #expect(out.lists["l"]?.itemIds == ["x", "y"], "without a mark nothing was removed, so nothing is dropped")
        #expect(out.rescued.isEmpty)
    }

    /// A removal mark travels ninety days and then falls: every device
    /// that will ever merge it has seen it by then, and the blob must not
    /// grow with every title ever removed.
    @Test("Grabsteine je Eintrag altern: nach 90 Tagen fallen sie, juengere bleiben")
    func removalMarksAge() {
        let now: Double = 100 * 86_400
        var a = entry("Abend", now - 10, ["a"])
        a.removed = ["old": now - 95 * 86_400, "fresh": now - 10 * 86_400]
        let b = entry("Abend", now - 20, ["a", "old", "fresh"])
        let out = MaerPlaylistMerge.merge(local: .init(lists: ["l": a]), cloud: .init(lists: ["l": b]), now: now)
        #expect(out.lists["l"]?.removed == ["fresh": now - 10 * 86_400], "the old mark travelled on")
        #expect(out.lists["l"]?.itemIds == ["a"], "an aged mark still counts in the merge it falls from")
        let alone = MaerPlaylistMerge.merge(local: .init(lists: ["l": a]), cloud: .init(), now: now)
        #expect(alone.lists["l"]?.removed.keys.sorted() == ["fresh"], "a one-sided list ages its marks too")
    }

    @Test("eine Teilmenge wird nie gerettet; nur ein echter Verlust")
    func aSubsetIsNeverRescued() {
        #expect(!MaerPlaylistMerge.needsRescue(entry("T", 1, ["a", "b"]), existing: [["a", "b", "c"]]))
        #expect(!MaerPlaylistMerge.needsRescue(entry("T", 1, ["b", "a"]), existing: [["a", "b", "c"]]),
                "order does not make a loss")
        #expect(MaerPlaylistMerge.needsRescue(entry("T", 1, ["a", "d"]), existing: [["a", "b", "c"]]),
                "d stands nowhere: that is a loss")
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

    @Test("supplemented titles stay within the united list")
    func titlesFollowTheList() {
        var mine = entry("Abend", 200, ["x"])
        mine.titles = ["x": "Mondlicht"]
        mine.removed = ["gone": 200]
        var theirs = entry("Abend", 100, ["x", "gone"])
        theirs.titles = ["gone": "Geloescht"]
        let out = MaerPlaylistMerge.merge(
            local: .init(lists: ["a": mine]), cloud: .init(lists: ["a": theirs]))
        // A title for an entry the list no longer carries does not ride
        // along. The list decides, titles only describe it.
        #expect(out.lists["a"]?.titles == ["x": "Mondlicht"])
        #expect(out.rescued.isEmpty)
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

    /// A version every field of which is set, so a change of any one field
    /// is a change from a value, not from a default.
    private static let full = MaerPlaylistMerge.Entry(
        name: "Liste", updatedAt: 100, itemIds: ["a", "b"], titles: ["a": "A"], nameUpdatedAt: 90,
        snapshots: ["a": CarriedItem(id: "a", title: "A", subtitle: "S", duration: 60)],
        removed: ["c": 80], added: ["a": 70], device: "phone")

    /// `differs` compares every stored field but the device name, and the
    /// list of compared fields is the list of stored fields.
    @Test("jedes gespeicherte Feld ausser dem Geraetenamen ist ein Unterschied, und die Liste der Felder ist vollstaendig")
    func differsSeesEveryFieldButTheDevice() {
        let stored = Set(Mirror(reflecting: Self.full).children.compactMap(\.label))
        #expect(stored == MaerPlaylistMerge.comparedFields.union(["device"]),
                "a stored field of Entry is missing from comparedFields: \(stored)")
        var changes: [String: MaerPlaylistMerge.Entry] = [:]
        var e = Self.full; e.name = "Andere"; changes["name"] = e
        e = Self.full; e.updatedAt = 101; changes["updatedAt"] = e
        e = Self.full; e.nameUpdatedAt = 91; changes["nameUpdatedAt"] = e
        e = Self.full; e.itemIds = ["a"]; changes["itemIds"] = e
        e = Self.full; e.titles = ["a": "B"]; changes["titles"] = e
        e = Self.full; e.snapshots = [:]; changes["snapshots"] = e
        e = Self.full; e.removed = [:]; changes["removed"] = e
        e = Self.full; e.added = [:]; changes["added"] = e
        #expect(Set(changes.keys) == MaerPlaylistMerge.comparedFields, "the witness changes every compared field")
        for (field, changed) in changes {
            #expect(MaerPlaylistMerge.differs(Self.full, changed), "a change of \(field) is no difference")
        }
        e = Self.full; e.device = "tablet"
        #expect(!MaerPlaylistMerge.differs(Self.full, e), "the device name counted as a difference")
        #expect(!MaerPlaylistMerge.isSameVersion(Self.full, e), "another device is another version")
        #expect(MaerPlaylistMerge.isSameVersion(Self.full, Self.full))
    }

    /// The id a rescued loser came from: the local side first, then the
    /// cloud side, and only the very version, device name included.
    @Test("die Kennung einer geretteten Fassung ist die Liste, unter der genau diese Fassung stand")
    func theRescuedLoserNamesItsList() {
        var other = Self.full; other.name = "Andere"
        var elsewhere = Self.full; elsewhere.device = "tablet"
        let local = MaerPlaylistMerge.Snapshot(lists: ["mine": other, "near": elsewhere])
        let cloud = MaerPlaylistMerge.Snapshot(lists: ["far": Self.full])
        #expect(MaerPlaylistMerge.sourceId(of: Self.full, local: local, cloud: cloud) == "far")
        #expect(MaerPlaylistMerge.sourceId(of: other, local: local, cloud: cloud) == "mine")
        #expect(MaerPlaylistMerge.sourceId(of: Self.full, local: local, cloud: .init()) == nil,
                "a version neither side holds has no list")
    }

    /// No version compares with `==`; the compiler refuses it.
    @Test("weder Fassung noch Momentaufnahme noch Ergebnis sind vergleichbar mit ==")
    func noVersionIsEquatable() {
        #expect(!(MaerPlaylistMerge.Entry.self is any Equatable.Type))
        #expect(!(MaerPlaylistMerge.Snapshot.self is any Equatable.Type))
        #expect(!(MaerPlaylistMerge.Outcome.self is any Equatable.Type))
    }
}
#endif
