// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The tab a source target opens in follows from the target. It was set by
/// hand in eight branches next to each push; now it is one pure mapping,
/// and the handler sets it once.
struct PlayerSourceTabTests {
    static let item = LibraryItem(id: "sub:album:1", media: nil, addedAt: nil)
    static let artist = MusicArtist(id: "sub:artist:1", itemId: "sub:artist:1", name: "A", albumCount: nil)
    static let station = RadioStation(id: "radio:rb:1", name: "R", streamURL: "https://s/r")

    @Test("a book opens at the audiobooks")
    func book() { #expect(PlayerSourceTarget.book(itemId: "li_1").tab == .audiobooks) }

    @Test("a show opens at the podcasts")
    func podcastShow() { #expect(PlayerSourceTarget.podcastShow(feedURL: "https://f").tab == .podcasts) }

    @Test("an episode opens at the podcasts")
    func podcastEpisode() { #expect(PlayerSourceTarget.podcastEpisode(itemId: "rss:f:1").tab == .podcasts) }

    @Test("the latest episodes open at the podcasts")
    func podcastLatest() { #expect(PlayerSourceTarget.podcastLatest.tab == .podcasts) }

    @Test("an album opens at the music")
    func musicAlbum() { #expect(PlayerSourceTarget.musicAlbum(Self.item).tab == .music) }

    @Test("an artist opens at the music")
    func musicArtist() { #expect(PlayerSourceTarget.musicArtist(Self.artist).tab == .music) }

    @Test("a catalog album opens at the music")
    func catalogAlbum() { #expect(PlayerSourceTarget.catalogAlbum(itemId: "cat:1").tab == .music) }

    @Test("a station opens at the radio")
    func radioStation() { #expect(PlayerSourceTarget.radioStation(Self.station).tab == .radio) }

    /// The handler sets the tab once, from the mapping, and nowhere by hand.
    @Test("the receiver sets the tab exactly once, from the mapping", .needsTheSources)
    func theHandlerSetsTheTabOnce() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "LibraryView.swift" })
        let code = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(code.range(of: "func registerPlayerSourceRouter()"))
        let end = try #require(code.range(of: "\n    }\n", range: start.upperBound..<code.endIndex))
        let body = code[start.upperBound..<end.lowerBound]
        let sets = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("selectedMediaType =") }
        #expect(sets == ["selectedMediaType = target.tab"], "Reiter von Hand gesetzt: \(sets)")
    }
}
#endif
