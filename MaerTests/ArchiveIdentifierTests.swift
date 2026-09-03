// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A song address (`lva:X#n`) resolves to the same archive identifier as
/// its release, so source links and covers never carry `%23<index>`.
struct ArchiveIdentifierTests {
    @Test("Song und Album ergeben dieselbe Kennung, andere Quellen keine")
    func songResolvesToItsRelease() {
        let album = "lva:cocaine-bear-soundtrack"
        let song = CatalogSongID.make(album: album, index: 0)
        #expect(song.hasSuffix("#0"))
        #expect(FreeCatalog.archiveIdentifier(of: song) == "cocaine-bear-soundtrack")
        #expect(FreeCatalog.archiveIdentifier(of: album) == "cocaine-bear-soundtrack")
        #expect(FreeCatalog.archiveIdentifier(of: "lv:1234") == nil)
        #expect(FreeCatalog.archiveIdentifier(of: "jam:99") == nil)
    }

    @Test("Cover und Quelle eines Songs sind die des Albums, ohne %23")
    func coverAndSourceCarryNoFragment() {
        let album = "lva:cocaine-bear-soundtrack"
        let song = CatalogSongID.make(album: album, index: 3)
        let coverSong = FreeCatalog.archiveCoverURL(identifier: FreeCatalog.archiveIdentifier(of: song)!)
        let coverAlbum = FreeCatalog.archiveCoverURL(identifier: FreeCatalog.archiveIdentifier(of: album)!)
        #expect(coverSong == coverAlbum)
        let source = "https://archive.org/details/\(FreeCatalog.encodedPathSegment(FreeCatalog.archiveIdentifier(of: song)!))"
        #expect(!source.contains("%23") && !source.contains("#"))
        #expect(source == "https://archive.org/details/cocaine-bear-soundtrack")
    }
}
#endif
