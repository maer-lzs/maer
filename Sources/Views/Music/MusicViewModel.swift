// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Combine
import OSLog

/// Data source of the Music tab as injectable closures — the live wiring hits
/// the Subsonic provider; tests inject failing/stubbed ones.
struct MusicSource {
    // `@MainActor @Sendable` closures → `MusicSource` is Sendable (so it can feed
    // the parallel `async let` shelves/artists/playlists loads) while the closure
    // bodies still run on the main actor. That matches reality — the live wiring
    // only awaits the @MainActor Subsonic provider — and lets the injected test
    // closures capture their @MainActor observation state without a data race.
    /// One page of the album catalog for a given SORT (offset, size). The live
    /// wiring maps the semantic MusicSortOption to the Subsonic getAlbumList2
    /// type here (provider-level mapping — a future provider translates or
    /// reports a case unavailable). Teil 2.
    var albumsPage: @MainActor @Sendable (_ sort: MusicSortOption, _ offset: Int, _ size: Int) async throws -> [LibraryItem]
    var shelf: @MainActor @Sendable (_ type: String, _ size: Int) async throws -> [LibraryItem]
    var artists: @MainActor @Sendable () async throws -> [SubsonicArtist]
    var playlists: @MainActor @Sendable () async throws -> [SubsonicPlaylist]

    static let live = MusicSource(
        albumsPage: { try await AppSession.shared.musicProvider.albumPage(sort: $0, offset: $1, size: $2) },
        shelf: { try await AppSession.shared.musicProvider.albumShelf(type: $0, size: $1) },
        artists: { try await AppSession.shared.musicProvider.allArtists() },
        playlists: { try await AppSession.shared.musicProvider.allPlaylists() }
    )
}

#if DEBUG
extension MusicSource {
    /// UI-test wiring: the seeded source under `-uitest`, else the live one.
    static var uitestOrLive: MusicSource { UITestSeed.isActive ? .uitestSeed : .live }

    /// Serves the seeded albums without a server (see UITestSeed), so the Music
    /// tab (and S17b's background) are harness-visible.
    static let uitestSeed = MusicSource(
        albumsPage: { _, offset, _ in offset == 0 ? UITestSeed.seedAlbums : [] },
        shelf: { _, _ in Array(UITestSeed.seedAlbums.prefix(3)) },
        artists: { UITestSeed.seedArtists },
        playlists: { UITestSeed.seedPlaylists }
    )
}
#endif

/// Loads the Music tab from the Subsonic provider: two shelves (recently added,
/// most played), the full alphabetical album list, plus artists and playlists
/// for browsing. Album loading is critical (drives the error state); the rest is
/// best-effort so a server without playlists/artists still shows albums.
///
/// Error policy: a REAL error never discards loaded content (stale beats empty,
/// like the book library), and a cancellation is not an error at all —
/// `.refreshable` cancels its task when the bounce settles, which must not
/// surface as a fake network failure.
@MainActor
final class MusicViewModel: ObservableObject {
    @Published var newest: [LibraryItem] = []
    @Published var frequent: [LibraryItem] = []
    @Published var albums: [LibraryItem] = []
    @Published var artists: [SubsonicArtist] = []
    @Published var playlists: [SubsonicPlaylist] = []
    @Published var isLoading = false
    @Published var errorText: String?

    private let source: MusicSource
    private var loaded = false
    /// Teil 2: active album-grid sort (server-side). Shelves stay fixed.
    var sort: MusicSortOption = .nameAZ

    init(source: MusicSource = .live) {
        self.source = source
    }

    /// Switch the album sort and re-query from the first page. Paging reset is
    /// inherent — `reload()` always starts at offset 0.
    func setSort(_ newSort: MusicSortOption) async {
        guard newSort != sort else { return }
        sort = newSort
        await reload()
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        await reload()
        // One quiet retry before surfacing the error state on first entry —
        // the sporadic failure resolves itself on immediate re-request.
        if errorText != nil, albums.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            Logger.music.info("first music load failed — retrying once")
            await reload()
        }
    }

    /// S5 — staged loading: the shelves (small, parallel) render first, the
    /// album grid pages in 100s (first page critical, rest appended silently),
    /// artists/playlists arrive best-effort in parallel. Error policy unchanged:
    /// full-screen error only when the FIRST album page fails on an empty
    /// library; stale always beats empty; cancellation is silent.
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        errorText = nil

        // Parallel best-effort extras — assigned as they arrive; on failure/
        // cancellation the previous state stays instead of blanking with [].
        async let newestTask = source.shelf("newest", 20)
        async let frequentTask = source.shelf("frequent", 20)
        async let artistsTask = source.artists()
        async let playlistsTask = source.playlists()

        let pageSize = 100
        do {
            let first = try await source.albumsPage(sort, 0, pageSize)
            albums = first
            isLoading = false   // grid is on screen — the rest arrives silently
            // Remaining pages: append quietly; an abort keeps the partial list.
            var offset = first.count
            var lastCount = first.count
            while lastCount == pageSize {
                guard let next = try? await source.albumsPage(sort, offset, pageSize), !next.isEmpty else { break }
                // Layout-shift fix: silent page appends grow the grid — apply
                // through the shared calm gate, never mid-scroll.
                BottomBarState.shared.runWhenCalm { [self] in albums += next }
                offset += next.count
                lastCount = next.count
            }
        } catch is CancellationError {
            // Refreshable settled/was cancelled — not an error, keep everything.
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            // Real error: report it, but KEEP the already-loaded library
            // (the view shows the full-screen error page only when empty).
            errorText = (error as? SubsonicClient.SubsonicError)?.errorDescription
                ?? error.localizedDescription
            Logger.music.error("album page load failed: \(String(describing: error), privacy: .public)")
            return
        }

        // Late best-effort arrivals reshape the shelves — same calm gate.
        if let value = try? await newestTask {
            BottomBarState.shared.runWhenCalm { [self] in newest = value }
        }
        if let value = try? await frequentTask {
            BottomBarState.shared.runWhenCalm { [self] in frequent = value }
        }
        if let value = try? await artistsTask {
            BottomBarState.shared.runWhenCalm { [self] in artists = value }
        }
        // TF2: filter junk playlists (name == id / nameless, 0 songs) at THE one
        // feed, so both the F5 card row and the Playlists browse page are clean.
        if let value = try? await playlistsTask {
            BottomBarState.shared.runWhenCalm { [self] in playlists = PlaylistPresentation.realPlaylists(value) }
        }
    }
}
