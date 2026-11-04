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

    @Test("die Zeilen tragen, der Kurzbefehl findet die Buecher")
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

    @Test("leere Zeilen oder keine: keine Buecher, kein Fehler")
    func nothingIsNothing() async throws {
        let store = try await LibraryRowStore(connection: try SQLiteConnection(path: ":memory:"))
        #expect(await BookQuery.books(rows: store, tagOf: tagOf).isEmpty)
        #expect(await BookQuery.books(rows: nil, tagOf: tagOf).isEmpty)
    }

    @Test("ein Buch ohne Besitzer wird nicht angeboten")
    func noOwnerNoBook() {
        let books = BookQuery.books(from: [item("a", title: "Alpha"), item("unowned", title: "Ohne")], tagOf: tagOf)
        #expect(books.map(\.itemId) == ["a"])
    }

    @Test("die Kennung nach aussen, eine fremde und eine alte Kennung finden ihr Buch")
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
    @Test("eine alte Kennung findet ihr Buch ohne Register und ohne Salz")
    func anOlderIdNeedsNoRegisterAndNoSalt() throws {
        let items = [item("a", title: "Alpha"), item("c", title: nil)]
        let noTag: (String) -> String? = { _ in nil }
        let ref = try #require(OutwardItemRef.ref(itemId: "a", serverTag: tagOf("a")))
        let found = BookQuery.books(for: ["a", ref, "c", "gone"], in: items, tagOf: noTag)
        #expect(found.map(\.itemId) == ["a"], "the older id finds its book; the outward id, a book without a title and an unknown id do not")
        #expect(found.first?.id == "a", "without a tag the book keeps the id the shortcut holds")
        #expect(BookQuery.books(from: items, tagOf: noTag).isEmpty, "nothing new is offered without a tag")
    }

    @Test("das Hoerbuch der Audio-Domaene traegt, was die Zeile weiss, und dieselbe Kennung")
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
    @Test("der Bau exportiert das Hoerbuch unter dem Schema der Audio-Domaene")
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

    @Test("Siris Frage: nichts genannt ist Weiterhoeren, eine Suche findet Titel und Autor")
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

    @Test("Folgen der abonnierten Feeds, die neueste zuerst; Audiobookshelf noch nicht")
    func theEpisodesOnOffer() {
        let shows = [show("k1", title: "Zeitfragen", episodes: [("rss:k1:a", "Alt", 1_000_000), ("rss:k1:b", "Neu", 2_000_000)]),
                     show("abs", title: "Server", episodes: [("abspod:s:e", "Vom Server", 3_000_000)])]
        let offers = EpisodeOffer.episodes(from: shows)
        #expect(offers.map(\.itemId) == ["rss:k1:b", "rss:k1:a"], "newest first, no episode of a server")
        #expect(offers.first?.showTitle == "Zeitfragen")
        #expect(offers.first?.released == Date(timeIntervalSince1970: 2_000), "the release from the feed's milliseconds")
        #expect(offers.first?.duration == nil, "an unknown length stays empty")
    }

    @Test("Siris Frage findet Folgen nach Titel und Sendung, nichts genannt die zuletzt gehoerte")
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
    @Test("Siris Antwort ueber Folgen ist begrenzt, die neuesten zuerst")
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
    @Test("die Folgen werden neben dem Haupt-Akteur gerechnet", .needsTheSources)
    func theEpisodesAreWorkedOutOffMain() throws {
        let shortcuts = try FetchAnswerTests.squeezedSource("Sources/AppShortcuts.swift")
        #expect(shortcuts.contains("let shows = await shows() return await Task.detached(priority: .userInitiated) { work(shows) }.value"))
        #expect(!shortcuts.contains("EpisodeOffer.episodes(from: PodcastShowSources.active())"), "the episodes are built on the main actor")
        #expect(shortcuts.contains("let episodes = await PodcastEpisodeQuery.answer(for: ask, lastPlayedId: lastPlayed)"))
    }

    /// Siri's search asks the stations the door resolves, the one list the
    /// lookup by id reads.
    @Test("Siris Suche fragt die Sender, die die Tuer aufloest", .needsTheSources)
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

    @Test("der Bau exportiert Sendung und Folge unter dem Schema der Audio-Domaene")
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
    @Test("die Sender auf Angebot: Favorit, eigene Adresse, zuletzt gehoert, jeder einmal, keiner nur der Sitzung")
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
    @Test("Siris Frage findet Sender nach Name, nichts genannt setzt einen Sender fort")
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
    @Test("Siris Frage findet eigene Listen nach Name, nichts genannt keine Liste")
    func theAskFindsLists() {
        let morning = MaerPlaylists.Playlist(id: "l1", name: "Morgenrunde", updatedAt: 0, itemIds: [])
        let road = MaerPlaylists.Playlist(id: "l2", name: "Autofahrt", updatedAt: 0, itemIds: [])
        #expect(AudioAsk.lists(for: .search("morgen"), in: [morning, road]).map(\.id) == ["l1"])
        #expect(AudioAsk.lists(for: .unnamed, in: [morning, road]).isEmpty, "nothing named continues a title")
        #expect(AudioAsk.lists(for: .unanswered, in: [morning, road]).isEmpty)
    }

    /// What the app says for a list request: nothing when the list starts,
    /// that it starts nothing, or that it is not here.
    @Test("was die App zu einer Liste sagt: nichts, wenn sie startet, sonst warum")
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
    @Test("Siris Liste startet durch den Start der Listen, nach vorn nur mit einem Satz")
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

    @Test("der Bau exportiert die eigene Liste unter dem Schema der Audio-Domaene")
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

    @Test("der Bau exportiert den Sender unter dem Schema der Audio-Domaene")
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
    @Test("die Suche der Kurzbefehle ist die Suche von Siri, mit einer Grenze")
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

    @Test("beide Abfragen der Buecher fragen die eine Suche und die eine Grenze", .needsTheSources)
    func bothQueriesAskTheOneSearch() throws {
        let shortcuts = try FetchAnswerTests.squeezedSource("Sources/AppShortcuts.swift")
        #expect(!shortcuts.contains("title.localizedCaseInsensitiveContains"), "a book query searches on its own")
        #expect(!shortcuts.contains("prefix(12)"), "the limit stands twice")
        #expect(shortcuts.contains("return BookQuery.matching(string, in: BookQuery.books(from: now.items, tagOf: now.tagOf)).map(AudiobookEntity.init)"))
        #expect(shortcuts.contains("return Self.matching(string, in: Self.books(from: now.items, tagOf: now.tagOf))"))
    }

    /// The build exports Siri's play under the audio schema, and its search.
    @Test("der Bau exportiert Siris Wiedergabe unter dem Schema der Audio-Domaene")
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
    @Test("Siris Wiedergabe geht durch die eine Tuer des Weiterhoerens", .needsTheSources)
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

    @Test("der laufende Titel nennt Siri sein Buch, nur mit Kennung nach aussen")
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
    @Test("die Kennung des laufenden Titels wird je Titel einmal gerechnet")
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
    @Test("ein leeres Ergebnis weicht einem neuen Stand des Registers und nach einer Minute")
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

    @Test("ein gemerktes Ergebnis gilt fuer seinen Titel, leer nur bei gleichem Stand und binnen der Frist")
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

    @Test("ein geschriebenes Register zaehlt seinen Stand")
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

    @Test("Spotlight bleibt bei gleicher Menge, ersetzt bei jeder anderen")
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
    @Test("Spotlight traegt genau die angebotenen Buecher, die Abmeldung nimmt alle heraus")
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
    @Test("die Abmeldung waehrend eines Durchgangs laesst kein Buch in der Suche")
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
    @Test("ein Durchgang nach der Abmeldung traegt nichts ein")
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

    /// A change of the subscriptions asks a pass only when the shows on
    /// offer change: a show that comes or leaves, or its first episode.
    @Test("die Sendungen auf Angebot fuer Spotlight, nur mit einer Folge auf Angebot")
    @available(iOS 27, *)
    func theShowsForSpotlight() {
        let feed = show("s1", title: "Feed", episodes: [("rss:a", "Eins", 1)])
        let empty = show("s2", title: "Leer", episodes: [])
        let server = show("s3", title: "Server", episodes: [("abspod:x", "Zwei", 1)])
        #expect(SpotlightIndex.showIds([feed, empty, server]) == ["s1"], "only a show with an episode on offer")
        let arrived = show("s2", title: "Leer", episodes: [("rss:b", "Drei", 2)])
        #expect(SpotlightIndex.showIds([feed, empty]) != SpotlightIndex.showIds([feed, arrived]), "the first episode of a show asks a pass")
        let renamedEpisode = show("s1", title: "Feed", episodes: [("rss:a", "Eins neu", 1)])
        #expect(SpotlightIndex.showIds([feed]) == SpotlightIndex.showIds([renamedEpisode]), "a change inside a show asks none")
    }

    /// The shows go into the same index through the same line, without the
    /// sign in to Audiobookshelf, and a sign out leaves them.
    @Test("Spotlight traegt die Sendungen auf Angebot, die Abmeldung laesst sie stehen")
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
    /// out; the books follow a full list and the sign out, the shows a
    /// change of the subscriptions.
    @Test("nur eine Stelle schreibt Spotlight, nach der vollen Liste, bei der Abmeldung und mit den Abos", .needsTheSources)
    func spotlightHasOnePlace() throws {
        var writing: [String] = []
        var reconciling: [String] = []
        var forgetting: [String] = []
        var following: [String] = []
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            let squeezed = FetchAnswerTests.squeezed(text)
            if squeezed.contains("indexAppEntities(") || squeezed.contains("deleteAppEntities(")
                || squeezed.contains("CSSearchableIndex") { writing.append(file) }
            if squeezed.contains("SpotlightIndex.reconcile(") { reconciling.append(file) }
            if squeezed.contains("SpotlightIndex.forget(") { forgetting.append(file) }
            if squeezed.contains("SpotlightIndex.reconcileShows(") { following.append(file) }
        }
        #expect(writing == ["AppShortcuts.swift"], "the device's search is written elsewhere: \(writing)")
        #expect(reconciling == ["LibraryViewModel.swift"], "\(reconciling)")
        #expect(forgetting == ["AuthViewModel.swift"], "\(forgetting)")
        #expect(following == ["PodcastSubscriptions.swift"], "\(following)")
        let library = try FetchAnswerTests.squeezedSource("Sources/ViewModels/LibraryViewModel.swift")
        #expect(library.contains("cleanUpPerBook(full: full, bookLibraries: libraries.count) if full != nil, #available(iOS 27, *) { Task { await SpotlightIndex.reconcile() } }"),
                "the pass does not follow the full list")
        let subscriptions = try FetchAnswerTests.squeezedSource("Sources/Providers/PodcastSubscriptions.swift")
        #expect(subscriptions.contains("@Published private var stock: [PodcastShow] = [] { didSet { rebuildCaches() ListeningRevision.shared.bump(\"subscriptions\") if isTheApp, #available(iOS 27, *), SpotlightIndex.showIds(oldValue) != SpotlightIndex.showIds(stock) { Task { await SpotlightIndex.reconcileShows() } }"),
                "the shows' pass does not follow the stock")
    }

    @Test("die Angaben zum laufenden Titel tragen sein Buch", .needsTheSources)
    func theNowPlayingInfoCarriesTheBook() throws {
        let nowPlaying = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerViewModel+NowPlaying.swift")
        #expect(nowPlaying.contains("let identifiers = NowPlayingEntities.identifiers(forItem: item?.id) if !identifiers.isEmpty { info[MPNowPlayingInfoPropertyAppEntityIdentifiers] = identifiers }"),
                "the now playing info does not name the title's entity")
    }
}
#endif
