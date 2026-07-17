import SwiftUI

/// Home = cross-section aggregation tab (Etappe 3). It is NOT a library — the
/// media tabs stay full libraries. Reuses ONLY existing components (Regel 2:
/// PlayQueueRow, AlbumCell) and ranks STRICTLY by timestamp via HomeSections.
/// Sections are computed from a snapshot in a `.task` (staged, E10/F5 pattern),
/// never in the body.
struct HomeView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    var isActive: Bool = true
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject private var queue = PlayQueue.shared
    /// Available library tabs (for the jump points), excluding home itself.
    let jumpTargets: [MediaType]
    let onJump: (MediaType) -> Void

    /// Recency-ordered ids of in-progress books + episodes — resolved to the
    /// matching FeaturedCard (book vs podcast) in the view (Regel 2: same cards
    /// as the library tabs, no Home-specific component).
    @State private var continueIds: [String] = []
    @State private var newItems: [LibraryItem] = []
    @State private var recentAlbums: [LibraryItem] = []
    @State private var ready = false

    private var recomputeToken: String {
        "\(isActive)-\(libraryViewModel.entries.count)-\(libraryViewModel.continueListening.count)-\(libraryViewModel.recentlyAdded.count)-\(queue.ids.count)"
    }

    var body: some View {
        ScrollView {
            if ready {
                LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                    continueSection
                    upNextSection
                    itemSection("New", newItems)
                    albumsSection
                    jumpSection
                    if isEmpty { emptyState }
                }
                .padding(.top, TabContentLayout.topInset)
                .bottomBarClearance()
                .transition(.opacity)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 280)
            }
        }
        // Home hangs on the SHARED bottom bar like every tab — only the visible
        // one reports (active-gate). Transition/feedback edge untouched.
        .reportsBottomBarScroll(active: isActive)
        .task(id: recomputeToken) {
            guard isActive else { return }
            await compute()
        }
    }

    private var isEmpty: Bool {
        continueIds.isEmpty && queue.isEmpty && newItems.isEmpty && recentAlbums.isEmpty
    }

    // MARK: - Sections (reused components only)

    /// W1 "Continue": in-progress books + episodes as the SAME large FeaturedCards
    /// the library tabs use — BookFeaturedCard for books, PodcastFeaturedCard for
    /// episodes — mixed in one horizontal carousel, ranked by last played. Cards
    /// mean "started"; the rows below (Up Next) mean "planned". No new component.
    @ViewBuilder
    private var continueSection: some View {
        if !continueIds.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Continue").font(.title2).bold().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(continueIds, id: \.self) { id in
                            continueCard(id)
                        }
                    }
                    .padding(.horizontal)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    /// Resolve a continue id to the matching card: a library book → the book
    /// card, anything else (a podcast episode) → the podcast card.
    @ViewBuilder
    private func continueCard(_ id: String) -> some View {
        if let entry = libraryViewModel.entries.first(where: { $0.id == id }) {
            BookFeaturedCard(entry: entry,
                             playerCoordinator: playerCoordinator,
                             libraryViewModel: libraryViewModel)
        } else if let item = AppSession.shared.libraryItem(forId: id) {
            PodcastFeaturedCard(item: item, playerCoordinator: playerCoordinator)
        }
    }

    @ViewBuilder
    private func itemSection(_ title: LocalizedStringKey, _ items: [LibraryItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3).bold().padding(.horizontal)
                LazyVStack(spacing: 0) {
                    ForEach(items.prefix(6)) { item in
                        PlayQueueRow(item: item, playerCoordinator: playerCoordinator)
                            .padding(.horizontal)
                        Divider().padding(.leading, 88)
                    }
                }
            }
        }
    }

    /// "Up Next" — the global PlayQueue, same row component as the queue page.
    @ViewBuilder
    private var upNextSection: some View {
        let items = queue.ids.compactMap { AppSession.shared.libraryItem(forId: $0) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Up Next").font(.title3).bold().padding(.horizontal)
                LazyVStack(spacing: 0) {
                    ForEach(items.prefix(5)) { item in
                        PlayQueueRow(item: item, playerCoordinator: playerCoordinator)
                            .padding(.horizontal)
                        Divider().padding(.leading, 88)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var albumsSection: some View {
        if !recentAlbums.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recently Played Albums").font(.title3).bold().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(recentAlbums.prefix(10)) { album in
                            AlbumCell(item: album, width: 140, playerCoordinator: playerCoordinator)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    @ViewBuilder
    private var jumpSection: some View {
        if !jumpTargets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Libraries").font(.title3).bold().padding(.horizontal)
                VStack(spacing: 0) {
                    ForEach(jumpTargets) { type in
                        Button { onJump(type) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: type.systemImage)
                                    .frame(width: 28)
                                    .foregroundStyle(AppTheme.accent)
                                Text(type.label).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if type != jumpTargets.last { Divider().padding(.leading, 52) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing here yet",
            systemImage: "house",
            description: Text("Start listening — your books, podcasts and music show up here.")
        )
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Snapshot compute (off the body)

    private func compute() async {
        let shows = PodcastAutoContinue.allShows()
        let snapshot = PodcastSections.snapshot(shows: shows)
        let sections = await PodcastSections.computeDetached(shows: shows, snapshot: snapshot)

        // Weiterhören: in-progress books + in-progress episodes, by last played.
        let books = libraryViewModel.continueListening.map {
            (id: $0.id, ts: $0.progress?.lastUpdate ?? 0)
        }
        let episodes = sections.nextUp.map { (id: $0.id, ts: localTimestamp($0.id)) }
        let rankedContinue = HomeSections.byRecency([books, episodes], limit: 8)

        // Neu: newly added books + newest episodes of each show.
        let newBooks = libraryViewModel.recentlyAdded.map {
            (id: $0.id, ts: Double($0.item.addedAt ?? 0))
        }
        let newEpisodes = shows.compactMap { show -> (id: String, ts: Double)? in
            guard let ep = show.episodes.max(by: { $0.pubDate < $1.pubDate }) else { return nil }
            return (ep.guid, ep.pubDate)
        }
        let newIds = HomeSections.byRecency([newBooks, newEpisodes], limit: 8)

        // Music (dosed): recently played albums shelf — best-effort (empty without
        // a music server).
        let albums = (try? await SubsonicProvider.shared.albumShelf(type: "recent", size: 12)) ?? []

        continueIds = rankedContinue
        newItems = newIds.compactMap { AppSession.shared.libraryItem(forId: $0) }
        recentAlbums = albums
        withAnimation(ready ? nil : .easeOut(duration: 0.25)) { ready = true }
    }

    /// Last-played timestamp of an item from the local position store (same
    /// source podcast auto-continue uses), 0 if none.
    private func localTimestamp(_ id: String) -> Double {
        (UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(id)) as? [Double])?.last ?? 0
    }
}
