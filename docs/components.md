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
| `MediaRowContent` | `PlayQueueRow` · `BookDownloadRow` (BookGridComponents) · `PodcastEpisodeRow` (PodcastComponents) · RadioView (station rows) | `coverURL, title`; opt. `eyebrow, meta, progressFraction`; flags `titleDimmed/coverDimmed/offlineBadge/downloadedBadge/showsPlayedCheck`; `placeholderSystemImage`; `coverSize=64` |
| `PlayQueueRow` | HomeView (Up Next) · PodcastsView (Up Next) · PodcastQueueView (queue page) | `item, playerCoordinator`; wraps `MediaRowContent` at default cover size; tap plays (leaves queue) |
| `PodcastEpisodeRow` | PodcastsView (Downloaded shelf) · PodcastShowView (episode list) | `item, playerCoordinator`; `rowTap = .detail` (`.play`/`.detail`/`.none`); swipe/menu actions; wraps `MediaRowContent` |
| `RecentShowTile` | PodcastsView (Recently Updated grid) | `info: RecentShowInfo`; cover + new-episode count badge + title + relative update time; offline dimming; caller wraps in `NavigationLink(value: .show)` |
| `MediaTile` | `LatestEpisodesGrid` · HomeView (Rediscover row) · `RecommendationTile` (Home Discover + podcast tab Recommended) — the STANDARD grid tile | `title, subtitle?, coverURL, placeholderSystemImage, imageContentMode (fill/fit), cornerBadgeURL?` (~24 pt bottom-left, white border), `progress?` (thin bar at the image's bottom edge), `unavailable=false` (A3: dims the image AND overlays the white wifi.slash family badge — dimming never carries the state alone), `onTap` (caller's target), trailing `corner` slot (usually `MediaTilePlayBadge`; Discover passes `PodcastSubscribeBadge`) |
| `LatestEpisodesGrid` | HomeView (Latest Episodes) · PodcastsView (Latest Episodes — X1c tab parity) | `items` (newest-per-show via pure `PodcastSections.newestPerShow`, cap 30), `playerCoordinator`; self-measuring adaptive columns (3/4/5 at <640/<1000/≥1000 pt), 2 rows collapsed / 6 expanded (Y3a, inline; Y45: `.animation(.snappy(0.25), value: expanded)` on the grid so expand and collapse share one curve); MediaTile with show corner badge only when the episode has own artwork, play corner badge, progress, episode menu, A3 unavailable treatment |
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
| `CoverBadge` | `DownloadInstallRing` (disc size) · `BookCoverView` (wifi.slash + downloaded check) · `CardDownloadBadge` (tap frame) · BookDetailScreen (download-section buttons + X22b action-row min height) · `PodcastDownloadButton` (PodcastComponents, episode detail) | `detailControl = 44` — the family's HIT-TARGET constant: the detail pages' control buttons and `CardDownloadBadge`'s tap frame use it, and `size(tileWidth, cap=detailControl)` (= 22 % of tile, clamped 18…`cap`) caps at it; the card badge's visible size follows the card's info pill instead. A3/Y44: `View.offlineUnavailableBadge(_:)` — THE one unavailable treatment (0.5 dim + white wifi.slash disc, self-sizing 22 %), at the tile's TOP-RIGHT so it clears the bottom-right corner control (play badge / subscribe plus); applied by MediaTile (`unavailable:`) and `AlbumCell`. BookCoverView carries the same disc inline, also top-right, mutually exclusive with the finished check (a finished title needs no offline hint). Rows (`MediaRowContent`) already mark offline top-right. Exceptions: the FeaturedCards/`CardDownloadBadge` (offline lives in the card's info-pill badge) and `RecentShowTile` (offline top-LEFT — its top-right holds the unread-episode count, no bottom-right control) |
| `AdaptiveGlassBackground` | MiniPlayerBar · MediaTabBar · LibraryView (search/close/home/toolbar/banner) · SearchScreen (scope bar) · FloatingSearchButton · RefreshActivityPill · ResumeMessageBanner · BookDetailScreen (buttons/pills) | `shape`; `forceDark=false`; `lightAccent=nil`; iOS 26 `.glassEffect`, material fallback below. The bottom bar shows the same clear glass in every state (rest/scroll/collapsed/expanded) — no scroll-time material swap |

## Navigation

| Component | Registered / pushed from | Cases / variants |
|---|---|---|
| `PodcastRoute` | Registered on stack root (LibraryView) via `podcastNavigationDestinations`; pushed from PodcastsView · PodcastEpisodeDetailView · PodcastComponents (card/row/tile) · HomeView via `NavigationLink(value:)` / `pushPodcastRoute` env | `.show(feedURL)` · `.episode(itemId)` · `.queue` · `.showPreview(feedURL)` (temporary preview of an unsubscribed show; the Discover grid is gone). Book pushes from Home go through the `pushBookDetail` env (String route) the same way |
| `SearchScreen` + `GlobalSearchModel` | LibraryView (magnifier, every tab — THE one global search; Y23: FULL PAGE over the tab content, no drag handle, in-stack so deck cells push value routes; the FIELD lives in the bottom bar) | Y20 standing scope bar on top (single select `SearchScope`, gliding concentric pill — MediaTabBar pattern; `initial(for:)` = opening tab, Home→library; podcasts scope includes the catalog inline; trailing "Search the catalog" row otherwise, auto catalog view on zero own hits) · Y16 catalog card (grouped surface, "New Shows — from the catalog" + caption, every row carries `PodcastSubscribeBadge`, Y25 type meta "Podcast") · Y18 section cap 4 + "Show All (n)" · Y28 empty-field browse deck (Y30 recents chips on top — `RecentSearches`, tap re-runs, context-menu delete, Clear; upper entry tier (Y43: Apple-Podcasts-style TILES — 2-col raster of glyph + title + count, `deck-tier-<id>` a11y ids; same drill/scope targets as the former rows, cheap to revert): audiobooks Authors/Series/Genres, music Artists, library the MIXED tier of all types (drilled sub-levels of individual authors/artists stay ROWS); lower cover raster over `CoverGrid` + `BookGridCell`/`MediaTile`/`AlbumCell` with the LibraryView grid math; A–Z jump rail for audiobooks) · Y29 `.smooth(0.35)` arrival. Typed sections via pure `SearchRanking`; ONE result row over `MediaRowContent`; author/series drill in-page; navigation value-based per kind. Debounce 300 ms, cancel on input, 5 s per-provider timeout, partial results; per-source errors logged, total failure visible |
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
| `SyncHistory` + `SyncHistoryStore` (`SyncHistoryStoring`) | GPodderSync (reconcile — Y50: appends only on change/error/guard, else `noteChecked`) · SyncQueue (flush — appends on write, `noteChecked(.absProgress)` on every server-reached flush) · PlayerViewModel+Sync (`noteChecked(.absProgress)` on each progress write) · PodcastCloudSync (full reconcile — appends on change, else `noteChecked(.iCloud)`) · SubsonicProvider (`runLibrarySync` manual button appends; `fetchLibraryItems` live load `noteChecked(.music)` — Y49) · SyncHistoryView (Settings → Sync → Sync History: "Last checked" header + "Recent changes" ring) | Pure `entry(...)` (drops zero counters) + `trimmed` ring buffer (last 50); entries carry stable id + device id (stage 2 iCloud mirror / Android store behind the narrow protocol — not built); guard events (mass-delete veto) are PERMANENT marked entries (S20 final form). Y48/Y50: `noteChecked(service:)` keeps a per-service "last checked" stamp (monotonic, disk write coalesced to ≥30 s, own sibling file) so a check that changed nothing is still visible without cluttering the ring; `append` also refreshes the stamp |
| `SearchableProvider` (capability) + `SearchRanking`/`PodcastLocalSearch` | APIClient (ABS: books/authors/series, server search; offline = cached entries) · SubsonicProvider (search3: albums/songs/artists; offline = cached items) · RSSProvider (ALL subscribed shows incl. abspod via `allShows()` — the ABS-podcast provider deliberately does not conform, one searcher) · RadioProvider (F4: Radio Browser catalog + own stations; the radio SCOPE shows only while the source is active — Y37 pattern) | `search(query:) -> [SearchResult]` (typed, namespaced ids, `isPlayableNow` for the offline glyph rule); offline-first through the SAME protocol |
| `RediscoverSections` | HomeView (Rediscover row) | `picks(paused:unheard:seriesNext:now:daySeed:limit)` — three prioritized local sources (paused > 3 weeks · unheard > 30 days · next volume after a finished predecessor; both thresholds named constants), seeded daily rotation (`daySeed(for:)`), round-robin mix; `volume(fromSeriesName:)` parses the ABS "#N" convention; no candidates ⇒ empty ⇒ section hidden |

| `RadioMapping` · `ICYMetadata` · `RadioStore` (F1/F2, pure) | RadioProvider (catalog mapping, de-dupe by stationuuid, url_resolved preference; manual-station validation) · PlayerViewModel (ICY "Artist - Title" split for player/lock screen) · RadioView + RadioSourceView (favorites/manual/recents, UserDefaults) · PlayQueue (`canEnqueue`: F3 — `radio:` ids NEVER enqueue, play only replaces) | Foundation-only core (MaerCore rule); recents ring cap 8; ids `radio:rb:<uuid>` / `radio:manual:<uuid>` |
| `RequestRetryPolicy` (+ `fetch`) | APIClient `perform` (ABS, with logout hook after a CONFIRMED 401) · SubsonicClient `get` (Y39: shared `RequestRetryPolicy.fetch` loop + envelope-auth probe `subsonicDecision` for API codes 40/41) · `PodcastSubscriptions.fetchAndParse` (Y39: every feed pull — subscribe, refreshAll, preview) · best-effort metadata fetches (PodcastDirectory iTunes/PodcastIndex, CoverArtArchive, LRCLIB lyrics, PC20 chapter JSON — outward nil/empty semantics unchanged) · RadioBrowserClient | Pure per-attempt decision: 401 → ONE probe (500 ms) then fail; 429/5xx/timeout/connLost/cannotConnect → backoff [400, 1200]; real offline final. `fetch(_:session:)` = the policy loop for non-ABS callers, returns the last response so callers keep their own status semantics |

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
