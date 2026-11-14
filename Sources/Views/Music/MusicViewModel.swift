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
    /// reports a case unavailable).
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
    /// A later album page failed: the grid holds the pages read so far and
    /// is not the whole library. The page says so below the grid.
    @Published private(set) var albumsIncomplete = false

    private let source: MusicSource
    /// The attempt gate, in the CatalogLoadGate form: it counts ATTEMPTS, and
    /// a CANCELLED first run is no attempt. `loaded = true` used to be set
    /// before the run. A first load cancelled by a tab switch became final,
    /// and the tab showed "No music" until a hard restart. Third instance of
    /// the throw-is-not-the-end class.
    private var gate = CatalogLoadGate()
    /// Each reload is a new generation (`PageRuns`): a run that a new sort or
    /// reload has moved past decides nothing, so a page of the old sort never
    /// lands in the new grid.
    private var runs = PageRuns()
    /// Whether the tab has started its first load (`MusicPageState.of`).
    /// A reload sets `isLoading` right after the reset, so the change shows.
    var hasAsked: Bool { runs.hasStarted }
    /// Active album-grid sort (server-side). Shelves stay fixed.
    var sort: MusicSortOption = .nameAZ
    /// How long the first album page may take before the page says the
    /// server takes too long, with its retry. Measured before: no deadline
    /// of its own, only the session's limits and the retry of the first
    /// load, so a server that never answered kept the bar for minutes.
    var firstPageDeadline: Duration = .seconds(15)

    /// The switch of the music account the page loaded under.
    private var loadedUnder = MusicAccountSwitch.generation

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

    /// The sources changed (an address or account added or removed here):
    /// the reachability is asked again on every change, a page that said
    /// "no server here" loads at once, so does a tab that never loaded (it
    /// was mounted without a server), a server that went away shows the way
    /// out, and a full page is not asked again.
    func sourcesChanged() async {
        switch MusicPageState.onSourcesChange(reachableNow: source.reachable(), wasMissing: serverMissingHere,
                                              asked: hasAsked,
                                              accountChanged: loadedUnder != MusicAccountSwitch.generation) {
        case .showMissing:
            serverMissingHere = true
            // As in `loadIfNeeded`: a page without its server decided
            // nothing, so the attempt gate opens again and the server's
            // return (`.reload`) loads it.
            gate.reopen()
            Logger.music.notice("music server went away on this device")
        case .reload:
            await loadIfNeeded()
        case .startOver:
            // The lists are the former account's: none of them stays, also
            // when the new account's load fails.
            loadedUnder = MusicAccountSwitch.generation
            newest = []; frequent = []; recent = []; albums = []; artists = []; playlists = []
            Logger.music.notice("music account switched: the page drops its lists and loads anew")
            gate.reopen()
            await loadIfNeeded()
        case .keep:
            break
        }
    }

    func reload() async {
        let run = runs.reset()
        let isCurrent = { [self] in runs.isCurrent(run) }
        // Every exit of the current run clears the loading state, the early
        // one without a server too: an older run it moved past no longer
        // clears it, so the newest run must.
        defer { if isCurrent() { isLoading = false } }
        errorText = nil
        albumsIncomplete = false
        lastRunCancelled = false
        serverMissingHere = !source.reachable()
        guard !serverMissingHere else {
            Logger.music.notice("music on, but no server to ask on this device")
            return
        }
        isLoading = true

        // Parallel best-effort extras. Assigned as they arrive; on failure/
        // cancellation the previous state stays instead of blanking with [].
        async let newestTask = source.shelf(.newest, 20)
        async let frequentTask = source.shelf(.frequent, 20)
        async let recentTask = source.shelf(.recent, 20)
        async let artistsTask = source.artists()
        async let playlistsTask = source.playlists()

        let pageSize = 100
        let start = ContinuousClock.now
        do {
            let sort = sort
            let source = source
            let first = try await MusicPageLoad.withDeadline(firstPageDeadline) {
                try await source.albumsPage(sort, 0, pageSize)
            }
            MusicPageLoad.logStep("albums first page", since: start, count: first.count)
            if MusicPageLoad.superseded("albums", isCurrent()) { return }
            albums = first
            isLoading = false   // grid is on screen — the rest arrives silently
            // Remaining pages: append quietly; an abort keeps the partial list,
            // and a failed page says the list is not whole.
            var offset = first.count
            var lastCount = first.count
            while lastCount == pageSize {
                let page = await FetchAnswer.of("album page offset=\(offset)", logger: .music) {
                    try await source.albumsPage(sort, offset, pageSize)
                }
                if MusicPageLoad.superseded("albums offset=\(offset)", isCurrent()) { return }
                if page.failed { albumsIncomplete = true }
                guard let next = page.value, !next.isEmpty else { break }
                // Layout-shift fix: silent page appends grow the grid. Apply
                // through the shared calm gate, never mid-scroll. The gate may
                // run it later, so it asks again then.
                ScrollCalm.run { [self] in if isCurrent() { albums += next } }
                offset += next.count
                lastCount = next.count
            }
        } catch where MusicPageLoad.superseded("albums", isCurrent()) {
            // A failure of a run the page moved past is not the page's sentence.
            return
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
            // The deadline of the first page ends here as a timeout.
            MusicPageLoad.logStep("albums first page", since: start, failure: error)
            errorText = ErrorSentence.of(error)
            Logger.music.error("album page load failed: \(String(describing: error), privacy: .public)")
            return
        }

        // Late best-effort arrivals reshape the shelves. Same calm gate, and
        // only while this run is the page's. A failure keeps the previous
        // state and says so in its step line.
        do {
            let value = try await newestTask
            MusicPageLoad.logStep("shelf newest", since: start, count: value.count)
            ScrollCalm.run { [self] in if isCurrent() { newest = value } }
        } catch { MusicPageLoad.logStep("shelf newest", since: start, failure: error) }
        do {
            let value = try await recentTask
            MusicPageLoad.logStep("shelf recent", since: start, count: value.count)
            ScrollCalm.run { [self] in if isCurrent() { recent = value } }
        } catch { MusicPageLoad.logStep("shelf recent", since: start, failure: error) }
        do {
            let value = try await frequentTask
            MusicPageLoad.logStep("shelf frequent", since: start, count: value.count)
            ScrollCalm.run { [self] in if isCurrent() { frequent = value } }
        } catch { MusicPageLoad.logStep("shelf frequent", since: start, failure: error) }
        do {
            let value = try await artistsTask
            MusicPageLoad.logStep("artists", since: start, count: value.count)
            ScrollCalm.run { [self] in if isCurrent() { artists = value } }
        } catch { MusicPageLoad.logStep("artists", since: start, failure: error) }
        // Filter junk playlists (name == id / nameless, 0 songs) at THE one
        // feed, so both the playlist card row and the Playlists browse page are clean.
        do {
            let value = try await playlistsTask
            MusicPageLoad.logStep("playlists", since: start, count: value.count)
            ScrollCalm.run { [self] in if isCurrent() { playlists = PlaylistPresentation.realPlaylists(value) } }
        } catch { MusicPageLoad.logStep("playlists", since: start, failure: error) }
        // With two music servers, a list may carry only one server's half.
        // The inline hint names who did not answer.
        if MusicPageLoad.superseded("music shelves", isCurrent()) { return }
        if let sentence = source.failureSentence() {
            errorText = sentence
            Logger.music.notice("music source down, half shown")
        }
    }
}
