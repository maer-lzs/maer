// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Combine
@testable import Maer

/// The union of two music servers against two stand-in providers: every
/// offset answers its slice of the merged sequence whatever the order of the
/// questions, ids go to their server, a failing source is named and does not
/// empty a list, and the whole-list questions merge without merging names.
@MainActor
struct MusicUnionTests {

    /// A stand-in music server: named albums in its own order, a namespace,
    /// and a switch that makes every list question fail.
    final class Stand: MusicProvider {
        nonisolated let prefix: String
        var albums: [LibraryItem]
        var fails = false
        /// How often a page suspends before it answers. Without it two
        /// questions could never interleave, and a list without its queue
        /// would pass the concurrency witness for the wrong reason.
        var yields = 0
        private(set) var asked: [String] = []
        let librarySynced = PassthroughSubject<Void, Never>()

        init(prefix: String, titles: [String], added: [Double?]? = nil) {
            self.prefix = prefix
            albums = titles.enumerated().map { index, title in
                Stand.item("\(prefix)album:\(title)", title, added: added?[index])
            }
        }

        static func item(_ id: String, _ title: String, added: Double? = nil) -> LibraryItem {
            LibraryItem(id: id, media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: title, authorName: nil, narratorName: nil, seriesName: nil,
                                              genres: nil, publishedYear: nil, description: nil),
                duration: nil, chapters: nil, tracks: nil), addedAt: added)
        }

        struct Down: Error {}
        private func list(_ what: String) throws {
            asked.append(what)
            if fails { throw Down() }
        }

        func reconnectIfNeeded() {}
        func albumShelf(shelf: MusicShelf, size: Int) async throws -> [LibraryItem] {
            try list("shelf"); return Array(albums.prefix(size))
        }
        func albumPage(sort: MusicSortOption, offset: Int, size: Int) async throws -> [LibraryItem] {
            try list("page@\(offset)")
            for _ in 0..<yields { await Task.yield() }
            return Array(albums.dropFirst(offset).prefix(size))
        }
        func albumInfo(itemId: String) async -> MusicAlbumInfo? { asked.append("info \(itemId)"); return nil }
        func album(ofSong songItemId: String) async throws -> LibraryItem? { asked.append("album \(songItemId)"); return nil }
        func allArtists() async throws -> [MusicArtist] {
            try list("artists")
            return [MusicArtist(id: "1", itemId: "\(prefix)artist:1", name: "Cure", albumCount: 1)]
        }
        func artistAlbums(artistId: String) async throws -> [LibraryItem] { [] }
        func artist(forId id: String) -> MusicArtist? { nil }
        func cacheSearchedArtist(_ artist: MusicArtist) { asked.append("cache \(artist.itemId)") }
        func artistInfo(artistId: String) async -> MusicArtistInfo? { nil }
        func topSongs(artistId: String, count: Int) async -> [MusicTopSong] { [] }
        /// Songs in whatever order they were given; a page hands them out
        /// sorted, the way both real servers do for the song list.
        var songs: [MusicTopSong] = []
        func songPage(offset: Int, size: Int, sort: MusicSortOption) async throws -> [MusicTopSong] {
            try list("songs")
            return Array(SongOrder.sorted(songs, by: sort).dropFirst(offset).prefix(size))
        }
        var genreList = [MusicGenre(name: "Jazz")]
        func genres() async throws -> [MusicGenre] { try list("genres"); return genreList }
        func genreAlbums(genre: String, offset: Int, size: Int) async throws -> [LibraryItem] {
            asked.append("genreAlbums \(genre)"); return []
        }
        func genreSongs(genre: String, offset: Int, size: Int) async throws -> [MusicTopSong] { [] }
        func trackPlayCounts(forItemId itemId: String) -> [Int?] { [] }
        func allPlaylists() async throws -> [MusicPlaylist] { try list("playlists"); return [] }
        func createPlaylist(name: String) async throws -> String? { asked.append("create"); return nil }
        func addSongs(_ songIds: [String], toPlaylistItemId playlistItemId: String) async throws {
            asked.append("add \(playlistItemId)")
        }
        func renamePlaylist(itemId: String, newName: String) async throws {}
        func removeSongs(at indices: [Int], fromPlaylistItemId playlistItemId: String) async throws {}
        func deletePlaylist(itemId: String) async throws { asked.append("delete \(itemId)") }
        func songIds(forItemId itemId: String) async -> [String] { asked.append("songIds \(itemId)"); return [] }
        func songId(forItemId itemId: String, trackIndex: Int) async -> String? { nil }
        func playlistMosaicCoverIDs(forItemId itemId: String) async -> [String] { [] }
        func playlistArtistNames(forItemId itemId: String) async -> [String] { [] }
        func coverURL(coverArtId: String, size: Int) -> URL? { nil }
        func songItems(forItemId itemId: String) async -> [LibraryItem] { [] }
        func shuffleLibrarySongItems(limit: Int) async -> [LibraryItem] { Array(albums.prefix(limit)) }
        func lyrics(songId: String) async -> SongLyrics? { nil }
        func isStarred(itemId: String) async -> Bool { false }
        /// A server that does not take the favorite throws this.
        var starError: Error?
        func setStar(itemId: String, starred: Bool) async throws {
            asked.append("star \(itemId) \(starred)")
            if let starError { throw starError }
        }
        func libraryItem(forId itemId: String) -> LibraryItem? { albums.first { $0.id == itemId } }
        var cachedAlbumItems: [LibraryItem] { albums }
        nonisolated func owns(itemId: String) -> Bool { itemId.hasPrefix(prefix) }
        nonisolated func kind(of itemId: String) -> MusicItemKind? { owns(itemId: itemId) ? .album : nil }
        nonisolated func itemId(playlistId: String) -> String { "\(prefix)playlist:\(playlistId)" }
        nonisolated func itemId(songId: String) -> String { "\(prefix)song:\(songId)" }
        nonisolated func itemId(artistId: String) -> String { "\(prefix)artist:\(artistId)" }
        nonisolated func artistId(fromItemId itemId: String) -> String? { nil }

        var providerId: String { prefix }
        var keepsMarksOnDevice: Bool { false }
        var capabilities: ProviderCapabilities { [.passwordLogin, .remoteSearch, .downloadable] }
        var isAvailable: Bool { true }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail { throw Down() }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { nil }
        var streamAuthHeaders: [String: String] { [:] }
        /// The answer per title: nil plays a sign-in that cannot be read now.
        var itemHeaders: [String: String]? = [:]
        func streamAuthHeaders(forItemId itemId: String) -> [String: String]? { itemHeaders }
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
        func fetchAllProgress() async throws -> [String: BookProgress] { try list("progress"); return [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
            asked.append("progress \(itemId)")
        }
    }

    static func pair() -> (MusicUnion, Stand, Stand) {
        let sub = Stand(prefix: "sub:", titles: ["Abba", "Cure", "Eno", "Genesis", "Isis", "Kraan", "Muse"])
        let jf = Stand(prefix: "jf:", titles: ["Björk", "Cure", "Dylan", "Fugazi"])
        return (MusicUnion(sources: [sub, jf]), sub, jf)
    }

    static func titles(_ items: [LibraryItem]) -> [String] { items.map { $0.media?.metadata?.title ?? "?" } }

    /// The merged sequence as paging from the front gives it, page by page.
    static func fromTheFront(size: Int) async throws -> [String] {
        let (union, _, _) = pair()
        var all: [String] = []
        var offset = 0
        while true {
            let page = try await union.albumPage(sort: .nameAZ, offset: offset, size: size)
            all += titles(page)
            if page.count < size { break }
            offset += size
        }
        return all
    }

    // MARK: Paging, whatever the order of the questions

    @Test("von vorn geblaettert: beide Quellen in einer Namensordnung, Dubletten bleiben")
    func fromTheFrontIsTheMergedSequence() async throws {
        let all = try await Self.fromTheFront(size: 3)
        #expect(all == ["Abba", "Björk", "Cure", "Cure", "Dylan", "Eno", "Fugazi", "Genesis", "Isis", "Kraan", "Muse"])
    }

    /// A favorite goes to the album's own server, and a server that does
    /// not take it throws through the union: the album page then turns the
    /// heart back and says so, instead of showing a state the server never had.
    @Test("ein Favorit geht an den Server des Albums, und ein Scheitern kommt beim Rufer an")
    func aFavoriteThatFailsReachesTheCaller() async {
        let (union, sub, jf) = Self.pair()
        await #expect(throws: Never.self) { try await union.setStar(itemId: "jf:album:Dylan", starred: true) }
        #expect(jf.asked.contains("star jf:album:Dylan true"))
        #expect(!sub.asked.contains { $0.hasPrefix("star") }, "the other server was asked")
        sub.starError = Stand.Down()
        await #expect(throws: Stand.Down.self) { try await union.setStar(itemId: "sub:album:Cure", starred: true) }
    }

    @Test("Seite 3 zuerst gefragt ist dieselbe Seite wie beim Blaettern von vorn")
    func aLaterPageFirst() async throws {
        let reference = try await Self.fromTheFront(size: 3)
        let (union, _, _) = Self.pair()
        let third = try await union.albumPage(sort: .nameAZ, offset: 6, size: 3)
        #expect(Self.titles(third) == Array(reference[6..<9]))
        let first = try await union.albumPage(sort: .nameAZ, offset: 0, size: 3)
        #expect(Self.titles(first) == Array(reference[0..<3]))
    }

    @Test("zweimal dieselbe Seite: gleiche Eintraege, und die Quellen werden nicht erneut gefragt")
    func theSamePageTwice() async throws {
        let (union, sub, jf) = Self.pair()
        _ = try await union.albumPage(sort: .nameAZ, offset: 0, size: 3)
        let once = try await union.albumPage(sort: .nameAZ, offset: 3, size: 3)
        let askedBefore = sub.asked.count + jf.asked.count
        let twice = try await union.albumPage(sort: .nameAZ, offset: 3, size: 3)
        #expect(Self.titles(once) == Self.titles(twice))
        #expect(sub.asked.count + jf.asked.count == askedBefore)
    }

    @Test("zwei Anfragen gleichzeitig werden hintereinander bedient und stimmen mit der Folge von vorn")
    func twoQuestionsAtOnce() async throws {
        let reference = try await Self.fromTheFront(size: 3)
        let (union, sub, jf) = Self.pair()
        sub.yields = 5
        jf.yields = 5
        // Offset 0 is a restart by design, and the start order of `async let`
        // is not fixed: a page 0 queued behind page 3 would reload from the
        // front. So page 0 comes first, and the concurrent questions are the
        // later pages, whose claim holds in any order.
        let pa = try await union.albumPage(sort: .nameAZ, offset: 0, size: 3)
        async let b = union.albumPage(sort: .nameAZ, offset: 3, size: 3)
        async let c = union.albumPage(sort: .nameAZ, offset: 6, size: 3)
        async let d = union.albumPage(sort: .nameAZ, offset: 9, size: 3)
        let (pb, pc, pd) = try await (b, c, d)
        #expect(Self.titles(pa) == Array(reference[0..<3]))
        #expect(Self.titles(pb) == Array(reference[3..<6]))
        #expect(Self.titles(pc) == Array(reference[6..<9]))
        #expect(Self.titles(pd) == Array(reference[9...]))
        #expect(sub.asked == ["page@0", "page@3", "page@6"], "jede Seite einmal, in jeder Reihenfolge der Fragen")
        #expect(jf.asked == ["page@0", "page@3"])
    }

    @Test("Versatz 0 beginnt neu und sieht, was sich auf dem Server geaendert hat")
    func offsetZeroStartsOver() async throws {
        let (union, sub, _) = Self.pair()
        _ = try await union.albumPage(sort: .nameAZ, offset: 0, size: 3)
        sub.albums.insert(MusicUnionTests.Stand.item("sub:album:Aaa", "Aaa"), at: 0)
        let cached = try await union.albumPage(sort: .nameAZ, offset: 0, size: 3)
        #expect(Self.titles(cached).first == "Aaa", "ein Neuladen ist ein Neuladen")
    }

    @Test("jede Quelle wird an ihrem eigenen Versatz gefragt")
    func eachSourceAtItsOwnOffset() async throws {
        let (union, sub, jf) = Self.pair()
        var offset = 0
        while try await union.albumPage(sort: .nameAZ, offset: offset, size: 3).count == 3 { offset += 3 }
        #expect(sub.asked == ["page@0", "page@3", "page@6"])
        #expect(jf.asked == ["page@0", "page@3"])
    }

    @Test("Rang um Rang fuer Zuletzt gespielt, ueber Seiten hinweg")
    func rankByRankAcrossPages() async throws {
        let (union, _, _) = Self.pair()
        let first = try await union.albumPage(sort: .zuletztGespielt, offset: 0, size: 4)
        let second = try await union.albumPage(sort: .zuletztGespielt, offset: 4, size: 4)
        #expect(Self.titles(first + second) == ["Abba", "Björk", "Cure", "Cure", "Eno", "Dylan", "Genesis", "Fugazi"])
    }

    // MARK: A failing source

    @Test("faellt eine Quelle aus, bleibt die Liste der anderen, und der Ausfall ist benannt")
    func aFailingSourceIsNamed() async throws {
        let (union, _, jf) = Self.pair()
        jf.fails = true
        let page = try await union.albumPage(sort: .nameAZ, offset: 0, size: 20)
        #expect(Self.titles(page) == ["Abba", "Cure", "Eno", "Genesis", "Isis", "Kraan", "Muse"])
        #expect(union.failedSources == ["jf:"])
        let artists = try await union.allArtists()
        #expect(artists.map(\.itemId) == ["sub:artist:1"])
        #expect(union.failedSources == ["jf:"])
        jf.fails = false
        _ = try await union.allArtists()
        #expect(union.failedSources.isEmpty, "wieder da, nicht mehr benannt")
    }

    @Test("scheitern beide, wirft die Liste wie eine einzelne Quelle")
    func bothFailingThrows() async {
        let (union, sub, jf) = Self.pair()
        sub.fails = true
        jf.fails = true
        await #expect(throws: (any Error).self) { try await union.albumPage(sort: .nameAZ, offset: 0, size: 5) }
        await #expect(throws: (any Error).self) { try await union.allArtists() }
    }

    // MARK: Genres

    @Test("die Genre-Seite fragt jeden Server in seiner Schreibung und einen ohne das Genre gar nicht")
    func genrePageAsksEachInItsOwnWords() async throws {
        let (union, sub, jf) = Self.pair()
        sub.genreList = [MusicGenre(name: "Jazz"), MusicGenre(name: "Rock")]
        jf.genreList = [MusicGenre(name: "jazz ")]
        let genres = try await union.genres()
        #expect(genres.map(\.name) == ["Jazz", "Rock"])
        _ = try await union.genreAlbums(genre: "Jazz", offset: 0, size: 5)
        _ = try await union.genreAlbums(genre: "Rock", offset: 0, size: 5)
        #expect(sub.asked.filter { $0.hasPrefix("genreAlbums") } == ["genreAlbums Jazz", "genreAlbums Rock"])
        #expect(jf.asked.filter { $0.hasPrefix("genreAlbums") } == ["genreAlbums jazz "],
                "Jellyfin in seiner Schreibung, und nach Rock nicht gefragt")
    }

    @Test("faellt eine Genre-Liste aus, wird dieser Server auf der Genre-Seite trotzdem gefragt")
    func aFailedGenreListLacksNothing() async throws {
        let (union, sub, jf) = Self.pair()
        sub.genreList = [MusicGenre(name: "Rock")]
        jf.fails = true
        #expect(try await union.genres().map(\.name) == ["Rock"])
        jf.fails = false
        _ = try await union.genreAlbums(genre: "Rock", offset: 0, size: 5)
        #expect(jf.asked.contains("genreAlbums Rock"), "ein Ausfall heisst nicht, dass das Genre fehlt")
    }

    @Test("der Verbund legt keine Playlist an: er ist zwei Server, das Anlegen nennt einen")
    func theUnionCreatesNowhere() async throws {
        let (union, sub, jf) = Self.pair()
        #expect(try await union.createPlaylist(name: "Neu") == nil)
        #expect(!sub.asked.contains("create") && !jf.asked.contains("create"), "nicht mehr fest an die erste Quelle")
    }

    // MARK: Whole lists and ids

    @Test("ganze Listen: Kuenstler beider Server, gleiche Namen zweimal; Regal Neu auf einer Uhr")
    func wholeLists() async throws {
        let (union, _, _) = Self.pair()
        let artists = try await union.allArtists()
        #expect(artists.map(\.itemId) == ["sub:artist:1", "jf:artist:1"], "zwei Cure, nicht zusammengefuehrt")
        let genres = try await union.genres()
        #expect(genres.map(\.name) == ["Jazz"], "ein Genre, das beide kennen, erscheint einmal")
        let sub = Stand(prefix: "sub:", titles: ["A", "B"], added: [10, 30])
        let jf = Stand(prefix: "jf:", titles: ["C"], added: [20])
        let newest = try await MusicUnion(sources: [sub, jf]).albumShelf(shelf: .newest, size: 10)
        #expect(Self.titles(newest) == ["B", "C", "A"])
    }

    @Test("Fragen mit Kennung gehen an den Server der Kennung")
    func idsGoToTheirServer() async throws {
        let (union, sub, jf) = Self.pair()
        _ = await union.songIds(forItemId: "jf:album:Cure")
        try await union.deletePlaylist(itemId: "sub:playlist:7")
        try await union.addSongs(["x"], toPlaylistItemId: "jf:playlist:2")
        try await union.updateProgress(itemId: "jf:album:Cure", currentTime: 1, duration: 2, isFinished: false)
        union.cacheSearchedArtist(MusicArtist(id: "4", itemId: "jf:artist:4", name: "B", albumCount: nil))
        _ = try await union.album(ofSong: "sub:song:9")
        #expect(jf.asked == ["songIds jf:album:Cure", "add jf:playlist:2", "progress jf:album:Cure", "cache jf:artist:4"])
        #expect(sub.asked == ["delete sub:playlist:7", "album sub:song:9"])
        #expect(union.kind(of: "jf:album:1") == .album && union.owns(itemId: "sub:x") && !union.owns(itemId: "abs:x"))
    }

    @Test("Zufall aus beiden, und die kleine Bibliothek laesst keine halbe Liste")
    func shuffleFromBoth() async {
        let (union, _, _) = Self.pair()
        let pool = await union.shuffleLibrarySongItems(limit: 10)
        #expect(pool.count == 10)
        #expect(pool.filter { $0.id.hasPrefix("jf:") }.count == 4)
    }

    @Test("das Signal einer Quelle erreicht den Verbund")
    func theSignalRelays() {
        let (union, _, jf) = Self.pair()
        var heard = 0
        let listening = union.librarySynced.sink { heard += 1 }
        jf.librarySynced.send()
        #expect(heard == 1)
        listening.cancel()
    }

    // MARK: The sentence when one server does not answer

    @Test("der Satz nennt, wer nicht antwortet und wessen Haelfte zu sehen ist; sonst keiner")
    func theFailureSentence() {
        let one = MusicSourceFailure.sentence(failed: ["jf"], all: ["sub", "jf"])
        #expect(one == String(localized: "\("Jellyfin") is not answering right now; showing only what \("Subsonic") has."))
        #expect(MusicSourceFailure.sentence(failed: [], all: ["sub", "jf"]) == nil, "alle haben geantwortet")
        #expect(MusicSourceFailure.sentence(failed: ["sub", "jf"], all: ["sub", "jf"]) == nil,
                "keiner hat geantwortet: dafuer hat die Seite ihren Fehlerzustand")
        #expect(MusicSourceFailure.sentence(failed: [], all: ["sub"]) == nil, "eine Quelle hat keinen Satz")
    }

    @Test("der Verbund liefert Ausfall und Quellen fuer den Satz")
    func theUnionFeedsTheSentence() async throws {
        let (union, _, jf) = Self.pair()
        jf.fails = true
        _ = try await union.allPlaylists()
        #expect(MusicSourceFailure.sentence(failed: union.failedSources, all: union.sourceIds) != nil)
        #expect(union.sourceIds == ["sub:", "jf:"])
        #expect(Stand(prefix: "x:", titles: []).sourceIds == ["x:"], "ein einzelner Anbieter nennt sich selbst")
    }

    @Test("der Musik-Reiter zeigt den Satz, und die geladene Haelfte bleibt")
    func theTabShowsTheSentence() async {
        let album = Stand.item("sub:album:A", "A")
        let vm = MusicViewModel(source: MusicSource(
            albumsPage: { _, offset, _ in offset == 0 ? [album] : [] },
            shelf: { _, _ in [] },
            artists: { [] },
            playlists: { [] },
            failureSentence: { "Jellyfin fehlt" }))
        await vm.reload()
        #expect(vm.albums.count == 1)
        #expect(vm.errorText == "Jellyfin fehlt")
        let quiet = MusicViewModel(source: MusicSource(
            albumsPage: { _, offset, _ in offset == 0 ? [album] : [] },
            shelf: { _, _ in [] }, artists: { [] }, playlists: { [] }))
        await quiet.reload()
        #expect(quiet.errorText == nil, "ohne Ausfall kein Satz")
    }

    @Test("Start fragt die Art eines Musik-Schluessels an dessen Server", .needsTheSources)
    func homeAsksTheKindAtTheKeysServer() throws {
        let text = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/HomeView.swift"),
                              encoding: .utf8)
        let lines = Self.code(text).split(separator: "\n").filter { $0.contains(".kind(of:") }
        #expect(lines.contains { $0.contains("let kind = AppSession.shared.musicProvider(for: key).kind(of: key)") },
                "der Zaun findet die Stelle, die die angefangene Musik sortiert: \(lines)")
        #expect(lines.allSatisfy { $0.contains("musicProvider(for:") }, "eine Stelle fragt das Geraet: \(lines)")
        // And there is one such place, not more: a second asking line would
        // pass the two checks above without being counted.
        #expect(lines.count == 1, "the kind is asked in \(lines.count) places")
    }

    @Test("Portraets liegen unter der Kennung mit Quelle, nie unter der rohen Nummer", .needsTheSources)
    func portraitsAreKeyedByTheCarriedId() throws {
        var calls: [String] = []
        let root = SourceTree.root.appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let code = Self.code(try String(contentsOf: url, encoding: .utf8))
            // A CALL has a receiver; the declaration `func portraitURL(` has none.
            for match in code.matches(of: try Regex(#"\.portraitURL\(\s*artistKey:\s*([^,]+),"#)) {
                calls.append(String(match.output[1].substring ?? ""))
            }
        }
        #expect(!calls.isEmpty, "der Zaun hat den Rufer gefunden")
        #expect(calls.allSatisfy { $0.hasSuffix(".itemId") }, "ein Portraet unter anderer Kennung: \(calls)")
    }

    // MARK: The fence: no raw-number question to the device question

    /// Questions that carry only a server's raw number. The union cannot
    /// route them, so they must reach a provider through the door per item.
    nonisolated static let rawQuestions = ["artistAlbums", "artistInfo", "topSongs", "artist(forId",
                                           "coverURL(coverArtId", "itemId(playlistId", "itemId(songId",
                                           "itemId(artistId", "streamURL(forContentPath", "lyrics(songId",
                                           "fetchLibraryItems(libraryId", "fetchLibraryItemsPage"]

    /// Code without comments and string contents, whitespace around dots closed.
    nonisolated static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let noComment = line.components(separatedBy: "//").first ?? ""
            return noComment.replacingOccurrences(of: #""[^"]*""#, with: "\"\"", options: .regularExpression)
        }.joined(separator: "\n")
            .replacingOccurrences(of: #"\s*\.\s*"#, with: ".", options: .regularExpression)
    }

    /// Raw-number questions asked of `.musicProvider` (the device question,
    /// not the door `musicProvider(for:)`), directly or through a binding.
    nonisolated static func rawToDevice(in text: String) -> Int {
        let code = Self.code(text)
        let device = #"\.musicProvider(?![A-Za-z0-9_(])"#
        var receivers = [device]
        let binding = try! Regex(#"let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*[A-Za-z0-9_.]*"# + device)
        for match in code.matches(of: binding) {
            if let name = match.output[1].substring { receivers.append(#"(?:^|[^A-Za-z0-9_.])"# + name) }
        }
        let questions = rawQuestions.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        var count = 0
        for receiver in receivers {
            let pattern = try! Regex(receiver + #"\.(?:"# + questions + #")(?![A-Za-z0-9_])"#)
            count += code.matches(of: pattern).count
        }
        return count
    }

    @Test("keine Frage mit roher Nummer an die Geraete-Frage, in ganz Sources", .needsTheSources)
    func noRawQuestionToTheDevice() throws {
        let root = SourceTree.root.appendingPathComponent("Sources")
        var read = 0
        var found: [String] = []
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            read += 1
            let count = Self.rawToDevice(in: try String(contentsOf: url, encoding: .utf8))
            if count > 0 { found.append("\(url.lastPathComponent): \(count)") }
        }
        #expect(read > 100, "der Zaun hat die Quellen gelesen")
        #expect(found.isEmpty, "Frage mit roher Nummer an die Geraete-Frage: \(found)")
        #expect(Self.rawToDevice(in: "_ = await AppSession.shared.musicProvider.artistInfo(artistId: a.id)") == 1)
        #expect(Self.rawToDevice(in: "let music = AppSession.shared.musicProvider\nlet u = music.coverURL(coverArtId: c)") == 1,
                "ueber eine Bindung")
        #expect(Self.rawToDevice(in: "_ = AppSession.shared\n  .musicProvider\n  .lyrics(songId: s)") == 1, "ueber einen Umbruch")
        #expect(Self.rawToDevice(in: "_ = await AppSession.shared.musicProvider(for: id).artistInfo(artistId: a.id)") == 0,
                "die Tuer je Eintrag zaehlt nicht")
        #expect(Self.rawToDevice(in: "// musicProvider.artistInfo(artistId: x)\n_ = \"musicProvider.topSongs(\"") == 0,
                "Kommentar und Text zaehlen nicht")
        #expect(Self.rawToDevice(in: "_ = try await AppSession.shared.musicProvider.allArtists()") == 0,
                "eine Listen-Frage ist keine rohe")
    }

    @Test("mit beiden Quellen ist die Antwort der Verbund")
    func bothIsTheUnion() {
        let first = AppSession.shared.musicProvider(serving: .both)
        #expect(first is MusicUnion)
        #expect(first === AppSession.shared.musicProvider(serving: .both), "ein Verbund, sein Blaetter-Zustand bleibt")
        #expect((first as? MusicUnion)?.sources.map(\.providerId) == ["sub", "jf"])
    }
}
#endif
