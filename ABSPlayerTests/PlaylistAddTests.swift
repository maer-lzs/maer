// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Package 1: adding songs to a server playlist. The pure, tested seams are the
/// `updatePlaylist` query-item builder (one repeated `songIdToAdd` per song) and
/// the id namespacing that routes the music-only "Add to Playlist" action.
struct PlaylistAddTests {
    @Test func addSongItemsRepeatsSongIdToAdd() {
        let items = SubsonicClient.addSongItems(["a", "b", "c"])
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.name == "songIdToAdd" })
        #expect(items.map(\.value) == ["a", "b", "c"])
    }

    @Test func addSongItemsEmptyIsEmpty() {
        #expect(SubsonicClient.addSongItems([]).isEmpty)
    }

    @Test func songNamespaceRoundTrips() {
        let itemId = SubsonicProvider.itemId(songId: "42")
        #expect(itemId == "sub:song:42")
        #expect(SubsonicProvider.id(itemId, kind: "song") == "42")
    }

    @Test func playlistNamespaceRoundTrips() {
        let itemId = SubsonicProvider.itemId(playlistId: "pl7")
        #expect(itemId == "sub:playlist:pl7")
        #expect(SubsonicProvider.id(itemId, kind: "playlist") == "pl7")
        // Wrong kind does not cross-extract.
        #expect(SubsonicProvider.id(itemId, kind: "song") == nil)
    }

    @Test func ownsOnlySubsonicNamespace() {
        #expect(SubsonicProvider.owns(itemId: "sub:song:1"))
        #expect(SubsonicProvider.owns(itemId: "sub:album:1"))
        #expect(SubsonicProvider.owns(itemId: "sub:playlist:1"))
        #expect(!SubsonicProvider.owns(itemId: "li_book123"))
        #expect(!SubsonicProvider.owns(itemId: "radio:xyz"))
    }
}
#endif
