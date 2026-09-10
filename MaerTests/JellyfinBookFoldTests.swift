// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The fold that makes one book out of the files of one Jellyfin folder, and
/// the listening state of that book in both directions. Elements are shaped
/// as Jellyfin 12 lists them (one `AudioBook` per file, `ParentId` the
/// folder), so the cases stand for what the server produces.
struct JellyfinBookFoldTests {

    private func file(_ id: String, parent: String?, index: Int? = nil, name: String? = nil,
                      album: String? = nil, artist: String? = nil, seconds: Double = 100,
                      positionSeconds: Double? = nil, played: Bool? = nil) -> JFItem {
        let userData = (positionSeconds != nil || played != nil)
            ? JFUserData(isFavorite: nil, playCount: nil,
                         playbackPositionTicks: positionSeconds.map { $0 * 10_000_000 }, played: played)
            : nil
        return JFItem(id: id, name: name ?? id, type: "AudioBook", collectionType: nil,
                      runTimeTicks: seconds * 10_000_000, indexNumber: index, productionYear: nil,
                      genres: nil, album: album, albumId: nil, albumArtist: artist, artists: nil,
                      overview: nil, dateCreated: nil, childCount: nil, userData: userData,
                      playlistItemId: nil, parentId: parent)
    }

    private func tracks(_ elements: [JFItem]) -> (tracks: [ABSAudioTrack], total: Double) {
        let built = MusicTrackAssembly.build(elements.map {
            MusicTrackAssembly.Song(id: $0.id, title: $0.name,
                                    duration: ($0.runTimeTicks ?? 0) / 10_000_000, size: nil)
        })
        return (built.tracks, built.total)
    }

    @Test("three tagged files in one folder fold to one book in track order")
    func taggedFolderFolds() {
        let groups = JellyfinBookFold.fold([
            file("c", parent: "F", index: 3, album: "The Book", artist: "Author"),
            file("a", parent: "F", index: 1, album: "The Book", artist: "Author"),
            file("b", parent: "F", index: 2, album: "The Book", artist: "Author"),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].isFolded)
        #expect(groups[0].rawId == "F")
        #expect(groups[0].elements.map(\.id) == ["a", "b", "c"])
        #expect(JellyfinBookFold.title(of: groups[0].elements, folderName: "Folder") == "The Book")
        #expect(JellyfinBookFold.author(of: groups[0].elements) == "Author")
        #expect(!JellyfinBookFold.lacksIndex(groups[0].elements))
    }

    @Test("three untagged files fold by name, and say so")
    func untaggedFolderFoldsByName() {
        let groups = JellyfinBookFold.fold([
            file("x", parent: "F", name: "03 - Kapitel"),
            file("y", parent: "F", name: "01 - Kapitel"),
            file("z", parent: "F", name: "02 - Kapitel"),
        ])
        #expect(groups.count == 1 && groups[0].isFolded)
        #expect(groups[0].elements.map(\.id) == ["y", "z", "x"])
        #expect(JellyfinBookFold.lacksIndex(groups[0].elements))
        // No album tag: the folder's name carries the title, the file as the last resort.
        #expect(JellyfinBookFold.title(of: groups[0].elements, folderName: "Probebuch") == "Probebuch")
        #expect(JellyfinBookFold.title(of: groups[0].elements, folderName: nil) == "01 - Kapitel")
    }

    @Test("a folder with one file stays a single book keyed by the file")
    func singleFileStays() {
        let groups = JellyfinBookFold.fold([file("only", parent: "F")])
        #expect(groups.count == 1)
        #expect(!groups[0].isFolded)
        #expect(groups[0].rawId == "only")
    }

    @Test("two folders interleaved become two books in listing order")
    func twoFoldersMixed() {
        let groups = JellyfinBookFold.fold([
            file("a1", parent: "A", index: 1), file("b1", parent: "B", index: 1),
            file("a2", parent: "A", index: 2), file("b2", parent: "B", index: 2),
        ])
        #expect(groups.map(\.rawId) == ["A", "B"])
        // `allSatisfy` is `rethrows`, which the expect macro cannot see
        // through; a plain comparison says the same.
        #expect(groups.map(\.isFolded) == [true, true])
        #expect(groups[0].elements.map(\.id) == ["a1", "a2"])
        #expect(groups[1].elements.map(\.id) == ["b1", "b2"])
    }

    @Test("an element without a folder is its own single book")
    func orphanIsSingle() {
        let groups = JellyfinBookFold.fold([file("loose", parent: nil), file("p", parent: "F"), file("q", parent: "F")])
        #expect(groups.count == 2)
        #expect(groups[0].rawId == "loose" && !groups[0].isFolded)
        #expect(groups[1].rawId == "F" && groups[1].isFolded)
    }

    @Test("reading: the furthest element speaks, a played one as its whole length")
    func positionReadsFurthest() {
        let elements = [
            file("a", parent: "F", index: 1, seconds: 100, played: true),
            file("b", parent: "F", index: 2, seconds: 100, positionSeconds: 30),
            file("c", parent: "F", index: 3, seconds: 100),
        ]
        let (tracks, total) = tracks(elements)
        let read = JellyfinBookFold.position(elements: elements, tracks: tracks, total: total)
        #expect(read?.currentTime == 130)
        #expect(read?.isFinished == false)
        // Nothing said: nil, not zero.
        let silent = [file("a", parent: "F"), file("b", parent: "F")]
        let (t2, tot2) = self.tracks(silent)
        #expect(JellyfinBookFold.position(elements: silent, tracks: t2, total: tot2) == nil)
        // Every element played: finished at the end.
        let done = [file("a", parent: "F", played: true), file("b", parent: "F", played: true)]
        let (t3, tot3) = self.tracks(done)
        let end = JellyfinBookFold.position(elements: done, tracks: t3, total: tot3)
        #expect(end?.currentTime == 200 && end?.isFinished == true)
        // A stale position past the file's end never overshoots the track.
        let over = [file("a", parent: "F", seconds: 100, positionSeconds: 500), file("b", parent: "F")]
        let (t4, tot4) = self.tracks(over)
        #expect(JellyfinBookFold.position(elements: over, tracks: t4, total: tot4)?.currentTime == 100)
    }

    @Test("writing: a book time lands on the running track at its inner position")
    func writePlanLandsOnTrack() {
        let elements = [file("a", parent: "F", seconds: 100), file("b", parent: "F", seconds: 100),
                        file("c", parent: "F", seconds: 100)]
        let (tracks, total) = tracks(elements)
        #expect(JellyfinBookFold.writePlan(currentTime: 130, tracks: tracks, total: total)
                == .init(index: 1, withinTrack: 30))
        #expect(JellyfinBookFold.writePlan(currentTime: 0, tracks: tracks, total: total)
                == .init(index: 0, withinTrack: 0))
        // Past the end: the last track catches the rest.
        #expect(JellyfinBookFold.writePlan(currentTime: 350, tracks: tracks, total: total).index == 2)
        // Round trip: what is written reads back as the same book time.
        let plan = JellyfinBookFold.writePlan(currentTime: 230, tracks: tracks, total: total)
        let written = [
            file("a", parent: "F", seconds: 100, played: true),
            file("b", parent: "F", seconds: 100, played: true),
            file("c", parent: "F", seconds: 100, positionSeconds: plan.withinTrack),
        ]
        #expect(JellyfinBookFold.position(elements: written, tracks: tracks, total: total)?.currentTime == 230)
    }
}
#endif
