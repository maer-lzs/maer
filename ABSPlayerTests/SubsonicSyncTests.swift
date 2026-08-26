// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Combine
import Foundation
@testable import ABSPlayer

/// The music sync core — a successful run records exactly one
/// `.music` history entry (correct counters) and fires the `librarySynced`
/// signal (the live Music tab reloads on it); a failed run records an error
/// entry and stays silent.
/// `.serialized`: every test here swaps `SubsonicProvider.shared.historyStore`
/// for its own mock (with a `defer` reset). Run in parallel they race on that
/// one singleton across suspension points (`await mapAlbums`), so an append
/// can land in a NEIGHBOR test's mock — seen as a real one-in-many failure of
/// `successRecordsAndSignals` (entries.count == 0). Serializing the suite
/// removes the shared-state race; the tests themselves are unchanged.
@MainActor
@Suite(.serialized)
struct SubsonicSyncTests {
    private final class MockHistoryStore: SyncHistoryStoring {
        var entries: [SyncHistoryEntry] = []
        var lastChecked: [String: Date] = [:]
        func append(_ entry: SyncHistoryEntry) { entries.append(entry) }
        func noteChecked(_ service: SyncHistoryEntry.Service, at date: Date) {
            lastChecked[service.rawValue] = date
        }
    }

    private func album(id: String, songs: Int) -> SubsonicAlbum {
        SubsonicAlbum(id: id, name: "Album \(id)", artist: "Artist", artistId: nil,
                      coverArt: nil, songCount: songs, duration: nil, year: nil,
                      genre: nil, created: nil, musicBrainzId: nil, song: nil)
    }

    @Test("success: one .music entry with album/song counters, signal fired")
    func successRecordsAndSignals() async {
        let provider = SubsonicProvider.shared
        let mock = MockHistoryStore()
        provider.historyStore = mock
        defer { provider.historyStore = SyncHistoryStore.shared }
        var signals = 0
        let sub = provider.librarySynced.sink { signals += 1 }
        defer { sub.cancel() }

        let result = await provider.runLibrarySync {
            [self.album(id: "a1", songs: 10), self.album(id: "a2", songs: 5)]
        }

        #expect(result == nil)
        #expect(signals == 1)
        #expect(mock.entries.count == 1)
        let entry = mock.entries.first
        #expect(entry?.service == .music)
        #expect(entry?.error == nil)
        #expect(entry?.counters.first { $0.key == .albumsUpdated }?.value == 2)
        #expect(entry?.counters.first { $0.key == .songsUpdated }?.value == 15)
    }

    @Test("Y37 trap: isAvailable dispatches through `any AudioProvider`")
    func availabilityDispatchesDynamically() {
        let stored = AppStorageKeys.subsonicEnabledValue
        defer { AppStorageKeys.subsonicEnabledValue = stored }
        // With the source switched OFF the concrete implementation says false.
        // Before isAvailable was a protocol REQUIREMENT, the existential bound
        // statically to the extension default (true) — this test pinned it.
        AppStorageKeys.subsonicEnabledValue = false
        let provider: any AudioProvider = SubsonicProvider.shared
        #expect(provider.isAvailable == false)
    }

    @Test("failure: error entry recorded, no signal")
    func failureRecordsErrorSilently() async {
        let provider = SubsonicProvider.shared
        let mock = MockHistoryStore()
        provider.historyStore = mock
        defer { provider.historyStore = SyncHistoryStore.shared }
        var signals = 0
        let sub = provider.librarySynced.sink { signals += 1 }
        defer { sub.cancel() }

        let result = await provider.runLibrarySync {
            throw URLError(.notConnectedToInternet)
        }

        #expect(result != nil)
        #expect(signals == 0)
        #expect(mock.entries.count == 1)
        #expect(mock.entries.first?.service == .music)
        #expect(mock.entries.first?.error != nil)
        #expect(mock.entries.first?.counters.isEmpty == true)
    }

    // A1 (#61/V1): cancellation is never translated into SubsonicError.network.
    @Test("isCancellation: task+URL cancellation true, transport errors false")
    func cancellationDetection() {
        #expect(SubsonicClient.isCancellation(CancellationError()))
        #expect(SubsonicClient.isCancellation(URLError(.cancelled)))
        #expect(!SubsonicClient.isCancellation(URLError(.notConnectedToInternet)))
        #expect(!SubsonicClient.isCancellation(URLError(.timedOut)))
        #expect(!SubsonicClient.isCancellation(SubsonicClient.SubsonicError.network))
    }

    // Bookmark continue-scope — playlists AND albums, in every
    // mode (the Booksonic-only album condition is gone); single songs never.
    @Test("continueScope: playlists and albums always, songs never (M1)")
    func continueScopeM1() {
        #expect(SubsonicProvider.continueScope(itemId: "sub:playlist:p1"))
        #expect(SubsonicProvider.continueScope(itemId: "sub:album:a1"))
        #expect(!SubsonicProvider.continueScope(itemId: "sub:song:s1"))
    }

    // Playlist basics: index-based removal — ONE request carries all indices
    // (server resolves against one snapshot; the duplicate-song case removes
    // exactly the addressed position, not both copies).
    @Test("removeIndexItems: one request, all indices, duplicates stay precise")
    func removeIndexItems() {
        let items = SubsonicClient.removeIndexItems([1, 3])
        #expect(items.map(\.name) == ["songIndexToRemove", "songIndexToRemove"])
        #expect(items.map(\.value) == ["1", "3"])
        // Playlist [A, B, A]: removing index 2 addresses ONLY the second A.
        #expect(SubsonicClient.removeIndexItems([2]).map(\.value) == ["2"])
    }

    // Funkwhale sends ids as NUMBERS.
    @Test("Lenient id decode: string and int, all four DTOs share it")
    func lenientIDDecoding() throws {
        let album = try JSONDecoder().decode(SubsonicAlbum.self,
            from: Data(#"{"id":7,"name":"A"}"#.utf8))
        #expect(album.id == "7")
        let albumS = try JSONDecoder().decode(SubsonicAlbum.self,
            from: Data(#"{"id":"al-7"}"#.utf8))
        #expect(albumS.id == "al-7")
        let song = try JSONDecoder().decode(SubsonicSong.self,
            from: Data(#"{"id":42,"title":"T"}"#.utf8))
        #expect(song.id == "42")
        let artist = try JSONDecoder().decode(SubsonicArtist.self,
            from: Data(#"{"id":9}"#.utf8))
        #expect(artist.id == "9")
        let playlist = try JSONDecoder().decode(SubsonicPlaylist.self,
            from: Data(#"{"id":3,"name":"P"}"#.utf8))
        #expect(playlist.id == "3")
    }

    // Booksonic negotiates the protocol version down.
    @Test("Version negotiation persists per host")
    func versionNegotiation() {
        // The HOST is unique per run. With a constant one the
        // CFPrefs flush race bit: the defer-removal was not flushed at
        // process end while the write was, so the NEXT run found the key
        // already there. A per-run host makes the flush irrelevant — same
        // class as the U4 fence (a test must not describe the real store).
        let host = "test-booksonic-\(UUID().uuidString).example"
        defer { UserDefaults.standard.removeObject(forKey: "subsonicApiVersion.\(host)") }
        #expect(SubsonicClient.negotiatedVersion(host: host) == nil)
        SubsonicClient.persistNegotiated("1.15.0", host: host)
        #expect(SubsonicClient.negotiatedVersion(host: host) == "1.15.0")
    }
}
#endif
