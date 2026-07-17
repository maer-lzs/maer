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
| `PodcastEpisodeRow` | PodcastsView (Downloaded shelf) · HomeView (Latest Episodes) · PodcastShowView (episode list) | `item, playerCoordinator`; `rowTap = .detail` (`.play`/`.detail`/`.none`); swipe/menu actions; wraps `MediaRowContent` |
| `BookFeaturedCard` | HomeView (Continue) · LibraryView (Continue) | `entry, playerCoordinator, libraryViewModel`; fixed width 235; tap resumes, info pill → detail |
| `PodcastFeaturedCard` | HomeView (Continue) · PodcastsView (Continue) | `item, playerCoordinator`; fixed width 235; tap resumes, info pill → episode |
| `BookGridCell` | HomeView (Recently Added, w=150) · LibraryView (Recently Added w=180 · series · all-books grid) · BookGridComponents (author/genre browse grid) | `entry, width, playerCoordinator, libraryViewModel`; `NavigationLink(value: entry.id)` (String route) |
| `AlbumCell` | HomeView (Recently Added, w=150) · MusicView (albums grid `nil` · shelves w=150) · MusicBrowseViews (artist albums) | `item, width=nil, playerCoordinator`; `NavigationLink(value: MusicRoute.album)`; `musicItemMenu` |
| `ShowTile` | PodcastsView (Premium shelf) | `show`; fixed size 110 |

## Layout, badges & glass

| Component | Used by (file · context) | Parameters / variants |
|---|---|---|
| `CoverGrid` | MusicView (albums) · MusicBrowseViews (artist albums) · PodcastDiscoverView (discover) · BookGridComponents (browse grid) | `columns, @ViewBuilder content`; `LazyVGrid` leading, spacing 20 |
| `DownloadInstallRing` | BookFeaturedCard (card cover) · BookGridCell (BookGridComponents) | `itemId, tileWidth=180, lineWidth=3`; progress ring + cancel over the cover |
| `CoverBadge` | `DownloadInstallRing` (disc size) · `BookCoverView` (wifi.slash + downloaded check) | `size(tileWidth) -> CGFloat` = 22 % of tile, clamped 18…44 |
| `AdaptiveGlassBackground` | MiniPlayerBar · MediaTabBar · LibraryView (search/home/toolbar/banner) · FloatingSearchButton · RefreshActivityPill · ResumeMessageBanner · BookDetailScreen (buttons/pills) · BookGridComponents (featured card) | `shape`; `forceDark=false`; `lightAccent=nil`; `reduced=false` (drops Liquid Glass → material while scrolling); iOS 26 `.glassEffect`, material fallback below. **All bottom-bar elements** (mini player, home, search, tab bar) share one `reduced` source (`BottomBarState.isScrolling`) so the row never mixes clear glass and reduced material |

## Navigation

| Component | Registered / pushed from | Cases / variants |
|---|---|---|
| `PodcastRoute` | Registered on stack root (LibraryView) via `podcastNavigationDestinations`; pushed from PodcastsView · PodcastEpisodeDetailView · PodcastComponents (card/row) via `NavigationLink(value:)` / `pushPodcastRoute` env | `.show(feedURL)` · `.episode(itemId)` · `.queue` |
| `MusicRoute` | Registered on stack root (LibraryView) via `musicNavigationDestinations`; pushed from MusicView (album · browse rows) · MusicBrowseViews (artist · similar · playlist) | `.album(LibraryItem)` · `.artist(SubsonicArtist)` · `.artists([…])` · `.playlists([…])`; `Hashable` by id; `accessibilityId` per case |

Both push through the library's `navigationPath`, so a media-tab tap (which
empties the path) pops sub-pages back to the library root. Value-based only — a
plain `NavigationLink { destination }` would stay on the stack.

## Logic & derivations (pure, testable)

| Component | Used by | Surface |
|---|---|---|
| `ChapterModel` | PlayerViewModel (`resolved`, `current`) · BookDetailScreen (`resolved`) · BookFeaturedCard (`validated`, `current`) | Chapter validation + coverage/track/time-mark fallback; `isPodcast`-aware; file-mirroring chapters → parts (Teil) vs real chapters (Kapitel) |
| `NowPlayingPresentation` | PlayerViewModel+NowPlaying (lock screen + CarPlay) · PlayerViewModel+LiveActivity | `title(isMusic,songTitle,workTitle,fallback)` (work; song for music; never empty) · `subtitle(chapterTitle,author,isFallback)` (real chapter only) |
| `PodcastSections` | PodcastsView (`computeSections`) · HomeView (`compute`) | `snapshot` + `computeDetached` → `nextUp / recentShows / downloaded`; off-main |
| `HomeSections` | HomeView | `byRecency([[id,ts]], limit)` newest-first, de-duplicated · `interleave([[id]], limit)` fair round-robin (Recently Added books+albums, neither starves) |

## State & chrome

| Component | Used by | Parameters / variants |
|---|---|---|
| `BottomBarState.shared` + `reportsBottomBarScroll(active:)` | Reported by every tab root (LibraryView audiobooks · MusicView · PodcastsView · HomeView) and pushed pages (BookDetailScreen · PodcastShowView/EpisodeDetail/Queue); read by LibraryView (`collapsed`) + MiniPlayerBar (`isScrolling`) | `report/setUserDragging/setScrolling/scrollDidRest/expand/reset`; `@Published collapsed, isScrolling`; only the visible tab reports (`active`) |
| `MediaType.tint` | MediaTabBar (selected tab) | Per-type colour: audiobooks orange · podcasts purple · music red · home `.primary` (neutral) · radio teal |
| `MediaTabBar` | LibraryView (bottom bar) | `types, selected, onSelect`; selected tab in its `MediaType.tint`, others neutral; `tab-<rawValue>` a11y id |

## Test infrastructure

| Component | Used by | Parameters / variants |
|---|---|---|
| `UITestSeed` (seeding hook) | ABSPlayerApp (`applyIfRequested`) · MusicViewModel (`uitestSeed` source) · PlayerCoordinator (`_seedActivePlayerForUITest`) | `isActive` (`-uitest`) bypasses login + seeds providers; `seedsActivePlayer` (`-uitest-player`) adds a presentation-only player; fixtures `seedAlbums/seedArtists/seedPlaylists`; DEBUG-only |
