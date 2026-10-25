// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A music shuffle plays its drawn albums as songs, as the album page
/// does, from one answer per album.
@MainActor
struct CatalogShuffleSongsTests {
    private func item(_ id: String) -> LibraryItem { LibraryItem(id: id, media: nil, addedAt: nil) }
    private func songs(_ album: String, _ count: Int) -> [LibraryItem] {
        (0..<count).map { item(CatalogSongID.make(album: album, index: $0)) }
    }

    @Test("Ein gezogenes Album wird zu seinen Liedern, ein Titel mit einem Lied bleibt ein Lied")
    func anAlbumBecomesItsSongs() async {
        var asked: [String] = []
        let counts = ["lva:a": 3, "lva:one": 1]
        let built: CatalogShuffleSongs.AlbumSongs = { album in
            asked.append(album)
            return self.songs(album, counts[album] ?? 0)
        }
        let album = await CatalogShuffleSongs.songs(of: item("lva:a"), albumSongs: built)
        #expect(album.map(\.id) == ["lva:a#0", "lva:a#1", "lva:a#2"])
        #expect(asked == ["lva:a"], "one question for the album, none per song")
        let single = await CatalogShuffleSongs.songs(of: item("lva:one"), albumSongs: built)
        #expect(single.map(\.id) == ["lva:one"], "a title of one track stays the title")
        let unanswered = await CatalogShuffleSongs.songs(of: item("lva:gone"), albumSongs: built)
        #expect(unanswered.map(\.id) == ["lva:gone"], "without an answer the title stays itself")
    }

    @Test("Der Wurf startet die Lieder des ersten Albums, die uebrigen werden an ihrem Platz zu Liedern")
    func theDrawStartsSongsAndExpandsTheRest() async {
        let context = PlaybackContext()
        var played: [String] = []
        var asked: [String] = []
        let counts = ["lva:a": 3, "lva:b": 1, "lva:c": 2]
        await CatalogShuffleSongs.start([item("lva:a"), item("lva:b"), item("lva:c")], context: context,
                                        play: { items in
                                            played = items.map(\.id)
                                            context.replace(ids: items.dropFirst().map(\.id), source: "Netlabels")
                                        },
                                        songs: { title in
                                            asked.append(title.id)
                                            let n = counts[title.id] ?? 1
                                            return n > 1 ? self.songs(title.id, n) : [title]
                                        })
        #expect(played == ["lva:a#0", "lva:a#1", "lva:a#2", "lva:b", "lva:c"], "the first album plays song by song")
        #expect(context.ids == ["lva:a#1", "lva:a#2", "lva:b", "lva:c#0", "lva:c#1"],
                "Up Next and the skips step song by song, as from the album page")
        #expect(asked == ["lva:a", "lva:b", "lva:c"], "one question per drawn title")
        #expect(context.sourceTitle == "Netlabels")
    }

    @Test("Ein neuer Start mitten im Wurf: die uebrigen Titel werden nicht mehr gefragt")
    func aNewStartEndsTheExpansion() async {
        let context = PlaybackContext()
        var asked: [String] = []
        await CatalogShuffleSongs.start([item("lva:a"), item("lva:b"), item("lva:c")], context: context,
                                        play: { items in context.replace(ids: items.dropFirst().map(\.id), source: "x") },
                                        songs: { title in
                                            asked.append(title.id)
                                            if title.id == "lva:b" { context.replace(ids: ["abs-book"], source: "Book") }
                                            return self.songs(title.id, 2)
                                        })
        #expect(context.ids == ["abs-book"], "the new start keeps its context")
        #expect(asked == ["lva:a", "lva:b"], "the title that left is not asked")
    }

    @Test("Ein Eintrag des Kontexts wird an seinem Platz zu seinen Teilen")
    func contextExpandsAnEntryInPlace() {
        let context = PlaybackContext()
        context.replace(ids: ["lva:x", "lva:b", "lva:y"], source: "s")
        #expect(context.expand("lva:b", into: ["lva:b#0", "lva:b#1"]))
        #expect(context.ids == ["lva:x", "lva:b#0", "lva:b#1", "lva:y"])
        #expect(!context.expand("lva:gone", into: ["lva:gone#0"]), "an entry that left stays gone")
        #expect(context.expand("lva:x", into: []), "no parts: the entry stays itself")
        #expect(context.ids == ["lva:x", "lva:b#0", "lva:b#1", "lva:y"])
    }

    @Test("Der Zufall auf Musikbereichen startet die Lieder, Jamendo bleibt beim Titel", .needsTheSources)
    func theAreaShuffleStartsSongs() throws {
        let text = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/CatalogShuffle.swift"),
                              encoding: .utf8)
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        #expect(flat.contains("await start(items, coordinator: coordinator, sourceTitle: area.title, asSongs: true)"))
        #expect(flat.contains("await CatalogShuffleSongs.start(items) { await coordinator.playInOrder(items: $0, contextSource: sourceTitle) }"))
        #expect(flat.contains("await start(items, coordinator: coordinator, sourceTitle: String(localized: \"Music (Jamendo)\"))"),
                "a Jamendo track is a song already")
        let songs = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/CatalogShuffleSongs.swift"),
                               encoding: .utf8)
        #expect(songs.contains("await ArchiveMusicLoader.albumSongs(albumId: $0, router: .live)"),
                "the songs come the one way of a catalogue album's songs")
    }
}
#endif
