// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The car as the app's small sibling: its tabs, its player and the rules
/// it shares with the app.
@MainActor
struct CarPlayLayoutTests {

    @Test("Radio ist ein eigener Tab nur, wenn das System ihn erlaubt; sonst stehen die Favoriten auf Start")
    func radioIsATabOnlyWhenAllowed() {
        let four = CarPlayLayout.tabs(audiobooks: true, podcasts: true, music: true, radio: true, maximumTabCount: 4)
        #expect(four.tabs == [.start, .audiobooks, .podcasts, .music])
        #expect(four.radioOnStart, "the favourites vanished with the tab")
        let five = CarPlayLayout.tabs(audiobooks: true, podcasts: true, music: true, radio: true, maximumTabCount: 5)
        #expect(five.tabs == [.start, .audiobooks, .podcasts, .music, .radio])
        #expect(!five.radioOnStart, "the favourites stand twice")
        let few = CarPlayLayout.tabs(audiobooks: false, podcasts: true, music: false, radio: true, maximumTabCount: 4)
        #expect(few.tabs == [.start, .podcasts, .radio] && !few.radioOnStart)
    }

    @Test("ein Tab nur mit eingerichteter Quelle, Start immer, nie mehr Tabs als das System nimmt")
    func aTabOnlyWithItsSource() {
        let none = CarPlayLayout.tabs(audiobooks: false, podcasts: false, music: false, radio: false, maximumTabCount: 4)
        #expect(none.tabs == [.start] && !none.radioOnStart)
        let tight = CarPlayLayout.tabs(audiobooks: true, podcasts: true, music: true, radio: false, maximumTabCount: 3)
        #expect(tight.tabs.count == 3, "more tabs than the tab bar takes")
        #expect(tight.tabs.first == .start)
    }

    @Test("Als Naechstes und Geschwindigkeit im Player nur bei Hoerbuechern und Folgen")
    func playerExtrasForSpokenTitles() {
        #expect(CarPlayLayout.playerExtras(for: "rss:feed:episode-1"))
        #expect(CarPlayLayout.playerExtras(for: "abspod:show:episode"))
        #expect(!CarPlayLayout.playerExtras(for: "radio:rb:station"), "a live stream got a speed")
        #expect(!CarPlayLayout.playerExtras(for: nil))
    }

    @Test("die Geschwindigkeit geht die Stufen der App durch und beginnt nach der letzten von vorn")
    func theRateStepsThroughTheAppsRates() {
        let rates = SpeedMenu.rates
        #expect(CarPlayLayout.nextRate(after: 1.0, rates: rates) == 1.1)
        #expect(CarPlayLayout.nextRate(after: 2.0, rates: rates) == 0.8)
        #expect(CarPlayLayout.nextRate(after: 1.3, rates: rates) == 1.5)
    }

    @Test("CarPlay fragt die Regeln der App, keine eigene Fassung", .needsTheSources)
    func theCarAsksTheAppsRules() throws {
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        for asked in ["CarPlayLayout.tabs(", "SharedRows.continueIds(", "SharedRows.playlists(at: .start)",
                      "SharedRows.newEpisodeIds(", "SharedRows.showEpisodes(", "SharedRows.musicRecentlyPlayed(",
                      "SharedRows.musicPlaylists(", "SharedRows.playAlbum(", "RoutinePlayback.start(",
                      "queue.ids", "RadioPlay.play(", "CarPlayLayout.playerExtras("] {
            #expect(car.contains(asked), "the car does not ask \(asked)")
        }
        for copy in ["podcastPlayState(", ".sorted {", "newestPerShow(", "byRecency("] {
            #expect(!car.contains(copy), "the car keeps its own copy: \(copy)")
        }
        // The app's surfaces ask the same rules.
        let surfaces: [(String, String)] = [
            ("Sources/Views/HomeView.swift", "SharedRows.continueStreams("),
            ("Sources/Views/HomeView.swift", "SharedRows.newEpisodeIds()"),
            ("Sources/Views/PodcastsView.swift", "SharedRows.newEpisodeIds()"),
            ("Sources/Views/Music/MusicView.swift", "SharedRows.musicRecentlyPlayed("),
            ("Sources/Views/Music/MusicView.swift", "SharedRows.musicPlaylists("),
            ("Sources/Views/Music/PlaylistNameList.swift", "SharedRows.playlists(at: home)"),
            ("Sources/Views/Podcasts/PodcastShowView.swift", "Self.ordered(show, newestFirst: preferences.newestFirst)"),
            ("Sources/Views/Music/MusicAlbumView.swift", "SharedRows.playAlbum("),
        ]
        for (path, asked) in surfaces {
            #expect(try FetchAnswerTests.squeezedSource(path).contains(asked), "\(path) does not ask \(asked)")
        }
    }

    @Test("CarPlay folgt jeder Aenderung, solange das Auto verbunden ist", .needsTheSources)
    func theCarFollowsEveryChange() throws {
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        for signal in ["ListeningRevision.shared.objectWillChange", "queue.$ids",
                       "playlistStore.$playlists", "PodcastSubscriptions.shared.objectWillChange",
                       "session.libraryViewModel.$continueListening", "session.$sourcesVersion",
                       "template.updateSections(", "tabBar.updateTemplates("] {
            #expect(car.contains(signal), "the car does not follow \(signal)")
        }
    }
}
#endif
