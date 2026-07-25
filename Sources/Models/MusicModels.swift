// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Jellyfin stage 1½: the neutral music DOMAIN types the `MusicProvider`
// protocol speaks — in the spirit of `LibraryItem` (which already covers
// albums/songs as items). Only the fields the UI actually uses; the wire
// DTOs (`Subsonic*` Decodables) stay internal to their provider, which maps
// wire → domain at its boundary (anti-corruption layer).

/// An artist as the browse/search surfaces need it.
nonisolated struct MusicArtist: Identifiable, Hashable {
    let id: String
    /// Nil when the server sent none — call sites keep their own localized
    /// fallbacks ("Unknown Artist" on the artist page, "—" in the deck).
    let name: String?
    let albumCount: Int?
}

/// A playlist row/card. `changedAt` is epoch ms (parsed at the provider
/// boundary), so the F5 "recently changed first" sort needs no wire format.
nonisolated struct MusicPlaylist: Identifiable, Hashable {
    let id: String
    let name: String?
    let songCount: Int?
    /// Total duration in seconds.
    let duration: Double?
    let changedAt: Double?
}

/// Optional artist metadata (OpenSubsonic `getArtistInfo2` today). Empty is
/// NORMAL — a provider without metadata agents (or without the capability)
/// returns nil/empty and the UI sections simply don't appear.
nonisolated struct MusicArtistInfo {
    let biography: String?
    /// The one image the UI renders (providers pick their best size).
    let imageURL: URL?
    /// Names only — the UI matches them against the own library's artists.
    let similarArtistNames: [String]
}

/// Optional album metadata (notes + MusicBrainz id for the CAA cover).
nonisolated struct MusicAlbumInfo {
    let notes: String?
    let musicBrainzId: String?
}

/// One top-song row of an artist: the playable item plus the album name the
/// row shows (the item itself carries title/artist).
nonisolated struct MusicTopSong: Identifiable {
    var id: String { item.id }
    let item: LibraryItem
    let albumName: String?
}
