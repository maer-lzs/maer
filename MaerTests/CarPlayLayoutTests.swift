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

    @Test("Alle Buecher im Auto fragt die Liste ohne Filter", .needsTheSources)
    func allBooksInTheCarIgnoresTheAppsFilter() throws {
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        #expect(car.contains("library.sortedEntries.map("), "All Books does not ask the list without a filter")
        #expect(!car.contains("sortedFilteredEntries"), "the car inherits the app's filter")
    }

    @Test("eine gescheiterte Abfrage ist im Auto keine leere Bibliothek", .needsTheSources)
    func aFailedFetchIsNoEmptyLibraryInTheCar() throws {
        #expect(CarPlayLayout.emptyNote(failed: true) == .noAnswer)
        #expect(CarPlayLayout.emptyNote(failed: false) == .nothing)
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        let fetches = car.components(separatedBy: "FetchAnswer.of(").count - 1
        let asked = car.components(separatedBy: ".failed").count - 1
        #expect(fetches == 6, "the car's fetches: \(fetches)")
        #expect(asked == fetches, "\(fetches) fetches, \(asked) ask whether theirs failed")
        #expect(!car.contains("}.value"), "a fetch drops its failure")
        #expect(car.contains("CarPlayLayout.emptyNote(failed: failed)"), "the page does not ask the rule")
        #expect(car.contains("case .noAnswer: template.emptyViewTitleVariants = [Self.noAnswer]"),
                "a failed page does not say so")
    }

    @Test("Start im Auto traegt die Reihen von Start, jeder Tab beginnt wie in der App", .needsTheSources)
    func startCarriesStartsRowsAndEveryTabBeginsAsInTheApp() throws {
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        // Start's rows in Start's order.
        let order = ["SharedRows.continueIds(limit: 10)", "SharedRows.playlists(at: .start)", "await tiles(upNextItems())",
                     "await listenAgainTiles(continued:", "SharedRows.newEpisodeIds(limit: Int(CPMaximumNumberOfGridImages))"]
        var from = car.startIndex
        for step in order {
            let found = try #require(car.range(of: step, range: from..<car.endIndex), "Start misses or misplaces \(step)")
            from = found.upperBound
        }
        #expect(car.contains("SharedRows.listenAgain(serverRecent: recent, continued: continued"))
        // Podcasts begin with Continue, music with its playlists.
        let podcasts = try #require(car.range(of: "private func podcastSections()"))
        let continued = try #require(car.range(of: "SharedRows.continueEpisodeIds(", range: podcasts.upperBound..<car.endIndex))
        let latest = try #require(car.range(of: "SharedRows.newEpisodeIds(limit: CarPlayLayout.sectionLimit)",
                                            range: podcasts.upperBound..<car.endIndex))
        #expect(continued.lowerBound < latest.lowerBound, "the podcast tab does not begin with Continue")
        let music = try #require(car.range(of: "private func musicSections()"))
        let lists = try #require(car.range(of: "coverRow(String(localized: \"Playlists\"), cards)", range: music.upperBound..<car.endIndex))
        let played = try #require(car.range(of: "section(String(localized: \"Recently Played\")", range: music.upperBound..<car.endIndex))
        #expect(lists.lowerBound < played.lowerBound, "the music tab does not begin with its playlists")
        // A station shows the app's logo and the app's name for it.
        #expect(car.contains("RadioArtwork.gatedImage(for:"))
        #expect(car.contains("RadioMapping.displayName(station.name)"))
        #expect(!car.contains("text: station.name"), "the car shows a station's raw name")
    }

    @Test("Als Naechstes im Player, sobald etwas hinter dem Titel wartet, nie bei einem Sender")
    func upNextWheneverSomethingWaits() {
        #expect(CarPlayLayout.offersUpNext(for: "book-1", waiting: 1))
        #expect(CarPlayLayout.offersUpNext(for: "sub:song-1", waiting: 3))
        #expect(!CarPlayLayout.offersUpNext(for: "book-1", waiting: 0))
        #expect(!CarPlayLayout.offersUpNext(for: "radio:rb:station", waiting: 2))
        #expect(!CarPlayLayout.offersUpNext(for: nil, waiting: 2))
    }

    @Test("ein Katalogtitel ohne Namen steht nicht im Auto, der Knopf der Geschwindigkeit traegt die Zahl der App",
          .needsTheSources)
    func noNamelessTitleAndTheChosenSpeedWhilePaused() throws {
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        #expect(car.contains("case .catalogTrack(let id): if let title = await catalogTitle(id)"),
                "a catalogue title goes into the row without its name")
        #expect(!car.contains("session.playableItem(forId: id)"), "the car shows a title it cannot name")
        #expect(car.contains("let label = SpeedMenu.label(rate) + \"×\""), "the speed button does not carry the app's label")
        #expect(!car.contains("CPNowPlayingPlaybackRateButton {"), "the system's rate button shows no speed of the app")
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
