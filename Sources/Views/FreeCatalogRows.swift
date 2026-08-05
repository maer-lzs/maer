// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Combine
import OSLog

/// 0714d26: the free-catalog Discover rows on Home — "New free audiobooks"
/// (LibriVox, keyless) · "Popular free audiobooks" (archive.org downloads
/// sort, keyless) · "Free music" (Jamendo, only with a client key). Tiles
/// play DIRECTLY (tap-to-play like radio); the context menu opens the
/// license/details sheet (public-domain badge resp. the Jamendo ToS
/// attribution with artist + backlink). Each row has its own opt-out on the
/// network-services page; rows are net-gated and hide silently when empty.
struct FreeCatalogRows: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// 34c36e1: the rows are DUMB now — a lazily-mounted, initially EMPTY
    /// view below the fold never ran its .task reliably (the third suspect);
    /// loading lives in HomeView's compute() pass (always runs, calm-gated)
    /// via `FreeCatalogLoader`.
    /// 7edb21b: the two audiobook rows LEFT Home — the books mix into the
    /// Discover section instead (moderate share) and live in their own
    /// audiobooks-tab area; only classical + free music remain as rows.
    let freeMusic: [LibraryItem]
    let classical: [LibraryItem]
    @State private var detailItem: LibraryItem?

    var body: some View {
        Group {
            if !classical.isEmpty {
                // 50f4751: the teaser POINTS INTO the separate area — the
                // header row navigates to the music-tab browse page.
                VStack(alignment: .leading, spacing: 10) {
                    NavigationLink(value: MusicRoute.freeClassical) {
                        HStack(spacing: 6) {
                            Text("Free Classical").font(.title3).bold()
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-free-classical-link")
                    tileRow(items: classical)
                }
            }
            if !freeMusic.isEmpty {
                row(title: "Free Music", items: freeMusic)
            }
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    private func row(title: LocalizedStringKey, items: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3).bold().padding(.horizontal)
            tileRow(items: items)
        }
    }

    private func tileRow(items: [LibraryItem]) -> some View {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        FreeCatalogBookTile(
                            item: item,
                            placeholderSystemImage: item.id.hasPrefix(FreeCatalog.jamendoPrefix)
                                ? "music.note" : "book.closed",
                            onTap: { Task { await playerCoordinator.open(item: item) } }
                        )
                        .containerRelativeFrame(.horizontal,
                                                count: CardMetrics.recommendationColumns(regularWidth: false),
                                                spacing: 14)
                        .contextMenu {
                            Button {
                                detailItem = item
                            } label: { Label("Details", systemImage: "info.circle") }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
    }
}

/// fbcff9f: the LibriVox import shows its progress where every other
/// download does — in the tile's corner slot, through the SHARED
/// `UnifiedDownloadRing`. Self-observing like `CardDownloadBadge`, so only
/// this small view re-renders per progress tick; nothing at all is drawn
/// while no import runs for THIS item (the corner slot collapses).
struct FreeCatalogImportBadge: View {
    let itemId: String
    @ObservedObject private var importer = LibriVoxImporter.shared
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 17

    var body: some View {
        if importer.activeBookId == itemId,
           let fraction = LibriVoxImporter.ringFraction(importer.phase) {
            Button { importer.cancel() } label: {
                ZStack {
                    Circle().fill(.black.opacity(0.45))
                        .frame(width: ringSize + 10, height: ringSize + 10)
                    UnifiedDownloadRing(fraction: fraction, lineWidth: 2.5, tint: .white)
                        .frame(width: ringSize, height: ringSize)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel Download"))
        }
    }
}

/// 34c36e1: the ONE loader — called from HomeView.compute() (always runs,
/// no lazy-mount dependency). WireCorpus discipline at the call sites: a
/// throwing client is CAUGHT and LOGGED with the actual error (never a
/// silent try?-collapse to empty); the per-row log line names loaded/
/// filtered counts and the reason when a row stays empty.
@MainActor
enum FreeCatalogLoader {
    struct Rows {
        /// 7edb21b: LibriVox books for the DISCOVER mix (moderate share).
        var discoverBooks: [LibraryItem] = []
        /// cb99bf6: the audiobooks-tab tile row (same fetch, wider cut).
        var tabBooks: [LibraryItem] = []
        var freeMusic: [LibraryItem] = []
        var classical: [LibraryItem] = []
    }

    /// Moderate share (Fortsetzen-Deckel-Denke): at most this many LibriVox
    /// tiles mix into Discover; constant, not a setting.
    static let discoverBookCap = 3

    static func load() async -> Rows {
        // 5034add: master off ⇒ nothing loads, nothing fetches — the whole
        // catalog feature is dark (UI gates hide the surfaces separately).
        guard UserDefaults.standard.object(forKey: AppStorageKeys.freeCatalogsMasterEnabled) as? Bool ?? true else {
            return Rows()
        }
        var rows = Rows()
        #if DEBUG
        if UITestSeed.isActive { return rows }   // no external calls in the harness
        #endif
        let provider = FreeCatalogProvider.shared
        let librivoxOn = UserDefaults.standard.object(forKey: AppStorageKeys.librivoxRowsEnabled) as? Bool ?? true
        let archiveOn = UserDefaults.standard.object(forKey: AppStorageKeys.archivePopularEnabled) as? Bool ?? true
        let jamendoOn = UserDefaults.standard.object(forKey: AppStorageKeys.jamendoRowEnabled) as? Bool ?? true

        let areaOn = UserDefaults.standard.object(forKey: AppStorageKeys.freeAudiobooksEnabled) as? Bool ?? true
        if librivoxOn && areaOn {
            do {
                // 938aebc: the row used to fetch LibriVox's SINCE feed (new
                // additions) — which is why it showed obscure newcomers and
                // never the classics. It now rides the downloads sort, one
                // query PER active language, interleaved.
                let codes = SuggestionLanguages.current()
                let docs = try await ArchiveOrgClient.popularLibriVoxByLanguage(
                    rowsPerLanguage: 12, languageCodes: codes, limit: 12)
                Logger.library.notice("FREECAT discover-books sort=downloads codes=\(codes.isEmpty ? "-" : codes.joined(separator: ","), privacy: .public) loaded=\(docs.count)")
                if docs.isEmpty {
                    Logger.library.notice("FREECAT discover-books EMPTY: no docs for the active languages")
                }
                let items = docs.compactMap { provider.remember(popular: $0) }
                rows.discoverBooks = Array(items.prefix(Self.discoverBookCap))
                // cb99bf6: ONE fetch, two cuts — the tab row shows more.
                rows.tabBooks = items
            } catch {
                Logger.library.error("FREECAT discover-books FAILED: \(String(describing: error), privacy: .public)")
            }
        }
        let classicalOn = (UserDefaults.standard.object(forKey: AppStorageKeys.freeClassicalEnabled) as? Bool ?? true) && archiveOn
        if classicalOn {
            do {
                let docs = try await ArchiveOrgClient.popularClassical(rows: 12)
                Logger.library.notice("FREECAT classical-teaser loaded=\(docs.count)")
                rows.classical = docs.compactMap { provider.remember(popular: $0) }
            } catch {
                Logger.library.error("FREECAT classical-teaser FAILED: \(String(describing: error), privacy: .public)")
            }
        }
        if jamendoOn {
            if JamendoClient.clientId() == nil {
                Logger.library.notice("FREECAT jamendo EMPTY: no client key")
            } else {
                do {
                    let tracks = try await JamendoClient.popularTracks(limit: 12)
                    Logger.library.notice("FREECAT jamendo loaded=\(tracks.count)")
                    rows.freeMusic = tracks.compactMap { provider.remember(track: $0) }
                } catch {
                    Logger.library.error("FREECAT jamendo FAILED: \(String(describing: error), privacy: .public)")
                }
            }
        }
        return rows
    }
}

/// cb99bf6: the ONE shared home of the loaded catalog rows — Home's
/// compute() pass fills it (retry-while-empty stays there); the audiobooks
/// tab row observes the SAME store instead of loading a second time.
@MainActor
final class FreeCatalogStore: ObservableObject {
    static let shared = FreeCatalogStore()
    private init() {}
    @Published private(set) var rows = FreeCatalogLoader.Rows()
    private(set) var loaded = false
    private var loading = false

    /// 784aceb: language change ⇒ reload on the next compute pass; the old
    /// rows stay visible until the calm-gated replacement arrives.
    func invalidateForLanguageChange() {
        loaded = false
    }

    /// The single load pass (34c36e1 discipline: called from compute(),
    /// never from a lazily mounted empty view's own task).
    func ensureLoaded() async {
        guard !loaded, !loading, NetworkMonitor.shared.isConnected else { return }
        loading = true
        defer { loading = false }
        let loadedRows = await FreeCatalogLoader.load()
        loaded = !loadedRows.discoverBooks.isEmpty
            || !loadedRows.freeMusic.isEmpty || !loadedRows.classical.isEmpty
        BottomBarState.shared.runWhenCalm { [weak self] in self?.rows = loadedRows }
    }
}

/// License/details sheet: public-domain badge for LibriVox/archive items;
/// Jamendo carries the ToS-mandated artist credit, "via Jamendo" and the
/// DIRECT backlink to the track page.
struct FreeCatalogDetailSheet: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss
    /// 3125a42: take-into-library state (ABS upload / local feed).
    @ObservedObject private var importer = LibriVoxImporter.shared
    @State private var absLibraries: [ABSLibrary] = []
    @State private var showLibraryPicker = false
    @State private var showWiFiWarning = false
    @State private var localSubscribed = false
    /// b395e5f: hi-res cover once resolved (thumb → hires upgrade).
    @State private var hiresCover: URL?

    private var isJamendo: Bool { item.id.hasPrefix(FreeCatalog.jamendoPrefix) }
    private var jamendoTrack: JamendoTrack? {
        FreeCatalogProvider.shared.jamendoTrack(forId: item.id)
    }
    private var librivoxURL: URL? {
        FreeCatalogProvider.shared.librivoxBook(forId: item.id)?.url_librivox.flatMap { URL(string: $0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // b395e5f: thumb first, hi-res swapped in once resolved
                // (soft crossfade; ImageCache persists both).
                CachedAsyncImage(url: hiresCover ?? AppSession.shared.coverURL(forItemId: item.id)) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                        .overlay(Image(systemName: isJamendo ? "music.note" : "book.closed")
                            .font(.largeTitle).foregroundStyle(.secondary))
                }
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .animation(.easeInOut(duration: 0.25), value: hiresCover)

                VStack(spacing: 4) {
                    Text(item.title).font(.headline).multilineTextAlignment(.center)
                    if let author = item.author {
                        Text(author).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if isJamendo {
                    // ToS: artist credit + provider credit + direct backlink.
                    VStack(spacing: 6) {
                        Label("Creative Commons — via Jamendo", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.secondary)
                        if let share = jamendoTrack?.shareurl.flatMap({ URL(string: $0) }) {
                            Link(destination: share) {
                                Label("View on Jamendo", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        // e948444: do not claim public domain for everything —
                        // an Old-Time-Radio item can be CC-BY-NC-ND, and the
                        // user should see WHICH licence, not a blanket badge.
                        if let licence = FreeCatalogProvider.shared.licence(forItemId: item.id) {
                            Label(licence, systemImage: "checkmark.seal")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            // 50aefa8/12753d8: the else branch USED to claim
                            // public domain for every title without a licence
                            // field — 4271 of them in the classical row.
                            //
                            // The claim is gone, and so is the seal: a
                            // checkmark IS an assertion. What replaces it
                            // depends on what the source actually tells us
                            // (pure FreeCatalog.rightsNote).
                            switch FreeCatalog.rightsNote(
                                year: item.media?.metadata?.publishedYear?.value) {
                            case .publicDomain:
                                // ≤ 1925: expired even under the LONGEST of the
                                // three terms, so it holds everywhere.
                                Label("Public domain", systemImage: "checkmark.seal")
                                    .font(.caption).foregroundStyle(.secondary)
                            case .termsApply(let year):
                                // A fact about TERMS, never a verdict about
                                // this title — the answer differs by country,
                                // and the device region is not the listener's
                                // jurisdiction (travel, foreign account, VPN).
                                Label(String(localized: "Recording from \(year). Sound recordings are free after 50 years in Switzerland, 70 in the EU and 100 in the USA."),
                                      systemImage: "clock")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            case .unknown:
                                Label("Rights status not stated by the source",
                                      systemImage: "questionmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let url = librivoxURL {
                            Link(destination: url) {
                                Label("View on LibriVox", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        } else if item.id.hasPrefix(FreeCatalog.archivePrefix),
                                  let url = URL(string: "https://archive.org/details/\(item.id.dropFirst(FreeCatalog.archivePrefix.count))") {
                            Link(destination: url) {
                                Label("View on Internet Archive", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                    }
                }

                Button {
                    dismiss()
                    Task { await playerCoordinator.open(item: item) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                // 3125a42: take a LibriVox book into the library — ABS upload
                // (only with a connected audiobook library) or a LOCAL feed
                // subscription (clearly labeled: no server sync).
                if item.id.hasPrefix(FreeCatalog.librivoxPrefix) {
                    importSection
                }
                Spacer(minLength: 0)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            if item.id.hasPrefix(FreeCatalog.librivoxPrefix) {
                hiresCover = await FreeCatalogProvider.shared.hiresCoverURL(forItemId: item.id)
                absLibraries = await LibriVoxImporter.audiobookLibraries()
            }
        }
        // Library picker (first use / vanished remembered target). The
        // choice is remembered; the folder is the library's first (ABS
        // libraries practically always carry exactly one).
        .confirmationDialog("Choose the target library", isPresented: $showLibraryPicker,
                            titleVisibility: .visible) {
            ForEach(absLibraries) { library in
                Button(library.name) {
                    Task {
                        var folderId = library.folders?.first?.id
                        if folderId == nil {
                            folderId = (try? await AppSession.shared.apiClient
                                .fetchLibraryFolders(libraryId: library.id))?.first?.id
                        }
                        guard let folderId else { return }
                        UserDefaults.standard.set(library.id, forKey: AppStorageKeys.librivoxImportLibraryId)
                        UserDefaults.standard.set(folderId, forKey: AppStorageKeys.librivoxImportFolderId)
                        begin(libraryId: library.id, folderId: folderId)
                    }
                }
            }
        }
        .alert("Not on Wi-Fi", isPresented: $showWiFiWarning) {
            Button("Continue on Cellular", role: .destructive) {
                Task { await pickLibraryAndStart() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Audiobooks are large (often several hundred MB). Continue on cellular data?")
        }
    }

    private var book: LibriVoxBook? {
        FreeCatalogProvider.shared.librivoxBook(forId: item.id)
    }

    @ViewBuilder
    private var importSection: some View {
        switch importer.phase {
        case .downloading(let section, let of) where importer.activeBookId == item.id:
            VStack(spacing: 6) {
                // fbcff9f: the detail shows the SAME ring as the tile (one
                // progress language), the part line stays as the detail text.
                UnifiedDownloadRing(fraction: LibriVoxImporter.ringFraction(importer.phase) ?? -1,
                                    lineWidth: 3, tint: .accentColor)
                    .frame(width: 34, height: 34)
                Text("Downloading part \(section) of \(of)…")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { importer.cancel() }
                    .font(.caption)
            }
        case .uploading where importer.activeBookId == item.id:
            VStack(spacing: 6) {
                ProgressView()
                Text("Uploading to your server…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        // 31974ef (3): terminal states belong to THEIR book only — a
        // foreign sheet falls through to the menu below.
        case .done where importer.activeBookId == item.id:
            Label("Added to your library.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .duplicate(let existing) where importer.activeBookId == item.id:
            Label("Already in that library: \(existing)", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message) where importer.activeBookId == item.id:
            // 31974ef (2): the retry path — back to the menu on demand.
            VStack(spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Button("Try Again") { importer.reset() }
                    .font(.caption)
            }
        default:
            if importer.busy {
                // A second import while one runs: clear refusal, no ghost UI.
                Label("Another import is already running.", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
            Menu {
                if !absLibraries.isEmpty {
                    Button {
                        startServerImport()
                    } label: {
                        Label("To my server (Audiobookshelf)", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                if book?.url_rss?.isEmpty == false {
                    Button {
                        subscribeLocally()
                    } label: {
                        Label("Subscribe as feed (local only)", systemImage: "dot.radiowaves.up.forward")
                    }
                }
            } label: {
                Label(localSubscribed ? "Subscribed locally — no server sync" : "Add to Library…",
                      systemImage: localSubscribed ? "checkmark.circle" : "plus.circle")
                    .font(.subheadline)
            }
            .disabled(localSubscribed)
            .accessibilityIdentifier("librivox-import-menu")
            }
        }
    }

    private func startServerImport() {
        // Wi-Fi gate (books run 100–500 MB) — the existing cellular warning
        // mechanism; explicit confirmation continues on cellular.
        let warn = UserDefaults.standard.object(forKey: AppStorageKeys.warnCellularDownload) as? Bool ?? true
        Task {
            if warn, !(await NetworkStatus.isOnWiFi()) {
                showWiFiWarning = true
            } else {
                await pickLibraryAndStart()
            }
        }
    }

    private func pickLibraryAndStart() async {
        // Remembered target; picker on first use (or when it vanished).
        let storedLib = UserDefaults.standard.string(forKey: AppStorageKeys.librivoxImportLibraryId)
        if let storedLib, absLibraries.contains(where: { $0.id == storedLib }),
           let folder = UserDefaults.standard.string(forKey: AppStorageKeys.librivoxImportFolderId) {
            begin(libraryId: storedLib, folderId: folder)
        } else {
            showLibraryPicker = true
        }
    }

    private func begin(libraryId: String, folderId: String) {
        guard let book else { return }
        LibriVoxImporter.shared.start(book: book, itemId: item.id,
                                      libraryId: libraryId, folderId: folderId)
    }

    private func subscribeLocally() {
        guard let rss = book?.url_rss, !rss.isEmpty else { return }
        Task {
            localSubscribed = await PodcastSubscriptions.shared.subscribe(urlString: rss)
        }
    }
}
