// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// One derivation for lock-screen NowPlaying and CarPlay.
/// Title is always the work (tested at the call sites); the chapter shows in the
/// subtitle only when it's a REAL chapter. Never a fallback marker.
struct NowPlayingPresentationTests {
    @Test("Mini-Player: bei einem Song fuehrt der Kuenstler die zweite Zeile, nie der Titel noch einmal")
    func miniLeadForASongIsTheArtist() {
        #expect(NowPlayingPresentation.miniLead(isMusic: true, chapterTitle: "Diavolo rosso",
                                                artist: "Paolo Conte") == "Paolo Conte")
        #expect(NowPlayingPresentation.miniLead(isMusic: true, chapterTitle: "Diavolo rosso",
                                                artist: nil) == nil, "without an artist the time stands alone")
        #expect(NowPlayingPresentation.miniLead(isMusic: false, chapterTitle: "Chapter 2",
                                                artist: "Andrea Wulf") == "Chapter 2", "a book keeps its chapter")
    }

    @Test("real chapter + author form the subtitle")
    func realChapter() {
        #expect(NowPlayingPresentation.subtitle(chapterTitle: "Chapter 2", author: "Andrea Wulf",
                                                isFallback: false) == "Chapter 2 · Andrea Wulf")
    }

    @Test("a fallback marker never appears; the author alone remains")
    func fallbackExcluded() {
        #expect(NowPlayingPresentation.subtitle(chapterTitle: "Part 3 of 12", author: "Andrea Wulf",
                                                isFallback: true) == "Andrea Wulf")
    }

    @Test("chapter only when there is no author")
    func chapterOnly() {
        #expect(NowPlayingPresentation.subtitle(chapterTitle: "Chapter 1", author: nil,
                                                isFallback: false) == "Chapter 1")
    }

    @Test("nothing to show → nil (also empty/whitespace)")
    func empty() {
        #expect(NowPlayingPresentation.subtitle(chapterTitle: nil, author: nil, isFallback: false) == nil)
        #expect(NowPlayingPresentation.subtitle(chapterTitle: "", author: "  ", isFallback: false) == nil)
    }

    // MARK: - The large title is always the work, never empty

    @Test("book: the work title is the book, not the chapter")
    func bookTitle() {
        #expect(NowPlayingPresentation.title(isMusic: false, songTitle: nil,
                                             workTitle: "Die Letzte Flotte", fallback: "Audiobook")
                == "Die Letzte Flotte")
    }

    @Test("episode: the work title is the episode title")
    func episodeTitle() {
        #expect(NowPlayingPresentation.title(isMusic: false, songTitle: nil,
                                             workTitle: "Folge 42", fallback: "Audiobook")
                == "Folge 42")
    }

    @Test("song: the work title is the SONG, not the album")
    func songTitle() {
        // Music: the song is the work; the album is passed as workTitle and must
        // NOT win.
        #expect(NowPlayingPresentation.title(isMusic: true, songTitle: "Bohemian Rhapsody",
                                             workTitle: "A Night at the Opera", fallback: "Audiobook")
                == "Bohemian Rhapsody")
    }

    @Test("fallback-chapter book: the title is STILL the work, never the cleaned chapter or empty")
    func fallbackChapterBookKeepsWorkTitle() {
        // The regression: with cleaned chapters ("Teil 12"), the work
        // title must come from the work itself, not the chapter. And never blank.
        let title = NowPlayingPresentation.title(isMusic: false, songTitle: nil,
                                                 workTitle: "Armageddon", fallback: "Audiobook")
        #expect(title == "Armageddon")
        #expect(!title.isEmpty)
    }

    @Test("title never blank — missing/whitespace work title falls back to the generic label")
    func titleNeverEmpty() {
        #expect(NowPlayingPresentation.title(isMusic: false, songTitle: nil,
                                             workTitle: nil, fallback: "Audiobook") == "Audiobook")
        #expect(NowPlayingPresentation.title(isMusic: false, songTitle: nil,
                                             workTitle: "   ", fallback: "Audiobook") == "Audiobook")
        // Music with a blank song title falls back to the album, then the label.
        #expect(NowPlayingPresentation.title(isMusic: true, songTitle: "  ",
                                             workTitle: "The Album", fallback: "Audiobook") == "The Album")
    }

    // MARK: - The playing song of a music entry of several songs

    @Test("Lied in einer Playlist: Kuenstler und Cover des Liedes, die Playlist hat keine")
    func songInAPlaylistCarriesItsOwnArtistAndCover() {
        let song = NowPlayingPresentation.song(inPlaylist: true, songArtist: "Nicolas Falcon",
                                               songCoverArt: "al-51", entryArtist: nil)
        #expect(song == .init(artist: "Nicolas Falcon", coverArt: "al-51"))
        let bare = NowPlayingPresentation.song(inPlaylist: true, songArtist: " ", songCoverArt: "",
                                               entryArtist: nil)
        #expect(bare == .init(artist: nil, coverArt: nil), "without facts the entry's cover stays, no artist")
    }

    @Test("Lied in einem Album: Kuenstler des Liedes, sonst des Albums; das Cover bleibt das des Albums")
    func songInAnAlbum() {
        #expect(NowPlayingPresentation.song(inPlaylist: false, songArtist: "Gast", songCoverArt: "mf-1",
                                            entryArtist: "Band") == .init(artist: "Gast", coverArt: nil))
        #expect(NowPlayingPresentation.song(inPlaylist: false, songArtist: nil, songCoverArt: "mf-1",
                                            entryArtist: "Band") == .init(artist: "Band", coverArt: nil))
        #expect(NowPlayingPresentation.song(inPlaylist: false, songArtist: "Zero V", songCoverArt: "al-2",
                                            entryArtist: "Zero V") == .init(artist: "Zero V", coverArt: nil),
                "a single song keeps its entry's cover")
    }

    @Test("Die Zusammensetzung traegt Kuenstler und Cover jedes Liedes bis in seine Spur")
    func assemblyCarriesEachSongsFacts() {
        let built = MusicTrackAssembly.build([
            .init(id: "tr-214", title: "What I Know", duration: 148, size: nil,
                  artist: "Nicolas Falcon", coverArt: "al-51"),
            .init(id: "tr-2", title: "Young Night", duration: 67, size: nil),
        ])
        #expect(built.tracks[0].metadata?.artist == "Nicolas Falcon")
        #expect(built.tracks[0].metadata?.coverArt == "al-51")
        #expect(built.tracks[1].metadata?.artist == nil && built.tracks[1].metadata?.coverArt == nil)
        // A stored detail written before these fields reads on.
        let old = #"{"index":0,"startOffset":0,"duration":5,"contentUrl":"tr-1","metadata":{"size":10}}"#
        let decoded = try? JSONDecoder().decode(ABSAudioTrack.self, from: Data(old.utf8))
        #expect(decoded?.metadata?.size == 10 && decoded?.metadata?.artist == nil)
    }

    /// A netlabel release states title and performer per file; the track
    /// carries both (archive.org `eg0_234`, measured: `title` "track
    /// 00_soundboards_intro", `creator` "Ayato").
    @Test("Ein Netlabel-Album traegt Titel und Kuenstler jeder Datei bis in die Spur")
    func archiveTracksCarryTitleAndPerformer() {
        let tracks = FreeCatalog.archiveTracks(identifier: "eg0_234", files: [
            ArchiveFile(name: "track 00_soundboards_intro.mp3", length: "60", title: "track 00_soundboards_intro",
                        creator: "Ayato", track: "01", album: nil, format: "VBR MP3"),
            ArchiveFile(name: "track 01_clips_gallerie.mp3", length: "60", title: nil,
                        creator: nil, track: "02", album: nil, format: "VBR MP3"),
        ])
        #expect(tracks.map { $0.metadata?.title } == ["track 00_soundboards_intro", "track 01 clips gallerie"])
        #expect(tracks.map { $0.metadata?.artist } == ["Ayato", nil])
    }

    /// Music from a catalogue names the playing song and its artist like
    /// a music server: the song from its chapter, the artist by the rule.
    @Test("Musik aus einem Katalog nennt das laufende Lied und seinen Kuenstler wie ein Musikserver", .needsTheSources)
    func catalogueMusicNamesItsSong() throws {
        let lock = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/ViewModels/PlayerViewModel+NowPlaying.swift"), encoding: .utf8))
        #expect(lock.contains("songTitle: currentMusicSong?.title ?? (chapters.count > 1 ? currentChapter?.title : nil)"))
        let model = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8))
        #expect(model.contains("songArtist: track?.metadata?.artist"), "the artist skips the playing track")
    }

    /// The surfaces read the one answer: the artist from `musicArtist`, the
    /// time from `playbackSpan`, the cover from `songCoverURL`.
    @Test("Leiste, grosser Player und Sperrbildschirm lesen Kuenstler, Spanne und Cover an einer Stelle", .needsTheSources)
    func surfacesReadTheOneAnswer() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path),
                                                       encoding: .utf8))
        }
        let bar = try code("Sources/Views/MiniPlayerBar.swift")
        #expect(bar.contains("artist: viewModel.musicArtist"))
        #expect(!bar.contains("metadata?.authorName"), "the bar names the entry's artist past the rule")
        #expect(bar.contains("viewModel.playbackSpan.remaining(absolute: clock.time)"))
        #expect(!bar.contains("viewModel.duration - clock.time"), "the bar counts down the whole entry")
        #expect(bar.contains("viewModel.songCoverURL ?? router.coverURL(itemId)"))
        let player = try code("Sources/Views/PlayerView.swift")
        #expect(player.contains("viewModel.songCoverURL ?? coverURL"))
        #expect(player.contains("private var scrubberSpan: ScrubberSpan { viewModel.playbackSpan }"))
        let lock = try code("Sources/ViewModels/PlayerViewModel+NowPlaying.swift")
        #expect(lock.contains("if isMusicItem { return musicArtist }"))
        #expect(lock.contains("info[MPMediaItemPropertyPlaybackDuration] = span.length"))
        #expect(lock.contains("artworkKey != loadedArtworkKey"))
        let model = try code("Sources/ViewModels/PlayerViewModel.swift")
        #expect(model.contains("NowPlayingPresentation.song("))
        for provider in ["Sources/Providers/SubsonicProvider.swift", "Sources/Providers/JellyfinProvider.swift"] {
            let text = try code(provider)
            #expect(text.contains("artist: $0.") && text.contains("coverArt: $0."), "\(provider) drops a song's facts")
        }
    }
}
#endif
