// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A server song shows the cover its server names for it (`coverArt`),
/// not one asked with its own id, and keeps that address across sessions.
struct SongCoverArtMemoTests {
    @Test("Das Gedaechtnis lernt das Cover-Feld eines Liedes und sagt, was sich aenderte")
    func learnsTheSongsCoverField() {
        var memo = SongCoverArtMemo(server: "https://gonic.example|sim")
        #expect(memo.coverArt(of: "tr-146") == nil)
        #expect(memo.learn(songId: "tr-146", coverArt: "al-40") == .learned(previous: nil))
        #expect(memo.coverArt(of: "tr-146") == "al-40")
        #expect(memo.learn(songId: "tr-146", coverArt: "al-40") == .same, "the same answer again")
        #expect(memo.learn(songId: "tr-146", coverArt: "al-41") == .learned(previous: "al-40"), "the server changed it")
        #expect(memo.learn(songId: "tr-146", coverArt: nil) == .same, "a song without the field keeps what is known")
        #expect(memo.learn(songId: "tr-146", coverArt: "") == .same)
        #expect(memo.coverArt(of: "tr-146") == "al-41")
    }

    @Test("Ueber der Grenze geht das aelteste Lied, ein gehaltenes bleibt")
    func theCapDropsTheOldestButKeepsHeldSongs() {
        var memo = SongCoverArtMemo(server: "s")
        for i in 0..<SongCoverArtMemo.cap {
            _ = memo.learn(songId: "tr-\(i)", coverArt: "al-\(i)")
        }
        _ = memo.learn(songId: "tr-new", coverArt: "al-new", keeps: { $0 == "tr-0" })
        #expect(memo.order.count == SongCoverArtMemo.cap)
        #expect(memo.coverArt(of: "tr-0") == "al-0", "a downloaded song stays")
        #expect(memo.coverArt(of: "tr-1") == nil, "the oldest not held goes")
        #expect(memo.coverArt(of: "tr-new") == "al-new")
    }

    @Test("Das Gedaechtnis ueberdauert die Sitzung und gehoert seinem Server")
    func theMemoryOutlivesTheSessionForItsServer() throws {
        let defaults = try #require(UserDefaults(suiteName: "SongCoverArtMemoTests"))
        defaults.removePersistentDomain(forName: "SongCoverArtMemoTests")
        defer { defaults.removePersistentDomain(forName: "SongCoverArtMemoTests") }
        #expect(SongCoverArtMemo.load(server: "a", defaults: defaults).order.isEmpty, "nothing kept yet")
        var memo = SongCoverArtMemo(server: "a")
        _ = memo.learn(songId: "tr-146", coverArt: "al-40")
        memo.save(defaults: defaults)
        #expect(SongCoverArtMemo.load(server: "a", defaults: defaults).coverArt(of: "tr-146") == "al-40")
        let other = SongCoverArtMemo.load(server: "b", defaults: defaults)
        #expect(other.coverArt(of: "tr-146") == nil, "another server's ids name other songs")
        #expect(other.server == "b")
        defaults.set(Data("kaputt".utf8), forKey: SongCoverArtMemo.storeKey)
        #expect(SongCoverArtMemo.load(server: "a", defaults: defaults).order.isEmpty, "an unreadable memory starts empty")
    }

    @Test("Ein gehaltenes Gedaechtnis in anderer Form liest sich: fehlende Felder leer, die Folge ohne Luecke")
    func aKeptMemoryOfAnotherFormReads() throws {
        func read(_ json: String) throws -> SongCoverArtMemo {
            try JSONDecoder().decode(SongCoverArtMemo.self, from: Data(json.utf8))
        }
        let bare = try read(#"{"server":"a"}"#)
        #expect(bare.server == "a" && bare.order.isEmpty && bare.coverArt(of: "tr-1") == nil)
        let noOrder = try read(#"{"server":"a","coverArt":{"tr-2":"al-2","tr-1":"al-1"}}"#)
        #expect(noOrder.order == ["tr-1", "tr-2"], "songs the order lacks join at its end")
        let messy = try read(#"{"server":"a","order":["tr-1","tr-9","tr-1"],"coverArt":{"tr-1":"al-1"},"later":1}"#)
        #expect(messy.order == ["tr-1"], "each held song once, none without a cover id")
        #expect(messy.coverArt(of: "tr-1") == "al-1")
        var memo = SongCoverArtMemo(server: "a")
        _ = memo.learn(songId: "tr-1", coverArt: "al-1")
        #expect(try JSONDecoder().decode(SongCoverArtMemo.self, from: JSONEncoder().encode(memo)) == memo)
    }

    /// The provider asks the memory for a song's cover, learns from every
    /// answer that carries songs, and moves a downloaded song's kept cover.
    @Test("Der Anbieter fragt fuer ein Lied das Cover-Feld und lernt aus jeder Antwort mit Liedern", .needsTheSources)
    func theProviderAsksTheSongsCoverField() throws {
        let text = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/SubsonicProvider.swift"),
            encoding: .utf8))
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        #expect(flat.contains("let cover = Self.subParts(itemId)?.kind == \"song\" ? (songCoverMemo.coverArt(of: id) ?? id) : id"))
        #expect(flat.contains("return client.mediaURL(\"getCoverArt\", [\"id\": cover, \"size\": \"600\"])"))
        // Album, playlist and song detail; genre and top songs; the shuffle
        // pools; the search. Each answer that hands songs to a surface; and
        // the songs a device list holds that were met nowhere else.
        let learnSites = flat.components(separatedBy: "learnCovers(").count - 2
        #expect(learnSites == 7, "learnCovers call sites: \(learnSites)")
        #expect(flat.contains("for songId in missing where !Task.isCancelled { do { if let song = try await client.song(id: songId) { songs.append(song) } else { silent.append(songId) } } catch { guard SubsonicClient.isServersAnswer(error) else { break } silent.append(songId) } }"),
                "an answer without a song and the server's own failure note it; a cancelled pass or a lost network ends the pass")
        #expect(!flat.contains("try? await client.song("))
        #expect(flat.contains("let missing = UnansweredSongs.toAsk(itemIds.compactMap { Self.id($0, kind: \"song\") }, known: { memo.coverArt(of: $0) != nil }, asking: songCoversAsking, unanswered: songCoversUnanswered, limit: Self.songCoverPassLimit)"),
                "only songs without a named cover, each once, at most one pass's worth")
        #expect(flat.contains("songCoversUnanswered = songCoversUnanswered.belonging(to: server)"),
                "a pass reads the unanswered songs of its own server")
        #expect(flat.contains("if songCoversUnanswered.server == server { songCoversUnanswered.note(silent) }"))
        #expect(flat.contains("songCoverStore = nil songCoversUnanswered = UnansweredSongs(server: \"\")"),
                "a new configuration starts without the unanswered songs")
        #expect(flat.contains("keeps: { !downloads.hasScanned || downloads.downloadedItemIds.contains(Self.itemId(songId: $0)) }"),
                "before the scan of the downloads the trim keeps every song")
        #expect(flat.contains("learnCovers(songs) let (tracks, chapters, total) = Self.tracksAndChapters(from: songs)"))
        #expect(flat.contains("learnCovers(hits.song ?? [])"))
        #expect(flat.contains("Artwork.rename(from: old, to: new) Artwork.invalidate(new) await Artwork.persist(new)"))
        #expect(flat.contains("songCoverStore = nil"), "a new server starts its own memory")
        // The song list: the page shown learns the cover each kept entry names.
        #expect(flat.contains("let page = Array(sorted.dropFirst(offset).prefix(size)) learnCoverArt(Self.pageCoverArt(page)) return page"))
        #expect(flat.contains("played: song.played, playCount: song.playCount, coverArt: song.coverArt)"))
        #expect(flat.contains("playCount: entry.playCount, coverArt: entry.coverArt)"))
        #expect(flat.components(separatedBy: "learnCoverArt(").count - 1 == 3,
                "one definition, the answers with songs and the device list's songs (through learnCovers), the song list page")
    }

    /// A song the server did not answer for is skipped by the next passes
    /// of the same server; another server, or none after signing out,
    /// inherits nothing.
    @Test("Ein Lied ohne Antwort fragt der naechste Durchgang nicht, ein anderer Server erbt es nicht")
    func anUnansweredSongIsNotAskedAgain() {
        var silent = UnansweredSongs(server: "https://a.example|sim")
        silent.note(["tr-2"])
        let ask = { (set: UnansweredSongs) in
            UnansweredSongs.toAsk(["tr-1", "tr-2", "tr-3", "tr-1", "tr-4"], known: { $0 == "tr-3" },
                                  asking: [], unanswered: set, limit: 60)
        }
        #expect(ask(silent) == ["tr-1", "tr-4"], "each once, without the learned and the unanswered")
        #expect(ask(silent.belonging(to: "https://a.example|sim")) == ["tr-1", "tr-4"], "the same server keeps the set")
        let other = silent.belonging(to: "https://b.example|sim")
        #expect(!other.contains("tr-2") && other.server == "https://b.example|sim", "another server starts empty")
        #expect(ask(other) == ["tr-1", "tr-2", "tr-4"])
        #expect(silent.belonging(to: "|").ids.isEmpty, "signed out, no server inherits it")
        #expect(UnansweredSongs.toAsk(["tr-1", "tr-2"], known: { _ in false }, asking: ["tr-1"],
                                      unanswered: UnansweredSongs(server: "s"), limit: 60) == ["tr-2"],
                "a song a running pass asks is not asked twice")
        #expect(UnansweredSongs.toAsk((1...80).map { "tr-\($0)" }, known: { _ in false }, asking: [],
                                      unanswered: UnansweredSongs(server: "s"), limit: 60).count == 60)
        var full = UnansweredSongs(server: "s")
        full.note((0...UnansweredSongs.cap).map { "tr-\($0)" })
        #expect(full.ids.count == UnansweredSongs.cap, "the set stays within its cap")
    }

    /// The set notes what the server answered and nothing else: leaving a
    /// page cancels the pass, and a network that does not carry the question
    /// says nothing about the song.
    @Test("Ohne Antwort heisst: der Server hat geantwortet; Abbruch und Netz merken nichts")
    func onlyTheServersReplyNotesASong() {
        typealias Failure = SubsonicClient.SubsonicError
        let table: [(Error, Bool)] = [
            (Failure.http(404), true),
            (Failure.api(code: 70, message: "not found"), true),
            (Failure.decoding, true),
            (Failure.network, false),
            (Failure.blockedHere, false),
            (Failure.badURL, false),
            (Failure.keySignInNeedsEncryption, false),
            (CancellationError(), false),
            (URLError(.cancelled), false),
            (URLError(.notConnectedToInternet), false),
        ]
        for (error, noted) in table {
            #expect(SubsonicClient.isServersAnswer(error) == noted, "\(error)")
        }
    }

    @Test("Eine gehaltene Liederliste ohne Cover-Feld liest sich weiter, mit Feld traegt sie es")
    func aKeptSongListWithoutTheCoverFieldReads() throws {
        let old = #"{"entries":[{"id":"tr-146","title":"Lied","albumId":"al-40","duration":200,"playCount":3}],"wholeAt":1000,"serverCount":1}"#
        let kept = try JSONDecoder().decode(SongCatalog.self, from: Data(old.utf8))
        #expect(kept.entries.map(\.id) == ["tr-146"])
        #expect(kept.entries.first?.coverArt == nil, "an old list shows without a cover until it is loaded again")
        #expect(kept.entries.first?.playCount == 3)
        var entry = try #require(kept.entries.first)
        entry.coverArt = "al-40"
        let next = SongCatalog(entries: [entry], wholeAt: 2000, serverCount: 1, serverLastScan: nil)
        let read = try JSONDecoder().decode(SongCatalog.self, from: JSONEncoder().encode(next))
        #expect(read == next)
        #expect(read.entries.first?.coverArt == "al-40")
    }

    @Test("Ein Eintrag der Liederliste mit Cover-Feld zeigt dieses Cover, ohne Feld bleibt das Bekannte")
    func aSongListEntryWithTheFieldShowsItsCover() throws {
        let entry = SongCatalog.Entry(id: "tr-146", title: "Lied", artist: nil, album: nil, albumId: "al-40",
                                      duration: nil, created: nil, played: nil, playCount: nil, coverArt: "al-40")
        let bare = SongCatalog.Entry(id: "tr-7", title: "Alt", artist: nil, album: nil, albumId: nil,
                                     duration: nil, created: nil, played: nil, playCount: nil)
        let page = [entry, bare].map(SubsonicProvider.topSong(from:))
        #expect(page.map(\.id) == ["sub:song:tr-146", "sub:song:tr-7"])
        let named = SubsonicProvider.pageCoverArt(page)
        #expect(named.map(\.songId) == ["tr-146", "tr-7"])
        var memo = SongCoverArtMemo(server: "https://gonic.example|sim")
        _ = memo.learn(songId: "tr-7", coverArt: "al-9")
        for song in named { _ = memo.learn(songId: song.songId, coverArt: song.coverArt) }
        #expect(memo.coverArt(of: "tr-146") == "al-40", "the cover the server named, not the song id")
        #expect(memo.coverArt(of: "tr-7") == "al-9", "an entry kept without the field keeps what is known")
        #expect(memo.order == ["tr-7", "tr-146"])
    }
}
#endif
