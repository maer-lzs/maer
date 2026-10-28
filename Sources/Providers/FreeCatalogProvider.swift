// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Playback resolution for the free-catalog rows. Owns the
/// `lv:` (LibriVox book), `lva:` (archive.org item) and `jam:` (Jamendo
/// track) namespaces. NOT a library source: `isAvailable` stays false (no
/// tab, no search fan-out). The Discover rows remember their items here and
/// the player routes by prefix like everywhere else.
@MainActor
final class FreeCatalogProvider: AudioProvider {
    static let shared = FreeCatalogProvider()
    private init() {
        // A Gutenberg title kept before its rules existed reads readable too.
        kept = (Ablage.documents.loadNow([LibraryItem].self, name: Self.keptDocument).value ?? [])
            .map(FreeCatalog.gutenbergReadable)
        for item in kept where itemsById[item.id] == nil { itemsById[item.id] = item }
    }

    /// The titles resolved for playback, with their metadata
    /// (`CatalogKeptItems`): every surface that names a catalog title by its
    /// id finds it from the first display on.
    nonisolated static let keptDocument = "catalog-kept-items.json"
    private var kept: [LibraryItem] = []

    var providerId: String { "freecatalog" }
    var mediaTypes: Set<MediaType> { [.audiobooks] }
    var keepsMarksOnDevice: Bool { true }
    var capabilities: ProviderCapabilities { [] }
    var streamAuthHeaders: [String: String] { [:] }
    /// Deliberately false. Discover-only surface, never a tab/search source.
    var isAvailable: Bool { false }

    /// The ONE moment the form is knowable: the item was just fetched to be
    /// played, so its collections are warm. Written onto the entry, which
    /// already travels between devices. Later nobody can answer this any more,
    /// because the collections live only in memory.
    ///
    /// An item whose collections say nothing gets NO form. It then behaves
    /// exactly as before (Continue keeps it, "Listen Again" never shows it).
    /// Guessing here would put a reading into the music row, and that is the
    /// one mistake this switch exists to prevent.
    func notePlaybackStarted(itemId: String) {
        guard let form = startedForm(itemId: itemId) else { return }
        ListeningStore.noteStartedForm(itemId, form: form, atMs: Date().timeIntervalSince1970 * 1000)
    }

    /// The form the collections give an item while they are warm, in the
    /// vocabulary of the mark; nil when they say nothing. The player asks
    /// it before the start notes the mark.
    func startedForm(itemId: String) -> ProgressMark.StartedForm? {
        archiveForm(itemId: itemId).map { $0 == .album ? .album : .work }
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
        // LibriVox recordings are public domain in the USA, "not necessarily
        // in other countries" (LibriVox's own words), so the label says where.
        licences[id] = String(localized: "Public domain in the USA")
        // ONE normalization at the intake. Every surface shows it.
        let normalized = book.title.map(FreeCatalog.normalizedTitle)
        readingVersions[id] = normalized?.version
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: FreeCatalog.shownTitle(normalized?.title, itemId: id),
                    authorName: FreeCatalog.authorLine(book.authors),
                    // Pass the genres THROUGH. They were
                    // decoded away for months while the axis waited for them.
                    narratorName: nil, seriesName: nil,
                    genres: book.genres?.compactMap(\.name),
                    publishedYear: nil, description: nil),
                duration: book.totaltimesecs.map(Double.init), chapters: nil, tracks: nil),
            addedAt: nil)
        itemsById[id] = item
        return item
    }

    /// The collections an item belongs to, per item id. Filled at every
    /// intake (search index and metadata endpoint alike). It replaces the set
    /// of identifiers that only the radio-play row used to fill: what an item
    /// IS travelled with the row that showed it, so the same item was a series
    /// bundle from one surface and an ordinary item from another.
    private var itemCollections: [String: [String]] = [:]

    private func rememberCollections(_ collections: [String]?, forItemId id: String) {
        guard let collections, !collections.isEmpty else { return }
        let known = itemCollections.updateValue(collections, forKey: id)
        // An item whose collections say nothing about its form keeps the
        // surface's own default. A defensible choice, but never a silent one:
        // it is named here, once per item, with what the source did say.
        if known == nil, ArchiveItemForm.of(collections: collections) == nil {
            Logger.library.notice("CATALOG form unknown for \(id, privacy: .public) — collections \(collections.joined(separator: ","), privacy: .public); the surface keeps its default")
        }
    }

    /// Is the item one work in parts or an album of tracks? `nil` means the
    /// collections are not known yet. Before any fetch there is nothing to
    /// read, and the caller keeps its own default until the detail arrives.
    func archiveForm(itemId: String) -> ArchiveItemForm? {
        guard let collections = itemCollections[itemId] else { return nil }
        return ArchiveItemForm.of(collections: collections)
    }

    /// Is this item a radio-play series bundle (the class that gets
    /// a SHOW PAGE with an episode list instead of the detail sheet)?
    /// The question is whether the item has PARTS, not whether it lies in
    /// the radio-play collection: the callers want to know whether a parts
    /// list opens.
    func hasPartsList(itemId: String) -> Bool {
        guard let collections = itemCollections[itemId] else { return false }
        return ArchiveItemForm.hasParts(collections: collections)
    }

    /// Stated licence per item id, for the detail sheet.
    private var licences: [String: String] = [:]
    /// Reading version per item id ("Lesung 2"). A meta fact, never part
    /// of the title and never a dedupe (multiple readings are legitimate).
    private var readingVersions: [String: Int] = [:]

    func readingVersion(forItemId id: String) -> Int? { readingVersions[id] }

    func licence(forItemId id: String) -> String? { licences[id] }

    /// A Gutenberg audiobook as a library item. Non-audiobooks
    /// (music examples inside scholarly texts) are filtered by path.
    func remember(gutenberg book: GutenbergClient.Book) -> LibraryItem? {
        guard let audio = book.formats?["audio/mpeg"],
              FreeCatalog.isGutenbergAudiobook(audio) else { return nil }
        let id = FreeCatalog.gutenbergPrefix + String(book.id)
        // gutendex's `formats` holds ONE address per type, so a reading in
        // three files arrives here as one of them. The address is not kept:
        // the work plays from its record like a stock title (`GutenbergWorks`),
        // one conversion for both ways in.
        // Device finding: the Gutenberg tiles came up WITHOUT covers.
        // Cause: the cover url rode along in `formats` and was dropped here,
        // and `coverURL(forItemId:)` had no gut: branch at all. So every
        // Gutenberg tile fell back to the placeholder. Measured at gutendex
        // before building: 32 of 32 entries on page 1 carry an image/jpeg, and
        // the urls answer 200 image/jpeg (no hotlink block).
        gutenbergCovers[id] = FreeCatalog.gutenbergCoverURL(formats: book.formats)
        // No rights capsule on a tile: the record states the rights per
        // work, and several say "Copyrighted". The title page shows what the
        // record says once it is opened.
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: FreeCatalog.shownTitle(book.title, itemId: id),
                    authorName: FreeCatalog.gutenbergAuthor(book.authors?.compactMap(\.name).first),
                    narratorName: nil, seriesName: nil,
                    genres: FreeCatalog.gutenbergGenres(book.subjects),
                    publishedYear: nil, description: nil),
                duration: nil, chapters: nil, tracks: nil),
            addedAt: nil)
        itemsById[id] = item
        return item
    }

    /// A work of the kept Gutenberg stock as a library item. The stock
    /// carries number, title, author and subjects, no sound: the files and
    /// their durations are resolved when the work is opened
    /// (`GutenbergWorks`), never for a row.
    private func remember(gutenbergStock doc: ArchivePopularDoc, id: String) -> LibraryItem {
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: FreeCatalog.shownTitle(doc.title?.first, itemId: id),
                    authorName: FreeCatalog.gutenbergAuthor(doc.creator?.first),
                    narratorName: nil, seriesName: nil,
                    genres: FreeCatalog.gutenbergGenres(doc.subject?.values),
                    publishedYear: nil, description: nil),
                duration: nil, chapters: nil, tracks: nil),
            addedAt: nil)
        itemsById[id] = item
        return item
    }

    private var gutenbergCovers: [String: URL] = [:]
    /// The original picture of an archive item, per identifier, for the
    /// large views; learnt wherever the item's files are read anyway, never
    /// asked for its own sake (`noteFiles`).
    private var archiveOriginalCovers: [String: URL] = [:]

    #if DEBUG
    /// Test seam: the session's learnt originals forgotten, as a restart
    /// leaves them.
    func testForgetOriginalCovers() { archiveOriginalCovers = [:] }
    #endif

    /// Keeps the original picture of an item whose files were just read.
    private func noteFiles(_ meta: ArchiveDecoder.MetadataResponse, identifier: String) {
        if let cover = FreeCatalog.archiveOriginalCover(identifier: identifier, files: meta.files ?? []) {
            archiveOriginalCovers[identifier] = cover
        }
    }
    /// The one resolver of Gutenberg works, owned here; a witness hands in its own.
    private let gutenbergWorks = GutenbergWorks()

    func remember(popular doc: ArchivePopularDoc) -> LibraryItem? {
        guard let identifier = doc.identifier else { return nil }
        // 🟡 A KNOWN-dead identifier never becomes a tile again. The
        // curated rows skip it and fill up. Search and direct navigation do
        // not read this list (same line as "not interested"): they answer
        // what the index holds, and a dead item there is honest.
        guard !DeadCatalogItems.isDead(identifier) else { return nil }
        // A kept Gutenberg stock hands its works over in the same document
        // shape, with `gut:<number>` as identifier. They are Gutenberg titles,
        // never archive items: under the archive prefix they asked archive.org
        // for `gut:5884` and never played.
        if identifier.hasPrefix(FreeCatalog.gutenbergPrefix) {
            return remember(gutenbergStock: doc, id: identifier)
        }
        let id = FreeCatalog.archivePrefix + identifier
        if let licence = FreeCatalog.licenceLabel(doc.licenseurl) { licences[id] = licence }
        // A recording whose US term has run out is public domain by LAW,
        // not by uploader claim; the year is the recording year the index
        // states. Computed from the current year, so the boundary moves by
        // itself. It upgrades only the UNSTATED case: a stated licence is
        // the source's own word and stays. The download gate is untouched,
        // it keys on the stated licence URL alone.
        if licences[id] == FreeCatalog.unstatedRights,
           let yearText = doc.year?.first, let year = Int(yearText.prefix(4)),
           FreeCatalog.recordingIsPublicDomain(
               year: year, currentYear: Calendar.current.component(.year, from: Date())) {
            // The US term, so public domain there.
            licences[id] = String(localized: "Public domain in the USA")
        }
        rememberCollections(doc.collection?.values, forItemId: id)
        // Archive rows carry the same LibriVox title pattern (the
        // librivoxaudio collection). Same one-place normalization.
        // The OTR bundles additionally carry archive.org COLLECTION
        // housekeeping in the title (`… - Single Episodes`), which pushes the
        // work's name out of the tile. Same family, applied first.
        let normalized = doc.title?.first
            .map(FreeCatalog.repairedMojibake)
            .map(FreeCatalog.normalizedCollectionTitle)
            .map(FreeCatalog.normalizedTitle)
        readingVersions[id] = normalized?.version
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    // First entry leads (composer first); the
                    // detail sheet names everyone via the joined form.
                    title: FreeCatalog.shownTitle(normalized?.title, itemId: id),
                    // Same stored mojibake as the title, and more of it
                    // (30 titles against 514 creators, measured).
                    authorName: doc.creator?.first.map(FreeCatalog.repairedMojibake),
                    narratorName: nil,
                    // The recording year, where the index has one.
                    seriesName: nil, genres: doc.subject?.values,
                    publishedYear: doc.year?.first.map(LenientString.init),
                    description: nil),
                // The search index carries the runtime for most
                // items. The card's time line reads it from here.
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
                    // Jamendo delivers names HTML-encoded. Decode at the
                    // ONE intake through the existing text preparation, not
                    // in a second decoder. Title AND artist.
                    title: FreeCatalog.shownTitle(track.name.map(podcastPlainText), itemId: id),
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

    /// The source page of a catalog item: the ToS-
    /// mandated backlink for Jamendo, and the honest provenance for the
    /// archive/LibriVox items. Needed because the music tiles now PLAY on
    /// tap and thereby skip the detail sheet, where the attribution used to
    /// live; the player carries it instead. nil for anything that is not a
    /// catalog item.
    func sourceURL(forItemId id: String) -> URL? {
        if id.hasPrefix(FreeCatalog.jamendoPrefix) {
            return jamendoTracks[id]?.shareurl.flatMap { URL(string: $0) }
        }
        if let identifier = FreeCatalog.archiveIdentifier(of: id) {
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

    /// Detail metadata STARTS from the remembered item
    /// and overrides only what the detail answer really knows better. Year and
    /// genres were each forgotten here once. With this, a field added on the
    /// remember side reaches the detail automatically, instead of being a
    /// change at four places that is missed at three.
    private func detailMetadata(itemId: String,
                                title: String?, authorName: String?,
                                description: String? = nil) -> LibraryItemMetadata {
        let known = itemsById[itemId]?.media?.metadata
        return LibraryItemMetadata(
            title: FreeCatalog.shownTitle(title ?? known?.title, itemId: itemId),
            authorName: authorName ?? known?.authorName,
            narratorName: known?.narratorName,
            seriesName: known?.seriesName,
            genres: known?.genres,
            publishedYear: known?.publishedYear,
            // The metadata API's description reaches the detail.
            description: description ?? known?.description)
    }

    /// Marks releases whose stored album position was already carried over.
    private static let migratedKey = "catalogSongPositionMigrated"

    /// Carries a stored album position over to the song it falls into. Runs
    /// once per release, changes nothing else, and never invents an entry.
    /// A release counts as done once it was decided: no position to carry,
    /// or the detail answered. A failed detail marks nothing, so the next
    /// open asks again; marked on a failure, one network error kept the
    /// song from ever getting its position. `fetch`: the detail, a witness
    /// hands in its own.
    static func migrateAlbumPositionToSong(
        albumId: String,
        fetch: ((String) async throws -> LibraryItemDetail)? = nil
    ) async {
        guard !(AppStorageKeys.stringArray(migratedKey) ?? []).contains(albumId) else { return }
        guard let stored = ListeningStore.backup(albumId),
              stored.count >= 2, stored[0] > 0 else {
            markMigrated(albumId)
            return
        }
        let detail: LibraryItemDetail
        do {
            detail = try await (fetch ?? { try await shared.fetchAlbumDetail(albumId: $0) })(albumId)
        } catch {
            Logger.library.error("CATALOG album position not carried yet, detail failed for \(albumId, privacy: .public): \(FailureReason.of(error), privacy: .public)")
            return
        }
        defer { markMigrated(albumId) }
        guard let tracks = detail.media.tracks else { return }
        // The decision itself is pure and tested. Including against an
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

    /// Marks one release, read at the moment of marking: another release
    /// marked while this one awaited its detail stays marked.
    private static func markMigrated(_ albumId: String) {
        var done = Set(AppStorageKeys.stringArray(migratedKey) ?? [])
        done.insert(albumId)
        AppStorageKeys.set(Array(done), for: migratedKey)
    }

    #if DEBUG
    /// Whether a release counts as migrated, and its mark taken back, for
    /// the witnesses.
    static func _isMigrated(_ albumId: String) -> Bool {
        (AppStorageKeys.stringArray(migratedKey) ?? []).contains(albumId)
    }
    static func _forgetMigrated(_ albumId: String) {
        AppStorageKeys.set((AppStorageKeys.stringArray(migratedKey) ?? []).filter { $0 != albumId }, for: migratedKey)
    }
    #endif

    /// The release itself, without the song shortcut. Used by the migration.
    private func fetchAlbumDetail(albumId: String) async throws -> LibraryItemDetail {
        let identifier = FreeCatalog.archiveIdentifier(of: albumId) ?? albumId
        let meta = try await ArchiveOrgClient.metadata(identifier: identifier)
        noteFiles(meta, identifier: identifier)
        let tracks = FreeCatalog.archiveTracks(identifier: identifier, files: meta.files ?? [])
        guard !tracks.isEmpty else { throw URLError(.resourceUnavailable) }
        return LibraryItemDetail(id: albumId,
                                 media: LibraryItemMedia(metadata: nil, duration: nil,
                                                         chapters: nil, tracks: tracks),
                                 userMediaProgress: nil)
    }

    /// One track of a release as an item of its own. Built from the release's
    /// files, so the song carries the title and performer the source states.
    /// Not the album's.
    private func songDetail(songId: String, album albumId: String,
                            index: Int) async throws -> LibraryItemDetail {
        let identifier = FreeCatalog.archiveIdentifier(of: albumId) ?? albumId
        let meta = try await ArchiveOrgClient.metadata(identifier: identifier)
        noteFiles(meta, identifier: identifier)
        guard let detail = songDetail(songId: songId, identifier: identifier, meta: meta, index: index) else {
            throw URLError(.resourceUnavailable)
        }
        return detail
    }

    /// Every track of a release as the song item it is (`CatalogSongID`), in
    /// order: a song the session already holds as it is, the others built
    /// from ONE metadata answer for the whole release. `missing` names the
    /// indices that built nothing (past the release's files, or no answer);
    /// the caller says them, a song never drops out silently. `metadata`:
    /// the answer, a witness hands in its own.
    func albumSongs(albumId: String, count: Int,
                    metadata: ((String) async throws -> ArchiveDecoder.MetadataResponse)? = nil)
        async -> (songs: [LibraryItem], missing: [Int]) {
        let identifier = FreeCatalog.archiveIdentifier(of: albumId) ?? albumId
        var meta: ArchiveDecoder.MetadataResponse?
        var asked = false
        var songs: [LibraryItem] = []
        var missing: [Int] = []
        for index in 0..<max(count, 0) {
            let songId = CatalogSongID.make(album: albumId, index: index)
            if let held = itemsById[songId], !(held.media?.tracks ?? []).isEmpty {
                songs.append(held)
                continue
            }
            if !asked {
                asked = true
                do {
                    meta = try await (metadata ?? { try await ArchiveOrgClient.metadata(identifier: $0) })(identifier)
                    if let meta { noteFiles(meta, identifier: identifier) }
                } catch {
                    Logger.library.error("CATALOG album songs, release answer failed for \(albumId, privacy: .public): \(FailureReason.of(error), privacy: .public)")
                }
            }
            if let meta, let detail = songDetail(songId: songId, identifier: identifier, meta: meta, index: index) {
                songs.append(LibraryItem(id: songId, media: detail.media, addedAt: nil))
            } else {
                missing.append(index)
            }
        }
        return (songs, missing)
    }

    /// Every song of a release whose count the caller does not know (a
    /// tile's long-press Shuffle): ONE metadata answer counts the tracks and
    /// builds the songs. A title that is no archive release asks nothing.
    /// Without an answer the songs the session already holds stand, from
    /// the first on; a release past the plausible track count is a bundle,
    /// not an album, and comes back empty so the caller plays the title.
    func releaseSongs(albumId: String,
                      metadata: ((String) async throws -> ArchiveDecoder.MetadataResponse)? = nil)
        async -> [LibraryItem] {
        guard let identifier = FreeCatalog.archiveIdentifier(of: albumId) else { return [] }
        let meta: ArchiveDecoder.MetadataResponse
        do {
            meta = try await (metadata ?? { try await ArchiveOrgClient.metadata(identifier: $0) })(identifier)
            noteFiles(meta, identifier: identifier)
        } catch {
            guard !error.isCancellation else { return [] }
            let held = heldSongs(albumId: albumId)
            Logger.library.error("CATALOG album songs, release answer failed for \(albumId, privacy: .public): \(FailureReason.of(error), privacy: .public), held=\(held.count)")
            return held
        }
        let files = FreeCatalog.preferredAudioFiles(meta.files ?? [])
        let count = FreeCatalog.archiveTracks(identifier: identifier, files: files).count
        let collections = meta.metadata?.collection?.values ?? []
        let cap = ArchiveItemForm.isCuratedSeriesCollection(collections: collections)
            ? FreeCatalog.seriesTrackCap : FreeCatalog.defaultTrackCap
        guard FreeCatalog.trackCountPlausible(count, cap: cap) else {
            Logger.library.notice("CATALOG album songs gate: \(identifier, privacy: .public) has \(count) tracks, plays as its title")
            return []
        }
        // The answer also leaves the release's form and detail, as the
        // detail fetch would, so the album page after a Shuffle knows them.
        do {
            _ = try await releaseDetail(itemId: albumId, identifier: identifier, meta: meta)
        } catch {
            Logger.library.notice("CATALOG album songs kept no detail for \(albumId, privacy: .public): \(FailureReason.of(error), privacy: .public)")
        }
        let answer = await albumSongs(albumId: albumId, count: count) { _ in meta }
        if let first = answer.missing.first {
            Logger.library.notice("CATALOG album songs missing=\(answer.missing.count) of=\(count) first=\(first)")
        }
        return answer.songs
    }

    /// The songs of a release the session holds, from the first on, up to
    /// the first it does not hold.
    private func heldSongs(albumId: String) -> [LibraryItem] {
        var songs: [LibraryItem] = []
        while let held = itemsById[CatalogSongID.make(album: albumId, index: songs.count)],
              !(held.media?.tracks ?? []).isEmpty {
            songs.append(held)
        }
        return songs
    }

    /// One song built from its release's metadata answer; nil past the end
    /// of the release's playable files.
    private func songDetail(songId: String, identifier: String,
                            meta: ArchiveDecoder.MetadataResponse, index: Int) -> LibraryItemDetail? {
        let files = FreeCatalog.preferredAudioFiles(meta.files ?? [])
            .sorted { FreeCatalog.orderKey($0) < FreeCatalog.orderKey($1) }
        guard index < files.count else { return nil }
        let tracks = FreeCatalog.archiveTracks(identifier: identifier, files: files)
        guard index < tracks.count else { return nil }
        let file = files[index]
        let track = tracks[index]
        // The song starts at zero. It is the whole item now, not a section.
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

    /// What a detail fetch resolved goes into the session cache. "not in
    /// memory" must not stay true one fetch after the answer arrived. This is
    /// what lets a queue or playlist row fill itself in on demand.
    /// It is also kept on the device (`CatalogKeptItems`). A remembered entry
    /// that names its title keeps its metadata (the intake normalizes it) and
    /// takes the detail's duration where it has none (`CatalogKeptItems.merged`).
    private func rememberResolved(_ detail: LibraryItemDetail) {
        let item = CatalogKeptItems.merged(known: itemsById[detail.id],
                                           resolved: LibraryItem(id: detail.id, media: detail.media, addedAt: nil))
        keep(item)
        itemsById[detail.id] = item
    }

    private func keep(_ item: LibraryItem) {
        let next = CatalogKeptItems.adding(item, to: kept)
        guard next != kept else { return }
        kept = next
        Task {
            do {
                try await Ablage.documents.save(next, name: Self.keptDocument)
            } catch {
                Logger.library.error("CATALOG kept items not saved: \(FailureReason.of(error), privacy: .public)")
            }
        }
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        if itemId.hasPrefix(FreeCatalog.librivoxPrefix) {
            guard var book = librivoxBooks[itemId] else { throw URLError(.resourceUnavailable) }
            // The ROW no longer carries the chapter list (95 % of the
            // old payload, 291 kB → 45 kB for 20 books). It is fetched HERE,
            // once, for the one book the user actually opened. Metadata
            // where it is needed instead of on every tile.
            if (book.sections?.isEmpty ?? true) {
                let id = String(itemId.dropFirst(FreeCatalog.librivoxPrefix.count))
                if let full = try await LibriVoxClient.book(id: id) {
                    book = full
                    librivoxBooks[itemId] = full
                }
            }
            let tracks = FreeCatalog.tracks(from: book.sections)
            guard !tracks.isEmpty else { throw URLError(.resourceUnavailable) }
            let detail = LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(
                    metadata: detailMetadata(itemId: itemId, title: book.title,
                                             authorName: FreeCatalog.authorLine(book.authors)),
                    duration: book.totaltimesecs.map(Double.init), chapters: nil,
                    tracks: tracks),
                userMediaProgress: nil)
            rememberResolved(detail)
            return detail
        }
        if itemId.hasPrefix(FreeCatalog.archivePrefix) {
            // A song address resolves to a SINGLE-track item: its own title,
            // its own duration, and therefore its own position, its own place
            // in a playlist and its own "played".
            if let song = CatalogSongID.parse(itemId) {
                return try await songDetail(songId: itemId, album: song.album, index: song.index)
            }
            let identifier = FreeCatalog.archiveIdentifier(of: itemId) ?? itemId
            let meta = try await ArchiveOrgClient.metadata(identifier: identifier)
            noteFiles(meta, identifier: identifier)
            return try await releaseDetail(itemId: itemId, identifier: identifier, meta: meta)
        }
        if itemId.hasPrefix(FreeCatalog.jamendoPrefix) {
            guard let track = jamendoTracks[itemId], let audio = track.audio, !audio.isEmpty else {
                throw URLError(.resourceUnavailable)
            }
            let detail = LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(
                    metadata: detailMetadata(itemId: itemId, title: track.name,
                                             authorName: track.artist_name),
                    duration: track.duration.map(Double.init), chapters: nil,
                    tracks: [ABSAudioTrack(index: 0, startOffset: 0,
                                           duration: track.duration.map(Double.init),
                                           contentUrl: audio, metadata: nil)]),
                userMediaProgress: nil)
            rememberResolved(detail)
            return detail
        }
        if itemId.hasPrefix(FreeCatalog.gutenbergPrefix) {
            return try await gutenbergDetail(itemId: itemId)
        }
        throw URLError(.resourceUnavailable)
    }

    /// An archive release from its metadata answer: its collections, its
    /// tracks behind the plausibility gate, and the detail kept for the
    /// session. The detail fetch and the tile's Shuffle (`releaseSongs`)
    /// take in the same answer, so one answer leaves the same knowledge.
    private func releaseDetail(itemId: String, identifier: String,
                               meta: ArchiveDecoder.MetadataResponse) async throws -> LibraryItemDetail {
        // This endpoint answers for every item, including one that no row
        // ever showed. So the form is known here even on a cold start.
        rememberCollections(meta.metadata?.collection?.values, forItemId: itemId)
        let collections = itemCollections[itemId] ?? []
        // A position stored before tracks had addresses points at the whole
        // release. It is carried over to the song it falls into, once, and
        // the album entry stays untouched. Nobody loses where they were.
        // Only an ALBUM is carried over: for a work the single position IS
        // the truth, and splitting it into per-track marks would lose it.
        if ArchiveItemForm.of(collections: collections) == .album {
            await Self.migrateAlbumPositionToSong(albumId: itemId)
        }
        let tracks = FreeCatalog.archiveTracks(identifier: identifier, files: meta.files ?? [])
        guard !tracks.isEmpty else { throw URLError(.resourceUnavailable) }
        // Plausibility gate. A collection bundle with
        // hundreds of parts is not a book; named in the log, never mute.
        // A CURATED series collection passes the higher bound.
        // There the bundle is the unit, not an accident. Read from the
        // item's own collections, so a bundle reached by deep link or from
        // a playlist is no longer dropped for being too long.
        let cap = ArchiveItemForm.isCuratedSeriesCollection(collections: collections)
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
                                         authorName: meta.metadata?.creator?.joined.map(FreeCatalog.repairedMojibake),
                                         description: meta.metadata?.description?.joined),
                duration: total > 0 ? total : nil, chapters: nil, tracks: tracks),
            userMediaProgress: nil)
        rememberResolved(detail)
        return detail
    }

    /// A Gutenberg work from its record: every file of the reading as a
    /// track, placed by the durations before it, whether the tile came from
    /// gutendex or from the kept stock, and on a cold start from the number
    /// alone. A work without a sound file is gone; one whose part cannot be
    /// read says so rather than resuming in the wrong file.
    func gutenbergDetail(itemId: String, works: GutenbergWorks? = nil) async throws -> LibraryItemDetail {
        let works = works ?? gutenbergWorks
        guard let number = Int(itemId.dropFirst(FreeCatalog.gutenbergPrefix.count)),
              let work = try await works.work(number: number) else {
            throw URLError(.resourceUnavailable)
        }
        let tracks = try work.tracks()
        // The rights line comes from the record, verbatim reading.
        licences[itemId] = FreeCatalog.gutenbergRightsLabel(work.rights)
        let detail = LibraryItemDetail(
            id: itemId,
            media: LibraryItemMedia(
                metadata: detailMetadata(itemId: itemId, title: work.title,
                                         authorName: FreeCatalog.gutenbergAuthor(work.author)),
                duration: work.totalSeconds, chapters: nil, tracks: tracks),
            userMediaProgress: nil)
        rememberResolved(detail)
        return detail
    }

    func coverURL(forItemId itemId: String) -> URL? {
        if itemId.hasPrefix(FreeCatalog.librivoxPrefix) {
            guard let book = librivoxBooks[itemId],
                  let identifier = FreeCatalog.iarchiveIdentifier(from: book.url_iarchive)
            else { return nil }
            return FreeCatalog.archiveCoverURL(identifier: identifier)
        }
        if let identifier = FreeCatalog.archiveIdentifier(of: itemId) {
            return FreeCatalog.archiveCoverURL(identifier: identifier)
        }
        if itemId.hasPrefix(FreeCatalog.jamendoPrefix) {
            return jamendoTracks[itemId]?.image.flatMap { URL(string: $0) }
        }
        if itemId.hasPrefix(FreeCatalog.gutenbergPrefix) {
            // gutendex names the cover; a stock title and a cold start have
            // only the number, and the record names the same address.
            return gutenbergCovers[itemId] ?? FreeCatalog.gutenbergCoverURL(
                number: String(itemId.dropFirst(FreeCatalog.gutenbergPrefix.count)))
        }
        return nil
    }

    /// The cover of a large view: an archive item's original picture once
    /// its files were read (`noteFiles`), else the larger form of the grid
    /// cover where its source keeps one (`CoverAddressHistory`).
    func largeCoverURL(forItemId itemId: String) -> URL? {
        if let identifier = archiveIdentifier(forItemId: itemId), let original = archiveOriginalCovers[identifier] {
            return original
        }
        return CoverAddressHistory.large(coverURL(forItemId: itemId))
    }

    /// The archive.org item behind a catalogue id: a release or a song of it,
    /// or the archive copy of a LibriVox book.
    private func archiveIdentifier(forItemId itemId: String) -> String? {
        if itemId.hasPrefix(FreeCatalog.librivoxPrefix) {
            return FreeCatalog.iarchiveIdentifier(from: librivoxBooks[itemId]?.url_iarchive)
        }
        return FreeCatalog.archiveIdentifier(of: itemId)
    }

    func streamURL(forContentPath contentPath: String) -> URL? { URL(string: contentPath) }

    // MARK: - ProgressSyncAPI (local-only: no server truth to sync)

    func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}

    // No bookmark capability. The empty contract shape (capability-gated).
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}
}
