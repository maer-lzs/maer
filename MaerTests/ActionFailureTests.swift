// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// An action of the person that the server did not take is not done: the
/// surfaces that swallowed it (`try?`) and showed the change as made now
/// ask the answer and say a refusal (`actionFailedAlert`).
@MainActor
struct ActionFailureTests {
    /// The actions that read `try? await …` and went on as if they had
    /// landed; the old form must not come back.
    nonisolated static let swallowedActions: [(file: String, old: String)] = [
        ("Sources/Views/Music/PlaylistCard.swift", "try? await music.renamePlaylist("),
        ("Sources/Views/Music/PlaylistCard.swift", "try? await music.deletePlaylist("),
        ("Sources/Views/Music/MusicAlbumView.swift", "try? await music.removeSongs("),
        ("Sources/Views/Music/MusicAlbumView.swift", "try? await music.renamePlaylist("),
        ("Sources/Views/Music/MusicAlbumView.swift", "try? await music.deletePlaylist("),
        ("Sources/Providers/SubsonicProvider.swift", "try? await client.star("),
        ("Sources/Providers/SubsonicProvider.swift", "try? await client.createBookmark("),
        ("Sources/Providers/SubsonicProvider.swift", "try? await client.scrobble("),
        ("Sources/Providers/JellyfinProvider.swift", "try? await client.setFavorite("),
    ]

    private static func squeezed(_ relative: String) throws -> String {
        try FetchAnswerTests.squeezedSource(relative)
    }

    @Test("the actions that swallowed a failure ask for the answer and report a refusal", .needsTheSources)
    func theSwallowedActionsAskTheAnswer() throws {
        var offenders: [String] = []
        for site in Self.swallowedActions {
            let text = try Self.squeezed(site.file)
            if text.contains(site.old) { offenders.append("\(site.file): \(site.old)") }
        }
        #expect(offenders.isEmpty, "an action swallows its failure again: \(offenders)")
        // The page closes only on a deleted list, and both surfaces say a refusal.
        let album = try Self.squeezed("Sources/Views/Music/MusicAlbumView.swift")
        #expect(album.contains("if done.failed { actionFailed = true } else { dismissView() }"),
                "a refused delete closes the page as if the list were gone")
        #expect(album.contains(".actionFailedAlert($actionFailed)"))
        #expect(try Self.squeezed("Sources/Views/Music/PlaylistCard.swift").contains(".actionFailedAlert($actionFailed)"))
        // The heart turns back when the server did not take it.
        #expect(album.contains("if done.failed { starred = !target actionFailed = true }"),
                "a refused favorite keeps the heart the server never had")
        // A press of "change password" gets the answer of now, like the others.
        let settings = try Self.squeezed("Sources/Views/MaerSyncSettingsView.swift")
        #expect(settings.contains("show(await LookupOccasion.deliberate { await MaerSyncSignIn.changePassword("),
                "the password change waits out the rest after a refusal")
    }

    /// A press while the automatic pass runs: no pass ran, so the line does
    /// not say "Nothing to sync.".
    @Test("a sync that did not run because one was running does not say nothing to do")
    func aPassThatDidNotRunSaysNothing() {
        var running = PodcastSubscriptionSync.Report()
        running.alreadyRunning = true
        #expect(running.summary == nil, "a pass that did not run claims there was nothing to sync")
        #expect(PodcastSubscriptionSync.Report().summary == String(localized: "Nothing to sync."))
        var some = PodcastSubscriptionSync.Report()
        some.pushed = 2
        #expect(some.summary == String(localized: "\(2) subscriptions mirrored to server"))
    }
}
#endif
