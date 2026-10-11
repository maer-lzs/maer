// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS


import SwiftUI
import OSLog

/// The ONE loader. Called from HomeView.compute() (always runs,
/// no lazy-mount dependency). WireCorpus discipline at the call sites: a
/// throwing client is CAUGHT and LOGGED with the actual error (never a
/// silent try?-collapse to empty); the per-row log line names loaded/
/// filtered counts and the reason when a row stays empty.
@MainActor
enum FreeCatalogLoader {
    struct Rows {
        /// LibriVox books for the DISCOVER mix (moderate share).
        var discoverBooks: [LibraryItem] = []
        /// The audiobooks-tab tile row (same fetch, wider cut).
        var tabBooks: [LibraryItem] = []
        var freeMusic: [LibraryItem] = []
        /// An ENABLED Jamendo row that stayed empty says WHY. A switch
        /// without a row is a control without a destination. nil =
        /// off or loaded; a value is the short visible reason.
        var classical: [LibraryItem] = []
        /// Netlabels (archive.org, CC). Its own row next to Jamendo; the
        /// source name at the heading keeps them apart.
        var netlabels: [LibraryItem] = []
        /// A FAILED row is an ANSWER too. Without this only Jamendo
        /// could ever be answered, so a failing LibriVox left the pass
        /// permanently incomplete. And the reopen turned that into three
        /// full network passes in a row.
        /// Cancellations never land here: a cancelled step is "not loaded
        /// yet" and must stay retryable.
        enum Row: Hashable { case books, classical, netlabels, freeMusic }
        var problems: [Row: String] = [:]

        /// The Jamendo half's reason. Kept as its own name because the
        /// surfaces read it. One wording, one source.
        var freeMusicProblem: String? {
            get { problems[.freeMusic] }
            set { problems[.freeMusic] = newValue }
        }
    }

    /// Moderate share (Fortsetzen-Deckel-Denke): at most this many LibriVox
    /// tiles mix into Discover; constant, not a setting.
    static let discoverBookCap = 3

    /// 🟡 THE entry point for curated PREVIEW picks. Every
    /// surface that shows a small number of archive.org picks goes through
    /// here. The first version probed only the audiobook picks, and the
    /// sibling surface ("Discover · Music") kept showing fresh ghost records.
    /// Fourth instance of "the rule was built where it was reported".
    ///
    /// **The boundary, deliberately:** curated PREVIEW yes, mass no. Full
    /// grids and pages keep loading unprobed (dozens of requests per visit).
    /// There the reactive marking heals, which is why a ghost record
    /// disappears there after the first tap.
    /// The probe chain is OFF the
    /// build path. It cost **43 s per pass**. Up to 72 serial round trips
    /// and 4,5 MB of metadata just to learn whether 12 tiles have pictures.
    /// A check that costs more than its purpose is not a check; it is the
    /// reason the surface stayed empty for half a minute.
    ///
    /// Nothing is switched off: known-dead items are still kept out (the ONE
    /// place, `remember(popular:)`, filters them), and liveness is still
    /// LEARNED. `ArchiveOrgClient.metadata` notes it on every detail open
    /// and every playback start. Only the DISCOVERY moved off the build
    /// path: it is learned where the answer is free instead of asked 72
    /// times before anything appears.
    static func picksWithoutProbing(_ items: [LibraryItem], cap: Int) -> [LibraryItem] {
        Array(items.prefix(cap))
    }

    static func picks(_ docs: [ArchivePopularDoc], cap: Int,
                      provider: FreeCatalogProvider) async -> [LibraryItem] {
        // No probing on the build path. See `picksWithoutProbing`.
        picksWithoutProbing(docs.compactMap { provider.remember(popular: $0) }, cap: cap)
    }

    /// Has every ENABLED row an answer? Content or a stated
    /// problem counts; an enabled row that is empty AND silent means the pass
    /// was cut short (cancel). The session must be allowed to try again.
    /// All sources off = nothing to answer, every row passes trivially.
    static func passIsComplete(_ rows: Rows) -> Bool {
        func answered(_ on: Bool, _ items: [LibraryItem], _ problem: String?) -> Bool {
            !on || !items.isEmpty || problem != nil
        }
        let areaOn = AppStorageKeys.freeAudiobooksAreaActive
        let archiveOn = AppStorageKeys.archiveBooksActive
        // A booked FAILURE counts as an answer. Otherwise a failing
        // source keeps the pass incomplete forever and the retries turn into
        // a spinning wheel.
        return answered(AppStorageKeys.librivoxActive && areaOn,
                        rows.discoverBooks, rows.problems[.books])
            && answered(AppStorageKeys.freeClassicalActive && archiveOn,
                        rows.classical, rows.problems[.classical])
            && answered(AppStorageKeys.netlabelsActive && archiveOn,
                        rows.netlabels, rows.problems[.netlabels])
            && answered(AppStorageKeys.jamendoActive,
                        rows.freeMusic, rows.problems[.freeMusic])
    }

    /// `clients`, `gates` and `dayStore` (where the day's Jamendo answer is
    /// kept) are the live ones by default; a witness hands in its own and
    /// the pass touches neither the network nor the app's stores.
    static func load(using clients: CatalogClients = .live, gates: CatalogGates = .live,
                     dayStore: UserDefaults = .standard) async -> Rows {
        // No master any more: each source below gates its own fetch, so
        // with every source off this pass runs dry without traffic.
        var rows = Rows()
        #if DEBUG
        if UITestSeed.isActive { return rows }   // no external calls in the harness
        #endif
        let provider = FreeCatalogProvider.shared
        let librivoxOn = gates.librivox
        let archiveOn = gates.archiveBooks
        let jamendoOn = gates.jamendo

        let areaOn = gates.freeAudiobooksArea
        if librivoxOn && areaOn {
            do {
                // The row used to fetch LibriVox's SINCE feed (new
                // additions). Which is why it showed obscure newcomers and
                // never the classics. It now rides the downloads sort, one
                // query PER active language, interleaved.
                let codes = gates.languages
                let docs = try await clients.archive.popularLibriVoxByLanguage(12, codes, 12, 1)
                Logger.library.notice("FREECAT discover-books sort=downloads codes=\(codes.isEmpty ? "-" : codes.joined(separator: ","), privacy: .public) loaded=\(docs.count)")
                if docs.isEmpty {
                    Logger.library.notice("FREECAT discover-books EMPTY: no docs for the active languages")
                }
                // 🟡 The shown picks go through the ONE probed entry
                // point; the tab row is the same fetch, second cut
                // and stays unprobed. It is the wider list, not a preview.
                rows.discoverBooks = await Self.picks(docs, cap: Self.discoverBookCap,
                                                      provider: provider)
                rows.tabBooks = docs.compactMap { provider.remember(popular: $0) }
            } catch {
                guard !error.isCancellation else { return rows }
                Logger.library.error("FREECAT discover-books FAILED: \(String(describing: error), privacy: .public)")
                rows.problems[.books] = CatalogPageFailure.sentence(for: error, at: "discover-books") ?? String(localized: "The catalogs could not be loaded. Tap to try again.")
            }
        }
        let classicalOn = gates.freeClassical && archiveOn
        if classicalOn {
            do {
                // Daily rotation: the row shows a DIFFERENT page of the
                // popularity window today than yesterday, because the
                // all-time ranking never changes on its own.
                let page = CatalogRotation.page(
                    total: ArchiveMusicCatalog.classical.measuredTotal, rowSize: 12, on: Date())
                let docs = try await clients.archive.popularMusic(ArchiveMusicCatalog.classical, 12, page)
                Logger.library.notice("FREECAT classical-teaser loaded=\(docs.count)")
                rows.classical = await Self.picks(docs, cap: RowPreview.limit, provider: provider)
            } catch {
                guard !error.isCancellation else { return rows }
                Logger.library.error("FREECAT classical-teaser FAILED: \(String(describing: error), privacy: .public)")
                rows.problems[.classical] = CatalogPageFailure.sentence(for: error, at: "discover-classical") ?? String(localized: "The catalogs could not be loaded. Tap to try again.")
            }
        }
        let netlabelsOn = gates.netlabels && archiveOn
        if netlabelsOn {
            do {
                let page = CatalogRotation.page(
                    total: ArchiveMusicCatalog.netlabels.measuredTotal, rowSize: 12, on: Date())
                let docs = try await clients.archive.popularMusic(ArchiveMusicCatalog.netlabels, 12, page)
                Logger.library.notice("FREECAT netlabels loaded=\(docs.count)")
                rows.netlabels = await Self.picks(docs, cap: RowPreview.limit, provider: provider)
            } catch {
                guard !error.isCancellation else { return rows }
                Logger.library.error("FREECAT netlabels FAILED: \(String(describing: error), privacy: .public)")
                rows.problems[.netlabels] = CatalogPageFailure.sentence(for: error, at: "discover-netlabels") ?? String(localized: "The catalogs could not be loaded. Tap to try again.")
            }
        }
        if jamendoOn {
            if clients.jamendo.clientId() == nil {
                // The key ships with the build. No
                // user ever enters one, so an instruction to do so is wrong
                // for every regular build. Only a self-built copy without the
                // local key file lands here; the line says what holds
                // (nothing new right now), never what the user should do.
                Logger.library.notice("FREECAT jamendo EMPTY: no client key")
                rows.freeMusicProblem = String(localized: "Nothing new here right now.")
            } else if let tag = CatalogShelfSource.storedDay(surface: JamendoClient.daySurface,
                                                             defaults: dayStore)["popular"],
                      let tracks = tag?.tracks, !tracks.isEmpty {
                // The first good answer of the day carries the day. Asking
                // again would only give a later answer a chance to be empty
                // and flip the visible row; that flicker is the finding. And
                // one query per day is the operations cache clause 3.3
                // sentence 2 covers, nothing more.
                rows.freeMusic = tracks.compactMap { provider.remember(track: $0) }
                Logger.library.notice("FREECAT jamendo from day store: \(tracks.count)")
            } else {
                do {
                    // Jamendo has NO random sort (measured: `order=random`
                    // answers with status=failed), so the same daily rotation
                    // runs over the existing `offset`. The window is set
                    // deliberately rather than measured: Jamendo's popularity
                    // head is IDENTICAL across weekly, monthly and download
                    // sorting (measured), and the top ~600 tracks are the
                    // usable field.
                    let jamendoPage = CatalogRotation.page(
                        total: JamendoClient.rotationWindow, rowSize: 12, on: Date())
                    let tracks = try await clients.jamendo.popularTracks(12, [], (jamendoPage - 1) * 12, .none)
                    Logger.library.notice("FREECAT jamendo loaded=\(tracks.count)")
                    rows.freeMusic = tracks.compactMap { provider.remember(track: $0) }
                    if rows.freeMusic.isEmpty {
                        // A clean 200 with a success envelope and no tracks.
                        // Everything else THROWS now, so this line is finally
                        // true when it shows.
                        rows.freeMusicProblem = String(localized: "Jamendo answered without tracks right now.")
                    } else {
                        // Only a GOOD answer is written down. An empty or
                        // failed one never is, and never overwrites one:
                        // that is what makes the flicker dead for the user.
                        CatalogShelfSource.shelfStore.store(
                            .found(CatalogShelfSource.ShelfStock(
                                total: nil, books: nil, docs: nil, tracks: tracks)),
                            for: CatalogShelfSource.stockId(
                                surface: JamendoClient.daySurface, shelf: "popular"),
                            rule: JamendoClient.popularRule, defaults: dayStore)
                    }
                } catch {
                    if error.isCancellation {
                        // Cancelled = not loaded yet, never a problem line.
                        // And never an END state: the row stays unanswered,
                        // so `passIsComplete` keeps the session retryable.
                        Logger.library.notice("FREECAT jamendo CANCELLED — pass stays incomplete")
                        return rows
                    }
                    // MEASURED, not named: what actually came. A throttle
                    // answers 429 with Retry-After, a stated failure carries
                    // Jamendo's own code and message. If Jamendo throttles
                    // us, the consequence is asking less, not harder.
                    if let failure = error as? JamendoClient.JamendoFailure {
                        Logger.library.error("FREECAT jamendo FAILED: http=\(failure.status ?? -1) code=\(failure.code ?? -1) message=\(failure.message ?? "-", privacy: .public) retryAfter=\(failure.retryAfter ?? "-", privacy: .public)")
                    } else {
                        Logger.library.error("FREECAT jamendo FAILED: \(String(describing: error), privacy: .public)")
                    }
                    rows.freeMusicProblem = String(localized: "The Jamendo row could not be loaded.")
                }
            }
        } else {
            // The activation composition, visible in the
            // log. Answers "who turned it off" without a device session.
            Logger.library.notice("FREECAT jamendo row OFF: source=\(AppStorageKeys.jamendoActive)")
        }
        return rows
    }
}
