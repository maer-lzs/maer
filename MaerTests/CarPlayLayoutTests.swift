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

    @Test("Radio is a tab of its own only if the system allows it; otherwise the favorites are on Start")
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

    @Test("a tab only with a configured source, Start always, never more tabs than the system takes")
    func aTabOnlyWithItsSource() {
        let none = CarPlayLayout.tabs(audiobooks: false, podcasts: false, music: false, radio: false, maximumTabCount: 4)
        #expect(none.tabs == [.start] && !none.radioOnStart)
        let tight = CarPlayLayout.tabs(audiobooks: true, podcasts: true, music: true, radio: false, maximumTabCount: 3)
        #expect(tight.tabs.count == 3, "more tabs than the tab bar takes")
        #expect(tight.tabs.first == .start)
    }

    @Test("the first tabs at connect come from the settings, the build after reading from what each area holds")
    func theFirstTabsAsATable() {
        // At connect, nothing read yet: on and set up is enough.
        #expect(CarPlayLayout.showsTab(enabled: true, holds: false, read: false, setUp: true))
        #expect(!CarPlayLayout.showsTab(enabled: true, holds: false, read: false, setUp: false), "a tab without a source")
        #expect(!CarPlayLayout.showsTab(enabled: false, holds: true, read: false, setUp: true), "a tab for an area switched off")
        // What the app already holds counts before the reading too.
        #expect(CarPlayLayout.showsTab(enabled: true, holds: true, read: false, setUp: false))
        // After the reading only what it holds: a set-up area without content drops its tab.
        #expect(!CarPlayLayout.showsTab(enabled: true, holds: false, read: true, setUp: true), "an empty tab stays")
        #expect(CarPlayLayout.showsTab(enabled: true, holds: true, read: true, setUp: false))
    }

    @Test("the tab bar stands at connect, each tab loading, and the build only changes its tabs", .needsTheSources)
    func theTabBarStandsAtConnect() throws {
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        #expect(car.contains("nowPlaying.upNextTitle = String(localized: \"Up Next\") showLoadingTabs() connectTask?.cancel()"),
                "the car waits for every tab before it shows the bar")
        #expect(car.contains("let layout = tabLayout(read: false)") && car.contains("let layout = tabLayout(read: true)"),
                "connect and build choose their tabs by different rules")
        #expect(car.contains("template.emptyViewTitleVariants = [String(localized: \"Loading…\")]"),
                "a tab at connect does not say it loads")
        #expect(car.contains("template.updateSections(filled) template.emptyViewTitleVariants = []"),
                "a filled tab still says it loads")
        #expect(car.components(separatedBy: "setRootTemplate(").count - 1 == 1, "the tab bar is set in a second place")
    }

    @Test("Up Next and speed in the player only for audiobooks and episodes")
    func playerExtrasForSpokenTitles() {
        #expect(CarPlayLayout.playerExtras(for: "rss:feed:episode-1"))
        #expect(CarPlayLayout.playerExtras(for: "abspod:show:episode"))
        #expect(!CarPlayLayout.playerExtras(for: "radio:rb:station"), "a live stream got a speed")
        #expect(!CarPlayLayout.playerExtras(for: nil))
    }

    @Test("the speed goes through the steps of the app and starts over after the last one")
    func theRateStepsThroughTheAppsRates() {
        let rates = SpeedMenu.rates
        #expect(CarPlayLayout.nextRate(after: 1.0, rates: rates) == 1.1)
        #expect(CarPlayLayout.nextRate(after: 2.0, rates: rates) == 0.8)
        #expect(CarPlayLayout.nextRate(after: 1.3, rates: rates) == 1.5)
    }

    @Test("CarPlay asks the rules of the app, no version of its own", .needsTheSources)
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

    @Test("All Books in the car asks the list without a filter", .needsTheSources)
    func allBooksInTheCarIgnoresTheAppsFilter() throws {
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        #expect(car.contains("library.sortedEntries.map("), "All Books does not ask the list without a filter")
        #expect(!car.contains("sortedFilteredEntries"), "the car inherits the app's filter")
    }

    @Test("a failed query is not an empty library in the car", .needsTheSources)
    func aFailedFetchIsNoEmptyLibraryInTheCar() throws {
        #expect(CarPlayLayout.emptyNote(failed: true) == .noAnswer)
        #expect(CarPlayLayout.emptyNote(failed: false) == .nothing)
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        let fetches = car.components(separatedBy: "FetchAnswer.of(").count - 1
        let asked = car.components(separatedBy: ".failed").count - 1
        #expect(fetches == 6, "the car's fetches: \(fetches)")
        // Every fetch is asked once, the playlists twice: by the music
        // tab's row of covers and by the page of all playlists.
        #expect(asked == fetches + 1, "\(fetches) fetches, \(asked) ask whether theirs failed")
        #expect(!car.contains("}.value"), "a fetch drops its failure")
        #expect(car.contains("CarPlayLayout.emptyNote(failed: failed)"), "the page does not ask the rule")
        #expect(car.contains("case .noAnswer: template.emptyViewTitleVariants = [Self.noAnswer]"),
                "a failed page does not say so")
    }

    @Test("Start in the car carries the rows of Start, every tab begins as in the app", .needsTheSources)
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
        // The lists of the podcast tab and of the book library stand in
        // their tabs, as the music tab carries its own.
        #expect(car.contains("sections += await listSections(at: .podcasts)"), "the podcast tab shows no lists")
        #expect(car.contains("sections += await listSections(at: .library)"), "the audiobook tab shows no lists")
        // A station shows the app's logo and the app's name for it.
        #expect(car.contains("RadioArtwork.gatedImage(for:"))
        #expect(car.contains("RadioMapping.displayName(station.name)"))
        #expect(!car.contains("text: station.name"), "the car shows a station's raw name")
    }

    @Test("shuffle in the player only for songs, and only while two titles of what was started wait")
    func shuffleOnlyForSongs() {
        let song = JellyfinProvider.itemId(songId: "s1")
        #expect(CarPlayLayout.offersShuffle(for: song, waitingInContext: 2))
        #expect(!CarPlayLayout.offersShuffle(for: song, waitingInContext: 1), "a mix of one changes nothing")
        #expect(!CarPlayLayout.offersShuffle(for: "book-1", waitingInContext: 5), "a book got a shuffle")
        #expect(!CarPlayLayout.offersShuffle(for: "rss:feed:episode-1", waitingInContext: 5), "an episode got a shuffle")
        #expect(!CarPlayLayout.offersShuffle(for: "radio:rb:station", waitingInContext: 5))
        #expect(!CarPlayLayout.offersShuffle(for: nil, waitingInContext: 5))
    }

    @Test("the shuffle mixes the rest of what was started and puts it back; a new start is in order")
    @MainActor
    func theShuffleMixesTheRestAndPutsItBack() {
        let context = PlaybackContext()
        let order = (1...12).map { "jf:song:\($0)" }
        context.replace(ids: order, source: "Album")
        var generator = SplitMix(state: 7)
        context.setShuffled(true, using: &generator)
        #expect(context.isShuffled)
        #expect(context.ids != order && context.ids.sorted() == order.sorted(), "the mix is not a permutation of the rest")
        // Titles leave while it runs mixed; back in order keeps the rest's order.
        context.remove(order[0])
        context.remove(order[5])
        context.setShuffled(false)
        #expect(!context.isShuffled)
        #expect(context.ids == order.filter { $0 != order[0] && $0 != order[5] })
        // Nothing is kept: a new start after a mix runs in order.
        context.setShuffled(true, using: &generator)
        context.replace(ids: ["a", "b", "c"], source: nil)
        #expect(!context.isShuffled && context.ids == ["a", "b", "c"])
        // A rest of one is not mixed.
        context.replace(ids: ["only"], source: nil)
        context.setShuffled(true, using: &generator)
        #expect(!context.isShuffled)
    }

    @Test("a context mixed and then rekeyed or expanded goes back to the order under its new entries")
    @MainActor
    func theOrderBeforeAShuffleFollowsEveryWrite() {
        let context = PlaybackContext()
        context.replace(ids: ["sub:song:1", "sub:album:a", "sub:song:3", "sub:song:4"], source: "List")
        var generator = SplitMix(state: 11)
        context.setShuffled(true, using: &generator)
        // A drawn album becomes its songs, then the server answers to new ids.
        #expect(context.expand("sub:album:a", into: ["sub:song:a1", "sub:song:a2"]))
        _ = context.rekey { $0.replacingOccurrences(of: "sub:", with: "nd:") }
        context.setShuffled(false)
        #expect(context.ids == ["nd:song:1", "nd:song:a1", "nd:song:a2", "nd:song:3", "nd:song:4"],
                "back in order brought old ids or put the album's songs at the end: \(context.ids)")
    }

    @Test("back in order: the waiting titles in their former order, a title that came in since after them")
    func backInOrderAsATable() {
        #expect(MediaShuffle.backInOrder(now: ["c", "a", "b"], before: ["a", "b", "c"]) == ["a", "b", "c"])
        #expect(MediaShuffle.backInOrder(now: ["c", "a"], before: ["a", "b", "c"]) == ["a", "c"], "a title that left stays gone")
        #expect(MediaShuffle.backInOrder(now: ["c", "x1", "x2", "a"], before: ["a", "b", "c"]) == ["a", "c", "x1", "x2"])
    }

    @Test("the car's shuffle mixes the context through its one door and shows its state", .needsTheSources)
    func theCarShufflesThroughTheContext() throws {
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        #expect(car.contains("CarPlayLayout.offersShuffle(for: coordinator.activeItem?.id, markedForm: form, waitingInContext: context.ids.count)"),
                "the car offers the shuffle by a rule of its own")
        #expect(car.contains("self.context.setShuffled(!self.context.isShuffled)"), "the button mixes past the context")
        #expect(car.contains("button.isSelected = context.isShuffled"), "the button does not show the state")
        #expect(!car.contains("queue.shuffle") && !car.contains("MediaShuffle."), "the car mixes by itself or mixes the orders")
    }

    /// A seeded generator, so the mix in the witness is the same each run.
    nonisolated private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    @Test("Up Next in the player as soon as something waits behind the title, never for a station")
    func upNextWheneverSomethingWaits() {
        #expect(CarPlayLayout.offersUpNext(for: "book-1", waiting: 1))
        #expect(CarPlayLayout.offersUpNext(for: "sub:song-1", waiting: 3))
        #expect(!CarPlayLayout.offersUpNext(for: "book-1", waiting: 0))
        #expect(!CarPlayLayout.offersUpNext(for: "radio:rb:station", waiting: 2))
        #expect(!CarPlayLayout.offersUpNext(for: nil, waiting: 2))
    }

    @Test("a catalog title without a name is not in the car, the speed button carries the number of the app",
          .needsTheSources)
    func noNamelessTitleAndTheChosenSpeedWhilePaused() throws {
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        #expect(car.contains("case .catalogTrack(let id): if let title = await catalogTitle(id)"),
                "a catalogue title goes into the row without its name")
        #expect(!car.contains("session.playableItem(forId: id)"), "the car shows a title it cannot name")
        #expect(car.contains("let label = SpeedMenu.label(rate) + \"×\""), "the speed button does not carry the app's label")
        #expect(!car.contains("CPNowPlayingPlaybackRateButton {"), "the system's rate button shows no speed of the app")
    }

    @Test("CarPlay follows every change as long as the car is connected", .needsTheSources)
    func theCarFollowsEveryChange() throws {
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        for signal in ["ListeningRevision.shared.objectWillChange", "queue.$ids",
                       "playlistStore.$playlists", "subscriptions.objectWillChange",
                       "session.libraryViewModel.$continueListening", "session.$sourcesVersion",
                       "downloads.stock.objectWillChange",
                       "template.updateSections(", "tabBar.updateTemplates("] {
            #expect(car.contains(signal), "the car does not follow \(signal)")
        }
    }

    @Test("Podcasts and Music carry a downloads page with the titles of the app's page, only with downloads", .needsTheSources)
    func downloadsPagesForEveryKind() throws {
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        #expect(car.contains("return downloadsPage(.podcasts)"), "Podcasts carry no downloads page")
        #expect(car.contains("return downloadsPage(.music) + lists"), "Music carries no downloads page")
        #expect(car.contains("SharedRows.podcastDownloads(item: ItemRouter.live.item, isDownloaded: downloads.isDownloaded(itemId:))")
                && car.contains("SharedRows.musicDownloads(downloads.downloadedItemIds, source: session.musicProvider(for:))")
                && car.contains("session.libraryViewModel.downloadedEntries.map(\\.item)"),
                "the car shows other downloads than the app's page of the kind")
        #expect(car.contains("guard !downloadedItems(kind).isEmpty else { return [] }"), "the car shows an empty downloads page")
        // The rule itself: a podcast id counts as a podcast, music by its recorded kind.
        let ids = DownloadKind.podcasts.ids(in: ["rss:f:g", "li_book"], recorded: [:], sole: { _ in nil })
        #expect(ids == ["rss:f:g"])
    }

    @Test("a car started alone restores the last session paused, by the app's own start path", .needsTheSources)
    func carColdStartRestoresLikeTheApp() throws {
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        let app = try FetchAnswerTests.squeezedSource("Sources/Views/LibraryView.swift")
        #expect(car.contains("await session.playerCoordinator.restoreAtColdStart(library: session.libraryViewModel)"),
                "the car's prepare skips the restore, the player has no title")
        #expect(app.contains("await playerCoordinator.restoreAtColdStart(library: viewModel)"),
                "the app starts by a path of its own")
        // The restore itself stays inside the one start path.
        for file in ProjectFileIntegrityTests.sourceFiles() where file.lastPathComponent != "PlayerCoordinator.swift" {
            let text = try SourceTree.text(file)
            #expect(!text.contains("restoreLastSession("), "\(file.lastPathComponent) restores beside the start path")
        }
    }

    @Test("after an open in the car: the player when the title runs, a hint with the app's sentence when it started nothing")
    func afterAnOpenAsATable() {
        #expect(CarPlayLayout.afterOpen(requested: "b1", activeBefore: nil, active: "b1", failure: nil) == .player)
        #expect(CarPlayLayout.afterOpen(requested: "b1", activeBefore: "b0", active: "b1", failure: "stale") == .player,
                "a sentence left from before beats a title that plays")
        #expect(CarPlayLayout.afterOpen(requested: "b1", activeBefore: "b0", active: "b0", failure: "Offline.") == .hint("Offline."),
                "the player would show another title")
        #expect(CarPlayLayout.afterOpen(requested: "b1", activeBefore: nil, active: nil, failure: "Offline.") == .hint("Offline."))
        #expect(CarPlayLayout.afterOpen(requested: "b1", activeBefore: "b0", active: nil, failure: nil) == .player,
                "an open without a sentence (the title on its way) keeps the player")
        // An album is asked for by its id, as it plays as itself.
        #expect(CarPlayLayout.afterOpen(requested: "sub:album:a", activeBefore: "b0", active: "b0", failure: "Offline.")
                == .hint("Offline."), "an album that started nothing showed the player of the title before")
        // A list by the title active before it.
        #expect(CarPlayLayout.afterOpen(requested: nil, activeBefore: "b0", active: "s3", failure: "x") == .player,
                "a list runs its title")
        #expect(CarPlayLayout.afterOpen(requested: nil, activeBefore: "b0", active: "b0", failure: "Offline.") == .hint("Offline."),
                "a list that started nothing showed the player of the title before")
        #expect(CarPlayLayout.afterOpen(requested: nil, activeBefore: "s3", active: "s3", failure: nil) == .player,
                "a list whose first title already runs keeps the player")
        #expect(CarPlayLayout.afterOpen(requested: nil, activeBefore: nil, active: nil, failure: "Offline.") == .hint("Offline."))
    }

    @Test("every open in the car goes through the one rule; only a station shows the player straight", .needsTheSources)
    func everyOpenAsksTheRule() throws {
        let car = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/CarPlay/CarPlaySceneDelegate.swift"), encoding: .utf8))
        let lines = car.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var straight: [String] = []
        for (index, line) in lines.enumerated() where line == "self?.showNowPlaying()" {
            if index == 0 || !lines[index - 1].hasPrefix("RadioPlay.play(") { straight.append(lines[max(index - 1, 0)]) }
        }
        #expect(straight.isEmpty, "the player is shown straight after: \(straight)")
        // Every open stands in the one door, which notes the title active
        // before it; an album and a title are asked for by their id.
        var outside: [String] = []
        var opens = 0
        for (index, line) in lines.enumerated() where index > 0 {
            let door = lines[index - 1]
            if line.hasPrefix("await RoutinePlayback.start(") {
                opens += 1
                if !door.hasSuffix("openThenShow(nil) {") { outside.append(line) }
            } else if line.hasPrefix("await SharedRows.playAlbum(") || line == "await coordinator.open(item: item)" {
                opens += 1
                if !door.hasSuffix("openThenShow(item.id) {") { outside.append(line) }
            }
        }
        #expect(opens == 6 && outside.isEmpty, "\(opens) opens, outside the door or without their id: \(outside)")
        let door = try #require(functionBody(of: "private func openThenShow(_ requested: String?, _ open: () async -> Void) async {", in: car))
        #expect(door.contains("let before = coordinator.activeItem?.id\n        await open()"), "the door does not note the title before the open")
        #expect(door.contains("activeBefore: before,"), "the rule does not hear the title before the open")
    }
}
#endif
