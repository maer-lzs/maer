// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Siri book query reads the rows, the same books the library shows.
/// The calls a stand-in for the system's search index received.
@MainActor
final class SpotlightRecorder {
    var calls: [String] = []
    var failAdd = false
    /// The items the offer is built from.
    var items: [LibraryItem] = []
    /// Holds the next removal until it is let go.
    var holdNextRemoval = false
    var held: CheckedContinuation<Void, Never>?

    @available(iOS 27, *)
    func index() -> SpotlightIndex.Index<AudiobookEntity> { index(naming: \.itemId) }

    /// The index of one kind; `name` gives what a call writes for an entity.
    @available(iOS 27, *)
    func index<Entity>(naming name: @escaping (Entity) -> String) -> SpotlightIndex.Index<Entity> {
        SpotlightIndex.Index(
            removeAll: {
                self.calls.append("remove")
                if self.holdNextRemoval {
                    self.holdNextRemoval = false
                    await withCheckedContinuation { self.held = $0 }
                }
            },
            add: { entities in
                if self.failAdd { throw URLError(.cannotWriteToFile) }
                self.calls.append("add " + entities.map(name).sorted().joined(separator: ","))
            })
    }
}

struct ShortcutBooksTests {
    private func item(_ id: String, title: String?, author: String? = "A") -> LibraryItem {
        LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: title, authorName: author, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil,
                                              description: nil),
                duration: 10, chapters: nil, tracks: nil),
            addedAt: 1)
    }

    private let tagOf = OutwardServerTag.tagOf(
        owners: OutwardItemRefTests.owners(["a": OutwardItemRefTests.serverA, "b": OutwardItemRefTests.serverA,
                                            "c": OutwardItemRefTests.serverA]),
        salt: OutwardItemRefTests.saltA)

    @Test("the rows hold, the shortcut finds the books")
    func theRowsCarry() async throws {
        let store = try await LibraryRowStore(connection: try SQLiteConnection(path: ":memory:"))
        _ = try await store.replaceAll(LibraryDiskCache(items: [item("a", title: "Alpha"), item("b", title: "Beta"),
                                                                item("c", title: nil)],
                                                        progress: [:]))
        let books = await BookQuery.books(rows: store, tagOf: tagOf)
        #expect(books.map(\.title) == ["Alpha", "Beta"], "a title is what makes a book; the one without stays out")
        #expect(books.first?.author == "A")
        #expect(books.map(\.itemId) == ["a", "b"])
        #expect(books.map(\.id) == ["a", "b"].map { OutwardItemRef.ref(itemId: $0, serverTag: tagOf($0)) },
                "the entity's id is the outward id")
    }

    @Test("empty rows or none: no books, no error")
    func nothingIsNothing() async throws {
        let store = try await LibraryRowStore(connection: try SQLiteConnection(path: ":memory:"))
        #expect(await BookQuery.books(rows: store, tagOf: tagOf).isEmpty)
        #expect(await BookQuery.books(rows: nil, tagOf: tagOf).isEmpty)
    }

    @Test("a book without an owner is not offered")
    func noOwnerNoBook() {
        let books = BookQuery.books(from: [item("a", title: "Alpha"), item("unowned", title: "Ohne")], tagOf: tagOf)
        #expect(books.map(\.itemId) == ["a"])
    }

    @Test("the outward id, a foreign id and an old id find their book")
    func theIdentifiersFindTheirBooks() throws {
        let items = [item("a", title: "Alpha"), item("b", title: "Beta")]
        let own = try #require(BookQuery.books(from: items, tagOf: tagOf).first?.id)
        let otherTag = try #require(OutwardServerTag.tag(owner: OutwardItemRefTests.serverA, salt: OutwardItemRefTests.saltB))
        let fromAnotherDevice = try #require(OutwardItemRef.ref(itemId: "b", serverTag: otherTag))
        let found = BookQuery.books(for: [own, fromAnotherDevice, "a", "abs.\(otherTag).gone", "gone"], in: items, tagOf: tagOf)
        #expect(found.map(\.itemId) == ["a", "b", "a"],
                "an outward id, one from another device and a library id of an older shortcut")
        #expect(found.last?.id == own, "an older id is answered with its outward id where there is one")
    }

    /// Without a register or without a salt no item has a tag: an older
    /// shortcut still finds its book in the rows, an outward id does not.
    @Test("an old id finds its book without a register and without a salt")
    func anOlderIdNeedsNoRegisterAndNoSalt() throws {
        let items = [item("a", title: "Alpha"), item("c", title: nil)]
        let noTag: (String) -> String? = { _ in nil }
        let ref = try #require(OutwardItemRef.ref(itemId: "a", serverTag: tagOf("a")))
        let found = BookQuery.books(for: ["a", ref, "c", "gone"], in: items, tagOf: noTag)
        #expect(found.map(\.itemId) == ["a"], "the older id finds its book; the outward id, a book without a title and an unknown id do not")
        #expect(found.first?.id == "a", "without a tag the book keeps the id the shortcut holds")
        #expect(BookQuery.books(from: items, tagOf: noTag).isEmpty, "nothing new is offered without a tag")
    }

    @Test("the audiobook of the audio domain carries what the row knows, and the same id")
    @available(iOS 27, *)
    func theAudiobookCarriesTheRow() throws {
        let row = LibraryItem(
            id: "a",
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "Alpha", authorName: "A", narratorName: "N",
                                              seriesName: "S", genres: ["Krimi", "Hoerspiel"], publishedYear: nil,
                                              description: nil),
                duration: 10, chapters: nil, tracks: nil),
            addedAt: 1)
        let book = try #require(BookQuery.books(from: [row], tagOf: tagOf).first)
        let audiobook = AudiobookEntity(book)
        #expect(audiobook.id == book.id, "one outward id for both entities")
        #expect(audiobook.itemId == "a")
        #expect(audiobook.title == "Alpha")
        #expect(audiobook.author == "A")
        #expect(audiobook.narrator == "N")
        #expect(audiobook.seriesTitle == "S")
        #expect(audiobook.genre == "Krimi, Hoerspiel")
        #expect(audiobook.publisher == nil && audiobook.purchaseDate == nil && audiobook.releaseDate == nil,
                "a field the library does not hold stays empty")
    }

    /// The build exports the entity under the audio schema: without it the
    /// metadata of the whole target are missing and no intent works.
    @Test("the build exports the audiobook under the audio domain schema")
    func theBuildExportsTheAudiobook() throws {
        let url = try #require(Bundle.main.url(forResource: "extract", withExtension: "actionsdata",
                                               subdirectory: "Metadata.appintents"),
                               "the app carries no App Intents metadata")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])
        let entities = try #require(json["entities"] as? [String: Any])
        let entity = try #require(entities["AudiobookEntity"], "the audiobook entity is not exported")
        let text = String(describing: entity)
        #expect(text.contains("MediaBookEntity") && text.contains("audio"), "not under the audio schema: \(text.prefix(300))")
    }

    @Test("Siri's question: nothing named is continue listening, a search finds title and author")
    func whatSiriAsksFinds() {
        let books = BookQuery.books(from: [item("a", title: "Der Zauberberg", author: "Thomas Mann"),
                                           item("b", title: "Die unendliche Geschichte", author: "Michael Ende"),
                                           item("c", title: "Effi Briest", author: "Theodor Fontane")], tagOf: tagOf)
        let ids = { (ask: AudioAsk, last: String?) in AudioAsk.books(for: ask, in: books, lastPlayedId: last).map(\.itemId) }
        #expect(ids(.unnamed, "c") == ["c"], "nothing named continues the last played book")
        #expect(ids(.unnamed, "rss:feed:episode").isEmpty, "the last played title is no book on offer")
        #expect(ids(.unnamed, nil).isEmpty)
        #expect(ids(.search("zauberberg"), nil) == ["a"], "a search ignores case")
        #expect(ids(.search("Fontané"), nil) == ["c"], "a search ignores accents and finds the author")
        #expect(ids(.search("  "), nil).isEmpty, "an empty search finds nothing")
        #expect(ids(.unanswered, "a").isEmpty, "an address is not answered")
        #expect(AudioAsk.search("geheim").kind == "search", "the log line names the kind, never the words")
    }

    private func show(_ id: String, title: String, episodes: [(String, String, Double)]) -> PodcastShow {
        PodcastShow(id: id, title: title, feedURL: "https://feeds.example.org/\(id)",
                    episodes: episodes.map { PodcastEpisode(guid: $0.0, title: $0.1, audioURL: "https://x.example/a.mp3",
                                                            pubDate: $0.2, duration: 0) })
    }

    @Test("episodes of the subscribed feeds, newest first; Audiobookshelf not yet")
    func theEpisodesOnOffer() {
        let shows = [show("k1", title: "Zeitfragen", episodes: [("rss:k1:a", "Alt", 1_000_000), ("rss:k1:b", "Neu", 2_000_000)]),
                     show("abs", title: "Server", episodes: [("abspod:s:e", "Vom Server", 3_000_000)])]
        let offers = EpisodeOffer.episodes(from: shows)
        #expect(offers.map(\.itemId) == ["rss:k1:b", "rss:k1:a"], "newest first, no episode of a server")
        #expect(offers.first?.showTitle == "Zeitfragen")
        #expect(offers.first?.released == Date(timeIntervalSince1970: 2_000), "the release from the feed's milliseconds")
        #expect(offers.first?.duration == nil, "an unknown length stays empty")
    }

    @Test("Siri's question finds episodes by title and show, nothing named the one heard last")
    func whatSiriAsksFindsEpisodes() {
        let offers = EpisodeOffer.episodes(from: [
            show("k1", title: "Forschung aktuell", episodes: [("rss:k1:a", "Café im Weltall", 1_000)]),
            show("k2", title: "Zeitfragen", episodes: [("rss:k2:b", "Wasser", 2_000)])])
        let ids = { (ask: AudioAsk, last: String?) in AudioAsk.episodes(for: ask, in: offers, lastPlayedId: last).map(\.itemId) }
        #expect(ids(.unnamed, "rss:k2:b") == ["rss:k2:b"], "nothing named continues the last played episode")
        #expect(ids(.unnamed, "a-book").isEmpty)
        #expect(ids(.search("cafe"), nil) == ["rss:k1:a"], "the title, without accents")
        #expect(ids(.search("zeitfragen"), nil) == ["rss:k2:b"], "the show's title")
        #expect(ids(.unanswered, "rss:k1:a").isEmpty)
    }

    /// Every episode is asked, the answer to Siri is a handful: at most
    /// the limit, the newest across all shows first.
    @Test("Siri's answer about episodes is limited, the newest first")
    func theEpisodeAnswerIsBounded() {
        let shows = (0..<3).map { s in
            show("k\(s)", title: "Sendung \(s)",
                 episodes: (0..<10).map { e in ("rss:k\(s):g\(e)", "Wasser \(e)", Double((e * 3 + s) * 1000)) })
        }
        let answer = EpisodeOffer.answer(for: .search("wasser"), in: shows, lastPlayedId: nil, limit: BookQuery.suggestionLimit)
        #expect(answer.count == BookQuery.suggestionLimit, "30 hits, the answer holds the limit")
        #expect(answer.first?.itemId == "rss:k2:g9", "the newest across all shows comes first")
        #expect(answer.map(\.released) == answer.map(\.released).sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) })
        #expect(EpisodeOffer.answer(for: .unnamed, in: shows, lastPlayedId: "rss:k0:g0", limit: 12).map(\.itemId) == ["rss:k0:g0"],
                "an old last played episode is still found")
    }

    /// The episodes are worked out off the main actor; only the shows are
    /// read there.
    @Test("the episodes are worked out off the main actor", .needsTheSources)
    func theEpisodesAreWorkedOutOffMain() throws {
        let shortcuts = try FetchAnswerTests.squeezedSource("Sources/AppShortcuts.swift")
        #expect(shortcuts.contains("let shows = await shows() return await Task.detached(priority: .userInitiated) { work(shows) }.value"))
        #expect(!shortcuts.contains("EpisodeOffer.episodes(from: PodcastShowSources.active())"), "the episodes are built on the main actor")
        #expect(shortcuts.contains("let episodes = await PodcastEpisodeQuery.answer(for: ask, lastPlayedId: lastPlayed)"))
    }

    /// The prints of a pass are worked out off the main actor, for both
    /// kinds through the one way, and the pass waits for them in line.
    @Test("the prints of a pass are formed off the main actor", .needsTheSources)
    func thePrintsAreWorkedOutOffMain() throws {
        let shortcuts = try FetchAnswerTests.squeezedSource("Sources/AppShortcuts.swift")
        #expect(shortcuts.contains("nonisolated static func prints<Entity: Sendable>(of offer: [Entity]) async -> Set<String> { await Task.detached(priority: .userInitiated) { Set(offer.map(fingerprint)) }.value }"),
                "the prints are not worked out off the main actor")
        #expect(shortcuts.contains("let printed = await Self.prints(of: offer) guard pass(offer: printed, indexed: indexed) == .replace"),
                "the pass does not take the prints from beside the main actor")
        #expect(shortcuts.components(separatedBy: "map(fingerprint)").count == 2, "a print is worked out a second way")
    }

    /// Siri's search asks the stations the door resolves, the one list the
    /// lookup by id reads.
    @Test("Siri's search asks the stations the door resolves", .needsTheSources)
    func theSearchAsksTheStations() throws {
        let shortcuts = try FetchAnswerTests.squeezedSource("Sources/AppShortcuts.swift")
        #expect(shortcuts.contains("static func stations() -> [RadioStation] { RadioStore.onHand() }"), "the offer is another list")
        #expect(shortcuts.contains("let stations = AudioAsk.stations(for: ask, in: RadioStationQuery.stations(), lastPlayedId: lastPlayed)"),
                "Siri's search does not ask the stations")
        #expect(shortcuts.contains("+ stations.map { .station(RadioStationEntity($0)) }"), "the stations found are not answered")
        #expect(shortcuts.contains("let lists = AudioAsk.lists(for: ask, in: await PlaylistQuery.lists().playlists)"), "Siri's search does not ask the lists")
        #expect(shortcuts.contains("+ lists.map { .playlist(PlaylistEntity($0)) }"), "the lists found are not answered")
        let radio = try FetchAnswerTests.squeezedSource("Sources/Models/RadioModels.swift")
        #expect(radio.contains("static func station(forId id: String, defaults: UserDefaults = .standard) -> RadioStation? { onHand(defaults: defaults).first { $0.id == id } }"),
                "the lookup by id reads another list than the offer")
    }

    @Test("the build exports show and episode under the audio domain schema")
    func theBuildExportsShowAndEpisode() throws {
        let url = try #require(Bundle.main.url(forResource: "extract", withExtension: "actionsdata",
                                               subdirectory: "Metadata.appintents"))
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])
        let entities = try #require(json["entities"] as? [String: Any])
        let show = String(describing: try #require(entities["PodcastShowEntity"], "the show is not exported"))
        let episode = String(describing: try #require(entities["PodcastEpisodeEntity"], "the episode is not exported"))
        #expect(show.contains("PodcastShowEntity") && show.contains("audio"), "\(show.prefix(300))")
        #expect(episode.contains("PodcastEpisodeEntity") && episode.contains("audio"), "\(episode.prefix(300))")
    }

    /// The stations on offer are the ones that resolve by id beyond this
    /// session: a catalog station held only for the session is not offered.
    @Test("the stations on offer: favorite, own address, heard last, each once, none only of the session")
    @MainActor
    func theStationsOnOffer() {
        let suiteName = "siri-stations-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let favorite = RadioStation(id: "radio:rb:fav-\(UUID().uuidString)", name: "Favorit", streamURL: "https://a.example/s")
        let manual = RadioStation(id: "radio:manual:\(UUID().uuidString)", name: "Eigene", streamURL: "https://b.example/s")
        let recent = RadioStation(id: "radio:rb:recent-\(UUID().uuidString)", name: "Zuletzt", streamURL: "https://c.example/s")
        let session = RadioStation(id: "radio:rb:session-\(UUID().uuidString)", name: "Sitzung", streamURL: "https://d.example/s")
        RadioStore.replaceFavorites([favorite], defaults: defaults)
        RadioStore.addManual(manual, defaults: defaults)
        RadioStore.recordRecent(recent, defaults: defaults)
        RadioStore.recordRecent(favorite, defaults: defaults)
        #expect(RadioStore.onHand(defaults: defaults).map(\.id) == [favorite.id, manual.id, recent.id],
                "each station once, favorites first")
        RadioProvider.shared.remember([session])
        #expect(RadioProvider.shared.station(forId: session.id) != nil, "the session station resolves for now")
        #expect(!RadioStore.onHand(defaults: defaults).contains { $0.id == session.id }, "a station of the session alone is not offered")
        #expect(RadioStore.station(forId: recent.id, defaults: defaults)?.name == "Zuletzt", "the lookup reads the same list")
    }

    /// Siri's ask finds a station by its name, and nothing named continues
    /// a station that played last.
    @Test("Siri's question finds stations by name, nothing named continues a station")
    func theAskFindsStations() {
        let cafe = RadioStation(id: "radio:rb:cafe", name: "Radio Café", streamURL: "https://a.example/s")
        let swr = RadioStation(id: "radio:manual:swr", name: "SWR3", streamURL: "https://b.example/s")
        #expect(AudioAsk.stations(for: .search("cafe"), in: [cafe, swr], lastPlayedId: nil).map(\.id) == ["radio:rb:cafe"])
        #expect(AudioAsk.stations(for: .unnamed, in: [cafe, swr], lastPlayedId: "radio:manual:swr").map(\.id) == ["radio:manual:swr"])
        #expect(AudioAsk.stations(for: .unnamed, in: [cafe, swr], lastPlayedId: "rss:a:b").isEmpty, "an episode last is no station")
        #expect(AudioAsk.stations(for: .unanswered, in: [cafe, swr], lastPlayedId: nil).isEmpty)
    }

    /// Siri's ask finds a list by its name; nothing named continues a
    /// title, never a list.
    @Test("Siri's question finds own lists by name, nothing named no list")
    func theAskFindsLists() {
        let morning = MaerPlaylists.Playlist(id: "l1", name: "Morgenrunde", updatedAt: 0, itemIds: [])
        let road = MaerPlaylists.Playlist(id: "l2", name: "Autofahrt", updatedAt: 0, itemIds: [])
        #expect(AudioAsk.lists(for: .search("morgen"), in: [morning, road]).map(\.id) == ["l1"])
        #expect(AudioAsk.lists(for: .unnamed, in: [morning, road]).isEmpty, "nothing named continues a title")
        #expect(AudioAsk.lists(for: .unanswered, in: [morning, road]).isEmpty)
    }

    /// What the app says for a list request: nothing when the list starts,
    /// that it starts nothing, or that it is not here.
    @Test("what the app says about a list: nothing if it starts, otherwise why")
    @available(iOS 27, *)
    func whatTheAppSaysForAList() {
        let list = MaerPlaylists.Playlist(id: "l1", name: "Morgenrunde", updatedAt: 0, itemIds: [])
        let nothing = PlaylistStart.sentence(for: .start(list), started: false)
        let notHere = PlaylistStart.sentence(for: .missing, started: false)
        #expect(PlaylistStart.sentence(for: .start(list), started: true) == nil)
        #expect(nothing != nil && notHere != nil && nothing != notHere)
        #expect(PlaylistStart.sentence(for: .wait, started: false) == notHere, "a list the start read has not reached is not here for Siri")
    }

    /// A list goes through the one start of lists in the background; the app
    /// comes to the front only to say why nothing started.
    @Test("Siri's list starts through the start of lists, to the front only with a sentence")
    @available(iOS 27, *)
    @MainActor
    func aListStartsThroughTheStartOfLists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("siri-lists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        let mine = store.create(name: "Morgenrunde")
        let keptStart = PlaylistStart.start
        let keptSay = PlaylistStart.say
        defer {
            PlaylistStart.start = keptStart
            PlaylistStart.say = keptSay
        }
        var started: [String] = []
        var said: [String] = []
        var fronts = 0
        var startsSomething = true
        PlaylistStart.start = { list in
            started.append(list.id)
            return startsSomething
        }
        PlaylistStart.say = { said.append($0) }
        let front: @MainActor () async throws -> Bool = {
            fronts += 1
            return true
        }

        try await PlaylistStart.run(listId: mine.id, in: store, bringsAppToFront: front)
        #expect(started == [mine.id], "the list goes through the start of lists")
        #expect(fronts == 0 && said.isEmpty, "a list that starts stays in the background")
        startsSomething = false
        try await PlaylistStart.run(listId: mine.id, in: store, bringsAppToFront: front)
        #expect(fronts == 1 && said == [PlaylistStart.sentence(for: .start(mine), started: false)], "\(said)")
        try await PlaylistStart.run(listId: "gone-\(UUID().uuidString)", in: store, bringsAppToFront: front)
        #expect(started.count == 2, "a list that is not here starts nothing")
        #expect(fronts == 2 && said.last == PlaylistStart.sentence(for: .missing, started: false), "\(said)")
    }

    @Test("the build exports the own list under the audio domain schema")
    func theBuildExportsTheList() throws {
        let url = try #require(Bundle.main.url(forResource: "extract", withExtension: "actionsdata",
                                               subdirectory: "Metadata.appintents"))
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])
        let entities = try #require(json["entities"] as? [String: Any])
        let list = String(describing: try #require(entities["PlaylistEntity"], "the list is not exported"))
        #expect(list.contains("PlaylistEntity") && list.contains("audio"), "\(list.prefix(300))")
    }

    @Test("the build exports the station under the audio domain schema")
    func theBuildExportsTheStation() throws {
        let url = try #require(Bundle.main.url(forResource: "extract", withExtension: "actionsdata",
                                               subdirectory: "Metadata.appintents"))
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])
        let entities = try #require(json["entities"] as? [String: Any])
        let station = String(describing: try #require(entities["RadioStationEntity"], "the station is not exported"))
        #expect(station.contains("RadioStationEntity") && station.contains("audio"), "\(station.prefix(300))")
    }

    /// A shortcut's search and Siri's search are one search: title and
    /// author, without case or accents, and one limit for suggestions.
    @Test("the shortcuts' search is Siri's search, with one limit")
    func theShortcutSearchIsSirisSearch() {
        let books = BookQuery.books(from: [item("a", title: "Der Zauberberg", author: "Thomas Mann"),
                                           item("c", title: "Effi Briest", author: "Theodor Fontane")], tagOf: tagOf)
        #expect(BookQuery.matching("fontane", in: books).map(\.itemId) == ["c"], "the author is found")
        #expect(BookQuery.matching("Fontané", in: books).map(\.itemId) == ["c"], "accents are folded")
        #expect(BookQuery.matching("zauber", in: books).map(\.itemId) == ["a"])
        #expect(BookQuery.matching("Fontané", in: books).map(\.itemId)
                == AudioAsk.books(for: .search("Fontané"), in: books, lastPlayedId: nil).map(\.itemId))
        let many = BookQuery.books(from: (0..<20).map { item("m\($0)", title: "T\($0)") },
                                   tagOf: { _ in OutwardServerTag.tag(owner: OutwardItemRefTests.serverA, salt: OutwardItemRefTests.saltA) })
        #expect(BookQuery.suggested(in: many).count == BookQuery.suggestionLimit)
    }

    @Test("both book queries ask the one search and the one limit", .needsTheSources)
    func bothQueriesAskTheOneSearch() throws {
        let shortcuts = try FetchAnswerTests.squeezedSource("Sources/AppShortcuts.swift")
        #expect(!shortcuts.contains("title.localizedCaseInsensitiveContains"), "a book query searches on its own")
        #expect(!shortcuts.contains("prefix(12)"), "the limit stands twice")
        #expect(shortcuts.contains("return BookQuery.matching(string, in: BookQuery.books(from: now.items, tagOf: now.tagOf)).map(AudiobookEntity.init)"))
        #expect(shortcuts.contains("return Self.matching(string, in: Self.books(from: now.items, tagOf: now.tagOf))"))
    }

    /// The build exports Siri's play under the audio schema, and its search.
    @Test("the build exports Siri's play under the audio domain schema")
    func theBuildExportsThePlay() throws {
        let url = try #require(Bundle.main.url(forResource: "extract", withExtension: "actionsdata",
                                               subdirectory: "Metadata.appintents"))
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])
        let actions = try #require(json["actions"] as? [String: Any])
        let play = try #require(actions["PlayAudioIntent"], "Siri's play is not exported")
        let text = String(describing: play)
        #expect(text.contains("PlayAudioIntent") && text.contains("audio"), "not under the audio schema: \(text.prefix(300))")
    }

    /// Siri's play starts a title through the one door of continue
    /// listening, never a way of its own.
    @Test("Siri's play goes through the one door of continue listening", .needsTheSources)
    func thePlayGoesThroughTheDoor() throws {
        let shortcuts = try FetchAnswerTests.squeezedSource("Sources/AppShortcuts.swift")
        #expect(shortcuts.contains("switch audioEntity.start { case .item(let itemId): try await ResumeListeningIntent.run(itemId: itemId)"),
                "Siri's title does not go through the door")
        #expect(shortcuts.contains("case .list(let listId): try await PlaylistStart.run(listId: listId, in: PlaylistQuery.lists())"),
                "Siri's list does not go through the start of lists")
        #expect(shortcuts.contains("await RoutinePlayback.start(list, in: PlaylistQuery.lists(), on: coordinator)"),
                "the start of a list is a way of its own")
        #expect(shortcuts.contains("case .audiobook(let book): .item(book.itemId) case .episode(let episode): .item(episode.id) case .station(let station): .item(station.id) case .playlist(let list): .list(list.id)"),
                "a kind starts something else than its id of the app")
        #expect(!shortcuts.contains("resume(namedItemId:"), "a way of its own beside the door")
        let widget = try FetchAnswerTests.squeezedSource("Sources/Models/WidgetShared.swift")
        #expect(widget.contains("try await Self.run(itemId: itemId) { try await Self.opensApp(self) }"),
                "the widget's command left the shared run")
    }

    @Test("the playing title tells Siri its book, only with the outward id")
    @available(iOS 27, *)
    func thePlayingTitleNamesItsBook() {
        #expect(NowPlayingEntities.ref(forItem: "a", tagOf: tagOf) == OutwardItemRef.ref(itemId: "a", serverTag: tagOf("a")))
        #expect(NowPlayingEntities.ref(forItem: "a", tagOf: tagOf) != nil)
        #expect(NowPlayingEntities.ref(forItem: "unowned", tagOf: tagOf) == nil, "a book without an owner")
        #expect(NowPlayingEntities.ref(forItem: "rss:feed:episode", tagOf: tagOf) == nil, "an episode is no book")
        #expect(NowPlayingEntities.ref(forItem: nil, tagOf: tagOf) == nil)
    }

    /// The info is written on every event of the playback: the device's
    /// tags are read once per title, never for a title with a namespace.
    @Test("the id of the playing title is worked out once per title")
    @available(iOS 27, *)
    @MainActor
    func theIdentifiersAreWorkedOutOncePerTitle() {
        let owned = "li_\(UUID().uuidString)"
        let other = "li_\(UUID().uuidString)"
        let owners = OutwardItemRefTests.owners([owned: OutwardItemRefTests.serverA, other: OutwardItemRefTests.serverA])
        var reads = 0
        let tags: () -> ((String) -> String?)? = {
            reads += 1
            return OutwardServerTag.tagOf(owners: owners, salt: OutwardItemRefTests.saltA)
        }
        #expect(NowPlayingEntities.identifiers(forItem: owned, tagOf: tags).count == 1)
        #expect(NowPlayingEntities.identifiers(forItem: owned, tagOf: tags).count == 1)
        #expect(reads == 1, "the second write of the same title reads nothing")
        #expect(NowPlayingEntities.identifiers(forItem: other, tagOf: tags).count == 1)
        #expect(reads == 2, "another title is worked out anew")
        #expect(NowPlayingEntities.identifiers(forItem: "rss:feed:\(UUID().uuidString)", tagOf: tags).isEmpty)
        #expect(reads == 2, "a title with a namespace reads nothing")
        #expect(NowPlayingEntities.identifiers(forItem: "li_\(UUID().uuidString)", tagOf: { nil }).isEmpty,
                "without salt or register no entity")
    }

    /// A book often plays for days: an empty answer gives way when the
    /// register gets a new stand, and an unreadable salt is asked again
    /// after a minute, without a read on every write in between.
    @Test("an empty result gives way to a new stand of the register and after a minute")
    @available(iOS 27, *)
    @MainActor
    func anEmptyAnswerGivesWay() {
        let book = "li_\(UUID().uuidString)"
        let start = Date()
        var reads = 0
        var owners = ItemOwners()
        let tags: () -> ((String) -> String?)? = {
            reads += 1
            return OutwardServerTag.tagOf(owners: owners, salt: OutwardItemRefTests.saltA)
        }
        #expect(NowPlayingEntities.identifiers(forItem: book, tagOf: tags, generation: 7, now: start).isEmpty,
                "no owner yet")
        #expect(NowPlayingEntities.identifiers(forItem: book, tagOf: tags, generation: 7, now: start + 30).isEmpty)
        #expect(reads == 1, "the same stand within the minute reads nothing")
        owners.noteFullLoad(ids: [book], server: OutwardItemRefTests.serverA)
        #expect(NowPlayingEntities.identifiers(forItem: book, tagOf: tags, generation: 8, now: start + 31).count == 1,
                "the register's new stand gives the entity while the same book plays")
        #expect(reads == 2)
        #expect(NowPlayingEntities.identifiers(forItem: book, tagOf: tags, generation: 9, now: start + 999).count == 1)
        #expect(reads == 2, "a found entity holds for its title")

        let locked = "li_\(UUID().uuidString)"
        var saltReadable = false
        let lockedTags: () -> ((String) -> String?)? = {
            reads += 1
            guard saltReadable else { return nil }
            return OutwardServerTag.tagOf(owners: OutwardItemRefTests.owners([locked: OutwardItemRefTests.serverA]),
                                          salt: OutwardItemRefTests.saltA)
        }
        #expect(NowPlayingEntities.identifiers(forItem: locked, tagOf: lockedTags, generation: 9, now: start).isEmpty,
                "a locked keychain gives no salt")
        saltReadable = true
        #expect(NowPlayingEntities.identifiers(forItem: locked, tagOf: lockedTags, generation: 9, now: start + 59).isEmpty)
        #expect(reads == 3, "within the minute nothing is read")
        #expect(NowPlayingEntities.identifiers(forItem: locked, tagOf: lockedTags, generation: 9, now: start + 61).count == 1,
                "after the minute the salt is asked again")
    }

    @Test("a remembered result holds for its title, empty only with the same stand and within the period")
    @available(iOS 27, *)
    func whenAKeptAnswerHolds() {
        let at = Date()
        let holds = { (count: Int, kept: Int, now: Int, after: TimeInterval, asked: String?) in
            NowPlayingEntities.holds(itemId: "a", identifiers: count, generation: kept, at: at,
                                     for: asked, generation: now, now: at + after)
        }
        #expect(holds(1, 1, 2, 9999, "a"), "a found entity holds")
        #expect(!holds(1, 1, 1, 0, "b"), "another title never holds")
        #expect(holds(0, 1, 1, 59, "a"), "empty, same stand, within the minute")
        #expect(!holds(0, 1, 2, 0, "a"), "empty gives way to a new stand")
        #expect(!holds(0, 1, 1, NowPlayingEntities.emptyHolds, "a"), "empty gives way after the minute")
    }

    @Test("a written register counts its stand")
    func aWrittenRegisterCountsItsStand() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("owners-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let shelf = ItemOwnerShelf(file: dir.appendingPathComponent("item-owners.json"))
        let before = OutwardServerTag.registerGeneration
        shelf.write(OutwardItemRefTests.owners(["a": OutwardItemRefTests.serverA]), afterCorruptRead: false)
        #expect(OutwardServerTag.registerGeneration > before, "a written register is a new stand")
        let after = OutwardServerTag.registerGeneration
        shelf.write(ItemOwners(), afterCorruptRead: true)
        #expect(OutwardServerTag.registerGeneration == after, "a write that does not happen is no new stand")
    }

    @Test("Spotlight stays with the same set, replaces with any other")
    @available(iOS 27, *)
    func whenSpotlightChanges() {
        #expect(SpotlightIndex.pass(offer: ["a", "b"], indexed: ["b", "a"]) == .keep)
        #expect(SpotlightIndex.pass(offer: ["a"], indexed: ["a", "b"]) == .replace, "a book left")
        #expect(SpotlightIndex.pass(offer: ["a", "c"], indexed: ["a"]) == .replace, "a book came")
        #expect(SpotlightIndex.pass(offer: ["a"], indexed: nil) == .replace, "unknown is set anew")
        #expect(SpotlightIndex.pass(offer: [], indexed: []) == .keep)
    }

    /// The index is set to what is on offer, through the one place, and a
    /// sign out takes every book out; the system index stands in as a list.
    @Test("Spotlight holds exactly the offered books, the sign out takes all out")
    @available(iOS 27, *)
    @MainActor
    func spotlightCarriesTheOffer() async {
        let kept = SpotlightIndex.index
        defer { SpotlightIndex.index = kept }
        let index = SpotlightRecorder()
        SpotlightIndex.index = index.index()
        let shelf = [item("a", title: "Alpha"), item("b", title: "Beta"), item("unowned", title: "Ohne")]
        index.items = shelf
        let tagOf = self.tagOf
        let offer: @MainActor () async -> [BookEntity] = { BookQuery.books(from: index.items, tagOf: tagOf) }
        let signedIn: @MainActor () -> Bool = { true }

        await SpotlightIndex.forget()
        index.calls = []
        await SpotlightIndex.reconcile(books: offer, signedIn: signedIn)
        #expect(index.calls == ["remove", "add a,b"], "the books on offer replace the index, the one without an owner stays out")
        await SpotlightIndex.reconcile(books: offer, signedIn: signedIn)
        #expect(index.calls == ["remove", "add a,b"], "the same books change nothing")
        index.items = [shelf[0]]
        await SpotlightIndex.reconcile(books: offer, signedIn: signedIn)
        #expect(index.calls == ["remove", "add a,b", "remove", "add a"], "a book that left goes out")
        index.failAdd = true
        index.items = shelf
        await SpotlightIndex.reconcile(books: offer, signedIn: signedIn)
        index.failAdd = false
        await SpotlightIndex.reconcile(books: offer, signedIn: signedIn)
        #expect(Array(index.calls.suffix(3)) == ["remove", "remove", "add a,b"], "after a failure the next pass sets the index again")
        await SpotlightIndex.forget()
        #expect(index.calls.last == "remove", "the sign out takes every book out")
        let count = index.calls.count
        await SpotlightIndex.reconcile(books: { [] }, signedIn: signedIn)
        #expect(index.calls.count == count, "nothing on offer after the sign out changes nothing")
    }

    /// A pass that suspends at the index and a sign out asked meanwhile:
    /// the sign out comes last, and nothing of the account stays in the
    /// search.
    @Test("a sign out during a pass leaves no book in the search")
    @available(iOS 27, *)
    @MainActor
    func aSignOutDuringAPassLeavesNothing() async {
        let kept = SpotlightIndex.index
        defer { SpotlightIndex.index = kept }
        let index = SpotlightRecorder()
        SpotlightIndex.index = index.index()
        index.items = [item("a", title: "Alpha"), item("b", title: "Beta")]
        let tagOf = self.tagOf
        await SpotlightIndex.forget()
        index.calls = []

        index.holdNextRemoval = true
        let pass = Task { @MainActor in
            await SpotlightIndex.reconcile(books: { BookQuery.books(from: index.items, tagOf: tagOf) }, signedIn: { true })
        }
        while index.held == nil { await Task.yield() }
        let signOut = Task { @MainActor in await SpotlightIndex.forget() }
        for _ in 0..<20 { await Task.yield() }
        index.held?.resume()
        index.held = nil
        await pass.value
        await signOut.value
        #expect(index.calls == ["remove", "add a,b", "remove"], "the sign out runs after the pass: \(index.calls)")
    }

    /// A load still under way when the person signs out finishes later and
    /// asks a pass: no one is signed in, so it adds nothing.
    @Test("a pass after the sign out adds nothing")
    @available(iOS 27, *)
    @MainActor
    func aPassAfterTheSignOutAddsNothing() async {
        let kept = SpotlightIndex.index
        defer { SpotlightIndex.index = kept }
        let index = SpotlightRecorder()
        SpotlightIndex.index = index.index()
        index.items = [item("a", title: "Alpha")]
        let tagOf = self.tagOf
        await SpotlightIndex.forget()
        index.calls = []
        await SpotlightIndex.reconcile(books: { BookQuery.books(from: index.items, tagOf: tagOf) }, signedIn: { false })
        #expect(index.calls.isEmpty, "a pass without anyone signed in touches the index: \(index.calls)")
    }

    /// The shows on offer are those with an episode on offer; a pass
    /// compares every field of each entity, so a renamed show is a change
    /// and the same fields are none.
    @Test("the shows on offer for Spotlight, only with an episode on offer")
    @available(iOS 27, *)
    @MainActor
    func theShowsForSpotlight() {
        let feed = show("s1", title: "Feed", episodes: [("rss:a", "Eins", 1)])
        let empty = show("s2", title: "Leer", episodes: [])
        let server = show("s3", title: "Server", episodes: [("abspod:x", "Zwei", 1)])
        let prints = { (shows: [PodcastShow]) in Set(PodcastShowQuery.offer(shows).map(SpotlightIndex.fingerprint)) }
        #expect(PodcastShowQuery.offer([feed, empty, server]).map(\.id) == ["s1"], "only a show with an episode on offer")
        let arrived = show("s2", title: "Leer", episodes: [("rss:b", "Drei", 2)])
        #expect(prints([feed, empty]) != prints([feed, arrived]), "the first episode of a show is a change")
        #expect(prints([feed]) == prints([show("s1", title: "Feed", episodes: [("rss:a", "Eins", 1)])]), "the same fields are none")
        #expect(prints([feed]) != prints([show("s1", title: "Feed neu", episodes: [("rss:a", "Eins", 1)])]), "a renamed show is a change")
    }

    /// Every field that goes into a book's entity is in its print: a book
    /// renamed, by another author, read by another narrator, in another
    /// series or genre asks a pass; the same book asks none.
    @Test("a book's print carries every field that goes into the search")
    @available(iOS 27, *)
    @MainActor
    func aBooksPrintCarriesEveryField() {
        let book = BookEntity(id: "r1", itemId: "a", title: "Alpha", author: "A", narrator: "N", series: "S", genres: ["G"])
        let print = { (book: BookEntity) in SpotlightIndex.fingerprint(AudiobookEntity(book)) }
        #expect(print(book) == print(book), "the same book is no change")
        var changed: [String: BookEntity] = [:]
        changed["title"] = BookEntity(id: "r1", itemId: "a", title: "Beta", author: "A", narrator: "N", series: "S", genres: ["G"])
        changed["author"] = BookEntity(id: "r1", itemId: "a", title: "Alpha", author: "B", narrator: "N", series: "S", genres: ["G"])
        changed["narrator"] = BookEntity(id: "r1", itemId: "a", title: "Alpha", author: "A", narrator: "M", series: "S", genres: ["G"])
        changed["series"] = BookEntity(id: "r1", itemId: "a", title: "Alpha", author: "A", narrator: "N", series: "T", genres: ["G"])
        changed["genre"] = BookEntity(id: "r1", itemId: "a", title: "Alpha", author: "A", narrator: "N", series: "S", genres: ["H"])
        for (field, other) in changed {
            #expect(print(book) != print(other), "a changed \(field) is no change")
        }
    }

    /// A renamed book and a renamed show set the index again; the same
    /// fields leave it.
    @Test("a renamed book and a renamed show trigger a pass, the same fields none")
    @available(iOS 27, *)
    @MainActor
    func aRenameAsksAPass() async {
        let keptBooks = SpotlightIndex.index
        let keptShows = SpotlightIndex.showIndex
        defer {
            SpotlightIndex.index = keptBooks
            SpotlightIndex.showIndex = keptShows
        }
        let books = SpotlightRecorder()
        let shows = SpotlightRecorder()
        SpotlightIndex.index = books.index(naming: { $0.title ?? "" })
        SpotlightIndex.showIndex = shows.index(naming: \.title)
        var title = "Alpha"
        let book = { [BookEntity(id: "r1", itemId: "a", title: title, author: "A", narrator: nil, series: nil, genres: [])] }
        await SpotlightIndex.forget()
        await SpotlightIndex.reconcile(books: { book() }, signedIn: { true })
        await SpotlightIndex.reconcile(books: { book() }, signedIn: { true })
        title = "Beta"
        await SpotlightIndex.reconcile(books: { book() }, signedIn: { true })
        #expect(books.calls == ["remove", "remove", "add Alpha", "remove", "add Beta"], "\(books.calls)")

        var name = "Eins"
        let offer: @MainActor () -> [PodcastShowEntity] = { [PodcastShowEntity(id: "s1", title: name)] }
        await SpotlightIndex.reconcileShows(shows: { [] })
        shows.calls = []
        await SpotlightIndex.reconcileShows(shows: offer)
        await SpotlightIndex.reconcileShows(shows: offer)
        name = "Eins neu"
        await SpotlightIndex.reconcileShows(shows: offer)
        #expect(shows.calls == ["remove", "add Eins", "remove", "add Eins neu"], "\(shows.calls)")
    }

    /// The shows on offer follow what the podcast surface shows: at a cold
    /// start a show on both sides stands by its feed until the server's
    /// shows are read, then the server's copy wins and has no episode on
    /// offer; the switch of the server's podcasts brings the feed's copy
    /// back. Each change asks a pass, and the pass follows.
    @Test("the search follows the shows of the surface: first read of the server and switch")
    @available(iOS 27, *)
    @MainActor
    func theShowsFollowTheSurface() async {
        let keptShows = SpotlightIndex.showIndex
        defer { SpotlightIndex.showIndex = keptShows }
        let shows = SpotlightRecorder()
        SpotlightIndex.showIndex = shows.index(naming: \.id)
        let feed = show("k1", title: "Zeitfragen", episodes: [("rss:k1:a", "Eins", 1)])
        var server = feed
        server.id = "abs-k1"
        server.episodes = [PodcastEpisode(guid: "abspod:s:e", title: "Eins", audioURL: "https://x.example/a.mp3", pubDate: 1, duration: 0)]
        var absShows: [PodcastShow] = []
        let offer: @MainActor () -> [PodcastShowEntity] = { PodcastShowQuery.offer(PodcastShowMerge.merge(abs: absShows, rss: [feed])) }

        await SpotlightIndex.reconcileShows(shows: { [] })
        shows.calls = []
        await SpotlightIndex.showsChanged(shows: offer).value
        #expect(shows.calls == ["remove", "add k1"], "before the server's shows are read the feed stands: \(shows.calls)")
        absShows = [server]
        await SpotlightIndex.showsChanged(shows: offer).value
        #expect(shows.calls == ["remove", "add k1", "remove"], "the first read lets the server's copy win: \(shows.calls)")
        absShows = []
        await SpotlightIndex.showsChanged(shows: offer).value
        #expect(shows.calls == ["remove", "add k1", "remove", "remove", "add k1"], "the switch brings the feed back: \(shows.calls)")
    }

    /// The shows go into the same index through the same line, without the
    /// sign in to Audiobookshelf, and a sign out leaves them.
    @Test("Spotlight holds the shows on offer, the sign out leaves them")
    @available(iOS 27, *)
    @MainActor
    func spotlightCarriesTheShows() async {
        let keptBooks = SpotlightIndex.index
        let keptShows = SpotlightIndex.showIndex
        defer {
            SpotlightIndex.index = keptBooks
            SpotlightIndex.showIndex = keptShows
        }
        let books = SpotlightRecorder()
        let shows = SpotlightRecorder()
        SpotlightIndex.index = books.index()
        SpotlightIndex.showIndex = shows.index(naming: \.id)
        var offer = [PodcastShowEntity(id: "s1", title: "Eins"), PodcastShowEntity(id: "s2", title: "Zwei")]
        let current: @MainActor () -> [PodcastShowEntity] = { offer }

        await SpotlightIndex.reconcileShows(shows: { [] })
        shows.calls = []
        await SpotlightIndex.reconcileShows(shows: current)
        #expect(shows.calls == ["remove", "add s1,s2"], "the shows on offer replace their index")
        await SpotlightIndex.reconcileShows(shows: current)
        #expect(shows.calls == ["remove", "add s1,s2"], "the same shows change nothing")
        offer = [offer[1]]
        await SpotlightIndex.reconcileShows(shows: current)
        #expect(shows.calls == ["remove", "add s1,s2", "remove", "add s2"], "a show that left goes out")
        books.calls = []
        await SpotlightIndex.forget()
        #expect(books.calls == ["remove"], "the sign out takes the books out")
        #expect(shows.calls.count == 4, "the sign out leaves the shows: \(shows.calls)")
        shows.failAdd = true
        offer = [PodcastShowEntity(id: "s3", title: "Drei")]
        await SpotlightIndex.reconcileShows(shows: current)
        shows.failAdd = false
        await SpotlightIndex.reconcileShows(shows: current)
        #expect(Array(shows.calls.suffix(3)) == ["remove", "remove", "add s3"], "after a failure the next pass sets the shows again")
    }

    /// One place adds books and shows to the device's search and takes them
    /// out; the books follow a full list and the sign out, the shows every
    /// writer of what the podcast surface shows: the subscriptions, the
    /// server's shows and their archive, and the switch of the sources.
    @Test("only one place writes Spotlight, after the full list, at the sign out and with the shows of the surface", .needsTheSources)
    func spotlightHasOnePlace() throws {
        var writing: [String] = []
        var reconciling: [String] = []
        var forgetting: [String] = []
        var following: [String] = []
        var asking: [String] = []
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            let squeezed = FetchAnswerTests.squeezed(text)
            if squeezed.contains("indexAppEntities(") || squeezed.contains("deleteAppEntities(")
                || squeezed.contains("CSSearchableIndex") { writing.append(file) }
            if squeezed.contains("SpotlightIndex.reconcile(") { reconciling.append(file) }
            if squeezed.contains("SpotlightIndex.forget(") { forgetting.append(file) }
            if squeezed.contains("SpotlightIndex.reconcileShows(") { following.append(file) }
            if squeezed.contains("SpotlightIndex.showsChanged(") { asking.append(file) }
        }
        #expect(writing == ["AppShortcuts.swift"], "the device's search is written elsewhere: \(writing)")
        #expect(reconciling == ["LibraryViewModel.swift"], "\(reconciling)")
        #expect(forgetting == ["AuthViewModel.swift"], "\(forgetting)")
        #expect(following.isEmpty, "the shows' pass is asked past the one way: \(following)")
        #expect(Set(asking) == ["PodcastSubscriptions.swift", "ABSPodcastProvider.swift", "AppSession.swift"], "\(asking)")
        let server = try FetchAnswerTests.squeezedSource("Sources/Providers/ABSPodcastProvider.swift")
        #expect(server.contains("episodeHandles = handles changeToken += 1 if #available(iOS 27, *) { SpotlightIndex.showsChanged() } }"),
                "the server's shows do not ask a pass where they change")
        #expect(server.contains("AppStorageKeys.set(Array(archivedShowIds), for: Self.archiveKey) changeToken += 1 if #available(iOS 27, *) { SpotlightIndex.showsChanged() } }"),
                "the archive does not ask a pass")
        let session = try FetchAnswerTests.squeezedSource("Sources/AppSession.swift")
        #expect(session.contains("Task { await ContinueRowsWriter.keepStanding { self.provider(for: $0).isAvailable } } if #available(iOS 27, *) { SpotlightIndex.showsChanged() } }"),
                "the switch of the sources does not ask a pass")
        let library = try FetchAnswerTests.squeezedSource("Sources/ViewModels/LibraryViewModel.swift")
        #expect(library.contains("cleanUpPerBook(full: full, bookLibraries: libraries.count) if full != nil, #available(iOS 27, *) { Task { await SpotlightIndex.reconcile() } }"),
                "the pass does not follow the full list")
        let subscriptions = try FetchAnswerTests.squeezedSource("Sources/Providers/PodcastSubscriptions.swift")
        #expect(subscriptions.contains("@Published private var stock: [PodcastShow] = [] { didSet { rebuildCaches() ListeningRevision.shared.bump(\"subscriptions\") if isTheApp, #available(iOS 27, *) { SpotlightIndex.showsChanged() } }"),
                "the shows' pass does not follow the stock")
    }

    @Test("the info on the playing title carries its book", .needsTheSources)
    func theNowPlayingInfoCarriesTheBook() throws {
        let nowPlaying = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerViewModel+NowPlaying.swift")
        #expect(nowPlaying.contains("let identifiers = NowPlayingEntities.identifiers(forItem: item?.id) if !identifiers.isEmpty { info[MPNowPlayingInfoPropertyAppEntityIdentifiers] = identifiers }"),
                "the now playing info does not name the title's entity")
    }
}
#endif
