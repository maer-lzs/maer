// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AppIntents
import CoreSpotlight
import Foundation
import MediaIntents
import MediaPlayer
import OSLog

/// "Continue listening": opens the app and resumes the last played book. The
/// same path as the home-screen quick action (pending flag + notification,
/// carried out by the library).
struct ContinueListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    static let description = IntentDescription("Resumes the last played audiobook.")
    /// Most robust variant: bring the app to the foreground and start there
    /// (starting audio from the background would be more error-prone).
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // What can be known before the app opens is said, not called a
        // success: a device without a last played title and without an
        // open player has nothing to continue.
        if AppSession.shared.playerCoordinator.findsNothingToContinue {
            Logger.library.notice("SIRI continue: nothing to continue on this device")
            throw ResumeAsk.Refusal(ResumeTarget.Missing.noLastPlayed.sentence)
        }
        ResumeRequest.pending = true
        NotificationCenter.default.post(name: .resumeLastBookRequested, object: nil)
        return .result()
    }
}

// MARK: - "Play [book]"

/// Book entity for the Siri parameter. Fed from the library rows, which
/// hold the library since the document was poured into them; the document
/// in Documents stays the reader of last resort for a device that has not
/// migrated yet.
///
/// Its `id` is the outward id (`OutwardItemRef`); the library id stays in
/// the app and is what a request starts.
struct BookEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Audiobook"
    static let defaultQuery = BookQuery()

    let id: String
    let itemId: String
    let title: String
    let author: String?
    var narrator: String? = nil
    var series: String? = nil
    var genres: [String] = []

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: author.map { "\($0)" }
        )
    }
}

/// The same book for the audio domain of iOS 27 (`.audio.audiobook`): what
/// Siri and the system's search ask about a book. It comes from the one
/// reading of the rows (`BookQuery`); a field the library does not hold
/// stays empty.
@available(iOS 27, *)
@AppEntity(schema: .audio.audiobook)
struct AudiobookEntity: AppEntity {
    static let defaultQuery = AudiobookQuery()

    let id: String
    let itemId: String
    var title: String?
    var author: String?
    var genre: String?
    var narrator: String?
    var publisher: String?
    var purchaseDate: Date?
    var releaseDate: Date?
    var seriesTitle: String?

    init(_ book: BookEntity) {
        id = book.id
        itemId = book.itemId
        title = book.title
        author = book.author
        genre = book.genres.isEmpty ? nil : book.genres.joined(separator: ", ")
        narrator = book.narrator
        seriesTitle = book.series
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title ?? "")", subtitle: author.map { "\($0)" })
    }
}

@available(iOS 27, *)
struct AudiobookQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AudiobookEntity] {
        let now = await BookQuery.current()
        return BookQuery.books(for: identifiers, in: now.items, tagOf: now.tagOf).map(AudiobookEntity.init)
    }

    func entities(matching string: String) async throws -> [AudiobookEntity] {
        let now = await BookQuery.current()
        return BookQuery.matching(string, in: BookQuery.books(from: now.items, tagOf: now.tagOf)).map(AudiobookEntity.init)
    }

    func suggestedEntities() async throws -> [AudiobookEntity] {
        let now = await BookQuery.current()
        return BookQuery.suggested(in: BookQuery.books(from: now.items, tagOf: now.tagOf)).map(AudiobookEntity.init)
    }
}

struct BookQuery: EntityStringQuery {
    /// The items the rows hold; no rows or a failed read is no item.
    nonisolated static func items(rows: LibraryRowStore?) async -> [LibraryItem] {
        guard let rows else { return [] }
        do {
            return try await rows.loadAll()?.items ?? []
        } catch {
            Logger.library.error("SHORTCUT rows failed reason=\(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// The books the rows hold, each with its outward id.
    nonisolated static func books(rows: LibraryRowStore?, tagOf: (String) -> String?) async -> [BookEntity] {
        books(from: await items(rows: rows), tagOf: tagOf)
    }

    /// The entity of one item under `id`; an item without a title is no book.
    nonisolated static func book(_ item: LibraryItem, id: String) -> BookEntity? {
        guard let metadata = item.media?.metadata, let title = metadata.title else { return nil }
        return BookEntity(id: id, itemId: item.id, title: title, author: item.author,
                          narrator: metadata.narratorName, series: metadata.seriesName, genres: metadata.genres ?? [])
    }

    /// The entities on offer: a book needs a title and an outward id, so a
    /// book whose server the register does not name stays out.
    nonisolated static func books(from items: [LibraryItem], tagOf: (String) -> String?) -> [BookEntity] {
        items.compactMap { item in
            OutwardItemRef.ref(itemId: item.id, serverTag: tagOf(item.id)).flatMap { book(item, id: $0) }
        }
    }

    /// The books the identifiers name, in their order. An outward id finds
    /// its book when this device knows its owner. An identifier that is no
    /// outward id is a library id from an older shortcut and finds its book
    /// in the rows, without the register and without the salt; it carries
    /// its outward id when there is one, else its own.
    nonisolated static func books(for identifiers: [String], in items: [LibraryItem],
                                  tagOf: (String) -> String?) -> [BookEntity] {
        identifiers.compactMap { identifier in
            guard OutwardItemRef.parts(of: identifier) != nil else {
                return items.first { $0.id == identifier }.flatMap { item in
                    book(item, id: OutwardItemRef.ref(itemId: item.id, serverTag: tagOf(item.id)) ?? identifier)
                }
            }
            guard let itemId = OutwardItemRef.itemId(ref: identifier, tagOf: tagOf),
                  let item = items.first(where: { $0.id == itemId }),
                  let ref = OutwardItemRef.ref(itemId: itemId, serverTag: tagOf(itemId)) else { return nil }
            return book(item, id: ref)
        }
    }

    /// The rows' items and the tags of this device; without a salt or a
    /// register no item has a tag. Both entities of a book ask this reading.
    nonisolated static func current() async -> (items: [LibraryItem], tagOf: (String) -> String?) {
        let tagOf = OutwardServerTag.appTagOf() ?? { _ in nil }
        var rows: LibraryRowStore?
        do {
            rows = try await MaerDatabase.libraryRows()
        } catch {
            Logger.library.error("SHORTCUT rows unavailable reason=\(String(describing: error), privacy: .public)")
        }
        return (await Self.items(rows: rows), tagOf)
    }

    func entities(for identifiers: [String]) async throws -> [BookEntity] {
        let now = await Self.current()
        return Self.books(for: identifiers, in: now.items, tagOf: now.tagOf)
    }

    /// How many books a shortcut and Siri suggest.
    nonisolated static let suggestionLimit = 12

    /// The books a typed search finds: the one search for books, the one
    /// Siri's play asks too (`AudioAsk`), over title and author, without
    /// case or accents.
    nonisolated static func matching(_ text: String, in books: [BookEntity]) -> [BookEntity] {
        AudioAsk.books(for: .search(text), in: books, lastPlayedId: nil)
    }

    /// The books a shortcut and Siri suggest.
    nonisolated static func suggested(in books: [BookEntity]) -> [BookEntity] {
        Array(books.prefix(suggestionLimit))
    }

    func entities(matching string: String) async throws -> [BookEntity] {
        let now = await Self.current()
        return Self.matching(string, in: Self.books(from: now.items, tagOf: now.tagOf))
    }

    func suggestedEntities() async throws -> [BookEntity] {
        let now = await Self.current()
        return Self.suggested(in: Self.books(from: now.items, tagOf: now.tagOf))
    }
}

// MARK: - Siri's "play" in the audio domain (iOS 27)

/// What Siri asks for when it asks this app to play: nothing named (the
/// person said only "play something"), a search, or what the app does not
/// answer (an address).
nonisolated enum AudioAsk: Equatable, Sendable {
    case unnamed
    case search(String)
    case unanswered

    /// The kind of the ask for a log line; never the words of a search.
    var kind: String {
        switch self {
        case .unnamed: "unnamed"
        case .search: "search"
        case .unanswered: "unanswered"
        }
    }

    /// What an ask finds among `titles`, for every kind: nothing named is
    /// continue listening, the last played title when it is on offer; a
    /// search finds the titles one of whose `fields` contains it, without
    /// case or accents.
    static func found<Title>(for ask: AudioAsk, in titles: [Title], itemId: (Title) -> String,
                             fields: (Title) -> [String?], lastPlayedId: String?) -> [Title] {
        switch ask {
        case .unnamed:
            return titles.filter { itemId($0) == lastPlayedId }
        case .search(let text):
            let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return [] }
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            return titles.filter { title in
                fields(title).contains { $0?.range(of: query, options: options) != nil }
            }
        case .unanswered:
            return []
        }
    }

    /// The books an ask finds, by title and author.
    static func books(for ask: AudioAsk, in books: [BookEntity], lastPlayedId: String?) -> [BookEntity] {
        found(for: ask, in: books, itemId: \.itemId, fields: { [$0.title, $0.author] }, lastPlayedId: lastPlayedId)
    }

    /// The stations an ask finds, by name.
    static func stations(for ask: AudioAsk, in stations: [RadioStation], lastPlayedId: String?) -> [RadioStation] {
        found(for: ask, in: stations, itemId: \.id, fields: { [$0.name] }, lastPlayedId: lastPlayedId)
    }

    /// The lists an ask finds, by name. Nothing named continues a title,
    /// never a list: what played last is a title.
    static func lists(for ask: AudioAsk, in lists: [MaerPlaylists.Playlist]) -> [MaerPlaylists.Playlist] {
        found(for: ask, in: lists, itemId: \.id, fields: { [$0.name] }, lastPlayedId: nil)
    }

    /// The episodes an ask finds, by title and the show's title.
    static func episodes(for ask: AudioAsk, in episodes: [EpisodeOffer], lastPlayedId: String?) -> [EpisodeOffer] {
        found(for: ask, in: episodes, itemId: \.itemId, fields: { [$0.title, $0.showTitle] }, lastPlayedId: lastPlayedId)
    }
}

/// An episode on offer to Siri, with its show: the episodes of the shows
/// subscribed by their feed (`rss:` ids, the id of the app, which carries no
/// address). An Audiobookshelf episode is not offered yet: the owner
/// register names only library ids, so its server has no tag.
nonisolated struct EpisodeOffer: Equatable, Sendable {
    let itemId: String
    let title: String
    let showId: String
    let showTitle: String
    let released: Date?
    let duration: Double?

    /// Whether an episode is on offer: one with a feed's id.
    static func isOffered(_ episode: PodcastEpisode) -> Bool { ItemNamespace.of(episode.guid) == "rss:" }

    /// Whether a show has an episode on offer.
    static func hasOffer(_ show: PodcastShow) -> Bool { show.episodes.contains(where: isOffered) }

    /// What Siri gets for an ask: the episodes it finds, the newest first,
    /// at most `limit`. Every episode of every show is asked; only the answer
    /// is bounded, so it stays a handful of entities however long the
    /// shows' histories are.
    static func answer(for ask: AudioAsk, in shows: [PodcastShow], lastPlayedId: String?, limit: Int) -> [EpisodeOffer] {
        let found = AudioAsk.episodes(for: ask, in: episodes(from: shows), lastPlayedId: lastPlayedId)
        return Array(found.sorted { ($0.released ?? .distantPast) > ($1.released ?? .distantPast) }.prefix(limit))
    }

    /// The episodes of `shows` that are on offer, newest first per show.
    static func episodes(from shows: [PodcastShow]) -> [EpisodeOffer] {
        shows.flatMap { show in
            show.episodes
                .filter(isOffered)
                .sorted { $0.pubDate > $1.pubDate }
                .map { episode in
                    EpisodeOffer(itemId: episode.guid, title: episode.title, showId: show.id, showTitle: show.title,
                                 released: episode.pubDate > 0 ? Date(timeIntervalSince1970: episode.pubDate / 1000) : nil,
                                 duration: episode.duration > 0 ? episode.duration : nil)
                }
        }
    }
}

/// A show for the audio domain (`.audio.podcastShow`), from the shows
/// subscribed by their feed; its id is the show's id in the app.
@available(iOS 27, *)
@AppEntity(schema: .audio.podcastShow)
struct PodcastShowEntity: AppEntity {
    static let defaultQuery = PodcastShowQuery()

    let id: String
    var title: String
    var showDescription: String?

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

@available(iOS 27, *)
struct PodcastShowQuery: EntityStringQuery {
    /// The shows on offer: those with an episode on offer.
    @MainActor
    static func shows() -> [PodcastShowEntity] {
        offer(PodcastShowSources.active())
    }

    /// The shows on offer among `shows`, as entities.
    @MainActor
    static func offer(_ shows: [PodcastShow]) -> [PodcastShowEntity] {
        shows.filter(EpisodeOffer.hasOffer).map { PodcastShowEntity(id: $0.id, title: $0.title) }
    }

    func entities(for identifiers: [String]) async throws -> [PodcastShowEntity] {
        let shows = await Self.shows()
        return identifiers.compactMap { id in shows.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [PodcastShowEntity] {
        let shows = await Self.shows()
        return AudioAsk.found(for: .search(string), in: shows, itemId: \.id, fields: { [$0.title] }, lastPlayedId: nil)
    }

    func suggestedEntities() async throws -> [PodcastShowEntity] {
        Array(await Self.shows().prefix(BookQuery.suggestionLimit))
    }
}

/// An episode for the audio domain (`.audio.podcastEpisode`), with its show.
@available(iOS 27, *)
@AppEntity(schema: .audio.podcastEpisode)
struct PodcastEpisodeEntity: AppEntity {
    static let defaultQuery = PodcastEpisodeQuery()

    let id: String
    var title: String
    var show: PodcastShowEntity?
    var showName: String?
    var releaseDate: Date?
    var duration: Double?

    init(_ offer: EpisodeOffer) {
        id = offer.itemId
        title = offer.title
        show = PodcastShowEntity(id: offer.showId, title: offer.showTitle)
        showName = offer.showTitle
        releaseDate = offer.released
        duration = offer.duration
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: showName.map { "\($0)" })
    }
}

@available(iOS 27, *)
struct PodcastEpisodeQuery: EntityStringQuery {
    /// The shows as the podcast surface holds them; the one read on the
    /// main actor, a copy of values.
    @MainActor
    static func shows() -> [PodcastShow] { PodcastShowSources.active() }

    /// Works `work` out off the main actor: every episode of every show can
    /// be a hundred thousand rows for long histories, too much for the
    /// actor that draws the screen.
    nonisolated static func offMain<Result: Sendable>(_ work: @escaping @Sendable ([PodcastShow]) -> Result) async -> Result {
        let shows = await shows()
        // detached because a nonisolated async function runs on its caller's
        // executor, and the caller of an entity query is the main actor.
        return await Task.detached(priority: .userInitiated) { work(shows) }.value
    }

    /// The answer to an ask, off the main actor.
    nonisolated static func answer(for ask: AudioAsk, lastPlayedId: String?) async -> [EpisodeOffer] {
        await offMain { EpisodeOffer.answer(for: ask, in: $0, lastPlayedId: lastPlayedId, limit: BookQuery.suggestionLimit) }
    }

    func entities(for identifiers: [String]) async throws -> [PodcastEpisodeEntity] {
        let wanted = Set(identifiers)
        let found = await Self.offMain { EpisodeOffer.episodes(from: $0).filter { wanted.contains($0.itemId) } }
        return identifiers.compactMap { id in found.first { $0.itemId == id } }.map(PodcastEpisodeEntity.init)
    }

    func entities(matching string: String) async throws -> [PodcastEpisodeEntity] {
        await Self.answer(for: .search(string), lastPlayedId: nil).map(PodcastEpisodeEntity.init)
    }

    func suggestedEntities() async throws -> [PodcastEpisodeEntity] {
        let newest = await Self.offMain { shows in
            Array(EpisodeOffer.episodes(from: shows)
                .sorted { ($0.released ?? .distantPast) > ($1.released ?? .distantPast) }
                .prefix(BookQuery.suggestionLimit))
        }
        return newest.map(PodcastEpisodeEntity.init)
    }
}

/// A live station for the audio domain (`.audio.liveRadioStation`): one the
/// person keeps (`RadioStore.onHand`), with the id of the app, which carries
/// no address. A catalog station heard only in this session is not offered:
/// it resolves by id only until the app ends.
@available(iOS 27, *)
@AppEntity(schema: .audio.liveRadioStation)
struct RadioStationEntity: AppEntity {
    static let defaultQuery = RadioStationQuery()

    let id: String
    var title: String
    /// Who broadcasts the station; the stored station names none.
    var providerName: String?

    init(_ station: RadioStation) {
        id = station.id
        title = station.name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

@available(iOS 27, *)
struct RadioStationQuery: EntityStringQuery {
    static func stations() -> [RadioStation] { RadioStore.onHand() }

    func entities(for identifiers: [String]) async throws -> [RadioStationEntity] {
        let stations = Self.stations()
        return identifiers.compactMap { id in stations.first { $0.id == id } }.map(RadioStationEntity.init)
    }

    func entities(matching string: String) async throws -> [RadioStationEntity] {
        AudioAsk.stations(for: .search(string), in: Self.stations(), lastPlayedId: nil).map(RadioStationEntity.init)
    }

    func suggestedEntities() async throws -> [RadioStationEntity] {
        Self.stations().prefix(BookQuery.suggestionLimit).map(RadioStationEntity.init)
    }
}

/// A list of this device for the audio domain (`.audio.playlist`), the
/// routines among them; its id is the list's, which carries no address. The
/// playlists of a music server are not offered.
@available(iOS 27, *)
@AppEntity(schema: .audio.playlist)
struct PlaylistEntity: AppEntity {
    static let defaultQuery = PlaylistQuery()

    let id: String
    var title: String
    /// A list of this device is the person's own: made by them, not put
    /// together for them, with no other owner to name.
    var createdByMe: Bool?
    var curatedForMe: Bool?
    var owner: PlaylistOwner?

    init(_ list: MaerPlaylists.Playlist) {
        id = list.id
        title = list.name
        createdByMe = true
        curatedForMe = false
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

/// Who a list belongs to, in the form the schema asks; a list of this
/// device names none.
@available(iOS 27, *)
@UnionValue
enum PlaylistOwner {
    case person(IntentPerson)
    case name(String)
}

@available(iOS 27, *)
struct PlaylistQuery: EntityStringQuery {
    /// The lists of this device, in their order.
    @MainActor
    static func lists() -> MaerPlaylists { RoutineQuery.lists() }

    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        let lists = await Self.lists().playlists
        return identifiers.compactMap { id in lists.first { $0.id == id } }.map(PlaylistEntity.init)
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        AudioAsk.lists(for: .search(string), in: await Self.lists().playlists).map(PlaylistEntity.init)
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        await Self.lists().playlists.prefix(BookQuery.suggestionLimit).map(PlaylistEntity.init)
    }
}

/// What Siri's play starts for a kind: a title through the one door of
/// continue listening, or a list through the one start of every list.
nonisolated enum AudioStart: Equatable, Sendable {
    case item(String)
    case list(String)
}

/// The kinds Siri may ask this app to play; each kind joins with its slice.
/// A show is not one yet: what playing a whole show starts is open.
@available(iOS 27, *)
@UnionValue
enum PlayableAudio {
    case audiobook(AudiobookEntity)
    case episode(PodcastEpisodeEntity)
    case station(RadioStationEntity)
    case playlist(PlaylistEntity)

    /// What the intent starts: a title by its id of the app, or a list.
    var start: AudioStart {
        switch self {
        case .audiobook(let book): .item(book.itemId)
        case .episode(let episode): .item(episode.id)
        case .station(let station): .item(station.id)
        case .playlist(let list): .list(list.id)
        }
    }
}

/// Siri's start of a list: the one start of every list
/// (`RoutinePlayback.start`), as the list's Play button, in the background.
/// The app comes to the front only to say that the list is not here or
/// starts nothing.
@available(iOS 27, *)
@MainActor
enum PlaylistStart {
    /// The player that starts the list and says why it did not.
    private static var coordinator: PlayerCoordinator { AppSession.shared.playerCoordinator }

    /// What a request comes to; the sentence the app says for it, if any.
    nonisolated static func sentence(for request: RoutinePlayback.Request, started: Bool) -> String? {
        switch request {
        case .start: started ? nil : String(localized: "This playlist has nothing to play right now.")
        case .wait, .missing: String(localized: "This playlist is not on this device.")
        }
    }

    /// The list's start; a witness stands in for the app's.
    static var start: @MainActor (MaerPlaylists.Playlist) async -> Bool = { list in
        await RoutinePlayback.start(list, in: PlaylistQuery.lists(), on: coordinator)
    }

    /// The app's way to say a sentence once it is in front.
    static var say: @MainActor (String) -> Void = { sentence in
        coordinator.sayOpenFailure(sentence, cause: .unknown, title: nil)
    }

    /// Starts the list `listId` among `store`'s lists. A list the start read
    /// has not reached yet is not here for Siri: there is no view to wait in.
    static func run(listId: String, in store: MaerPlaylists,
                    bringsAppToFront: @MainActor () async throws -> Bool) async throws {
        let request = RoutinePlayback.request(listId, in: store.playlists, complete: !store.startIncomplete)
        var started = false
        if case .start(let list) = request { started = await start(list) }
        Logger.library.notice("SIRI list start=\(started) found=\(request != .missing && request != .wait)")
        guard let sentence = sentence(for: request, started: started) else { return }
        guard try await bringsAppToFront() else {
            Logger.library.notice("SIRI list says nothing: the system cannot bring the app to the front")
            return
        }
        say(sentence)
    }
}

/// Siri's search for what to play, over the books of this device.
@available(iOS 27, *)
struct PlayableAudioSearch: IntentValueQuery {
    func values(for input: AudioSearch) async throws -> [PlayableAudio] {
        let ask: AudioAsk = switch input.criteria {
        case .unspecified: .unnamed
        case .searchQuery(let text): .search(text)
        case .url: .unanswered
        @unknown default: .unanswered
        }
        let lastPlayed = AppStorageKeys.lastPlayedItemIdValue
        let now = await BookQuery.current()
        let books = AudioAsk.books(for: ask, in: BookQuery.books(from: now.items, tagOf: now.tagOf), lastPlayedId: lastPlayed)
        let episodes = await PodcastEpisodeQuery.answer(for: ask, lastPlayedId: lastPlayed)
        let stations = AudioAsk.stations(for: ask, in: RadioStationQuery.stations(), lastPlayedId: lastPlayed)
        let lists = AudioAsk.lists(for: ask, in: await PlaylistQuery.lists().playlists)
        Logger.library.notice("SIRI audio search ask=\(ask.kind, privacy: .public) books=\(books.count) episodes=\(episodes.count) stations=\(stations.count) lists=\(lists.count)")
        return books.map { .audiobook(AudiobookEntity($0)) } + episodes.map { .episode(PodcastEpisodeEntity($0)) }
            + stations.map { .station(RadioStationEntity($0)) } + lists.map { .playlist(PlaylistEntity($0)) }
    }
}

/// How Siri may ask a title to be played; a book plays from where it stands.
@available(iOS 27, *)
@AppEnum(schema: .audio.playbackAttributes)
enum AudioPlaybackAttribute: String, AppEnum {
    case `repeat`, shuffle
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.repeat: "Repeat", .shuffle: "Shuffle"]
}

/// Where Siri may ask a title to go in the queue; this app plays it now.
@available(iOS 27, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum AudioQueueLocation: String, AppEnum {
    case next, tail
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.next: "Play Next", .tail: "Play Last"]
}

/// The schema's answer to a warm up of the queue; this app warms up nothing
/// and finds none.
@available(iOS 27, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct AudioWarmupResult: AppEntity {
    struct Query: EntityStringQuery {
        func entities(for identifiers: [String]) async throws -> [AudioWarmupResult] { [] }
        func entities(matching string: String) async throws -> [AudioWarmupResult] { [] }
    }
    static let defaultQuery = Query()
    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

/// Siri's "play" for this app: the title goes through the one door of
/// continue listening (`ResumeListeningIntent.run`), in the background,
/// and the app comes to the front only to say it found nothing.
@available(iOS 27, *)
@AppIntent(schema: .audio.playAudio)
struct PlayAudioIntent: AppIntent {
    var audioEntity: PlayableAudio
    var playbackAttributes: Set<AudioPlaybackAttribute>
    var queueLocation: AudioQueueLocation?
    var warmupAudioQueueResult: AudioWarmupResult?

    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult {
        if !playbackAttributes.isEmpty || queueLocation != nil {
            // A book plays from where it stands and now; the wish is noted, not followed.
            Logger.library.notice("SIRI play attributes=\(playbackAttributes.map(\.rawValue).sorted(), privacy: .public) queue=\(queueLocation?.rawValue ?? "none", privacy: .public) not followed")
        }
        switch audioEntity.start {
        case .item(let itemId):
            try await ResumeListeningIntent.run(itemId: itemId) {
                try await continueInForeground(nil, alwaysConfirm: false)
                return true
            }
        case .list(let listId):
            try await PlaylistStart.run(listId: listId, in: PlaylistQuery.lists()) {
                try await continueInForeground(nil, alwaysConfirm: false)
                return true
            }
        }
        return .result()
    }
}

/// The entity the lock screen's title stands for, so Siri knows what plays
/// (`MPNowPlayingInfoPropertyAppEntityIdentifiers`): a book with its outward
/// id. Worked out once per title, because the info is written on every
/// event of the playback. A found entity holds for its title. An empty
/// answer holds only while the owner register keeps its stand and for at
/// most `emptyHolds` seconds: a book often plays for days, its owner comes
/// with the next full load, and a salt the locked keychain did not give
/// comes without an event.
@available(iOS 27, *)
@MainActor
enum NowPlayingEntities {
    /// How long an empty answer holds when nothing else changes.
    nonisolated static let emptyHolds: TimeInterval = 60

    private static var memo: (itemId: String?, identifiers: [MPAppEntityIdentifier], generation: Int, at: Date)?

    /// Whether a kept answer still holds for this title: a found entity
    /// always, an empty one under the same register stand and within its time.
    nonisolated static func holds(itemId: String?, identifiers: Int, generation: Int, at: Date,
                                  for asked: String?, generation now: Int, now date: Date) -> Bool {
        guard itemId == asked else { return false }
        return identifiers > 0 || (generation == now && date.timeIntervalSince(at) < emptyHolds)
    }

    /// The outward id of the playing title, when it is a book on offer.
    nonisolated static func ref(forItem itemId: String?, tagOf: (String) -> String?) -> String? {
        guard let itemId, ItemNamespace.of(itemId) == nil else { return nil }
        return OutwardItemRef.ref(itemId: itemId, serverTag: tagOf(itemId))
    }

    /// The identifiers for the playing title; the device's tags are read
    /// only when the kept answer no longer holds, and only for a library id.
    static func identifiers(forItem itemId: String?,
                            tagOf: () -> ((String) -> String?)? = { OutwardServerTag.appTagOf() },
                            generation: Int = OutwardServerTag.registerGeneration,
                            now: Date = Date()) -> [MPAppEntityIdentifier] {
        if let memo, holds(itemId: memo.itemId, identifiers: memo.identifiers.count, generation: memo.generation,
                           at: memo.at, for: itemId, generation: generation, now: now) {
            return memo.identifiers
        }
        var identifiers: [MPAppEntityIdentifier] = []
        if let itemId, ItemNamespace.of(itemId) == nil, let tags = tagOf(),
           let ref = ref(forItem: itemId, tagOf: tags),
           let identifier = MPAppEntityIdentifier(entityIdentifier: EntityIdentifier(for: AudiobookEntity.self, identifier: ref)) {
            identifiers = [identifier]
        }
        memo = (itemId, identifiers, generation, now)
        return identifiers
    }
}

// MARK: - Spotlight (iOS 27)

@available(iOS 27, *)
extension AudiobookEntity: IndexedEntity {}

@available(iOS 27, *)
extension PodcastShowEntity: IndexedEntity {}

/// The books and the shows in the device's search: the one place that adds
/// them and takes them out. Each pass sets the index of one kind to what is
/// on offer now (the books with an outward id, the shows with an episode on
/// offer): all entities of this kind out, the ones on offer in. So a book
/// that left, a server under a new name (a new tag) and a new server need no
/// list of the indexed books; no store keeps an outward id. The prints
/// indexed last (every field of each entity) are kept per kind in this
/// process only, so a pass with the same entities does nothing and a renamed
/// book or show is a change. A sign out takes every book out; the shows are
/// subscribed on this device and stay.
///
/// Passes and the sign out run one at a time, in the order they are asked
/// (`line`): each waits for the one before. A pass that suspends at the
/// index can so never write after a sign out that came later, and a pass
/// that starts after the sign out, from a load still under way, finds no
/// one signed in and adds nothing.
@available(iOS 27, *)
@MainActor
enum SpotlightIndex {
    /// The last pass or sign out asked for; the next one waits for it.
    private static var line: Task<Void, Never>?

    /// Runs `work` after everything asked before it.
    private static func inLine(_ work: @escaping @MainActor () async -> Void) async {
        let previous = line
        let next = Task { @MainActor in
            await previous?.value
            await work()
        }
        line = next
        await next.value
    }

    /// What a pass does with the index.
    enum Pass: Equatable {
        case keep
        case replace
    }

    /// The index of one kind as the app uses it; a witness stands in for
    /// the system.
    struct Index<Entity> {
        var removeAll: @MainActor () async throws -> Void
        var add: @MainActor ([Entity]) async throws -> Void
    }

    static var index = Index<AudiobookEntity>(
        removeAll: { try await CSSearchableIndex.default().deleteAppEntities(ofType: AudiobookEntity.self) },
        add: { try await CSSearchableIndex.default().indexAppEntities($0) })

    static var showIndex = Index<PodcastShowEntity>(
        removeAll: { try await CSSearchableIndex.default().deleteAppEntities(ofType: PodcastShowEntity.self) },
        add: { try await CSSearchableIndex.default().indexAppEntities($0) })

    /// The prints indexed last in this process, per kind; nil when unknown.
    private static var indexed: Set<String>?
    private static var showsIndexed: Set<String>?

    /// Whether a pass with `offer` changes the index: not when it holds
    /// exactly these prints already.
    nonisolated static func pass(offer: Set<String>, indexed: Set<String>?) -> Pass {
        offer == indexed ? .keep : .replace
    }

    /// What a pass compares for one entity: every stored field, read from
    /// the entity itself, so a field that joins the entity joins the print
    /// without a list.
    nonisolated static func fingerprint<Entity>(_ entity: Entity) -> String {
        Mirror(reflecting: entity).children
            .map { "\($0.label ?? ""):\(String(describing: $0.value))" }
            .joined(separator: "\u{1F}")
    }

    /// The prints of `offer`, worked out off the main actor: a print reads
    /// every field of every entity, too much for the actor that draws the
    /// screen when the library is large.
    nonisolated static func prints<Entity: Sendable>(of offer: [Entity]) async -> Set<String> {
        // detached because a nonisolated async function runs on its caller's
        // executor, and every pass runs on the main actor.
        await Task.detached(priority: .userInitiated) { Set(offer.map(fingerprint)) }.value
    }

    /// The pass of the shows asked and not begun yet; the writes of one
    /// turn ask one pass.
    private static var showsAsked: Task<Void, Never>?

    /// Asks a pass of the shows. Every writer of what
    /// `PodcastShowSources.active()` reads calls here: the subscriptions,
    /// the server's shows and their archive, and the switch of the sources.
    /// The pass keeps the index when the prints are the same.
    @discardableResult
    static func showsChanged(shows: @escaping @MainActor () -> [PodcastShowEntity] = { PodcastShowQuery.shows() }) -> Task<Void, Never> {
        if let showsAsked { return showsAsked }
        let asked = Task { @MainActor in
            showsAsked = nil
            await reconcileShows(shows: shows)
        }
        showsAsked = asked
        return asked
    }

    /// Sets the index to the books on offer, in line. Without anyone signed
    /// in a pass adds nothing.
    static func reconcile(books: @escaping @MainActor () async -> [BookEntity] = {
        let now = await BookQuery.current()
        return BookQuery.books(from: now.items, tagOf: now.tagOf)
    }, signedIn: @escaping @MainActor () -> Bool = { AppSession.shared.authViewModel.isLoggedIn }) async {
        await inLine {
            guard signedIn() else {
                Logger.library.notice("SPOTLIGHT pass skipped: no one signed in")
                return
            }
            let offer = await books().map(AudiobookEntity.init)
            indexed = await replace(offer, in: index, indexed: indexed, kind: "books")
        }
    }

    /// Sets the index to the shows on offer, in line. The shows do not ask
    /// who is signed in to Audiobookshelf: they come from their feeds.
    static func reconcileShows(shows: @escaping @MainActor () -> [PodcastShowEntity] = { PodcastShowQuery.shows() }) async {
        await inLine {
            showsIndexed = await replace(shows(), in: showIndex, indexed: showsIndexed, kind: "shows")
        }
    }

    /// Sets `index` to `offer` unless it holds exactly these prints, and
    /// gives the prints it holds now. A failure gives nil, unknown, so the
    /// next pass sets it again. The pass stays in line while the prints are
    /// worked out beside it.
    private static func replace<Entity: IndexedEntity>(
        _ offer: [Entity], in index: Index<Entity>, indexed: Set<String>?, kind: String
    ) async -> Set<String>? {
        let printed = await Self.prints(of: offer)
        guard pass(offer: printed, indexed: indexed) == .replace else { return indexed }
        do {
            try await index.removeAll()
            if !offer.isEmpty { try await index.add(offer) }
            Logger.library.notice("SPOTLIGHT \(kind, privacy: .public) indexed=\(offer.count)")
            return printed
        } catch {
            Logger.library.error("SPOTLIGHT \(kind, privacy: .public) not indexed: \(FailureReason.of(error), privacy: .public)")
            return nil
        }
    }

    /// Takes every book out of the index, in line: the sign out.
    static func forget() async {
        await inLine {
            indexed = nil
            do {
                try await index.removeAll()
                indexed = []
                Logger.library.notice("SPOTLIGHT books removed")
            } catch {
                Logger.library.error("SPOTLIGHT books not removed: \(FailureReason.of(error), privacy: .public)")
            }
        }
    }
}

/// "Play [book]": opens the app and starts this specific book.
struct PlayBookIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Audiobook"
    static let description = IntentDescription("Plays a specific audiobook from your library.")
    static let openAppWhenRun = true

    @Parameter(title: "Book")
    var book: BookEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        ResumeRequest.pendingItemId = book.itemId
        NotificationCenter.default.post(name: .resumeLastBookRequested, object: nil)
        return .result()
    }
}

// MARK: - "Start [routine]"

/// A routine for the Siri parameter: a list of this device with a rule.
struct RoutineEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Routine"
    static let defaultQuery = RoutineQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct RoutineQuery: EntityStringQuery {
    /// The routines among the lists, in the lists' order; a list without a
    /// rule is no routine and is not offered.
    nonisolated static func routines(from lists: [MaerPlaylists.Playlist]) -> [RoutineEntity] {
        lists.filter(\.isRoutine).map { RoutineEntity(id: $0.id, name: $0.name) }
    }

    /// The lists of this device: the one grip on them for Siri and Shortcuts.
    @MainActor
    static func lists() -> MaerPlaylists { .shared }

    @MainActor
    private func allRoutines() -> [RoutineEntity] {
        Self.routines(from: Self.lists().playlists)
    }

    func entities(for identifiers: [String]) async throws -> [RoutineEntity] {
        let routines = await allRoutines()
        return identifiers.compactMap { id in routines.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [RoutineEntity] {
        await allRoutines().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [RoutineEntity] {
        await allRoutines()
    }
}

/// "Start [routine]": opens the app and starts this routine, the same
/// start as its card on Start.
struct PlayRoutineIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Routine"
    static let description = IntentDescription("Starts one of your routines.")
    static let openAppWhenRun = true

    @Parameter(title: "Routine")
    var routine: RoutineEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        // The newest request wins: an older one still waiting gives way,
        // and its line says which.
        if let standing = ResumeRequest.standing(routineId: ResumeRequest.pendingRoutineId, pending: ResumeRequest.pending,
                                                 itemId: ResumeRequest.pendingItemId) {
            Logger.library.notice("ROUTINE request \(routine.id, privacy: .public) replaces a waiting request: \(standing, privacy: .public)")
        }
        ResumeRequest.pending = false
        ResumeRequest.pendingItemId = nil
        ResumeRequest.pendingRoutineId = routine.id
        NotificationCenter.default.post(name: .resumeLastBookRequested, object: nil)
        return .result()
    }
}

extension MaerPlaylists {
    /// The shortcuts learn the routines anew: their phrases name them.
    static let refreshShortcuts: @MainActor () -> Void = { MaerShortcuts.updateAppShortcutParameters() }
}

struct DriveModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Drive Mode"
    static let description = IntentDescription("Opens the big-button drive layout.")
    static let openAppWhenRun = true
    /// Not offered in Shortcuts while drive mode's gate is closed.
    static var isDiscoverable: Bool { DriveModeGate.isOpen }

    @MainActor
    func perform() async throws -> some IntentResult {
        DriveModeController.shared.enter()
        return .result()
    }
}

struct MaerShortcuts: AppShortcutsProvider {
    // Drive mode has no phrase here while its gate is closed
    // (`DriveModeGate`); the builder takes no condition but `#available`.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueListeningIntent(),
            // Every intent carries a form with the word "app": Siri hears
            // the bare name as the German word for "more", so people say
            // "in der Maer-App" or "von der App Maer", and those forms must
            // be registered or Siri takes the generic media intent instead
            // (measured on a device, 14.09.2026).
            phrases: [
                "Continue listening in \(.applicationName)",
                "Continue listening in the \(.applicationName) app",
                "Resume my audiobook in \(.applicationName)",
                "Resume my audiobook in the \(.applicationName) app",
                "Weiterhören in \(.applicationName)",
                "Weiterhören in der \(.applicationName)-App",
                "Weiterhören mit der App \(.applicationName)",
                "Höre mein Hörbuch in \(.applicationName) weiter",
                "Höre mein Hörbuch in der \(.applicationName)-App weiter"
            ],
            shortTitle: "Continue Listening",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayBookIntent(),
            phrases: [
                "Play \(\.$book) in \(.applicationName)",
                "Play \(\.$book) in the \(.applicationName) app",
                "Play \(\.$book) with the \(.applicationName) app",
                "Spiele \(\.$book) in \(.applicationName)",
                "Spiele \(\.$book) in der \(.applicationName)-App",
                "Spiele \(\.$book) mit der App \(.applicationName)",
                "Spiele \(\.$book) von der App \(.applicationName)",
                "Spiel \(\.$book) von der App \(.applicationName)",
                "Spiel \(\.$book) in der \(.applicationName)-App"
            ],
            shortTitle: "Play Audiobook",
            systemImageName: "book.fill"
        )
        AppShortcut(
            intent: PlayRoutineIntent(),
            phrases: [
                "Start \(\.$routine) in \(.applicationName)",
                "Start \(\.$routine) in the \(.applicationName) app",
                "Start \(\.$routine) with the \(.applicationName) app",
                "Starte \(\.$routine) in \(.applicationName)",
                "Starte \(\.$routine) in der \(.applicationName)-App",
                "Starte \(\.$routine) mit der App \(.applicationName)",
                "Starte \(\.$routine) von der App \(.applicationName)"
            ],
            shortTitle: "Start Routine",
            systemImageName: "music.note.list"
        )
    }
}
