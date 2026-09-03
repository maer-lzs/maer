# Changelog

## v2.9 (Build 22) — TestFlight

307 commits since v2.8 — the "bring your listening along" release: what other
podcast apps know about your shows and where you stopped comes into Mär, and
what Mär knows goes out again in a file any of them can read back.

### Import and export
- **Listening states from other apps.** One seam for every source, one
  matching ladder (GUID, enclosure, twin bridge, episode link, unambiguous
  title), one conflict rule: both sides with a moment, the newer wins;
  a source without a moment only fills gaps; a finished episode is never
  taken back. Every import shows a preview first and names what it could
  not match.
- **Overcast** (extended OPML), **AntennaPod** (exported database), **Pocket
  Casts** (your own account, email and password, one pass, nothing stored),
  **Apple Podcasts** (MTLibrary.sqlite, now on the same rule: the newer
  state wins, not the further one).
- **Export with listening states.** The OPML export mirrors the extended
  format, so a file of Mär's comes back complete; premium feeds stay out
  together with their states, and the dialog says what leaves before it does.
- **Known limits.** AntennaPod was accepted against a schema-built database,
  not an export of the real app. Pocket Casts needs an account with email and
  password; accounts signed in with Apple or Google have no password door.

### Catalogue and covers
- **Catalogue pages switch instantly**: the day's stock is indexed once
  instead of scanned eighteen times on the main thread, and a write path
  that called itself no longer crashes the page on the first visit of a day.
- **Cover cache works again**: the login token was part of the cache key and
  made file names too long to write; persistent covers for downloads survive
  offline; images fit or fill by one rule on every square surface.
- **Player tools follow the media**: a book, a podcast, a song and a live
  station each carry the tools that apply to them, by one rule.
- **Settings gear on tab roots only**, never on a pushed page.

### Build 23
- **This device's own export, imported straight back, adopts nothing.** The
  exchange format rounds sub-millisecond stamps up, which made a handful of
  states look newer than themselves; moments now compare on whole
  milliseconds. The import log names the reason for every adoption.
- **Import summary**: shows already followed count as "already subscribed",
  newly subscribed shows are listed by name, finished and in-progress states
  are shown apart.
- **Pocket Casts archive**: an archived episode counts as finished, heard or
  not; the mark is kept on this device and goes back out in the export as
  archived. Known limit: an export made on a second device does not carry
  it, because the mark does not sync.
- **Statistics**: imported states no longer count as listening time until
  the episode is heard here, and "Most Listened Shows" names the show
  instead of its key.
- The preview says "recorded when heard" only for sources that record it.

### Known in this build
- The Pocket Casts support export (for accounts signed in with Apple or
  Google) has no file entry yet; its format is unknown.

## v2.8 (Build 19)

137 commits since v2.7 — the "open shelf" release: Mär now brings a library of
its own. Free audiobooks, radio plays, netlabel music and old shellac records
are one tap away without owning a server, every row leads to a page that holds
the rest, and what the app knows about the rights of a recording it says
plainly instead of guessing.

### Security
- **Subscription store wipe race**: a cold background refresh could mutate the
  store *before* the disk load finished and wipe subscriptions. Now nothing
  mutates before `ensureLoaded()`, a guard blocks implausible mass removals,
  and a recovery path restores from the last good state.
- **OPML export leaves premium and token feeds out by default**: those URLs
  carry personal access links. The export says how many it withheld and offers
  the full export as an explicit second choice.

### Free catalogues
- **One area, "Free Audiobooks & Radio Plays"**, with a page per source:
  LibriVox, Internet Archive, Project Gutenberg, Old Time Radio — plus curated
  feed rows (public broadcasters, independent anthologies).
- **Genre shelves as the standard shape** wherever the axis actually carries:
  measured per source (Internet Archive 26 %, Old Time Radio 40 %, Jamendo
  93 % via tags). Where it does not, the source stays a browsable pool.
- **Shelves ask their own question**: each shelf queries the server with its
  own genre/subject clause and pages independently, instead of filtering the
  twelve visible preview tiles.
- **Rights are never guessed.** A recording without a licence field says
  "rights not stated by the source" with a question mark — not a green check.
  Public domain claimed by an uploader is labelled as claimed, not as derived.
- **Series bundles get show pages** with an episode list; Old Time Radio
  filenames are turned back into titles (date becomes "first aired", the
  administrative tail falls away) — conservatively, and only when a date was
  actually recognised.
- **Daily rotation** through the popularity rows, so the shelf does not show
  the same twelve titles every morning.

### Rows and pages
- **Every row is a preview, and every preview has a page behind it.** Counted
  rows carry a chevron with their total; catalogue rows carry an entry chevron
  (their stock is measured, and a counting rule would hide the way in at
  12 of 12); fully curated feed rows carry none, because there is nothing
  more to show.
- **Sorting and filtering moved to the surfaces** they act on; the glass
  button in the tab header is gone. A filter that matches nothing now says so
  and stays reachable.

### Radio
- **Logos load by themselves** through a two-stage fallback (Wikidata P154,
  then the site's touch icon) behind a favicon quality gate.
- **A failure is not a finding**: a network error used to be stored as "this
  station has no logo" and kept for fourteen days — every logo disappeared.
  Only a cleanly completed no-hit is recorded now.
- **Regional rows** with a vote floor, parallel fan-out and per-row dedupe;
  the cold start paints the last known state in the first frame.

### Podcasts
- **Curated public-broadcaster entry** with a page by country; empty countries
  do not appear.
- **Pinchflat** as its own source: connect a server, mirror its channel list,
  keep it in its own group, and mark the origin ("YouTube") wherever a
  mirrored episode shows up outside that group.
- **Premium is one truth**: feed signal, credentials, token URLs and a manual
  mark all feed the same answer; mirrored feeds are never premium.
- **Rediscover for podcasts**, and background refresh fails fast instead of
  spinning for minutes without an end state.

### Music
- **Netlabels and 78 rpm records as positive shelves** — an inclusion list of
  genres, never an exclusion list.
- **Jamendo genre shelves** load server-side; the catalogue tap is
  data-driven: one track plays, several open the album page.
- **Shuffle** draws from the whole shelf, not from the visible twelve —
  random sort *and* random page, because the sort alone is cached.

### Playlists
- **Mär playlists** hold ids from every source (server music, catalogue
  titles, podcast episodes) — the second playlist type next to server
  playlists, which can only reference what the server owns.
- **"Add to playlist" wherever an item is operable**, including the player.
- **iCloud sync across your own devices**: merged per list, and the losing
  version is kept as a local copy instead of dropped.

### Downloads
- **Automatic download of new episodes per show** (it existed, three per run,
  from the day you switch it on) gained the three things it was missing: Wi-Fi
  as a *gate* rather than a warning, a cleanup that only ever touches what the
  automatism itself downloaded (a week after you finished them), and a visible
  reason when an episode cannot be fetched.

### Onboarding & settings
- **The first screen is the map of the areas**, not an Audiobookshelf login:
  one sentence about what Mär is, then each area with one line about what it
  needs. Four of the five need no account at all, and "start without a server"
  is the equal choice.
- **The same map is the sources overview in the settings** — which is also the
  way back to it.
- **One activation answer per source** instead of the same default repeated
  35 times across eleven files; a test keeps it that way.
- Global playback settings (skip interval, default speed, smart rewind) left
  the Audiobooks pill: they govern podcasts, music and radio too.

### Project
- **Licence**: GPL-3.0 with additional terms for app-store distribution, a
  name and artwork reservation, an EULA, and a licence header in every source
  file — with a test that keeps it there.
- **One identity to the outside world**: the app introduced itself to foreign
  servers under six hand-maintained user-agent strings, one of which named a
  private host. Now there is one, derived from the bundle version.

### Reliability
- **"Played" no longer depends on a duration that changes.** Shows with
  dynamically inserted ads report a different length per request; finished
  episodes reappeared as "3 minutes left" after every refresh. The mark now
  carries the duration it was written against.
- **Knowledge that only the store has survives a refresh** — provenance and
  measured length are classified as store facts instead of being restored
  field by field.
- **Xcode self-references at the root**: the synchronised group carries
  `path = Sources`, so the project file cannot inject them any more; a test
  fails loudly if it happens.
- Bundle hygiene: only what the app needs ships.
## v2.7.1 (Build 18)

- Fix: the podcast listening history page failed to compile in Release
  builds (API stuck inside a debug-only block) — v2.7 could not be
  archived for TestFlight. No functional changes.

## v2.7 (Build 17)

160 commits since v2.6 — the "reach everything" release: the app now drives
cars, speaks two music-server dialects, plays radio from your own region, and
survives hostile networks without ever inventing an empty library.

### Drive Mode & CarPlay
- **Drive mode**: a big-button full-screen player layout for the car mount —
  enter/exit manually or automatically when a chosen car audio route connects
  (route matching, no new permissions); screen stays awake, dimmed overlay,
  Siri shortcut ("drive mode").
- **CarPlay**: audiobook tabs (Continue / Downloaded / Library), a Podcasts
  tab with the global Up-Next queue, and a Music tab when a music source is
  live; verified in the simulator (podcast chain incl. playback/skip); real
  cars need Apple's CarPlay entitlement.

### Music
- **Playlists**: create, rename, delete; add songs/albums from every context
  menu ("Add to Playlist", with a new-playlist flow); index-precise removal;
  full-size playlist cards with a real cover mosaic (unique per album).
- **Artists**: browse list with portraits, artist pages with top songs; a
  conservative, keyless portrait chain (MusicBrainz → Wikidata → Commons,
  1 req/s, opt-out in settings).
- **Music tab reordered**: playlist cards on top, a grouped library list
  (Artists · Albums · Songs · Playlists · Downloaded), then "Recently
  Played" / "Recently Added" shelves; a paged all-songs Titles list.
- **Continue listening for albums and playlists** — server bookmarks on
  Subsonic (cross-device), local fallback elsewhere; Home "Continue" shows
  music alongside books and episodes.
- **Jellyfin (beta)**: a second music backend behind the same provider
  surface (albums, artists, playlists, search, lyrics, favorites); active
  when it is the only configured music source. Verification against a real
  server is still open — treat it as beta.
- **Booksonic**: a Subsonic source can be declared "audiobooks" — albums
  become books with chapters, progress and continue-listening included.
- **Genres**: a genre browse grid (server genres with counters, curated
  glyphs) as the sixth library entry; each genre opens its albums and a
  paged song list.
- **Top songs** on album/playlist pages (client-side ranking over server
  play counts); **lyrics** in the player (server first, LRCLIB fallback with
  cache and opt-out); shuffle from cards, pages and the whole library.
- **Search**: the music scope now shows Artists · Albums · Songs · Playlists
  sections and offers Albums/Songs/Playlists/Genres category tiles. Note:
  Subsonic matches per entity — searching an artist name lists the artist;
  albums/songs match on their own titles.

### Radio
- **National & regional discovery**: popular stations of your country, plus a
  state/region picker; codec/bitrate variants folded to one station with a
  quality picker on the station page and in the live player.
- **Station detail pages** (context menu, and via a tap on the live player's
  station title): facts (codec/bitrate/country/tags), website, quality
  picker, and similar stations; an ICY now-playing artwork lookup
  (MusicBrainz → Cover Art Archive, station logo as fallback).
- **Region picker curated**: community noise filtered, spelling variants
  merged (queries still hit every raw variant), sorted by station count,
  with a search field and an explicit country choice (your choice beats the
  device locale — no location access).

### Podcasts
- **Listen log**: a per-person listening history that survives unsubscribes
  and feed rotation (own file, tombstones, one-time backfill) — now with a
  **History page** on the Podcasts tab (finished episodes, newest first;
  entries link back while the episode still resolves).
- **Transcripts**: episodes with a `podcast:transcript` tag (SRT/VTT/JSON,
  content-sniffed) get a synced transcript view in the player — live
  highlight, tap to seek.
- **Genre chips** in the podcast search (keyless iTunes genre charts) as a
  browse entry.
- **Text-only episodes** (no audio enclosure) are kept and marked instead of
  hidden — dimmed row, "Text only" badge, tap opens the show notes; they
  never enter queue, downloads, or auto-continue.
- **gpodder hardening**: device registration for stricter servers
  (PodFetch/Pinepods/Nextcloud), and an unreadable server response now
  surfaces as an error instead of silently reading as "0 subscriptions"
  (captive-portal protection; the mass-delete guard stays as second line).
- Feed parsing hardened against the real world: Podsync/`video` enclosures,
  relative URLs, duplicate GUIDs, exotic RFC-2822 dates, broken OPML now
  fails visibly instead of importing a partial list.

### App-wide
- **Full player → source pages**: tap the title/subtitle to jump to the book
  page, show page, or album page (player minimizes, playback continues);
  a context menu adds artist/episode targets.
- **The app restarts on the last selected tab**; a transiently unreachable
  server can no longer throw you off your tab (only a real settings toggle
  moves the selection).
- **Search**: first-open and first-query work moved off the main thread;
  opening the search from a pushed detail page works now (release gate).
- **Full-player bottom row reordered**: Up Next · Bookmarks · Lyrics ·
  Transcript · a "…" menu (Drive Mode, Mark Finished) — and AirPlay solo,
  centered (the Apple position). Navigable titles carry a subtle chevron.
- **One card language**: playlist and music-continue cards share the exact
  Featured-card anatomy (details pill bottom-left, corner button
  bottom-right, tap plays); category tiles flattened app-wide.
- **Silent-error hardening**: broken server answers (captive portals, half
  JSON) now fail over mirrors or surface visibly instead of reading as an
  empty list; a corrupt local subscription store is preserved for recovery
  instead of being silently overwritten.
- Two-level source toggles (tab master + per-source) — a disabled source
  makes zero network calls; large-title loss on tab switch damped
  (iOS 26 framework bug, FB18304716); many small fixes.

### Known open points (honest)
- iPad mini: a slight residual hitch at the bar collapse remains (damped, not
  cured); the profiling trail points at framework layout/text cost per grid
  row — a structural cut is planned (per-tab navigation stacks).
- The large-title damping is an accepted interim solution; the root fix
  arrives with the tab-structure rebuild.
- Jellyfin is beta until verified against a real server.
- The drive-mode hero cover and the reworked cards await the device pass;
  listening statistics are designed but deliberately not in this release.

## v2.6

Internet radio as a fourth media type, global full-page search, color-world
refresh, serverless onboarding, settings reorder + sync history, shared
follow grids, retry parity. (See git history for details.)
