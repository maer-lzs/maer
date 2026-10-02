// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import OSLog

/// Data source of the Music tab as injectable closures. The live wiring hits
/// the Subsonic provider; tests inject failing/stubbed ones.
struct MusicSource {
    // `@MainActor @Sendable` closures → `MusicSource` is Sendable (so it can feed
    // the parallel `async let` shelves/artists/playlists loads) while the closure
    // bodies still run on the main actor. That matches reality. The live wiring
    // only awaits the @MainActor Subsonic provider. And lets the injected test
    // closures capture their @MainActor observation state without a data race.
    /// One page of the album catalog for a given SORT (offset, size). The live
    /// wiring maps the semantic MusicSortOption to the Subsonic getAlbumList2
    /// type here (provider-level mapping. A future provider translates or
    /// reports a case unavailable). Teil 2.
    var albumsPage: @MainActor @Sendable (_ sort: MusicSortOption, _ offset: Int, _ size: Int) async throws -> [LibraryItem]
    var shelf: @MainActor @Sendable (_ shelf: MusicShelf, _ size: Int) async throws -> [LibraryItem]
    var artists: @MainActor @Sendable () async throws -> [MusicArtist]
    var playlists: @MainActor @Sendable () async throws -> [MusicPlaylist]
    /// The sentence when one of two music servers did not answer the last
    /// list question; nil with one server, or when every server answered.
    var failureSentence: @MainActor @Sendable () -> String? = { nil }
    /// Whether a music server can be asked on this device. Music can be on
    /// while the server's address and account are missing here (the switch
    /// travels between devices, the access does not), and then every list
    /// is empty without a server having said so.
    var reachable: @MainActor @Sendable () -> Bool = { true }

    /// The library's lists ask the device's music provider: none of them
    /// names a title, so there is no id that could answer instead.
    private static var music: any MusicProvider { AppSession.shared.musicProvider }

    static let live = MusicSource(
        albumsPage: { try await music.albumPage(sort: $0, offset: $1, size: $2) },
        shelf: { try await music.albumShelf(shelf: $0, size: $1) },
        artists: { try await music.allArtists() },
        playlists: { try await music.allPlaylists() },
        failureSentence: {
            MusicSourceFailure.sentence(failed: music.failedSources, all: music.sourceIds,
                                        names: music.sourceNames)
        },
        reachable: { music.isAvailable }
    )
}

#if DEBUG
extension MusicSource {
    /// UI-test wiring: the seeded source under `-uitest`, else the live one.
    static var uitestOrLive: MusicSource { UITestSeed.isActive ? .uitestSeed : .live }

    /// Serves the seeded albums without a server (see UITestSeed), so the Music
    /// tab (and its background behind the bar) are harness-visible.
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
/// like the book library), and a cancellation is not an error at all.
/// `.refreshable` cancels its task when the bounce settles, which must not
/// surface as a fake network failure.
@MainActor
final class MusicViewModel: ObservableObject {
    @Published var newest: [LibraryItem] = []
    @Published var frequent: [LibraryItem] = []
    /// Musik-Tab-Neuordnung: "Recently Played" shelf (server-side `recent`).
    @Published var recent: [LibraryItem] = []
    @Published var albums: [LibraryItem] = []
    @Published var artists: [MusicArtist] = []
    @Published var playlists: [MusicPlaylist] = []
    @Published var isLoading = false
    @Published var errorText: String?
    /// Music is on, and this device has no server to ask: the page says
    /// that instead of "your server reported an empty library".
    @Published private(set) var serverMissingHere = false

    private let source: MusicSource
    /// The attempt gate, in the CatalogLoadGate form: it counts ATTEMPTS, and
    /// a CANCELLED first run is no attempt. `loaded = true` used to be set
    /// before the run. A first load cancelled by a tab switch became final,
    /// and the tab showed "No music" until a hard restart. Third instance of
    /// the throw-is-not-the-end class.
    private var gate = CatalogLoadGate()
    /// Teil 2: active album-grid sort (server-side). Shelves stay fixed.
    var sort: MusicSortOption = .nameAZ

    init(source: MusicSource = .live) {
        self.source = source
    }

    /// Switch the album sort and re-query from the first page. Paging reset is
    /// inherent. `reload()` always starts at offset 0.
    func setSort(_ newSort: MusicSortOption) async {
        guard newSort != sort else { return }
        sort = newSort
        await reload()
    }

    func loadIfNeeded() async {
        guard gate.startIfNeeded(connected: true) else { return }
        defer { gate.finish() }
        await reload()
        // One quiet retry before surfacing the error state on first entry.
        // The sporadic failure resolves itself on immediate re-request.
        if errorText != nil, albums.isEmpty, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled {
                Logger.music.info("first music load failed — retrying once")
                await reload()
            }
        }
        // A cancelled run decided nothing. The next appearance starts fresh
        // instead of inheriting an empty forever. Both faces of the abort are
        // covered: the task itself cancelled (tab switch) and the source
        // throwing its cancellation into reload's silent exit.
        if Task.isCancelled || lastRunCancelled { gate.reopen() }
        // No server here decided nothing either: the next appearance asks
        // again, after the address may have been added.
        if serverMissingHere { gate.reopen() }
    }

    /// Staged loading: the shelves (small, parallel) render first, the
    /// album grid pages in 100s (first page critical, rest appended silently),
    /// artists/playlists arrive best-effort in parallel. Error policy unchanged:
    /// full-screen error only when the FIRST album page fails on an empty
    /// library; stale always beats empty; cancellation is silent.
    /// Whether the LAST run ended in a cancellation. The silent exit above
    /// is right for the UI (no fake error), but the attempt gate must know:
    /// a cancelled run decided nothing, a completed empty one did.
    private(set) var lastRunCancelled = false

    func reload() async {
        errorText = nil
        lastRunCancelled = false
        serverMissingHere = !source.reachable()
        guard !serverMissingHere else {
            Logger.music.notice("music on, but no server to ask on this device")
            return
        }
        isLoading = true
        defer { isLoading = false }

        // Parallel best-effort extras. Assigned as they arrive; on failure/
        // cancellation the previous state stays instead of blanking with [].
        async let newestTask = source.shelf(.newest, 20)
        async let frequentTask = source.shelf(.frequent, 20)
        async let recentTask = source.shelf(.recent, 20)
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
                // Layout-shift fix: silent page appends grow the grid. Apply
                // through the shared calm gate, never mid-scroll.
                ScrollCalm.run { [self] in albums += next }
                offset += next.count
                lastCount = next.count
            }
        } catch is CancellationError {
            // Refreshable settled/was cancelled. Not an error, keep everything.
            lastRunCancelled = true
            return
        } catch let error as URLError where error.code == .cancelled {
            lastRunCancelled = true
            return
        } catch {
            // Real error: report it, but KEEP the already-loaded library
            // (the view shows the full-screen error page only when empty).
            // No client-type cast in the UI: the one sentence rule keeps the
            // text of a SubsonicError and names any other error by its kind.
            errorText = ErrorSentence.of(error)
            Logger.music.error("album page load failed: \(String(describing: error), privacy: .public)")
            return
        }

        // Late best-effort arrivals reshape the shelves. Same calm gate.
        if let value = try? await newestTask {
            ScrollCalm.run { [self] in newest = value }
        }
        if let value = try? await recentTask {
            ScrollCalm.run { [self] in recent = value }
        }
        if let value = try? await frequentTask {
            ScrollCalm.run { [self] in frequent = value }
        }
        if let value = try? await artistsTask {
            ScrollCalm.run { [self] in artists = value }
        }
        // Filter junk playlists (name == id / nameless, 0 songs) at THE one
        // feed, so both the playlist card row and the Playlists browse page are clean.
        if let value = try? await playlistsTask {
            ScrollCalm.run { [self] in playlists = PlaylistPresentation.realPlaylists(value) }
        }
        // With two music servers, a list may carry only one server's half.
        // The inline hint names who did not answer.
        if let sentence = source.failureSentence() {
            errorText = sentence
            Logger.music.notice("music source down, half shown")
        }
    }
}
