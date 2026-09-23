// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// One paged list merged from several sources, answering any offset.
///
/// The callers page with an offset (`albumPage(sort:offset:size:)`); the
/// sources page with an offset EACH. So the list keeps the merged sequence
/// from its start and answers `offset..<offset+size` of it, whatever order
/// the questions come in: a later page first extends the sequence up to
/// it, a page asked twice is served from what is there, and offset 0 starts
/// over (a refresh). Questions to the same list run one after another.
@MainActor
final class MergedList<Item: Sendable> {
    /// An item with the place it holds in its own source, so rank by rank
    /// is an order like any other.
    nonisolated struct Tagged: Sendable {
        let item: Item
        let source: Int
        let rank: Int
    }

    typealias Fetch = (_ source: Int, _ offset: Int, _ size: Int) async throws -> [Item]

    private let sources: Int
    private let inOrder: (Tagged, Tagged) -> Bool
    private var produced: [Item] = []
    private var streams: [MusicMerge.Stream<Tagged>]
    private var done = false
    private var failed: Set<Int> = []
    private var flight: Task<Void, Never>?

    init(sources: Int, inOrder: @escaping (Tagged, Tagged) -> Bool) {
        self.sources = sources
        self.inOrder = inOrder
        self.streams = Array(repeating: MusicMerge.Stream<Tagged>(), count: sources)
    }

    /// Rank by rank: first of each source, then second of each.
    static func rankByRank(_ a: Tagged, _ b: Tagged) -> Bool { (a.rank, a.source) < (b.rank, b.source) }

    /// The run is its own task on purpose: a caller that goes away (a page
    /// scrolled off) does not cancel it halfway, so the sequence stays whole.
    func items(offset: Int, size: Int, fetch: @escaping Fetch) async -> (items: [Item], failed: Set<Int>) {
        let previous = flight
        let run = Task { () -> (items: [Item], failed: Set<Int>) in
            await previous?.value
            return await self.serve(offset: offset, size: size, fetch: fetch)
        }
        flight = Task { _ = await run.value }
        return await run.value
    }

    private func serve(offset: Int, size: Int, fetch: @escaping Fetch) async -> (items: [Item], failed: Set<Int>) {
        if offset == 0 {
            produced = []
            streams = Array(repeating: MusicMerge.Stream<Tagged>(), count: sources)
            done = false
            failed = []
        } else if offset > produced.count {
            Logger.music.notice("MUSICUNION list extended from \(self.produced.count) to offset \(offset)")
        }
        while produced.count < offset + size, !done {
            // A copy across the suspension: the list is serialized, so no
            // other question touches the streams meanwhile.
            var working = streams
            let step = await MusicMerge.page(size, streams: &working, inOrder: inOrder) { source, from, count in
                let items = try await fetch(source, from, count)
                return items.enumerated().map { Tagged(item: $0.element, source: source, rank: from + $0.offset) }
            }
            streams = working
            produced += step.items.map(\.item)
            failed.formUnion(step.failed)
            if step.items.count < size { done = true }
        }
        let start = min(offset, produced.count)
        return (Array(produced[start..<min(offset + size, produced.count)]), failed)
    }
}

/// The music provider when BOTH music servers are active. Every list asks
/// both and merges (`MusicMerge`, nothing merged by name); every question
/// with an item id goes to the server of the id. A question that carries
/// only a server's RAW number cannot be routed: it goes to the first source,
/// as before the union, and a fence keeps such questions away from here.
///
/// A failing source does not empty a list: the other's entries stand, and
/// `failedSources` names who did not answer, for the sentence on the page.
@MainActor
final class MusicUnion: MusicProvider {
    // The one instance is assembled in `AppSession`, the only place that
    // names the concrete servers; the union itself knows only sources.

    nonisolated let sources: [any MusicProvider]
    let librarySynced = PassthroughSubject<Void, Never>()
    /// The provider ids of the sources that failed the LAST list question.
    private(set) var failedSources: [String] = []
    private var lists: [String: MergedList<LibraryItem>] = [:]
    private var songLists: [String: MergedList<MusicTopSong>] = [:]
    private var relays: [AnyCancellable] = []

    init(sources: [any MusicProvider]) {
        self.sources = sources
        let relay = librarySynced
        relays = sources.map { $0.librarySynced.sink { relay.send() } }
    }

    // MARK: Routing

    /// The source that owns an id; the first one for an id it cannot place.
    nonisolated func source(for itemId: String) -> any MusicProvider {
        sources.first { $0.owns(itemId: itemId) } ?? sources[0]
    }

    /// A raw number cannot be routed. The first source answers, as before.
    private func raw(_ question: String) -> any MusicProvider {
        Logger.music.notice("MUSICUNION raw-number question \(question, privacy: .public) went to the first source")
        return sources[0]
    }

    /// Both answers of a whole-list question, the failures noted. Throws
    /// only when every source failed.
    private func both<T>(_ ask: (any MusicProvider) async throws -> T) async throws -> [T] {
        var answers: [T] = []
        var failed: [String] = []
        var lastError: Error?
        for source in sources {
            do { answers.append(try await ask(source)) } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                failed.append(source.providerId)
                lastError = error
                Logger.music.notice("MUSICUNION source \(source.providerId, privacy: .public) failed: \(FailureReason.of(error), privacy: .public)")
            }
        }
        failedSources = failed
        if answers.isEmpty, let lastError { throw lastError }
        return answers
    }

    private func note(_ failed: Set<Int>) {
        failedSources = failed.sorted().map { sources[$0].providerId }
    }

    // MARK: Orders

    nonisolated static func byTitle(_ a: MergedList<LibraryItem>.Tagged, _ b: MergedList<LibraryItem>.Tagged) -> Bool {
        let (ta, tb) = (a.item.media?.metadata?.title, b.item.media?.metadata?.title)
        if ta != tb { return MusicMerge.nameOrder(ta, tb) }
        return (a.rank, a.source) < (b.rank, b.source)
    }

    nonisolated static func byArtist(_ a: MergedList<LibraryItem>.Tagged, _ b: MergedList<LibraryItem>.Tagged) -> Bool {
        let (aa, ab) = (a.item.author, b.item.author)
        if aa != ab { return MusicMerge.nameOrder(aa, ab) }
        return byTitle(a, b)
    }

    nonisolated static func newestFirst(_ a: MergedList<LibraryItem>.Tagged, _ b: MergedList<LibraryItem>.Tagged) -> Bool {
        switch (a.item.addedAt, b.item.addedAt) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return (a.rank, a.source) < (b.rank, b.source)
        }
    }

    nonisolated static func songTitle(_ a: MergedList<MusicTopSong>.Tagged, _ b: MergedList<MusicTopSong>.Tagged) -> Bool {
        let (ta, tb) = (a.item.item.media?.metadata?.title, b.item.item.media?.metadata?.title)
        if ta != tb { return MusicMerge.nameOrder(ta, tb) }
        return (a.rank, a.source) < (b.rank, b.source)
    }

    private func list(_ key: String, _ order: @escaping (MergedList<LibraryItem>.Tagged, MergedList<LibraryItem>.Tagged) -> Bool)
        -> MergedList<LibraryItem> {
        if let known = lists[key] { return known }
        let made = MergedList<LibraryItem>(sources: sources.count, inOrder: order)
        lists[key] = made
        return made
    }

    private func songList(_ key: String) -> MergedList<MusicTopSong> {
        if let known = songLists[key] { return known }
        let made = MergedList<MusicTopSong>(sources: sources.count, inOrder: Self.songTitle)
        songLists[key] = made
        return made
    }

    /// A paged answer: failures noted, and a list with nothing from anyone
    /// because everyone failed throws like a single source would.
    private func paged<T>(_ answer: (items: [T], failed: Set<Int>)) throws -> [T] {
        note(answer.failed)
        if answer.items.isEmpty, answer.failed.count == sources.count { throw URLError(.cannotConnectToHost) }
        return answer.items
    }

    // MARK: MusicProvider, lists

    func reconnectIfNeeded() { sources.forEach { $0.reconnectIfNeeded() } }

    func albumShelf(shelf: MusicShelf, size: Int) async throws -> [LibraryItem] {
        let answers = try await both { try await $0.albumShelf(shelf: shelf, size: size) }
        let merged: [LibraryItem]
        switch shelf {
        case .newest: merged = MusicMerge.byRecency(answers, stamp: \.addedAt)
        case .recent, .frequent: merged = MusicMerge.rankByRank(answers)
        case .alphabetical, .byArtist:
            var streams = answers.map { MusicMerge.Stream<LibraryItem>(buffer: $0, offset: $0.count, exhausted: true) }
            merged = MusicMerge.take(size * answers.count, from: &streams) { a, b in
                shelf == .byArtist && a.author != b.author
                    ? MusicMerge.nameOrder(a.author, b.author)
                    : MusicMerge.nameOrder(a.media?.metadata?.title, b.media?.metadata?.title)
            }.items
        }
        return Array(merged.prefix(size))
    }

    func albumPage(sort: MusicSortOption, offset: Int, size: Int) async throws -> [LibraryItem] {
        let order: (MergedList<LibraryItem>.Tagged, MergedList<LibraryItem>.Tagged) -> Bool
        switch sort {
        case .nameAZ: order = Self.byTitle
        case .kuenstler: order = Self.byArtist
        case .neu: order = Self.newestFirst
        case .zuletztGespielt, .meistgespielt: order = MergedList<LibraryItem>.rankByRank
        }
        let sources = self.sources
        return try paged(await list("albums|\(sort.rawValue)", order).items(offset: offset, size: size) { source, from, count in
            try await sources[source].albumPage(sort: sort, offset: from, size: count)
        })
    }

    func songPage(offset: Int, size: Int) async throws -> [MusicTopSong] {
        let sources = self.sources
        return try paged(await songList("songs").items(offset: offset, size: size) { source, from, count in
            try await sources[source].songPage(offset: from, size: count)
        })
    }

    func genreAlbums(genre: String, offset: Int, size: Int) async throws -> [LibraryItem] {
        let sources = self.sources
        return try paged(await list("genreAlbums|\(genre)", Self.byTitle).items(offset: offset, size: size) { source, from, count in
            try await sources[source].genreAlbums(genre: genre, offset: from, size: count)
        })
    }

    func genreSongs(genre: String, offset: Int, size: Int) async throws -> [MusicTopSong] {
        let sources = self.sources
        return try paged(await songList("genreSongs|\(genre)").items(offset: offset, size: size) { source, from, count in
            try await sources[source].genreSongs(genre: genre, offset: from, size: count)
        })
    }

    func allArtists() async throws -> [MusicArtist] {
        let answers = try await both { try await $0.allArtists() }
        // Both lists, nothing merged by name; a stable name order.
        return answers.flatMap { $0 }.enumerated()
            .sorted { a, b in
                a.element.name != b.element.name
                    ? MusicMerge.nameOrder(a.element.name, b.element.name) : a.offset < b.offset
            }.map(\.element)
    }

    /// Until the genre rule is decided, both lists one after the other:
    /// a name both servers know appears twice.
    func genres() async throws -> [MusicGenre] {
        try await both { try await $0.genres() }.flatMap { $0 }
    }

    func allPlaylists() async throws -> [MusicPlaylist] {
        let answers = try await both { try await $0.allPlaylists() }
        return MusicMerge.byRecency(answers, stamp: \.changedAt)
    }

    func shuffleLibrarySongItems(limit: Int) async -> [LibraryItem] {
        var lists: [[LibraryItem]] = []
        for source in sources { lists.append(await source.shuffleLibrarySongItems(limit: limit)) }
        var generator = SystemRandomNumberGenerator()
        return MusicMerge.sharedPool(lists, limit: limit, using: &generator)
    }

    var cachedAlbumItems: [LibraryItem] { sources.flatMap(\.cachedAlbumItems) }

    // MARK: MusicProvider, by item id

    func albumInfo(itemId: String) async -> MusicAlbumInfo? { await source(for: itemId).albumInfo(itemId: itemId) }
    func cacheSearchedArtist(_ artist: MusicArtist) { source(for: artist.itemId).cacheSearchedArtist(artist) }
    func trackPlayCounts(forItemId itemId: String) -> [Int?] { source(for: itemId).trackPlayCounts(forItemId: itemId) }
    func addSongs(_ songIds: [String], toPlaylistItemId playlistItemId: String) async throws {
        try await source(for: playlistItemId).addSongs(songIds, toPlaylistItemId: playlistItemId)
    }
    func renamePlaylist(itemId: String, newName: String) async throws {
        try await source(for: itemId).renamePlaylist(itemId: itemId, newName: newName)
    }
    func removeSongs(at indices: [Int], fromPlaylistItemId playlistItemId: String) async throws {
        try await source(for: playlistItemId).removeSongs(at: indices, fromPlaylistItemId: playlistItemId)
    }
    func deletePlaylist(itemId: String) async throws { try await source(for: itemId).deletePlaylist(itemId: itemId) }
    func songIds(forItemId itemId: String) async -> [String] { await source(for: itemId).songIds(forItemId: itemId) }
    func songId(forItemId itemId: String, trackIndex: Int) async -> String? {
        await source(for: itemId).songId(forItemId: itemId, trackIndex: trackIndex)
    }
    func playlistMosaicCoverIDs(forItemId itemId: String) async -> [String] {
        await source(for: itemId).playlistMosaicCoverIDs(forItemId: itemId)
    }
    func playlistArtistNames(forItemId itemId: String) async -> [String] {
        await source(for: itemId).playlistArtistNames(forItemId: itemId)
    }
    func songItems(forItemId itemId: String) async -> [LibraryItem] { await source(for: itemId).songItems(forItemId: itemId) }
    func isStarred(itemId: String) async -> Bool { await source(for: itemId).isStarred(itemId: itemId) }
    @discardableResult
    func toggleStar(itemId: String) async -> Bool { await source(for: itemId).toggleStar(itemId: itemId) }
    func libraryItem(forId itemId: String) -> LibraryItem? { source(for: itemId).libraryItem(forId: itemId) }

    nonisolated func owns(itemId: String) -> Bool { sources.contains { $0.owns(itemId: itemId) } }
    nonisolated func kind(of itemId: String) -> MusicItemKind? { source(for: itemId).kind(of: itemId) }
    nonisolated func artistId(fromItemId itemId: String) -> String? { source(for: itemId).artistId(fromItemId: itemId) }

    // MARK: MusicProvider, raw numbers (fenced: no caller asks the union)

    func artistAlbums(artistId: String) async throws -> [LibraryItem] {
        try await raw("artistAlbums").artistAlbums(artistId: artistId)
    }
    func artist(forId id: String) -> MusicArtist? { raw("artist(forId:)").artist(forId: id) }
    func artistInfo(artistId: String) async -> MusicArtistInfo? { await raw("artistInfo").artistInfo(artistId: artistId) }
    func topSongs(artistId: String, count: Int) async -> [MusicTopSong] {
        await raw("topSongs").topSongs(artistId: artistId, count: count)
    }
    func coverURL(coverArtId: String, size: Int) -> URL? { sources[0].coverURL(coverArtId: coverArtId, size: size) }
    func lyrics(songId: String) async -> SongLyrics? { await source(for: songId).lyrics(songId: songId) }
    /// Until F5b-5 gives it a target, a new server playlist goes where it
    /// went before the union.
    func createPlaylist(name: String) async throws -> String? { try await sources[0].createPlaylist(name: name) }
    nonisolated func itemId(playlistId: String) -> String { sources[0].itemId(playlistId: playlistId) }
    nonisolated func itemId(songId: String) -> String { sources[0].itemId(songId: songId) }
    nonisolated func itemId(artistId: String) -> String { sources[0].itemId(artistId: artistId) }

    // MARK: AudioProvider

    var providerId: String { "music-union" }
    var mediaTypes: Set<MediaType> { sources.reduce(into: Set()) { $0.formUnion($1.mediaTypes) } }
    func servingSignature(for type: MediaType) -> String {
        sources.map { $0.servingSignature(for: type) }.joined(separator: "|")
    }
    /// What only one source can do is not offered for the lists; the
    /// door per item still reaches it.
    var capabilities: ProviderCapabilities {
        sources.dropFirst().reduce(sources[0].capabilities) { $0.intersection($1.capabilities) }
    }
    var isAvailable: Bool { sources.contains { $0.isAvailable } }

    func fetchLibraries() async throws -> [ABSLibrary] { try await both { try await $0.fetchLibraries() }.flatMap { $0 } }
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        try await raw("fetchLibraryItems(libraryId:)").fetchLibraryItems(libraryId: libraryId)
    }
    func fetchLibraryItems(for type: MediaType) async throws -> [LibraryItem] {
        try await both { try await $0.fetchLibraryItems(for: type) }.flatMap { $0 }
    }
    func fetchLibraryItemsPage(libraryId: String, limit: Int, page: Int) async throws -> (items: [LibraryItem], total: Int) {
        try await raw("fetchLibraryItemsPage").fetchLibraryItemsPage(libraryId: libraryId, limit: limit, page: page)
    }
    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        try await source(for: itemId).fetchItemDetail(itemId: itemId)
    }
    func notePlaybackStarted(itemId: String) { source(for: itemId).notePlaybackStarted(itemId: itemId) }
    func coverURL(forItemId itemId: String) -> URL? { source(for: itemId).coverURL(forItemId: itemId) }
    func streamURL(forContentPath contentPath: String) -> URL? { sources[0].streamURL(forContentPath: contentPath) }
    var streamAuthHeaders: [String: String] { sources[0].streamAuthHeaders }
    func streamAuthHeaders(forItemId itemId: String) -> [String: String] {
        source(for: itemId).streamAuthHeaders(forItemId: itemId)
    }
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] {
        try await source(for: itemId).fetchBookmarks(itemId: itemId)
    }
    func createBookmark(itemId: String, time: Double, title: String) async throws {
        try await source(for: itemId).createBookmark(itemId: itemId, time: time, title: title)
    }
    func deleteBookmark(itemId: String, time: Double) async throws {
        try await source(for: itemId).deleteBookmark(itemId: itemId, time: time)
    }

    // MARK: ProgressSyncAPI

    /// Both maps; the keys carry their namespace and cannot meet.
    func fetchAllProgress() async throws -> [String: BookProgress] {
        try await both { try await $0.fetchAllProgress() }.reduce(into: [:]) { $0.merge($1) { first, _ in first } }
    }
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        try await source(for: itemId).updateProgress(itemId: itemId, currentTime: currentTime,
                                                     duration: duration, isFinished: isFinished)
    }
}
