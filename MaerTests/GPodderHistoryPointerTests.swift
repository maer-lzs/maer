// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The two markers of the gpodder listening history belong to one account
/// on one server, and a play whose episode is not known yet is not lost
/// behind the marker.
@MainActor
@Suite(.serialized)
struct GPodderHistoryPointerTests {
    private func play(_ episode: String, feed: String, at stamp: String = "2026-11-11T08:00:00") -> GPodderEpisodeAction {
        GPodderEpisodeAction(podcast: feed, episode: episode, action: "play", timestamp: stamp,
                             position: 120, total: 600, started: 0)
    }

    @Test("ein erster Abgleich vor dem Laden der Feeds: der Stand einer bekannten Sendung wartet, bis seine Folge bekannt ist")
    func aPlayOfAnUnknownEpisodeWaits() {
        let followed = "https://feed.example/show.xml"
        let first = [play("https://cdn.example/e1.mp3", feed: followed),
                     play("https://cdn.example/x.mp3", feed: "https://other.example/feed.xml"),
                     GPodderEpisodeAction(podcast: followed, episode: "https://cdn.example/e1.mp3", action: "download",
                                          timestamp: nil, position: nil, total: nil, started: nil)]
        // Round one: the feed is followed, its episodes are not fetched yet.
        let one = GPodderParking.split(first, isKnownEpisode: { _ in false }, isFollowedFeed: { $0 == followed })
        #expect(one.matched.isEmpty)
        #expect(one.parked.map(\.episode) == ["https://cdn.example/e1.mp3"], "the play was lost, or a foreign feed was kept")
        // Round two: the parked play comes again and its episode is known.
        let two = GPodderParking.split(one.parked, isKnownEpisode: { $0 == "https://cdn.example/e1.mp3" },
                                       isFollowedFeed: { $0 == followed })
        #expect(two.matched.map(\.episode) == ["https://cdn.example/e1.mp3"])
        #expect(two.parked.isEmpty)
        // At most the newest are kept.
        let many = (0..<(GPodderParking.most + 5)).map { index in
            play("https://cdn.example/\(index).mp3", feed: followed, at: String(format: "2026-11-11T08:%02d:%02d", index / 60 % 60, index % 60))
        }
        #expect(GPodderParking.split(many, isKnownEpisode: { _ in false }, isFollowedFeed: { _ in true }).parked.count == GPodderParking.most)
    }

    @Test("Abmelden nimmt beide Zeiger und die geparkten Staende mit; der Abruf fragt danach ab null")
    func signingOutForgetsThePointers() {
        let kept = GPodderSync.historyPointerKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let keptAccount = [AppStorageKeys.gpodderServerURL, AppStorageKeys.gpodderUsername]
            .map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let password = AppStorageKeys.gpodderPasswordValue
        defer {
            for (key, value) in kept + keptAccount { UserDefaults.standard.set(value, forKey: key) }
            AppStorageKeys.setGpodderPassword(password)
        }
        AppStorageKeys.set(1_700_000_000, for: AppStorageKeys.gpodderEpisodeSince)
        AppStorageKeys.set(1_700_000_000.0, for: AppStorageKeys.gpodderLastEpisodePush)
        GPodderParking.save([play("https://cdn.example/e1.mp3", feed: "https://feed.example/show.xml")])
        GPodderSync.shared.disconnect(shelf: nil)
        #expect(AppStorageKeys.int(AppStorageKeys.gpodderEpisodeSince) == nil, "the pull would ask from the old marker")
        #expect(AppStorageKeys.double(AppStorageKeys.gpodderLastEpisodePush) == nil, "stands before the old push marker would never go out")
        #expect(GPodderParking.load().isEmpty)
    }
}
#endif
