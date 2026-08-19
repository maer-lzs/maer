// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// 0714d26: playback resolution for the free-catalog rows — owns the
/// `lv:` (LibriVox book), `lva:` (archive.org item) and `jam:` (Jamendo
/// track) namespaces. NOT a library source: `isAvailable` stays false (no
/// tab, no search fan-out) — the Discover rows remember their items here and
/// the player routes by prefix like everywhere else.
@MainActor
final class FreeCatalogProvider: AudioProvider {
    static let shared = FreeCatalogProvider()
    private init() {}

    var providerId: String { "freecatalog" }
    var mediaTypes: Set<MediaType> { [.audiobooks] }
    var capabilities: ProviderCapabilities { [] }
    var streamAuthHeaders: [String: String] { [:] }
    /// Deliberately false — Discover-only surface, never a tab/search source.
    var isAvailable: Bool { false }

    /// The ONE moment the form is knowable: the item was just fetched to be
    /// played, so its collections are warm. Written onto the entry, which
    /// already travels between devices — later nobody can answer this any more,
    /// because the collections live only in memory.
    ///
    /// An item whose collections say nothing gets NO form. It then behaves
    /// exactly as before (Continue keeps it, "Listen Again" never shows it) —
    /// guessing here would put a reading into the music row, and that is the
    /// one mistake this switch exists to prevent.
    func notePlaybackStarted(itemId: String) {
        guard let form = archiveForm(itemId: itemId) else { return }
        ListeningStore.noteStartedForm(
            itemId, form: form == .album ? .album : .work,
            atMs: Date().timeIntervalSince1970 * 1000)
    }

    /// Session caches the rows fill (id → source object).
    private var librivoxBooks: [String: LibriVoxBook] = [:]
    private var jamendoTracks: [String: JamendoTrack] = [:]
    private var itemsById: [String: LibraryItem] = [:]

    func remember(book: LibriVoxBook) -> LibraryItem {
        if let page = book.url_librivox.flatMap({ URL(string: $0) }) {
            librivoxPages[FreeCatalog.librivoxPrefix + book.id] = page
        }
        let id = FreeCatalog.librivoxPrefix + book.id
        librivoxBooks[id] = book
        // 40b8f96: LibriVox recordings are public domain — the capsule says so
        // instead of leaving the class blank where we DO know it.
        licences[id] = String(localized: "Public domain")
        // Q2: ONE normalization at the intake — every surface shows it.
        let normalized = book.title.map(FreeCatalog.normalizedTitle)
        readingVersions[id] = normalized?.version
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: normalized?.title, authorName: FreeCatalog.authorLine(book.authors),
                    // 48e786d Schritt 0: pass the genres THROUGH — they were
                    // decoded away for months while the axis waited for them.
                    narratorName: nil, seriesName: nil,
                    genres: book.genres?.compactMap(\.name),
                    publishedYear: nil, description: nil),
                duration: book.totaltimesecs.map(Double.init), chapters: nil, tracks: nil),
            addedAt: nil)
        itemsById[id] = item
        return item
    }

    /// The collections an item belongs to, per item id — filled at every
    /// intake (search index and metadata endpoint alike). It replaces the set
    /// of identifiers that only the radio-play row used to fill: what an item
    /// IS travelled with the row that showed it, so the same item was a series
    /// bundle from one surface and an ordinary item from another.
    private var itemCollections: [String: [String]] = [:]

    private func rememberCollections(_ collections: [String]?, forItemId id: String) {
        guard let collections, !collections.isEmpty else { return }
        let known = itemCollections.updateValue(collections, forKey: id)
        // An item whose collections say nothing about its form keeps the
        // surface's own default — a defensible choice, but never a silent one:
        // it is named here, once per item, with what the source did say.
        if known == nil, ArchiveItemForm.of(collections: collections) == nil {
            Logger.library.notice("CATALOG form unknown for \(id, privacy: .public) — collections \(collections.joined(separator: ","), privacy: .public); the surface keeps its default")
        }
    }

    /// Is the item one work in parts or an album of tracks? `nil` means the
    /// collections are not known yet — before any fetch there is nothing to
    /// read, and the caller keeps its own default until the detail arrives.
    func archiveForm(itemId: String) -> ArchiveItemForm? {
        guard let collections = itemCollections[itemId] else { return nil }
        return ArchiveItemForm.of(collections: collections)
    }

    /// Auftrag O: is this item a radio-play series bundle (the class that gets
    /// a SHOW PAGE with an episode list instead of the detail sheet)?
    func isOldTimeRadio(itemId: String) -> Bool {
        guard let collections = itemCollections[itemId] else { return false }
        return ArchiveItemForm.isRadioPlayBundle(collections: collections)
    }

    /// e948444: stated licence per item id, for the detail sheet.
    private var licences: [String: String] = [:]
    /// Q3: reading version per item id ("Lesung 2") — a meta fact, never part
    /// of the title and never a dedupe (multiple readings are legitimate).
    private var readingVersions: [String: Int] = [:]

    func readingVersion(forItemId id: String) -> Int? { readingVersions[id] }

    func licence(forItemId id: String) -> String? { licences[id] }

    /// 0ce5df3: a Gutenberg audiobook as a library item. Non-audiobooks
    /// (music examples inside scholarly texts) are filtered by path.
    func remember(gutenberg book: GutenbergClient.Book) -> LibraryItem? {
        guard let audio = book.formats?["audio/mpeg"],
              FreeCatalog.isGutenbergAudiobook(audio) else { return nil }
        let id = FreeCatalog.gutenbergPrefix + String(book.id)
        gutenbergAudio[id] = audio
        // Device finding: the Gutenberg tiles came up WITHOUT covers.
        // Cause: the cover url rode along in `formats` and was dropped here,
        // and `coverURL(forItemId:)` had no gut: branch at all — so every
        // Gutenberg tile fell back to the placeholder. Measured at gutendex
        // before building: 32 of 32 entries on page 1 carry an image/jpeg, and
        // the urls answer 200 image/jpeg (no hotlink block).
        gutenbergCovers[id] = FreeCatalog.gutenbergCoverURL(formats: book.formats)
        licences[id] = String(localized: "Public domain")
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: book.title ?? "—",
                    authorName: book.authors?.compactMap(\.name).first,
                    narratorName: nil, seriesName: nil,
                    genres: book.subjects,
                    publishedYear: nil, description: nil),
                duration: nil, chapters: nil, tracks: nil),
            addedAt: nil)
        itemsById[id] = item
        return item
    }

    private var gutenbergAudio: [String: String] = [:]
    private var gutenbergCovers: [String: URL] = [:]

    func gutenbergAudioURL(forItemId id: String) -> String? { gutenbergAudio[id] }

    func remember(popular doc: ArchivePopularDoc) -> LibraryItem? {
        guard let identifier = doc.identifier else { return nil }
        // 🟡 P10: a KNOWN-dead identifier never becomes a tile again — the
        // curated rows skip it and fill up. Search and direct navigation do
        // not read this list (same line as "not interested"): they answer
        // what the index holds, and a dead item there is honest.
        guard !DeadCatalogItems.isDead(identifier) else { return nil }
        let id = FreeCatalog.archivePrefix + identifier
        if let licence = FreeCatalog.licenceLabel(doc.licenseurl) { licences[id] = licence }
        rememberCollections(doc.collection?.values, forItemId: id)
        // Q2: archive rows carry the same LibriVox title pattern (the
        // librivoxaudio collection) — same one-place normalization.
        // O-P3 (09.08.): the OTR bundles additionally carry archive.org
        // COLLECTION housekeeping in the title („… - Single Episodes"), which
        // pushed the work's name out of the tile. Same family, applied first.
        let normalized = doc.title?.first
            .map(FreeCatalog.normalizedCollectionTitle)
            .map(FreeCatalog.normalizedTitle)
        readingVersions[id] = normalized?.version
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    // 3ac9183: first entry leads (composer first); the
                    // detail sheet names everyone via the joined form.
                    title: normalized?.title, authorName: doc.creator?.first, narratorName: nil,
                    // 50aefa8: the recording year, where the index has one.
                    seriesName: nil, genres: doc.subject?.values,
                    publishedYear: doc.year?.first.map(LenientString.init),
                    description: nil),
                // ea6e002: the search index carries the runtime for most
                // items — the card's time line reads it from here.
                duration: FreeCatalog.runtimeSeconds(doc.runtime), chapters: nil, tracks: nil),
            addedAt: nil)
        itemsById[id] = item
        return item
    }

    func remember(track: JamendoTrack) -> LibraryItem? {
        guard let trackId = track.id else { return nil }
        let id = FreeCatalog.jamendoPrefix + trackId
        jamendoTracks[id] = track
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    // Befund W: Jamendo delivers names HTML-encoded
                    // ("Bessonn&amp;sa") — decode at the ONE intake through
                    // the existing text preparation (Regel 2, no second
                    // decoder). Title AND artist.
                    title: track.name.map(podcastPlainText),
                    authorName: track.artist_name.map(podcastPlainText),
                    narratorName: nil,
                    seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: track.duration.map(Double.init), chapters: nil, tracks: nil),
            addedAt: nil)
        itemsById[id] = item
        return item
    }

    func libraryItem(forId id: String) -> LibraryItem? { itemsById[id] }
    func librivoxBook(forId id: String) -> LibriVoxBook? { librivoxBooks[id] }
    func jamendoTrack(forId id: String) -> JamendoTrack? { jamendoTracks[id] }

    /// M1-Auflage (09.08.): the source page of a catalog item — the ToS-
    /// mandated backlink for Jamendo, and the honest provenance for the
    /// archive/LibriVox items. Needed because the music tiles now PLAY on
    /// tap and thereby skip the detail sheet, where the attribution used to
    /// live; the player carries it instead. nil for anything that is not a
    /// catalog item.
    func sourceURL(forItemId id: String) -> URL? {
        if id.hasPrefix(FreeCatalog.jamendoPrefix) {
            return jamendoTracks[id]?.shareurl.flatMap { URL(string: $0) }
        }
        if id.hasPrefix(FreeCatalog.archivePrefix) {
            let identifier = String(id.dropFirst(FreeCatalog.archivePrefix.count))
            return URL(string: "https://archive.org/details/\(FreeCatalog.encodedPathSegment(identifier))")
        }
        if id.hasPrefix(FreeCatalog.librivoxPrefix) {
            return librivoxPages[id]
        }
        if id.hasPrefix(FreeCatalog.gutenbergPrefix) {
            let bookId = String(id.dropFirst(FreeCatalog.gutenbergPrefix.count))
            return URL(string: "https://www.gutenberg.org/ebooks/\(bookId)")
        }
        return nil
    }

    /// The LibriVox catalogue page per remembered book (the API gives it).
    private var librivoxPages: [String: URL] = [:]

    // MARK: - AudioProvider

    func fetchLibraries() async throws -> [ABSLibrary] { [] }
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }

    /// 9081fa1 Strukturfix: detail metadata STARTS from the remembered item
    /// and overrides only what the detail answer really knows better. Year and
    /// genres were each forgotten here once — with this, a field added on the
    /// remember side reaches the detail automatically, instead of being a
    /// change at four places that is missed at three.
    private func detailMetadata(itemId: String,
                                title: String?, authorName: String?,
                                description: String? = nil) -> LibraryItemMetadata {
        let known = itemsById[itemId]?.media?.metadata
        return LibraryItemMetadata(
            title: title ?? known?.title,
            authorName: authorName ?? known?.authorName,
            narratorName: known?.narratorName,
            seriesName: known?.seriesName,
            genres: known?.genres,
            publishedYear: known?.publishedYear,
            // Auftrag O/P2: the metadata API's description reaches the detail.
            description: description ?? known?.description)
    }

    /// Marks releases whose stored album position was already carried over.
    private static let migratedKey = "catalogSongPositionMigrated"

    /// Carries a stored album position over to the song it falls into. Runs
    /// once per release, changes nothing else, and never invents an entry.
    static func migrateAlbumPositionToSong(albumId: String) async {
        var done = Set(UserDefaults.standard.stringArray(forKey: migratedKey) ?? [])
        guard !done.contains(albumId) else { return }
        defer {
            done.insert(albumId)
            UserDefaults.standard.set(Array(done), forKey: migratedKey)
        }
        guard let stored = ListeningStore.backup(albumId),
              stored.count >= 2, stored[0] > 0 else { return }
        guard let detail = try? await shared.fetchAlbumDetail(albumId: albumId),
              let tracks = detail.media.tracks else { return }
        // The decision itself is pure and tested — including against an
        // IMPORTED stock, which is what a new user starts with.
        let songIdFor = { (index: Int) in CatalogSongID.make(album: albumId, index: index) }
        guard let carried = CatalogPositionMigration.songEntry(
            albumPosition: stored, tracks: tracks,
            songAlreadyHasEntry: FreeCatalog.trackIndex(at: stored[0], tracks: tracks)
                .map { ListeningStore.hasStand(songIdFor($0)) } ?? false)
        else { return }
        ListeningStore.store(songIdFor(carried.index), entry: carried.entry)
        Logger.library.notice("CATALOG carried album position to song index \(carried.index) of \(albumId, privacy: .public)")
    }

    /// The release itself, without the song shortcut — used by the migration.
    private func fetchAlbumDetail(albumId: String) async throws -> LibraryItemDetail {
        let identifier = String(albumId.dropFirst(FreeCatalog.archivePrefix.count))
        let meta = try await ArchiveOrgClient.metadata(identifier: identifier)
        let tracks = FreeCatalog.archiveTracks(identifier: identifier, files: meta.files ?? [])
        guard !tracks.isEmpty else { throw URLError(.resourceUnavailable) }
        return LibraryItemDetail(id: albumId,
                                 media: LibraryItemMedia(metadata: nil, duration: nil,
                                                         chapters: nil, tracks: tracks),
                                 userMediaProgress: nil)
    }

    /// One track of a release as an item of its own. Built from the release's
    /// files, so the song carries the title and performer the source states —
    /// not the album's.
    private func songDetail(songId: String, album albumId: String,
                            index: Int) async throws -> LibraryItemDetail {
        let identifier = String(albumId.dropFirst(FreeCatalog.archivePrefix.count))
        let meta = try await ArchiveOrgClient.metadata(identifier: identifier)
        let files = FreeCatalog.preferredAudioFiles(meta.files ?? [])
            .sorted { FreeCatalog.orderKey($0) < FreeCatalog.orderKey($1) }
        guard index < files.count else { throw URLError(.resourceUnavailable) }
        let tracks = FreeCatalog.archiveTracks(identifier: identifier, files: files)
        guard index < tracks.count else { throw URLError(.resourceUnavailable) }
        let file = files[index]
        let track = tracks[index]
        // The song starts at zero — it is the whole item now, not a section.
        let single = ABSAudioTrack(index: 0, startOffset: 0, duration: track.duration,
                                   contentUrl: track.contentUrl, metadata: track.metadata)
        let performer = file.creator ?? meta.metadata?.creator?.joined
        let songDetail = LibraryItemDetail(
            id: songId,
            media: LibraryItemMedia(
                metadata: detailMetadata(itemId: songId,
                                         title: FreeCatalog.trackTitle(file),
                                         authorName: performer,
                                         description: file.album ?? meta.metadata?.title?.first),
                duration: track.duration, chapters: nil, tracks: [single]),
            userMediaProgress: nil)
        rememberResolved(songDetail)
        return songDetail
    }

    /// What a detail fetch resolved goes into the session cache — "not in
    /// memory" must not stay true one fetch after the answer arrived. This is
    /// what lets a queue or playlist row fill itself in on demand.
    private func rememberResolved(_ detail: LibraryItemDetail) {
        guard itemsById[detail.id] == nil else { return }
        itemsById[detail.id] = LibraryItem(id: detail.id, media: detail.media, addedAt: nil)
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        if itemId.hasPrefix(FreeCatalog.librivoxPrefix) {
            guard let book = librivoxBooks[itemId] else { throw URLError(.resourceUnavailable) }
            let tracks = FreeCatalog.tracks(from: book.sections)
            guard !tracks.isEmpty else { throw URLError(.resourceUnavailable) }
            return LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(
                    metadata: detailMetadata(itemId: itemId, title: book.title,
                                             authorName: FreeCatalog.authorLine(book.authors)),
                    duration: book.totaltimesecs.map(Double.init), chapters: nil,
                    tracks: tracks),
                userMediaProgress: nil)
        }
        if itemId.hasPrefix(FreeCatalog.archivePrefix) {
            // A song address resolves to a SINGLE-track item: its own title,
            // its own duration, and therefore its own position, its own place
            // in a playlist and its own "played".
            if let song = CatalogSongID.parse(itemId) {
                return try await songDetail(songId: itemId, album: song.album, index: song.index)
            }
            let identifier = String(itemId.dropFirst(FreeCatalog.archivePrefix.count))
            let meta = try await ArchiveOrgClient.metadata(identifier: identifier)
            // This endpoint answers for every item, including one that no row
            // ever showed — so the form is known here even on a cold start.
            rememberCollections(meta.metadata?.collection?.values, forItemId: itemId)
            let collections = itemCollections[itemId] ?? []
            // A position stored before tracks had addresses points at the whole
            // release. It is carried over to the song it falls into, once, and
            // the album entry stays untouched — nobody loses where they were.
            // Only an ALBUM is carried over: for a work the single position IS
            // the truth, and splitting it into per-track marks would lose it.
            if ArchiveItemForm.of(collections: collections) == .album {
                await Self.migrateAlbumPositionToSong(albumId: itemId)
            }
            let tracks = FreeCatalog.archiveTracks(identifier: identifier, files: meta.files ?? [])
            guard !tracks.isEmpty else { throw URLError(.resourceUnavailable) }
            // aed5d25 (2): plausibility gate — a collection bundle with
            // hundreds of parts is not a book; named in the log, never mute.
            // e948444: a CURATED series collection passes the higher bound —
            // there the bundle is the unit, not an accident. Read from the
            // item's own collections, so a bundle reached by deep link or from
            // a playlist is no longer dropped for being too long.
            let cap = ArchiveItemForm.isRadioPlayBundle(collections: collections)
                ? FreeCatalog.seriesTrackCap : FreeCatalog.defaultTrackCap
            guard FreeCatalog.trackCountPlausible(tracks.count, cap: cap) else {
                Logger.library.notice("FREECAT gate: \(identifier, privacy: .public) dropped — \(tracks.count) tracks (collection bundle)")
                throw URLError(.resourceUnavailable)
            }
            let total = tracks.compactMap(\.duration).reduce(0, +)
            let detail = LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(
                    // The hand-rescued title fallback is covered by the helper.
                    metadata: detailMetadata(itemId: itemId,
                                             title: meta.metadata?.title?.first,
                                             authorName: meta.metadata?.creator?.joined,
                                             description: meta.metadata?.description?.joined),
                    duration: total > 0 ? total : nil, chapters: nil, tracks: tracks),
                userMediaProgress: nil)
            rememberResolved(detail)
            return detail
        }
        if itemId.hasPrefix(FreeCatalog.jamendoPrefix) {
            guard let track = jamendoTracks[itemId], let audio = track.audio, !audio.isEmpty else {
                throw URLError(.resourceUnavailable)
            }
            return LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(
                    metadata: detailMetadata(itemId: itemId, title: track.name,
                                             authorName: track.artist_name),
                    duration: track.duration.map(Double.init), chapters: nil,
                    tracks: [ABSAudioTrack(index: 0, startOffset: 0,
                                           duration: track.duration.map(Double.init),
                                           contentUrl: audio, metadata: nil)]),
                userMediaProgress: nil)
        }
        if itemId.hasPrefix(FreeCatalog.gutenbergPrefix) {
            // This branch was missing: the stored audio url had no caller at
            // all, so a tap on a Gutenberg tile ran into resourceUnavailable
            // and those titles were never playable.
            guard let audio = gutenbergAudio[itemId] else {
                throw URLError(.resourceUnavailable)
            }
            let known = itemsById[itemId]
            return LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(
                    metadata: detailMetadata(itemId: itemId, title: nil, authorName: nil),
                    duration: known?.media?.duration, chapters: nil,
                    tracks: [ABSAudioTrack(index: 0, startOffset: 0,
                                           duration: known?.media?.duration,
                                           contentUrl: audio, metadata: nil)]),
                userMediaProgress: nil)
        }
        throw URLError(.resourceUnavailable)
    }

    /// b395e5f: session cache id → hi-res cover (resolved lazily; nil result
    /// is cached too so a broken feed is fetched only once).
    private var hiresCovers: [String: URL?] = [:]

    /// b395e5f: resolve the HI-RES cover behind a LibriVox book — ONE light
    /// tag scan of the book's `url_rss` (itunes:image; no full feed parse),
    /// redirects followed by URLSession. Falls back to nil → callers keep
    /// the archive thumb; failures stay silent by spec (log only).
    func hiresCoverURL(forItemId itemId: String) async -> URL? {
        if let cached = hiresCovers[itemId] { return cached }
        guard itemId.hasPrefix(FreeCatalog.librivoxPrefix),
              let rss = librivoxBooks[itemId]?.url_rss, let url = URL(string: rss) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await RequestRetryPolicy.fetch(request)
            let resolved = FreeCatalog.extractItunesImage(data).flatMap { URL(string: $0) }
            hiresCovers[itemId] = resolved
            return resolved
        } catch {
            Logger.library.notice("FREECAT hires-cover failed (thumb stays): \(String(describing: error), privacy: .public)")
            hiresCovers[itemId] = URL?.none
            return nil
        }
    }

    func coverURL(forItemId itemId: String) -> URL? {
        if itemId.hasPrefix(FreeCatalog.librivoxPrefix) {
            guard let book = librivoxBooks[itemId],
                  let identifier = FreeCatalog.iarchiveIdentifier(from: book.url_iarchive)
            else { return nil }
            return FreeCatalog.archiveCoverURL(identifier: identifier)
        }
        if itemId.hasPrefix(FreeCatalog.archivePrefix) {
            return FreeCatalog.archiveCoverURL(
                identifier: String(itemId.dropFirst(FreeCatalog.archivePrefix.count)))
        }
        if itemId.hasPrefix(FreeCatalog.jamendoPrefix) {
            return jamendoTracks[itemId]?.image.flatMap { URL(string: $0) }
        }
        if itemId.hasPrefix(FreeCatalog.gutenbergPrefix) {
            return gutenbergCovers[itemId]
        }
        return nil
    }

    func streamURL(forContentPath contentPath: String) -> URL? { URL(string: contentPath) }

    // MARK: - ProgressSyncAPI (local-only: no server truth to sync)

    func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}

    // No bookmark capability — the empty contract shape (capability-gated).
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}
}
