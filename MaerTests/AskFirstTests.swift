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
    @Test("Mark all as unplayed asks first; only the confirmation prompt marks", .needsTheSources)
    func markingAllUnplayedAsksFirst() throws {
        let page = try FetchAnswerTests.squeezedSource("Sources/Views/Podcasts/PodcastShowView.swift")
        #expect(page.contains("Button { showUnplayedConfirm = true } label: { Label(\"Mark All as Unplayed\""),
                "the menu marks at once")
        #expect(page.components(separatedBy: "markAllEpisodes(played: false)").count - 1 == 1)
        #expect(page.contains(".confirmationDialog(\"Mark all episodes as unplayed?\", isPresented: $showUnplayedConfirm, titleVisibility: .visible) { Button(\"Mark All as Unplayed\", role: .destructive) { markAllEpisodes(played: false) }"),
                "the marking stands outside the question")
    }

    @Test("a Mär playlist is deleted at each of its three places only after the confirmation prompt", .needsTheSources)
    func deletingAPlaylistAsksFirst() throws {
        let page = try FetchAnswerTests.squeezedSource("Sources/Views/Music/MusicLibraryPages.swift")
        #expect(page.contains("Button(role: .destructive) { deleting = true } label: { Label(\"Delete\", systemImage: \"trash\") }"),
                "the page's menu deletes at once")
        #expect(page.contains(".asksBeforeDeletingPlaylist(isPresented: $deleting) { store.delete(playlistId: playlistId) }"))
        #expect(page.components(separatedBy: "store.delete(playlistId:").count - 1 == 1, "another delete without the question")
        // One question, in one place, at the three places.
        for file in ["Sources/Views/Music/PlaylistCard.swift", "Sources/Views/Music/MusicAlbumView.swift"] {
            #expect(try FetchAnswerTests.squeezedSource(file).contains(".asksBeforeDeletingPlaylist(isPresented: $showDeleteConfirm) {"),
                    "\(file) asks in words of its own")
        }
        var spelled = 0
        for (_, text) in ProjectFileIntegrityTests.sourceTexts() where text.contains("\"Delete this playlist?\"") { spelled += 1 }
        #expect(spelled == 1, "the question is spelled out in \(spelled) files")
    }
}
#endif
