// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The fold that makes one book out of the files of one Jellyfin book, and
/// the listening state of that book in both directions. Elements are shaped
/// as Jellyfin 12 lists them (one `AudioBook` per file, `ParentId` the
/// folder, `Album` the tag); the shelves are the ones measured on the test
/// server: loose books in the root folder, an author folder with two
/// single-file books, and a book folder with three chapters.
struct JellyfinBookFoldTests {

    // Folders as the server listed them (ids shortened like the report).
    private let root = "43e7914d", author = "5004a78f", book = "4c0d70fc"

    private func file(_ id: String, parent: String?, album: String? = nil, index: Int? = nil,
                      name: String? = nil, artist: String? = nil, seconds: Double = 100,
                      positionSeconds: Double? = nil, played: Bool? = nil) -> JFItem {
        let userData = (positionSeconds != nil || played != nil)
            ? JFUserData(isFavorite: nil, playCount: nil,
                         playbackPositionTicks: positionSeconds.map { $0 * 10_000_000 }, played: played,
                         lastPlayedDate: nil)
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

    // MARK: - What folds, what stays (the five shelves of the finding)

    @Test("a book folder with three same-tagged files folds to one book in track order")
    func bookFolderFolds() {
        let groups = JellyfinBookFold.fold([
            file("33e62a06", parent: book, album: "Probebuch", index: 3, artist: "Probeautor"),
            file("5b452573", parent: book, album: "Probebuch", index: 1, artist: "Probeautor"),
            file("2a9f7b82", parent: book, album: "Probebuch", index: 2, artist: "Probeautor"),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].isFolded)
        #expect(groups[0].rawId == JellyfinBookFold.foldedRawId(parentId: book, album: "Probebuch"))
        #expect(groups[0].elements.map(\.id) == ["5b452573", "2a9f7b82", "33e62a06"])
        #expect(JellyfinBookFold.title(of: groups[0].elements, folderName: "Probebuch") == "Probebuch")
        #expect(JellyfinBookFold.author(of: groups[0].elements) == "Probeautor")
    }

    @Test("an author folder with two tagged single-file books stays two books")
    func authorFolderStaysTwo() {
        let groups = JellyfinBookFold.fold([
            file("bookC", parent: author, album: "BuchC"),
            file("bookD", parent: author, album: "BuchD"),
        ])
        #expect(groups.map(\.rawId) == ["bookC", "bookD"])
        #expect(groups.map(\.isFolded) == [false, false])
    }

    @Test("two loose books in the root folder stay two books")
    func rootStaysTwo() {
        let groups = JellyfinBookFold.fold([
            file("bookA", parent: root, album: "BuchA"),
            file("bookB", parent: root, album: "BuchB"),
        ])
        #expect(groups.map(\.rawId) == ["bookA", "bookB"])
        #expect(groups.map(\.isFolded) == [false, false])
    }

    @Test("a book folder with three untagged files stays three single books, and is named")
    func untaggedFolderStaysSingles() {
        let files = [
            file("x", parent: book, name: "03 - Kapitel"),
            file("y", parent: book, name: "01 - Kapitel"),
            file("z", parent: book, name: "02 - Kapitel"),
        ]
        let groups = JellyfinBookFold.fold(files)
        #expect(groups.count == 3)
        #expect(groups.map(\.isFolded) == [false, false, false])
        #expect(groups.map(\.rawId) == ["x", "y", "z"])
        // The listing says which folder it left split, and how many files.
        #expect(JellyfinBookFold.untaggedFolders(files) == [book: 3])
        // A single untagged file is no such folder.
        #expect(JellyfinBookFold.untaggedFolders([file("solo", parent: author)]).isEmpty)
    }

    @Test("a mixed folder: the two same-tagged files fold, the foreign-tagged one stays its own book")
    func mixedFolderSplitsByTag() throws {
        let groups = JellyfinBookFold.fold([
            file("p1", parent: author, album: "Buch P", index: 1),
            file("q", parent: author, album: "Buch Q"),
            file("p2", parent: author, album: "Buch P", index: 2),
        ])
        // A fold that lumps them yields ONE group; the witness must fail
        // there, not crash on an index and take the rest of the run with it.
        try #require(groups.count == 2)
        #expect(groups[0].isFolded && groups[0].elements.map(\.id) == ["p1", "p2"])
        #expect(!groups[1].isFolded && groups[1].rawId == "q")
        // The neighbours of a folded book are its own files and nothing else:
        // the foreign book is not in the tracks a write plan walks.
        let (tracks, _) = tracks(groups[0].elements)
        #expect(!tracks.map(\.contentUrl).contains("q"))
    }

    @Test("an element without a folder is its own single book")
    func orphanIsSingle() {
        let groups = JellyfinBookFold.fold([
            file("loose", parent: nil, album: "Loose"),
            file("p", parent: book, album: "Probebuch", index: 1),
            file("q", parent: book, album: "Probebuch", index: 2),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].rawId == "loose" && !groups[0].isFolded)
        #expect(groups[1].isFolded)
    }

    @Test("a listing of several files without any folder is blind, one file is not")
    func blindListingIsSeen() {
        #expect(JellyfinBookFold.isBlind([file("a", parent: nil), file("b", parent: nil)]))
        #expect(!JellyfinBookFold.isBlind([file("a", parent: book), file("b", parent: nil)]))
        #expect(!JellyfinBookFold.isBlind([file("a", parent: nil)]))
    }

    // MARK: - The folded id

    @Test("a folded id carries folder and album hash and parses back; a file id never does")
    func foldedIdRoundTrip() {
        let raw = JellyfinBookFold.foldedRawId(parentId: book, album: "Probebuch")
        let parsed = JellyfinBookFold.parseFoldedRawId(raw)
        #expect(parsed?.parentId == book)
        #expect(parsed?.albumHash == JellyfinBookFold.albumHash("Probebuch"))
        #expect(JellyfinBookFold.albumHash("Probebuch").count == 16)
        // Stable across devices: the same tag gives the same hash, another tag another.
        #expect(JellyfinBookFold.albumHash("Probebuch") == JellyfinBookFold.albumHash("Probebuch"))
        #expect(JellyfinBookFold.albumHash("Probebuch") != JellyfinBookFold.albumHash("probebuch"))
        // A file's own id, 32 hex without a dash, is never a folded one.
        #expect(JellyfinBookFold.parseFoldedRawId("5b4525734c0d70fc5b4525734c0d70fc") == nil)
        // Neither is a dashed GUID (its last segment is 12, not 16).
        #expect(JellyfinBookFold.parseFoldedRawId("5b452573-4c0d-70fc-5b45-25734c0d70fc") == nil)
    }

    @Test("the cover of a folded book is the folder's, of a single-file book the file's; nothing else is touched")
    func coverIdOfABook() {
        let folded = JellyfinBookFold.foldedRawId(parentId: book, album: "Probebuch")
        // `<folder>-<hash>` is not a Jellyfin id; the server sees the folder.
        #expect(JellyfinBookFold.serverId(for: folded) == book)
        #expect(JellyfinBookFold.serverId(for: "5b452573") == "5b452573")
        // The provider's cover call goes through the same mapping.
        #expect(JellyfinProvider.imageItemId(forItemId: "jf:book:\(folded)") == book)
        #expect(JellyfinProvider.imageItemId(forItemId: "jf:book:5b452573") == "5b452573")
        #expect(JellyfinProvider.imageItemId(forItemId: "jf:album:a1b2") == "a1b2")
        #expect(JellyfinProvider.imageItemId(forItemId: "sub:album:x") == nil)
    }

    // MARK: - Listening state

    @Test("reading: the furthest element speaks, a played one as its whole length")
    func positionReadsFurthest() {
        let elements = [
            file("a", parent: book, album: "B", index: 1, seconds: 100, played: true),
            file("b", parent: book, album: "B", index: 2, seconds: 100, positionSeconds: 30),
            file("c", parent: book, album: "B", index: 3, seconds: 100),
        ]
        let (tracks, total) = tracks(elements)
        let read = JellyfinBookFold.position(elements: elements, tracks: tracks, total: total)
        #expect(read?.currentTime == 130)
        #expect(read?.isFinished == false)
        let silent = [file("a", parent: book, album: "B"), file("b", parent: book, album: "B")]
        let (t2, tot2) = self.tracks(silent)
        #expect(JellyfinBookFold.position(elements: silent, tracks: t2, total: tot2) == nil)
        let done = [file("a", parent: book, album: "B", played: true), file("b", parent: book, album: "B", played: true)]
        let (t3, tot3) = self.tracks(done)
        let end = JellyfinBookFold.position(elements: done, tracks: t3, total: tot3)
        #expect(end?.currentTime == 200 && end?.isFinished == true)
        let over = [file("a", parent: book, album: "B", seconds: 100, positionSeconds: 500),
                    file("b", parent: book, album: "B")]
        let (t4, tot4) = self.tracks(over)
        #expect(JellyfinBookFold.position(elements: over, tracks: t4, total: tot4)?.currentTime == 100)
    }

    @Test("writing: a book time lands on the running track at its inner position")
    func writePlanLandsOnTrack() {
        let elements = [file("a", parent: book, album: "B", seconds: 100), file("b", parent: book, album: "B", seconds: 100),
                        file("c", parent: book, album: "B", seconds: 100)]
        let (tracks, total) = tracks(elements)
        #expect(JellyfinBookFold.writePlan(currentTime: 130, tracks: tracks, total: total)
                == .init(index: 1, withinTrack: 30))
        #expect(JellyfinBookFold.writePlan(currentTime: 0, tracks: tracks, total: total)
                == .init(index: 0, withinTrack: 0))
        #expect(JellyfinBookFold.writePlan(currentTime: 350, tracks: tracks, total: total).index == 2)
        let plan = JellyfinBookFold.writePlan(currentTime: 230, tracks: tracks, total: total)
        let written = [
            file("a", parent: book, album: "B", seconds: 100, played: true),
            file("b", parent: book, album: "B", seconds: 100, played: true),
            file("c", parent: book, album: "B", seconds: 100, positionSeconds: plan.withinTrack),
        ]
        #expect(JellyfinBookFold.position(elements: written, tracks: tracks, total: total)?.currentTime == 230)
    }
}
#endif
