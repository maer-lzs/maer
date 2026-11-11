// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// What takes a person's state on every device asks first: marking every
/// episode of a show as unplayed, and deleting a Mär playlist at each of
/// its three places.
struct AskFirstTests {
    @Test("Alle als ungehoert markieren fragt zuerst; erst die Rueckfrage markiert", .needsTheSources)
    func markingAllUnplayedAsksFirst() throws {
        let page = try FetchAnswerTests.squeezedSource("Sources/Views/Podcasts/PodcastShowView.swift")
        #expect(page.contains("Button { showUnplayedConfirm = true } label: { Label(\"Mark All as Unplayed\""),
                "the menu marks at once")
        #expect(page.components(separatedBy: "markAllEpisodes(played: false)").count - 1 == 1)
        #expect(page.contains(".confirmationDialog(\"Mark all episodes as unplayed?\", isPresented: $showUnplayedConfirm, titleVisibility: .visible) { Button(\"Mark All as Unplayed\", role: .destructive) { markAllEpisodes(played: false) }"),
                "the marking stands outside the question")
    }

    @Test("eine Mär-Playlist wird an jeder ihrer drei Stellen erst nach der Rueckfrage geloescht", .needsTheSources)
    func deletingAPlaylistAsksFirst() throws {
        let page = try FetchAnswerTests.squeezedSource("Sources/Views/Music/MusicLibraryPages.swift")
        #expect(page.contains("Button(role: .destructive) { deleting = true } label: { Label(\"Delete\", systemImage: \"trash\") }"),
                "the page's menu deletes at once")
        #expect(page.contains(".confirmationDialog(\"Delete this playlist?\", isPresented: $deleting, titleVisibility: .visible) { Button(\"Delete Playlist\", role: .destructive) { store.delete(playlistId: playlistId) } }"))
        #expect(page.components(separatedBy: "store.delete(playlistId:").count - 1 == 1, "another delete without the question")
        let card = try FetchAnswerTests.squeezedSource("Sources/Views/Music/PlaylistCard.swift")
        #expect(card.contains(".confirmationDialog(\"Delete this playlist?\""))
    }
}
#endif
