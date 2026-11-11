// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// Second `MusicProvider` implementation (Etappe 2): Jellyfin, music scope
/// only (albums/artists/songs/playlists/covers/search/lyrics/favorites).
/// ID namespace `jf:album:` / `jf:song:` / `jf:playlist:` / `jf:artist:`.
/// Same scheme as Subsonic's `sub:…`. Audiobooks ride `jf:book:`: one file
/// is one book, and the files of one folder fold into one (`JellyfinBookFold`).
///
/// Positions-sync: Jellyfin has no bookmark API for per-song positions, so
/// playlist continue-listening uses the LOCAL position backups only (the same
/// fallback path Subsonic uses when its bookmark API is unusable). Noted in
/// the report, no capability change needed.
@MainActor
final class JellyfinProvider: AudioProvider, MusicProvider {
    static let shared = JellyfinProvider()
    private init() { reloadConfig() }

    private var client: JellyfinClient?

    /// Same session caches as the Subsonic provider (Up-Next resolution,
    /// scrobble bookkeeping, artist route).
    var itemsById: [String: LibraryItem] = [:]
    var searchedArtistsById: [String: MusicArtist] = [:]
    private var songsByItemId: [String: [(id: String, start: Double)]] = [:]
    /// The song each item counted last (`ScrobbleBook`).
    private let scrobbles = ScrobbleBook()
    private var favoriteAlbumIds: Set<String>?
    private var playlistMosaicCache: [String: [String]] = [:]
    private var playlistArtistCache: [String: [String]] = [:]
    /// Per-track play counts of the last detail fetch, by item id.
    private var playCountsByItemId: [String: [Int?]] = [:]
    /// A folded book's tracks from the last detail fetch, each carrying the
    /// Jellyfin element behind it: the position write needs them to land the
    /// time on the running element. A single-file book has no entry here.
    private var foldedTracksByItemId: [String: [ABSAudioTrack]] = [:]
    /// The track index the last position write of a folded book landed on.
    /// The neighbours are reconciled only when it moves, not on every tick.
    private var lastWrittenTrackIndex: [String: Int] = [:]
    /// The positions of the books as the last listing read them. The listing
    /// carries `UserData` per file anyway, so the shelf gets its progress from
    /// the call it already made instead of one request per book.
    private var bookProgressByItemId: [String: BookProgress] = [:]
    /// One library-list request in flight at a time. The gate that decides
    /// whether this source serves audiobooks is synchronous and reads what
    /// this leaves behind.
    private var refreshingKnownLibraries = false

    func trackPlayCounts(forItemId itemId: String) -> [Int?] {
        playCountsByItemId[itemId] ?? []
    }

    var providerId: String { "jf" }
    /// Music always, audiobooks when the server reported a books library and
    /// that tab is on. Same shape as the Subsonic source, only the pair is
    /// derived from the server instead of asked of the person.
    var mediaTypes: Set<MediaType> {
        Set(MediaType.allCases.filter { AppStorageKeys.jellyfinActive(for: $0) })
    }
    /// The books library is a SERVER answer that can become a different one
    /// without this source starting or stopping to serve books, and then the
    /// ids on the shelf belong to a library nobody asks any more. Music has
    /// one library per account here, so it has nothing to tell apart.
    func servingSignature(for type: MediaType) -> String {
        type == .audiobooks ? AppStorageKeys.jellyfinBooksViewIdValue : ""
    }
    var keepsMarksOnDevice: Bool { false }
    var capabilities: ProviderCapabilities { [.passwordLogin, .remoteSearch, .downloadable] }
    var streamAuthHeaders: [String: String] { [:] }

    var isAvailable: Bool {
        AppStorageKeys.jellyfinActive && client != nil
    }

    /// Before a new address is stored: the access token and the user id
    /// were handed out by the stored server, and they go to no other one
    /// (`ServerAddressSwitch`). The next request signs in anew. The stored
    /// server leaves the device with it (`ServerLeaving`: its player, its
    /// rows). Answers whether anything was forgotten.
    /// Another user at the same address is another account and goes the
    /// same way (`ServerAddressSwitch.isAccountSwitch`); nil keeps the
    /// stored user.
    @discardableResult
    static func forgetAccessOnSwitch(to newURL: String, user newUser: String? = nil,
                                     player: PlayerCoordinator? = nil) -> Bool {
        let storedUser = AppStorageKeys.jellyfinUsernameValue
        guard ServerAddressSwitch.isAccountSwitch(fromAddress: AppStorageKeys.jellyfinServerURLValue, fromUser: storedUser,
                                                  toAddress: newURL, toUser: newUser ?? storedUser) else { return false }
        AppStorageKeys.setJellyfinToken("")
        AppStorageKeys.jellyfinUserIdValue = ""
        // Another user at the same address: the stands the user before
        // queued there stay theirs and are not written into the new account.
        let former = AppStorageKeys.jellyfinServerURLValue
        let userOnly = !ServerAddressSwitch.isSwitch(from: former, to: newURL)
        Task {
            await ServerLeaving.forget(ItemNamespace.isJellyfin, covers: .jellyfin, player: player)
            if userOnly { await SyncQueue.shared.forgetPending(onServer: former) }
        }
        Logger.music.notice("JELLYFIN account switch: the access of the stored account is forgotten")
        return true
    }

    /// Before a new address is stored: on a switch the stored password goes
    /// with the stored server and is forgotten; the field's text is kept
    /// only when the person typed another one for the new server.
    static func passwordAfterAddress(_ newURL: String, user newUser: String? = nil, typed: String) -> String {
        let storedUser = AppStorageKeys.jellyfinUsernameValue
        let after = ServerAddressSwitch.password(typed: typed, stored: AppStorageKeys.jellyfinPasswordValue,
                                                 from: AppStorageKeys.jellyfinServerURLValue, to: newURL,
                                                 fromUser: storedUser, toUser: newUser ?? storedUser)
        if after.forgetsStored {
            AppStorageKeys.setJellyfinPassword("")
            Logger.music.notice("JELLYFIN address switch: the password of the stored server is forgotten")
        }
        return after.field
    }

    /// The client the stored settings describe: address, user, password and
    /// the access the server handed out, if any is kept. A fresh sign-in is
    /// kept only while its server is still the stored one: a client of the
    /// former server lives on in running tasks after a switch, and the
    /// access it gets there must not reach the next client.
    static func storedClient() -> JellyfinClient {
        let builtFor = AppStorageKeys.jellyfinServerURLValue
        let builtUser = AppStorageKeys.jellyfinUsernameValue
        let client = JellyfinClient(
            serverURL: builtFor,
            username: builtUser,
            password: AppStorageKeys.jellyfinPasswordValue,
            deviceId: AppStorageKeys.jellyfinDeviceIdValue,
            accessToken: AppStorageKeys.jellyfinTokenValue.isEmpty ? nil : AppStorageKeys.jellyfinTokenValue,
            userId: AppStorageKeys.jellyfinUserIdValue.isEmpty ? nil : AppStorageKeys.jellyfinUserIdValue)
        client.onTokenRefresh = { token, userId in
            guard !ServerAddressSwitch.isAccountSwitch(fromAddress: builtFor, fromUser: builtUser,
                                                       toAddress: AppStorageKeys.jellyfinServerURLValue,
                                                       toUser: AppStorageKeys.jellyfinUsernameValue) else {
                Logger.music.notice("JELLYFIN sign-in of a former account not kept")
                return
            }
            AppStorageKeys.setJellyfinToken(token)
            AppStorageKeys.jellyfinUserIdValue = userId
        }
        return client
    }

    /// Rebuild the client from the stored settings (TF bib-toggles: nil when
    /// the source is not effectively active, so ALL calls stop).
    func reloadConfig() {
        if AppStorageKeys.jellyfinActive, !AppStorageKeys.jellyfinServerURLValue.isEmpty {
            let client = Self.storedClient()
            self.client = client
        } else {
            client = nil
        }
        Logger.music.notice("jellyfin config reloaded (active=\(AppStorageKeys.jellyfinActive), client=\(self.client != nil))")
        AppSession.shared.notifySourcesChanged()
        Task { await refreshKnownLibraries() }
    }

    /// Ask the server which libraries it has and remember whether one of them
    /// holds books. The activation gate is synchronous, so the answer has to
    /// stand there before anyone asks; every rebuilt client refreshes it, and
    /// a books library that appears or disappears on the server moves the tab
    /// on the next start or toggle.
    func refreshKnownLibraries() async {
        guard let client, !refreshingKnownLibraries else { return }
        refreshingKnownLibraries = true
        defer { refreshingKnownLibraries = false }
        // bearable, because a failure leaves the last measured answer standing and the next start asks again
        guard let views = try? await client.views() else {
            Logger.music.notice("jellyfin libraries not readable, keeping the last known answer")
            return
        }
        let booksViewId = Self.booksView(in: views)?.id ?? ""
        guard booksViewId != AppStorageKeys.jellyfinBooksViewIdValue else { return }
        AppStorageKeys.jellyfinBooksViewIdValue = booksViewId
        Logger.music.notice("jellyfin books library \(booksViewId.isEmpty ? "gone" : "found", privacy: .public)")
        AppSession.shared.notifySourcesChanged()
    }

    func reconnectIfNeeded() {
        if !isAvailable, AppStorageKeys.jellyfinEnabledValue { reloadConfig() }
    }

    func testConnection() async -> String? {
        reloadConfig()
        // The cause that really holds, not a list of three. The rule is the
        // same one the page's button asks, so both say the same thing.
        // Jellyfin always serves music (the kinds come from the server's
        // named libraries), so it cannot be set to serve nothing.
        if let missing = SourceReadiness.missing(active: AppStorageKeys.jellyfinActive,
                                            sourceEnabled: AppStorageKeys.jellyfinEnabledValue,
                                                 servesAnything: true,
                                                 address: AppStorageKeys.jellyfinServerURLValue,
                                                 username: AppStorageKeys.jellyfinUsernameValue) {
            return missing.sentence
        }
        guard let client else { return SourceReadiness.address.sentence }
        return await client.testConnection()
    }

    let librarySynced = PassthroughSubject<Void, Never>()
    var historyStore: any SyncHistoryStoring = SyncHistoryStore.shared

    /// Visible library refresh (sync parity with the other sources).
    func syncLibraryNow() async -> String? {
        guard let client else {
            Logger.music.error("jellyfin sync pressed but no client (URL/user missing)")
            return (SourceReadiness.missing(active: AppStorageKeys.jellyfinActive,
                                            sourceEnabled: AppStorageKeys.jellyfinEnabledValue,
                                            servesAnything: true,
                                            address: AppStorageKeys.jellyfinServerURLValue,
                                            username: AppStorageKeys.jellyfinUsernameValue)
                    ?? .address).sentence
        }
        let started = Date()
        await refreshKnownLibraries()
        do {
            let albums = try await client.albums(sortBy: "SortName")
            remember(albums.map(Self.libraryItem(fromAlbum:)))
            historyStore.append(SyncHistory.entry(
                service: .music, direction: .down,
                counters: [.init(key: .albumsUpdated, value: albums.count)],
                duration: Date().timeIntervalSince(started),
                deviceId: SyncHistoryStore.entryDeviceId, startedAt: started))
            Logger.music.notice("jellyfin sync ok: \(albums.count) albums")
            librarySynced.send()
            return nil
        } catch {
            let message = ErrorSentence.of(error)
            historyStore.append(SyncHistory.entry(
                service: .music, direction: .down, counters: [],
                duration: Date().timeIntervalSince(started), error: message,
                deviceId: SyncHistoryStore.entryDeviceId, startedAt: started))
            Logger.music.error("jellyfin sync failed: \(message, privacy: .public)")
            return message
        }
    }

    // MARK: - Library (AudioProvider)

    /// The music library is always there (this source IS the music
    /// source); an audiobook library appears only when the server actually has
    /// one. A books library is a plugin-side setup, not a given.
    func fetchLibraries() async throws -> [ABSLibrary] {
        var libraries = [ABSLibrary(id: "jf", name: String(localized: "Music"), mediaType: "music")]
        if let client, let books = Self.booksView(in: (try? await client.views()) ?? []) {
            libraries.append(ABSLibrary(id: Self.libraryId(booksViewId: books.id),
                                        name: books.name ?? String(localized: "Audiobooks"),
                                        mediaType: "book"))
        }
        return libraries
    }

    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        guard let client else { return [] }
        if let viewId = Self.booksViewId(fromLibraryId: libraryId) {
            let files = try await client.audioBooks(parentId: viewId)
            // A listing without folders is one the fold cannot see; said
            // out loud, because it would otherwise do nothing in silence.
            if JellyfinBookFold.isBlind(files) {
                Logger.music.error("JELLYFIN fold blind: no element carries ParentId, listing fields=\(JellyfinClient.bookFields, privacy: .public) elements=\(files.count)")
            }
            // One call for every folder's name, not one per book.
            // bearable, because the folder name is only the fallback for the title and the list stands without it
            let folders = (try? await client.audioBookFolders(parentId: viewId)) ?? []
            let folderNames = Dictionary(folders.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let groups = JellyfinBookFold.fold(files)
            for group in groups where group.isFolded && JellyfinBookFold.lacksIndex(group.elements) {
                Logger.music.notice("JELLYFIN book fold: folder without track numbers, ordered by name book=\(group.rawId, privacy: .private(mask: .hash)) files=\(group.elements.count)")
            }
            for (folder, count) in JellyfinBookFold.untaggedFolders(files) {
                Logger.music.notice("JELLYFIN book fold: folder with untagged files left as single books folder=\(folder, privacy: .private(mask: .hash)) files=\(count)")
            }
            let items = remember(groups.map { group in
                group.isFolded
                    ? Self.libraryItem(fromFolded: group, folderName: folderNames[group.rawId] ?? nil)
                    : Self.libraryItem(fromBook: group.elements[0])
            })
            // The listing already carries every file's UserData, so the shelf
            // reads its positions from it instead of asking per book.
            bookProgressByItemId = Dictionary(
                zip(items.map(\.id), groups).compactMap { id, group in
                    Self.bookProgress(for: group).map { (id, $0) }
                }, uniquingKeysWith: { _, last in last })
            return items
        }
        let albums = try await client.albums(sortBy: "SortName")
        historyStore.noteChecked(.music)
        return remember(albums.map(Self.libraryItem(fromAlbum:)))
    }

    /// Everything this source holds for a type. The default would ask for the
    /// provider's own slug, and that answer is the music library; the books of
    /// this server live behind their own library id, which only this source
    /// knows. Nothing is served for a type the gate says no to.
    func fetchLibraryItems(for type: MediaType) async throws -> [LibraryItem] {
        guard AppStorageKeys.jellyfinActive(for: type) else { return [] }
        switch type {
        case .audiobooks:
            let viewId = AppStorageKeys.jellyfinBooksViewIdValue
            guard !viewId.isEmpty else { return [] }
            return try await fetchLibraryItems(libraryId: Self.libraryId(booksViewId: viewId))
        case .music:
            return try await fetchLibraryItems(libraryId: providerId)
        default:
            return []
        }
    }

    /// The shelf position of one book, folded or single, read from the
    /// `UserData` the listing carries anyway. Pure, so a witness can drive it
    /// with the payload the server answered. The fold decides what finished
    /// means (every file played), not a comparison against the duration.
    nonisolated static func bookProgress(for group: JellyfinBookFold.Group) -> BookProgress? {
        let (tracks, _, total) = tracksAndChapters(from: group.elements)
        guard total > 0,
              let read = JellyfinBookFold.position(elements: group.elements, tracks: tracks, total: total)
        else { return nil }
        let lastUpdate = standMs(group.elements.map(\.userData)) ?? 0
        return BookProgress(fraction: min(max(read.currentTime / total, 0), 1),
                            isFinished: read.isFinished,
                            lastUpdate: lastUpdate,
                            currentTime: read.currentTime)
    }

    /// The detail of a folded book: the files of the folder that carry the
    /// album behind the id's hash, as tracks in order, one position for the
    /// whole. The folder's own name is the title's fallback behind the tag.
    private func foldedBookDetail(itemId: String, folderId: String, albumHash: String) async throws -> LibraryItemDetail {
        guard let client else { throw JellyfinClient.JellyfinError.network }
        guard let folder = try await client.item(id: folderId), folder.type == "Folder" else {
            throw JellyfinClient.JellyfinError.decoding
        }
        let elements = JellyfinBookFold.ordered(try await client.audioBooks(parentId: folderId)
            .filter { JellyfinBookFold.albumHash($0.album ?? "") == albumHash })
        guard !elements.isEmpty else { throw JellyfinClient.JellyfinError.decoding }
        let (tracks, chapters, total) = Self.tracksAndChapters(from: elements)
        let first = elements[0]
        let media = LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: JellyfinBookFold.title(of: elements, folderName: folder.name),
                authorName: JellyfinBookFold.author(of: elements),
                narratorName: nil, seriesName: nil,
                genres: first.genres?.isEmpty == false ? first.genres : nil,
                publishedYear: first.productionYear.map { LenientString(String($0)) },
                description: first.overview),
            duration: total, chapters: chapters, tracks: tracks)
        itemsById[itemId] = LibraryItem(id: itemId, media: media,
                                        addedAt: Self.epochMs(fromJFDate: first.dateCreated))
        foldedTracksByItemId[itemId] = tracks
        // A fresh detail forgets where the last write landed, so the first
        // write after it reconciles the neighbours once.
        lastWrittenTrackIndex[itemId] = nil
        let read = JellyfinBookFold.position(elements: elements, tracks: tracks, total: total)
        return LibraryItemDetail(
            id: itemId, media: media,
            userMediaProgress: read.map { state in
                MediaProgress(currentTime: state.currentTime, duration: total,
                              progress: total > 0 ? state.currentTime / total : 0,
                              isFinished: state.isFinished,
                              lastUpdate: Self.standMs(elements.map(\.userData)))
            })
    }

    /// The position of a folded book lands on the running file at its inner
    /// position. The neighbours are reconciled when the running file moves
    /// (forward, or by a seek either way): the files before it played, the
    /// ones after it at zero, so the server and a second device read one
    /// place. On a plain tick inside a file only that file is written.
    private func writeFoldedPosition(itemId: String, tracks: [ABSAudioTrack], currentTime: Double,
                                     duration: Double, isFinished: Bool) async throws {
        guard let client else { return }
        let plan = JellyfinBookFold.writePlan(currentTime: currentTime, tracks: tracks, total: duration)
        try await client.setPlaybackPosition(itemId: tracks[plan.index].contentUrl,
                                             seconds: plan.withinTrack, isFinished: isFinished)
        guard JellyfinBookFold.shouldReconcileNeighbours(mark: lastWrittenTrackIndex[itemId], planned: plan.index)
        else { return }
        var failed = 0
        for (index, track) in tracks.enumerated() where index != plan.index {
            do {
                try await client.setPlaybackPosition(itemId: track.contentUrl, seconds: 0,
                                                     isFinished: index < plan.index)
            } catch {
                // The running file is written above, so nothing is lost
                // here; but a neighbour that failed must not be booked as
                // reconciled, or a second device reads the book at the
                // wrong place until the track moves again. The mark below
                // stays empty, and the next write tries the neighbours again.
                failed += 1
                Logger.music.notice("JELLYFIN folded neighbour write failed track=\(index) reason=\(String(describing: error), privacy: .public); reconciled again at the next write")
            }
        }
        lastWrittenTrackIndex[itemId] = JellyfinBookFold.markAfterNeighbours(planned: plan.index, failed: failed)
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        guard let client else { throw JellyfinClient.JellyfinError.network }
        let songs: [JFItem]
        let title: String?
        let artist: String?
        let genre: String?
        var year: Int?
        if let albumId = Self.id(itemId, kind: "album") {
            songs = try await client.albumSongs(albumId: albumId)
            let album = try? await client.item(id: albumId)
            title = album?.name; artist = album?.albumArtist ?? songs.first?.albumArtist
            genre = album?.genres?.first; year = album?.productionYear
        } else if let playlistId = Self.id(itemId, kind: "playlist") {
            songs = try await client.playlistSongs(playlistId: playlistId)
            let pl = try? await client.item(id: playlistId)
            title = pl?.name; artist = nil; genre = nil
        } else if let bookId = Self.id(itemId, kind: "book") {
            // A folded id names a folder and an album; anything else is the
            // single-file book of before, and a folder under such an id is
            // not a book.
            if let folded = JellyfinBookFold.parseFoldedRawId(bookId) {
                return try await foldedBookDetail(itemId: itemId, folderId: folded.parentId,
                                                  albumHash: folded.albumHash)
            }
            guard let book = try await client.item(id: bookId), book.type != "Folder" else {
                throw JellyfinClient.JellyfinError.decoding
            }
            // ONE file, no chapters. And the server's own reading
            // position travels back with it, over the measured road.
            let media = LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: book.name, authorName: book.albumArtist ?? book.artists?.first,
                    narratorName: nil, seriesName: nil,
                    genres: book.genres?.isEmpty == false ? book.genres : nil,
                    publishedYear: book.productionYear.map { LenientString(String($0)) },
                    description: book.overview),
                duration: Self.seconds(fromTicks: book.runTimeTicks), chapters: nil,
                tracks: [ABSAudioTrack(index: 0, startOffset: 0,
                                       duration: Self.seconds(fromTicks: book.runTimeTicks),
                                       contentUrl: bookId, metadata: nil)])
            itemsById[itemId] = LibraryItem(id: itemId, media: media, addedAt: nil)
            let position = Self.position(fromUserData: book.userData)
            return LibraryItemDetail(
                id: itemId, media: media,
                userMediaProgress: position.map { seconds in
                    let duration = Self.seconds(fromTicks: book.runTimeTicks)
                    return MediaProgress(
                        currentTime: seconds, duration: duration,
                        progress: duration.map { $0 > 0 ? seconds / $0 : 0 },
                        isFinished: book.userData?.played ?? false,
                        lastUpdate: Self.standMs([book.userData]))
                })
        } else if let songId = Self.id(itemId, kind: "song"), let song = try await client.item(id: songId) {
            songs = [song]; title = song.name; artist = song.artists?.first; genre = nil
        } else {
            throw JellyfinClient.JellyfinError.decoding
        }
        let (tracks, chapters, total) = Self.tracksAndChapters(from: songs)
        songsByItemId[itemId] = tracks.map { ($0.contentUrl, $0.startOffset ?? 0) }
        scrobbles.forget(itemId)
        // Per-track play counts (UserData.PlayCount) for the client-side
        // "Top Songs" ranking.
        playCountsByItemId[itemId] = songs.map { $0.userData?.playCount }
        let media = LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: title, authorName: artist, narratorName: nil,
                seriesName: nil, genres: genre.map { [$0] },
                publishedYear: year.map { LenientString(String($0)) },
                description: nil
            ),
            duration: total, chapters: chapters, tracks: tracks
        )
        itemsById[itemId] = LibraryItem(id: itemId, media: media, addedAt: nil)
        return LibraryItemDetail(id: itemId, media: media, userMediaProgress: nil)
    }

    @discardableResult
    private func remember(_ items: [LibraryItem]) -> [LibraryItem] {
        for item in items { itemsById[item.id] = item }
        return items
    }

    func libraryItem(forId itemId: String) -> LibraryItem? { itemsById[itemId] }

    var cachedAlbumItems: [LibraryItem] {
        itemsById.values.filter { Self.id($0.id, kind: "album") != nil }
    }

    // MARK: - Media URLs

    func coverURL(forItemId itemId: String) -> URL? {
        guard let client, let imageId = Self.imageItemId(forItemId: itemId) else { return nil }
        return client.imageURL(itemId: imageId, maxWidth: 600)
    }

    /// The Jellyfin id whose primary image is an item's cover. A folded
    /// book's cover is its folder's (Jellyfin fills it from the files); a
    /// single-file book's is the file's; every other item is its own id.
    /// Pure, so the witness holds the same function the cover call uses.
    nonisolated static func imageItemId(forItemId itemId: String) -> String? {
        guard let raw = rawId(itemId) else { return nil }
        return JellyfinBookFold.serverId(for: raw)
    }

    func streamURL(forContentPath contentPath: String) -> URL? {
        client?.streamURL(songId: contentPath)
    }

    func coverURL(coverArtId: String, size: Int) -> URL? {
        client?.imageURL(itemId: coverArtId, maxWidth: size)
    }

    // MARK: - Albums

    /// The neutral shelf → Jellyfin SortBy/SortOrder mapping.
    nonisolated static func shelfSort(for shelf: MusicShelf) -> (by: String, order: String) {
        switch shelf {
        case .newest: return ("DateCreated", "Descending")
        case .frequent: return ("PlayCount", "Descending")
        case .recent: return ("DatePlayed", "Descending")
        case .byArtist: return ("AlbumArtist,SortName", "Ascending")
        case .alphabetical: return ("SortName", "Ascending")
        }
    }

    func albumShelf(shelf: MusicShelf, size: Int) async throws -> [LibraryItem] {
        guard let client else { return [] }
        let sort = Self.shelfSort(for: shelf)
        let albums = try await client.albums(sortBy: sort.by, sortOrder: sort.order, limit: size)
        return remember(albums.map(Self.libraryItem(fromAlbum:)))
    }

    func albumPage(sort: MusicSortOption, offset: Int, size: Int) async throws -> [LibraryItem] {
        guard let client else { return [] }
        let mapped = Self.shelfSort(for: sort.shelf)
        let albums = try await client.albums(sortBy: mapped.by, sortOrder: mapped.order,
                                             startIndex: offset, limit: size)
        return remember(albums.map(Self.libraryItem(fromAlbum:)))
    }

    func albumInfo(itemId: String) async -> MusicAlbumInfo? {
        guard let client, let albumId = Self.id(itemId, kind: "album"),
              let album = try? await client.item(id: albumId) else { return nil }
        // Jellyfin exposes no MusicBrainz id on the item by default. Notes only.
        guard let overview = album.overview, !overview.isEmpty else { return nil }
        return MusicAlbumInfo(notes: overview, musicBrainzId: nil)
    }

    func album(ofSong songItemId: String) async throws -> LibraryItem? {
        guard let songId = Self.id(songItemId, kind: "song") else { return nil }
        guard let client else { throw JellyfinClient.JellyfinError.network }
        guard let song = try await client.item(id: songId), let albumId = song.albumId else { return nil }
        return LibraryItem(
            id: Self.itemId(albumId: albumId),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: song.album, authorName: song.albumArtist, narratorName: nil,
                    seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: nil, chapters: nil, tracks: nil),
            addedAt: nil)
    }

    // MARK: - Artists

    func allArtists() async throws -> [MusicArtist] {
        guard let client else { return [] }
        return try await client.artists().map(Self.domainArtist)
    }

    func artistAlbums(artistId: String) async throws -> [LibraryItem] {
        guard let client else { return [] }
        return remember(try await client.artistAlbums(artistId: artistId).map(Self.libraryItem(fromAlbum:)))
    }

    func artist(forId id: String) -> MusicArtist? { searchedArtistsById[id] }

    func cacheSearchedArtist(_ artist: MusicArtist) { searchedArtistsById[artist.id] = artist }

    func artistInfo(artistId: String) async -> MusicArtistInfo? {
        guard let client, let item = await IndexRunLine.measured("artistInfo", id: artistId, {
            try await client.item(id: artistId)
        }) ?? nil else { return nil }
        let bio = (item.overview?.isEmpty == false) ? item.overview : nil
        let image = client.imageURL(itemId: artistId, maxWidth: 600)
        guard bio != nil || image != nil else { return nil }
        // Similar artists: no cheap Jellyfin equivalent in scope. Empty is
        // normal, the section simply doesn't appear.
        return MusicArtistInfo(biography: bio, imageURL: image, similarArtistNames: [], musicBrainzId: nil)
    }

    func topSongs(artistId: String, count: Int) async -> [MusicTopSong] {
        guard let client, let songs = try? await client.topSongs(artistId: artistId, limit: count)
        else { return [] }
        let result = songs.map { MusicTopSong(item: Self.songItem(from: $0), albumName: $0.album) }
        for entry in result { itemsById[entry.item.id] = entry.item }
        return result
    }

    func songPage(offset: Int, size: Int, sort: MusicSortOption) async throws -> [MusicTopSong] {
        guard let client else { return [] }
        let (sortBy, sortOrder) = Self.songSort(sort)
        let songs = try await client.songs(startIndex: offset, limit: size, sortBy: sortBy, sortOrder: sortOrder)
        let result = Self.songPage(from: songs, sort: sort)
        for entry in result { itemsById[entry.item.id] = entry.item }
        return result
    }

    /// The server's sort for each order `SongOrder` knows, key by key with
    /// its own direction, the title last and ascending like the tie there.
    /// `Name`, not `SortName`: a song's `SortName` is "disc - track - name"
    /// (measured), so it ordered by track number.
    nonisolated static func songSort(_ sort: MusicSortOption) -> (sortBy: String, sortOrder: String) {
        switch sort {
        case .nameAZ: return ("Name", "Ascending")
        case .kuenstler: return ("Artist,Name", "Ascending,Ascending")
        case .neu: return ("DateCreated,Name", "Descending,Ascending")
        case .zuletztGespielt: return ("DatePlayed,Name", "Descending,Ascending")
        case .meistgespielt: return ("PlayCount,Name", "Descending,Ascending")
        }
    }

    /// A page as the server sent it, put in `SongOrder`. Jellyfin's own
    /// collation still differs at the underscore and the apostrophe
    /// (measured on the demo: "01_…" before "01 …", "I'll" before "I met"),
    /// and the merge with the other server needs every source in the one
    /// order. Within a page this is exact; a pair that straddles two pages
    /// keeps the server's order.
    nonisolated static func songPage(from songs: [JFItem], sort: MusicSortOption) -> [MusicTopSong] {
        SongOrder.sorted(songs.map(topSong(from:)), by: sort)
    }

    nonisolated static func topSong(from song: JFItem) -> MusicTopSong {
        MusicTopSong(item: songItem(from: song), albumName: song.album,
                     addedAt: SongOrder.seconds(song.dateCreated),
                     lastPlayedAt: SongOrder.seconds(song.userData?.lastPlayedDate),
                     playCount: song.userData?.playCount)
    }

    // MARK: Genres

    /// Jellyfin ships NO counts on the genre list. Counts stay nil and the
    /// shared presentation sorts alphabetically (honest limit, reported).
    func genres() async throws -> [MusicGenre] {
        guard let client else { return [] }
        return try await client.musicGenres().compactMap { item in
            guard let name = item.name, !name.isEmpty else { return nil }
            return MusicGenre(name: name)
        }
    }

    func genreAlbums(genre: String, offset: Int, size: Int) async throws -> [LibraryItem] {
        guard let client else { return [] }
        let albums = try await client.albumsByGenre(genre: genre, startIndex: offset, limit: size)
        return remember(albums.map(Self.libraryItem(fromAlbum:)))
    }

    func genreSongs(genre: String, offset: Int, size: Int) async throws -> [MusicTopSong] {
        guard let client else { return [] }
        let songs = try await client.songsByGenre(genre: genre, startIndex: offset, limit: size)
        let result = songs.map { MusicTopSong(item: Self.songItem(from: $0), albumName: $0.album) }
        for entry in result { itemsById[entry.item.id] = entry.item }
        return result
    }

    // MARK: - Playlists

    func allPlaylists() async throws -> [MusicPlaylist] {
        guard let client else { return [] }
        return try await client.playlists().map(Self.domainPlaylist)
    }

    func createPlaylist(name: String) async throws -> String? {
        guard let client else { return nil }
        return (try await client.createPlaylist(name: name)).map { Self.itemId(playlistId: $0) }
    }

    func addSongs(_ songIds: [String], toPlaylistItemId playlistItemId: String) async throws {
        guard let client, let rawId = Self.id(playlistItemId, kind: "playlist"), !songIds.isEmpty else { return }
        try await client.addToPlaylist(playlistId: rawId, songIds: songIds)
        playlistMosaicCache[rawId] = nil
    }

    func renamePlaylist(itemId: String, newName: String) async throws {
        guard let client, let rawId = Self.id(itemId, kind: "playlist") else { return }
        try await client.renamePlaylist(playlistId: rawId, name: newName)
    }

    /// Index-based protocol → Jellyfin EntryIds: the current order resolves
    /// the indices to their PlaylistItemIds (duplicate songs stay precise.
    /// Each entry has its own id).
    func removeSongs(at indices: [Int], fromPlaylistItemId playlistItemId: String) async throws {
        guard let client, let rawId = Self.id(playlistItemId, kind: "playlist"), !indices.isEmpty else { return }
        let songs = try await client.playlistSongs(playlistId: rawId)
        // The songs of the rows shown, against the list as the server holds
        // it now: an entry is removed only where the same song still stands.
        let shown = songsByItemId[playlistItemId]
        let drawn = indices.map { index in shown.flatMap { $0.indices.contains(index) ? $0[index].id : nil } }
        guard PlaylistRemoval.stillAt(indices, drawn: drawn, current: songs.map(\.id)) else {
            Logger.music.notice("PLAYLIST remove refused: the list changed under the rows shown")
            songsByItemId[playlistItemId] = nil
            throw PlaylistRemoval.Changed()
        }
        let entryIds = indices.compactMap { songs.indices.contains($0) ? songs[$0].playlistItemId : nil }
        try await client.removeFromPlaylist(playlistId: rawId, entryIds: entryIds)
        playlistMosaicCache[rawId] = nil
        songsByItemId[playlistItemId] = nil
    }

    func deletePlaylist(itemId: String) async throws {
        guard let client, let rawId = Self.id(itemId, kind: "playlist") else { return }
        try await client.deletePlaylist(playlistId: rawId)
        playlistMosaicCache[rawId] = nil
        itemsById[itemId] = nil
    }

    func songIds(forItemId itemId: String) async -> [String] {
        if let songId = Self.id(itemId, kind: "song") { return [songId] }
        if let cached = songsByItemId[itemId] { return cached.map(\.id) }
        _ = try? await fetchItemDetail(itemId: itemId)
        return songsByItemId[itemId]?.map(\.id) ?? []
    }

    func songId(forItemId itemId: String, trackIndex: Int) async -> String? {
        if songsByItemId[itemId] == nil { _ = try? await fetchItemDetail(itemId: itemId) }
        guard let songs = songsByItemId[itemId], songs.indices.contains(trackIndex) else { return nil }
        return songs[trackIndex].id
    }

    /// Per-song artist names. Same playlistSongs fetch as the
    /// mosaic, cached alongside it.
    func playlistArtistNames(forItemId itemId: String) async -> [String] {
        guard let client, let rawId = Self.id(itemId, kind: "playlist") else { return [] }
        if let cached = playlistArtistCache[rawId] { return cached }
        guard let songs = try? await client.playlistSongs(playlistId: rawId) else { return [] }
        let names = songs.compactMap { $0.artists?.first }
        playlistArtistCache[rawId] = names
        return names
    }

    func playlistMosaicCoverIDs(forItemId itemId: String) async -> [String] {
        guard let client, let rawId = Self.id(itemId, kind: "playlist") else { return [] }
        if let cached = playlistMosaicCache[rawId] { return cached }
        guard let songs = await IndexRunLine.measured("mosaic", id: rawId, {
            try await client.playlistSongs(playlistId: rawId)
        }) else { return [] }
        var seen = Set<String>()
        var ids: [String] = []
        for song in songs {
            guard let albumId = song.albumId, seen.insert(albumId).inserted else { continue }
            ids.append(albumId)
            if ids.count == 4 { break }
        }
        playlistMosaicCache[rawId] = ids
        return ids
    }

    // MARK: - Shuffle / queue material

    func songItems(forItemId itemId: String) async -> [LibraryItem] {
        guard let client else { return [] }
        var songs: [JFItem] = []
        do {
            if let albumId = Self.id(itemId, kind: "album") {
                songs = try await client.albumSongs(albumId: albumId)
            } else if let playlistId = Self.id(itemId, kind: "playlist") {
                songs = try await client.playlistSongs(playlistId: playlistId)
            } else if let songId = Self.id(itemId, kind: "song") {
                songs = try await client.item(id: songId).map { [$0] } ?? []
            }
        } catch {
            // The caller gets no songs and says so (`ShufflePlayButton`).
            MusicSongsFailure.log(itemId: itemId, error)
        }
        let items = songs.map(Self.songItem(from:))
        for item in items { itemsById[item.id] = item }
        return items
    }

    func shuffleLibrarySongItems(limit: Int) async -> [LibraryItem] {
        guard let client, let songs = try? await client.randomSongs(limit: limit) else { return [] }
        let items = songs.map(Self.songItem(from:))
        for item in items { itemsById[item.id] = item }
        return items
    }

    // MARK: - Lyrics

    func lyrics(songId: String) async -> SongLyrics? {
        guard let client, let response = try? await client.lyrics(songId: songId) else { return nil }
        return Self.songLyrics(from: response)
    }

    // MARK: - Favorites

    func isStarred(itemId: String) async -> Bool {
        guard let albumId = Self.id(itemId, kind: "album") else { return false }
        if favoriteAlbumIds == nil, let client {
            favoriteAlbumIds = Set((try? await client.favoriteAlbums())?.map(\.id) ?? [])
        }
        return favoriteAlbumIds?.contains(albumId) ?? false
    }

    /// Sets the album's favorite state on the server; the cached set follows
    /// only what the server took.
    func setStar(itemId: String, starred: Bool) async throws {
        guard let client, let albumId = Self.id(itemId, kind: "album") else { throw JellyfinClient.JellyfinError.network }
        try await client.setFavorite(itemId: albumId, on: starred)
        if starred { favoriteAlbumIds?.insert(albumId) } else { favoriteAlbumIds?.remove(albumId) }
    }

    // MARK: - Progress (scrobble; playlist continue = local backups only)

    func fetchAllProgress() async throws -> [String: BookProgress] {
        guard client != nil else { return [:] }
        let playlists = (try? await allPlaylists()) ?? []
        var result: [String: BookProgress] = [:]
        for pl in playlists {
            let itemId = Self.itemId(playlistId: pl.id)
            result[itemId] = BookmarkProgressMath.progress(fromStand: ListeningStore.backup(itemId), duration: pl.duration)
        }
        // Books carry a real server position (UserData per file), read by the
        // last listing. They are the one Jellyfin kind whose progress travels
        // between devices without the local fallback.
        result.merge(bookProgressByItemId) { _, book in book }
        // Albums join the local fallback (Jellyfin continue stays local.
        // No per-song bookmark API; honest capability note in the report).
        for album in cachedAlbumItems {
            result[album.id] = BookmarkProgressMath.progress(fromStand: ListeningStore.backup(album.id),
                                                             duration: album.media?.duration)
        }
        return result
    }

    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        guard let client else { return }
        // A BOOK keeps a real position, and it travels the measured
        // road. The session route (`/Sessions/Playing…`) was measured NOT to
        // persist anything (it read back as 0), so it is not used here even
        // though it is the more obvious one.
        if let bookId = Self.id(itemId, kind: "book") {
            // The switch is the id's form, given at listing time from the
            // element's type, never a cache hit: a folded book whose tracks
            // are not in memory (a restart, a queued offline write) fetches
            // its detail first, so no write ever lands on a folder element.
            if JellyfinBookFold.parseFoldedRawId(bookId) != nil {
                if foldedTracksByItemId[itemId] == nil {
                    _ = try await fetchItemDetail(itemId: itemId)
                }
                guard let tracks = foldedTracksByItemId[itemId] else {
                    Logger.music.error("JELLYFIN folded write skipped: no tracks after detail item=\(itemId, privacy: .private(mask: .hash))")
                    return
                }
                try await writeFoldedPosition(itemId: itemId, tracks: tracks, currentTime: currentTime,
                                              duration: duration, isFinished: isFinished)
                return
            }
            try await client.setPlaybackPosition(itemId: bookId, seconds: currentTime,
                                                 isFinished: isFinished)
            return
        }
        // Music keeps no position. A song is not resumed, it is played again.
        guard let songs = songsByItemId[itemId], !songs.isEmpty else { return }
        // A play is counted once per song change, by the one rule; a count
        // the server did not take is logged and asked again at the next
        // call, not booked as done.
        if let refused = await scrobbles.count(ScrobbleTurn.song(at: currentTime, in: songs), in: itemId,
                                               send: { try await client.markPlayed(itemId: $0) }) {
            Logger.music.error("JELLYFIN play count failed song=\(refused.song, privacy: .private(mask: .hash)) reason=\(FailureReason.of(refused.error), privacy: .public)")
        }
    }

    // MARK: - Bookmarks (unsupported. No capability)

    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}

    // MARK: - Wire → domain mapping (pure, tested)

    nonisolated static func seconds(fromTicks ticks: Double?) -> Double? {
        ticks.map { $0 / 10_000_000 }
    }

    /// When the server's position was written: the newest `LastPlayedDate`
    /// of the item or its elements, in epoch ms; nil when none carries one
    /// (a position written before the app sent the date).
    nonisolated static func standMs(_ userData: [JFUserData?]) -> Double? {
        userData.compactMap { epochMs(fromJFDate: $0?.lastPlayedDate) }.max()
    }

    /// Jellyfin `DateCreated` → epoch ms. The 7-digit fraction Jellyfin sends
    /// is trimmed to 3 digits (ISO8601DateFormatter's supported shape).
    nonisolated static func epochMs(fromJFDate raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        var normalized = raw
        if let dot = raw.firstIndex(of: ".") {
            let fraction = raw[raw.index(after: dot)...].prefix(while: \.isNumber)
            let suffix = raw[raw.index(dot, offsetBy: fraction.count + 1)...]
            normalized = String(raw[..<dot]) + "." + fraction.prefix(3) + String(suffix)
        }
        return PlaylistPresentation.changedDate(normalized).map { $0.timeIntervalSince1970 * 1000 }
    }

    /// A Jellyfin audiobook as a library item.
    ///
    /// ONE track, no chapters, and that is not a gap: measured, a book on
    /// Jellyfin is exactly one file, `Chapters` is 0, and Jellyfin generates
    /// none for `AudioBook`. Building a chapter assembly here would be building
    /// for a case the server does not produce.
    nonisolated static func libraryItem(fromBook book: JFItem) -> LibraryItem {
        LibraryItem(
            id: itemId(bookId: book.id),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: book.name, authorName: book.albumArtist ?? book.artists?.first,
                    narratorName: nil, seriesName: nil,
                    genres: book.genres?.isEmpty == false ? book.genres : nil,
                    publishedYear: book.productionYear.map { LenientString(String($0)) },
                    description: book.overview
                ),
                duration: seconds(fromTicks: book.runTimeTicks),
                chapters: nil, tracks: nil
            ),
            addedAt: epochMs(fromJFDate: book.dateCreated)
        )
    }

    /// A folded book as a library item: the files of one folder as one book,
    /// keyed by the folder. The cover is the folder's, which Jellyfin fills
    /// from its files.
    nonisolated static func libraryItem(fromFolded group: JellyfinBookFold.Group,
                                        folderName: String?) -> LibraryItem {
        let first = group.elements[0]
        let total = group.elements.reduce(0.0) { $0 + (seconds(fromTicks: $1.runTimeTicks) ?? 0) }
        return LibraryItem(
            id: itemId(bookId: group.rawId),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: JellyfinBookFold.title(of: group.elements, folderName: folderName),
                    authorName: JellyfinBookFold.author(of: group.elements),
                    narratorName: nil, seriesName: nil,
                    genres: first.genres?.isEmpty == false ? first.genres : nil,
                    publishedYear: first.productionYear.map { LenientString(String($0)) },
                    description: first.overview),
                duration: total, chapters: nil, tracks: nil),
            addedAt: epochMs(fromJFDate: first.dateCreated))
    }

    nonisolated static func itemId(bookId: String) -> String { "jf:book:\(bookId)" }

    /// The measured reading position of a book, in seconds. Nil when the
    /// server knows none.
    nonisolated static func position(fromUserData userData: JFUserData?) -> Double? {
        guard let ticks = userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return ticks / 10_000_000
    }

    /// Which of the user's libraries is the audiobook one. Measured key:
    /// `CollectionType: "books"`.
    nonisolated static func booksView(in views: [JFItem]) -> JFItem? {
        views.first { $0.collectionType?.lowercased() == "books" }
    }

    nonisolated static func libraryItem(fromAlbum album: JFItem) -> LibraryItem {
        LibraryItem(
            id: itemId(albumId: album.id),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: album.name, authorName: album.albumArtist ?? album.artists?.first,
                    narratorName: nil, seriesName: nil,
                    genres: album.genres?.isEmpty == false ? album.genres : nil,
                    publishedYear: album.productionYear.map { LenientString(String($0)) },
                    description: nil
                ),
                duration: seconds(fromTicks: album.runTimeTicks),
                chapters: nil, tracks: nil
            ),
            addedAt: epochMs(fromJFDate: album.dateCreated)
        )
    }

    nonisolated static func songItem(from song: JFItem) -> LibraryItem {
        LibraryItem(
            id: itemId(songId: song.id),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: song.name, authorName: song.artists?.first ?? song.albumArtist,
                    narratorName: nil, seriesName: nil, genres: nil,
                    publishedYear: nil, description: nil),
                duration: seconds(fromTicks: song.runTimeTicks), chapters: nil, tracks: nil),
            addedAt: nil)
    }

    nonisolated static func domainArtist(_ item: JFItem) -> MusicArtist {
        MusicArtist(id: item.id, itemId: itemId(artistId: item.id), name: item.name, albumCount: item.childCount)
    }

    nonisolated static func domainPlaylist(_ item: JFItem) -> MusicPlaylist {
        MusicPlaylist(
            id: item.id, itemId: itemId(playlistId: item.id), name: item.name, songCount: item.childCount,
            duration: seconds(fromTicks: item.runTimeTicks),
            changedAt: epochMs(fromJFDate: item.dateCreated))
    }

    nonisolated static func songLyrics(from response: JFLyricsResponse) -> SongLyrics? {
        guard let rawLines = response.lyrics, !rawLines.isEmpty else { return nil }
        let synced = response.metadata?.isSynced == true
        let lines = rawLines.compactMap { line -> LyricsLine? in
            guard let text = line.text else { return nil }
            return LyricsLine(start: synced ? seconds(fromTicks: line.start) : nil, text: text)
        }
        guard !lines.isEmpty else { return nil }
        return SongLyrics(synced: synced, lines: lines)
    }

    nonisolated private static func tracksAndChapters(from songs: [JFItem])
        -> (tracks: [ABSAudioTrack], chapters: [ABSChapter], total: Double) {
        MusicTrackAssembly.build(songs.map {
            MusicTrackAssembly.Song(id: $0.id, title: $0.name,
                                    duration: seconds(fromTicks: $0.runTimeTicks) ?? 0, size: nil,
                                    artist: $0.artists?.first ?? $0.albumArtist, coverArt: $0.albumId)
        })
    }

    // MARK: - Id namespace

    /// The books library carries its Jellyfin view id, so the browse
    /// call knows which parent to ask.
    nonisolated static func libraryId(booksViewId: String) -> String { "jf:books:\(booksViewId)" }
    nonisolated static func booksViewId(fromLibraryId libraryId: String) -> String? {
        id(libraryId, kind: "books")
    }

    nonisolated static func itemId(albumId: String) -> String { "jf:album:\(albumId)" }
    nonisolated static func itemId(playlistId: String) -> String { "jf:playlist:\(playlistId)" }
    nonisolated static func itemId(songId: String) -> String { "jf:song:\(songId)" }
    nonisolated static func itemId(artistId: String) -> String { "jf:artist:\(artistId)" }

    nonisolated static func owns(itemId: String) -> Bool { itemId.hasPrefix("jf:") }

    nonisolated static func id(_ itemId: String, kind: String) -> String? {
        ItemNamespace.jellyfinId(itemId, kind: kind)
    }

    nonisolated private static func rawId(_ itemId: String) -> String? {
        guard itemId.hasPrefix("jf:") else { return nil }
        let raw = itemId.split(separator: ":", omittingEmptySubsequences: false).dropFirst(2).joined(separator: ":")
        return raw.isEmpty ? nil : raw
    }

    nonisolated func owns(itemId: String) -> Bool { Self.owns(itemId: itemId) }
    nonisolated func kind(of itemId: String) -> MusicItemKind? {
        if Self.id(itemId, kind: "album") != nil { return .album }
        if Self.id(itemId, kind: "playlist") != nil { return .playlist }
        if Self.id(itemId, kind: "song") != nil { return .song }
        if Self.id(itemId, kind: "artist") != nil { return .artist }
        return nil
    }
    nonisolated func itemId(playlistId: String) -> String { Self.itemId(playlistId: playlistId) }
    nonisolated func itemId(songId: String) -> String { Self.itemId(songId: songId) }
    nonisolated func itemId(artistId: String) -> String { Self.itemId(artistId: artistId) }
    nonisolated func artistId(fromItemId itemId: String) -> String? { Self.id(itemId, kind: "artist") }
}

// MARK: - Global search

extension JellyfinProvider: SearchableProvider {
    @MainActor
    func search(query: String) async throws -> [SearchResult] {
        guard let client, await Reachability.isConnected() else { return offlineSearch(query) }
        let hits = try await client.search(term: query)
        var out: [SearchResult] = []
        for hit in hits {
            guard let name = hit.name else { continue }
            switch hit.type {
            case "MusicArtist":
                searchedArtistsById[hit.id] = Self.domainArtist(hit)
                out.append(SearchResult(
                    id: itemId(artistId: hit.id), kind: .artist, title: name,
                    coverURL: coverURL(forItemId: itemId(artistId: hit.id))))
            case "MusicAlbum":
                let item = Self.libraryItem(fromAlbum: hit)
                itemsById[item.id] = item
                out.append(SearchResult(
                    id: item.id, kind: .album, title: item.title,
                    subtitle: hit.albumArtist, coverURL: coverURL(forItemId: item.id)))
            case "Audio":
                let item = Self.songItem(from: hit)
                if itemsById[item.id] == nil { itemsById[item.id] = item }
                out.append(SearchResult(
                    id: item.id, kind: .song, title: name,
                    subtitle: hit.artists?.first, coverURL: coverURL(forItemId: item.id)))
            case "Playlist":
                // Jellyfin ships playlist hits SERVER-side (unlike
                // Subsonic's local filter. Honest asymmetry, reported).
                let pid = itemId(playlistId: hit.id)
                if itemsById[pid] == nil {
                    itemsById[pid] = LibraryItem(
                        id: pid,
                        media: LibraryItemMedia(
                            metadata: LibraryItemMetadata(
                                title: name, authorName: nil, narratorName: nil,
                                seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                            duration: nil, chapters: nil, tracks: nil),
                        addedAt: nil)
                }
                out.append(SearchResult(
                    id: pid, kind: .playlist, title: name,
                    coverURL: coverURL(forItemId: pid)))
            default:
                continue
            }
        }
        return out
    }

    private func offlineSearch(_ query: String) -> [SearchResult] {
        itemsById.values.compactMap { item in
            guard PodcastLocalSearch.matches(item.title, query)
                || (item.author.map { PodcastLocalSearch.matches($0, query) } ?? false)
            else { return nil }
            let kind: SearchResult.Kind = item.id.hasPrefix("jf:song:") ? .song : .album
            return SearchResult(
                id: item.id, kind: kind, title: item.title,
                subtitle: item.author, coverURL: coverURL(forItemId: item.id),
                isPlayableNow: DownloadManager.shared.isDownloaded(itemId: item.id))
        }
    }
}
