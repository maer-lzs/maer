# Components

Living inventory of the shared UI and logic surfaces. One row per reusable
component: what it is, every surface that uses it, and its parameters/variants.
Present-tense, current state only — history lives in git.

**Two standing rules:**

1. Any commit that touches a shared surface, or adds one, updates the matching
   row in the **same commit**. This file is always current, never archaeological.
2. Coverage claims in reports ("all media tabs", "every download surface") cite a
   row here — this table is the source, not prose.

Convention: cross-media behaviour and reused UI is **one parametrised component**
used by every relevant surface (Regel 2). A new media tab wires the existing
components rather than forking them.

## Rows & cards

| Component | Used by (file · context) | Parameters / variants |
|---|---|---|
| `MediaRowContent` | `PlayQueueRow` · `BookDownloadRow` (BookGridComponents) · `PodcastEpisodeRow` (PodcastComponents) | `coverURL, title`; opt. `eyebrow, meta, progressFraction`; flags `titleDimmed/coverDimmed/offlineBadge/downloadedBadge/showsPlayedCheck`; `placeholderSystemImage`; `coverSize=64` |
| `PlayQueueRow` | HomeView (Up Next) · PodcastsView (Up Next) · PodcastQueueView (queue page) | `item, playerCoordinator`; wraps `MediaRowContent` at default cover size; tap plays (leaves queue) |
| `PodcastEpisodeRow` | PodcastsView (Downloaded shelf) · PodcastShowView (episode list) | `item, playerCoordinator`; `rowTap = .detail` (`.play`/`.detail`/`.none`); swipe/menu actions; wraps `MediaRowContent` |
| `RecentShowTile` | PodcastsView (Recently Updated grid) | `info: RecentShowInfo`; cover + new-episode count badge + title + relative update time; offline dimming; caller wraps in `NavigationLink(value: .show)` |
| `MediaTile` | HomeView (Latest Episodes grid · Rediscover row) · `RecommendationTile` (Home Discover + podcast tab Recommended) — the Home tab's STANDARD grid tile | `title, subtitle?, coverURL, placeholderSystemImage, imageContentMode (fill/fit), cornerBadgeURL?` (~24 pt bottom-left, white border), `progress?` (thin bar at the image's bottom edge), `onTap` (caller's target), trailing `corner` slot (usually `MediaTilePlayBadge`; Discover passes `PodcastSubscribeBadge`) |
| `BookFeaturedCard` | HomeView (Continue) · LibraryView (Continue) | `entry, playerCoordinator, libraryViewModel`; fixed width 235; tap resumes, info pill → detail |
| `PodcastFeaturedCard` | HomeView (Continue) · PodcastsView (Continue) | `item, playerCoordinator`; fixed width 235; tap resumes, info pill → episode |
| `BookGridCell` | HomeView (Recently Added, w=150) · LibraryView (Recently Added w=180 · series · all-books grid) · BookGridComponents (author/genre browse grid) | `entry, width, playerCoordinator, libraryViewModel`; `NavigationLink(value: entry.id)` (String route) |
| `AlbumCell` | HomeView (Recently Added, w=150) · MusicView (albums grid `nil` · shelves w=150) · MusicBrowseViews (artist albums) | `item, width=nil, playerCoordinator`; `NavigationLink(value: MusicRoute.album)`; `musicItemMenu` |
| `ShowTile` | PodcastsView (Premium shelf) | `show`; fixed size 110 |

## Layout, badges & glass

| Component | Used by (file · context) | Parameters / variants |
|---|---|---|
| `CoverGrid` | MusicView (albums) · MusicBrowseViews (artist albums) · BookGridComponents (browse grid) | `columns, @ViewBuilder content`; `LazyVGrid` leading, spacing 20 |
| `PodcastSubscribeBadge` | `RecommendationTile` corner slot · PodcastShowPreviewView (statics) | `feedURL`; check when subscribed / spinner / "+" subscribes (ABS server when active, else local + gpodder push) and drops the feed from the recommendations pool. Big sibling `PodcastSubscribeButton` (same statics, capsule with label) is the preview page's prominent subscribe control |
| `RecommendationTile` | HomeView (Discover row) · PodcastsView (Recommended row) | `result, subtitle?, width=140`; `MediaTile` + subscribe corner control; tap → `PodcastRoute.showPreview` (temporary preview: catalog seed + live RSS fetch, nothing persisted until subscribed) |
| `DownloadInstallRing` | BookGridCell (BookGridComponents) | `itemId, tileWidth=180, lineWidth=3`; progress ring + cancel over the cover (grid tiles) |
| `CardDownloadBadge` | BookFeaturedCard · PodcastFeaturedCard | `itemId, startDownload`; unified download/offline badge at the CARD's bottom-right, matching the card's own "Details" info pill BY CONSTRUCTION: capsule around subheadline-metric content (hidden text template) + the pill's 7 pt vertical padding ⇒ height-identical at every type size; solid `.white.opacity(0.22)` fill, NO glass/blur (info-pill performance note); 44 pt tap frame anchored bottom-trailing ⇒ same 12 pt corner distance as the pill; icons: offline wifi.slash / progress ring+cancel / checkmark / download arrow |
| `CoverBadge` | `DownloadInstallRing` (disc size) · `BookCoverView` (wifi.slash + downloaded check) · `CardDownloadBadge` (tap frame) · BookDetailScreen (download-section buttons + X22b action-row min height) · `PodcastDownloadButton` (PodcastComponents, episode detail) | `detailControl = 44` — the family's HIT-TARGET constant: the detail pages' control buttons and `CardDownloadBadge`'s tap frame use it, and `size(tileWidth, cap=detailControl)` (= 22 % of tile, clamped 18…`cap`) caps at it; the card badge's visible size follows the card's info pill instead |
| `AdaptiveGlassBackground` | MiniPlayerBar · MediaTabBar · LibraryView (search/close/home/toolbar/banner) · SearchScreen (scope bar) · FloatingSearchButton · RefreshActivityPill · ResumeMessageBanner · BookDetailScreen (buttons/pills) | `shape`; `forceDark=false`; `lightAccent=nil`; iOS 26 `.glassEffect`, material fallback below. The bottom bar shows the same clear glass in every state (rest/scroll/collapsed/expanded) — no scroll-time material swap |

## Navigation

| Component | Registered / pushed from | Cases / variants |
|---|---|---|
| `PodcastRoute` | Registered on stack root (LibraryView) via `podcastNavigationDestinations`; pushed from PodcastsView · PodcastEpisodeDetailView · PodcastComponents (card/row/tile) · HomeView via `NavigationLink(value:)` / `pushPodcastRoute` env | `.show(feedURL)` · `.episode(itemId)` · `.queue` · `.showPreview(feedURL)` (temporary preview of an unsubscribed show; the Discover grid is gone). Book pushes from Home go through the `pushBookDetail` env (String route) the same way |
| `SearchScreen` + `GlobalSearchModel` | LibraryView (magnifier, every tab — THE one global search; Y23: FULL PAGE over the tab content, no drag handle, in-stack so deck cells push value routes; the FIELD lives in the bottom bar) | Y20 standing scope bar on top (single select `SearchScope`, gliding concentric pill — MediaTabBar pattern; `initial(for:)` = opening tab, Home→library; podcasts scope includes the catalog inline; trailing "Search the catalog" row otherwise, auto catalog view on zero own hits) · Y16 catalog card (grouped surface, "New Shows — from the catalog" + caption, every row carries `PodcastSubscribeBadge`, Y25 type meta "Podcast") · Y18 section cap 4 + "Show All (n)" · Y28 empty-field browse deck (Y30 recents chips on top — `RecentSearches`, tap re-runs, context-menu delete, Clear; upper drilldown tier with counts: audiobooks Authors/Series/Genres, music Artists, library the MIXED tier of all types; lower cover raster over `CoverGrid` + `BookGridCell`/`MediaTile`/`AlbumCell` with the LibraryView grid math; A–Z jump rail for audiobooks) · Y29 `.smooth(0.35)` arrival. Typed sections via pure `SearchRanking`; ONE result row over `MediaRowContent`; author/series drill in-page; navigation value-based per kind. Debounce 300 ms, cancel on input, 5 s per-provider timeout, partial results; per-source errors logged, total failure visible |
| `MusicRoute` | Registered on stack root (LibraryView) via `musicNavigationDestinations`; pushed from MusicView (album · browse rows) · MusicBrowseViews (artist · similar · playlist) | `.album(LibraryItem)` · `.artist(SubsonicArtist)` · `.artists([…])` · `.playlists([…])`; `Hashable` by id; `accessibilityId` per case |

Both push through the library's `navigationPath`, so a media-tab tap (which
empties the path) pops sub-pages back to the library root. Value-based only — a
plain `NavigationLink { destination }` would stay on the stack.

## Logic & derivations (pure, testable)

| Component | Used by | Surface |
|---|---|---|
| `ChapterModel` | PlayerViewModel (`resolved`, `current`) · BookDetailScreen (`resolved`, `selectorLabel`) · BookFeaturedCard (`validated`, `current`) · PlayerView + ChapterListView (`selectorLabel`) | Chapter validation + coverage/track/time-mark fallback; `isPodcast`-aware; file-mirroring chapters → parts (Teil) vs real chapters (Kapitel); `selectorLabel(isMusic,isFallback)` = one wording (Tracks/Parts/Chapters) for every selector surface |
| `NowPlayingPresentation` | PlayerViewModel+NowPlaying (lock screen + CarPlay) | `title(isMusic,songTitle,workTitle,fallback)` (work; song for music; never empty) · `subtitle(chapterTitle,author,isFallback)` (real chapter only) |
| `PodcastSections` | PodcastsView (`computeSections`) · HomeView (`compute`) | `snapshot` + `computeDetached` → `nextUp / recentShows / downloaded`; off-main |
| `HomeSections` | HomeView | `byRecency([[id,ts]], limit)` newest-first, de-duplicated · `interleave([[id]], limit)` fair round-robin (Recently Added books+albums, neither starves) |
| `SyncHistory` + `SyncHistoryStore` (`SyncHistoryStoring`) | GPodderSync (reconcile) · SyncQueue (flush) · PodcastCloudSync (full reconcile) · SubsonicProvider (`syncLibraryNow`, Y27: service music, albums/songs counters, manual button in the music source) · SyncHistoryView (Settings → Sync → Sync History) | Pure `entry(...)` (drops zero counters) + `trimmed` ring buffer (last 50); entries carry stable id + device id (stage 2 iCloud mirror / Android store behind the narrow protocol — not built); guard events (mass-delete veto) are PERMANENT marked entries (S20 final form) |
| `SearchableProvider` (capability) + `SearchRanking`/`PodcastLocalSearch` | APIClient (ABS: books/authors/series, server search; offline = cached entries) · SubsonicProvider (search3: albums/songs/artists; offline = cached items) · RSSProvider (ALL subscribed shows incl. abspod via `allShows()` — the ABS-podcast provider deliberately does not conform, one searcher) | `search(query:) -> [SearchResult]` (typed, namespaced ids, `isPlayableNow` for the offline glyph rule); offline-first through the SAME protocol |
| `RediscoverSections` | HomeView (Rediscover row) | `picks(paused:unheard:seriesNext:now:daySeed:limit)` — three prioritized local sources (paused > 3 weeks · unheard > 30 days · next volume after a finished predecessor; both thresholds named constants), seeded daily rotation (`daySeed(for:)`), round-robin mix; `volume(fromSeriesName:)` parses the ABS "#N" convention; no candidates ⇒ empty ⇒ section hidden |

## State & chrome

| Component | Used by | Parameters / variants |
|---|---|---|
| `BottomBarState.shared` + `reportsBottomBarScroll(active:)` | Reported by every tab root (LibraryView audiobooks · MusicView · PodcastsView · HomeView) and pushed pages (BookDetailScreen · PodcastShowView/EpisodeDetail/Queue); `collapsed` read by LibraryView | `report/setUserDragging/setScrolling/scrollDidRest/expand/reset`; `@Published collapsed, isScrolling`; only the visible tab reports (`active`). `isScrolling` is a published placeholder — no reader since X17b. X21/X21b/X21c: collapse held `collapseDelaySeconds` (0.2 s) past scroll-start (pure `shouldCollapse`, with hysteresis — the delay gates only expanded→collapsed, a collapsed bar stays collapsed above the threshold), auto-expand idle 0.9 s, each flip emits a `barCollapsedFlip` os_signpost. Y31: collapsing additionally requires a USER gesture (`hasUserScrolled`, cleared on reset) — layout/programmatic offsets from populating pushed pages never collapse |
| `MediaType.tint` | MediaTabBar (selected tab) | Per-type colour: audiobooks orange · podcasts purple · music red · home `.primary` (neutral) · radio teal |
| `MediaTabBar` | LibraryView (bottom bar) | `types, selected, onSelect`; a matchedGeometry capsule pill CONCENTRIC to the bar capsule (one `pillGap` = end padding = vertical inset; capsule-in-capsule at a uniform gap ⇒ pill radius = bar radius − gap at every bar height — at rest, gliding and through the collapse morph; no own radius constant) glides behind the selected tab (type-tint wash, neutral at Home); selected label in its `MediaType.tint`, others neutral; `tab-<rawValue>` a11y id. Y37: `types` derives from `isAvailable` per render AND reacts live — `AppSession.sourcesVersion` (observable) bumps on every source change (Subsonic `reloadConfig`, ABS-podcast `hasPodcasts` flip; RSS was already live via `PodcastSubscriptions`); the active tab falls back to Home when its source disappears |

## Test infrastructure

| Component | Used by | Parameters / variants |
|---|---|---|
| `UITestSeed` (seeding hook) | ABSPlayerApp (`applyIfRequested`) · MusicViewModel (`uitestSeed` source) · PlayerCoordinator (`_seedActivePlayerForUITest`) | `isActive` (`-uitest`) bypasses login + seeds providers; `seedsActivePlayer` (`-uitest-player`) adds a presentation-only player; fixtures `seedAlbums/seedArtists/seedPlaylists`; DEBUG-only |
