// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AppIntents
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
        return BookQuery.books(from: now.items, tagOf: now.tagOf)
            .filter { $0.title.localizedCaseInsensitiveContains(string) }.map(AudiobookEntity.init)
    }

    func suggestedEntities() async throws -> [AudiobookEntity] {
        let now = await BookQuery.current()
        return BookQuery.books(from: now.items, tagOf: now.tagOf).prefix(12).map(AudiobookEntity.init)
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

    func entities(matching string: String) async throws -> [BookEntity] {
        let now = await Self.current()
        return Self.books(from: now.items, tagOf: now.tagOf).filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [BookEntity] {
        let now = await Self.current()
        return Array(Self.books(from: now.items, tagOf: now.tagOf).prefix(12))
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

    /// The books an ask finds. Nothing named is continue listening: the
    /// last played title, when it is a book on offer. A search finds the
    /// books whose title or author contains it, without case or accents.
    static func books(for ask: AudioAsk, in books: [BookEntity], lastPlayedId: String?) -> [BookEntity] {
        switch ask {
        case .unnamed:
            return books.filter { $0.itemId == lastPlayedId }
        case .search(let text):
            let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return [] }
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            return books.filter { book in
                book.title.range(of: query, options: options) != nil
                    || book.author?.range(of: query, options: options) != nil
            }
        case .unanswered:
            return []
        }
    }
}

/// The kinds Siri may ask this app to play; each kind joins with its slice.
@available(iOS 27, *)
@UnionValue
enum PlayableAudio {
    case audiobook(AudiobookEntity)
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
        let now = await BookQuery.current()
        let found = AudioAsk.books(for: ask, in: BookQuery.books(from: now.items, tagOf: now.tagOf),
                                   lastPlayedId: AppStorageKeys.lastPlayedItemIdValue)
        Logger.library.notice("SIRI audio search ask=\(ask.kind, privacy: .public) found=\(found.count)")
        return found.map { .audiobook(AudiobookEntity($0)) }
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
        switch audioEntity {
        case .audiobook(let book):
            try await ResumeListeningIntent.run(itemId: book.itemId) {
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

    @MainActor
    private func allRoutines() -> [RoutineEntity] {
        Self.routines(from: MaerPlaylists.shared.playlists)
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
