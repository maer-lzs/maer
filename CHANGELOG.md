# Changelog

## Next build (not yet cut)

- **Playlist entries travel with their name and say why they cannot play.**
  Every entry of a playlist on your devices now carries its title, artist,
  length and (for free catalogs) its cover to the other device. Netlabel,
  archive.org, LibriVox and Gutenberg entries play there straight from the
  entry; a server title, a local file or an episode the other device does
  not have stays in the list with the reason instead of vanishing. A copy
  the merge keeps when both devices changed the same list is named after
  the device and the moment it came from and explains itself on its page.
  A new playlist never takes a name that is already in use.
- **The mini player says which device is playing.** "Playing on iPad: 1Q84"
  in one line instead of two shortened parts; the device's name travels
  with the claim.

## v2.9.1 (Build 28), TestFlight

### Since Build 27
- **An unfinished adoption no longer removes subscriptions.** While a device
  is still following the account's feeds, or one feed fails to load, the
  missing ones used to be read as unsubscribed and could vanish from the
  whole account. Now only your own unsubscribe removes a show; feeds not yet
  followed stay offered until they load. The sync history names removed
  shows. A subscription that an earlier build had frozen behind a tombstone
  with the same stamp heals by itself: the device that still holds it
  writes it back, the other device follows.
- **Continue rows follow every new entry at once.** A start on this
  device, a takeover from the other one, a position or subscription that
  arrives over iCloud, an import, a finish: Home, the Podcasts tab, the
  Music tab, the Books tab and the mini player update on the next frame,
  without a restart, a tab switch or a pull. Home ranks by the real moment
  across books, episodes and albums.
- **The import preview reports itself.** States that stayed out are split
  into "already known on this device" and "nothing to take over"; states no
  episode claimed are grouped by show, each with the reason the matching
  stopped and what the feed carries here.
- **A feed that could not be followed shows up with its reason.** When the
  other device follows a feed this device cannot load (login missing, feed
  gone, timeout, unreachable), the Podcasts tab lists it under "Not followed
  yet" with the reason and a retry, or a button into the login form, instead
  of failing silently on every sync. The sync history counts these feeds.
  Dismissing such a placeholder is a local choice: the other device keeps the
  show, and subscribing it again there brings it back here.

### Please try
- Import your podcasts on one device: the other device follows the shows by
  itself within a minute, listening states included.
- Unsubscribe on one device, the other follows.
- A feed that needs a login shows up as needing one; dismissing it there
  leaves the other device alone.
- Start something on one device: the other device's Start page follows
  within a minute, without a restart, and the newest entry sits first.
- The takeover test from Build 26 again: five switches with different titles,
  three with the same title, no jump after the start.

## v2.9.1 (Build 27), TestFlight

### Since Build 26
- **Podcast subscriptions travel over iCloud.** Subscribing on one device
  subscribes on the other, unsubscribing too; an import brings its shows
  along. A device with a podcast server (gpodder or Audiobookshelf podcasts)
  keeps the server as its truth and never applies the account's list, but
  still shares its own changes. Adopted shows are fetched one by one in the
  background, without automatic downloads or "new episode" notifications;
  the listening states already in the pot then apply.
- **Per-show settings travel completely.** The playback rate of a show now
  travels like inbox mode, notifications and the episode limit.
- The sync history counts subscriptions that arrived over iCloud, and the
  import preview counts them into the shared space.

## v2.9.1 (Build 26), TestFlight

The iCloud release: taking over playback between two devices is faster and
never plays on both, the shared pot is written far less often, and what
sync cannot do says so where you look.

### Fixed since Build 25
- **Takeover stops the other device.** The device that plays is now the one
  that gets paused, whatever the player happened to hold at that moment.
- **One account, one listener.** Playing on one device pauses the other,
  whatever plays there; the paused device names what took over. Two
  devices at once is what switching iCloud sync off is for.
- **Takeover starts at the last known stand, without catching up.** The
  claim carries the position, refreshed every ten seconds and on every
  jump; the taking-over device starts there and stays there. Up to about
  twenty seconds may be heard twice, a jump while listening never happens.
- **Catalogue books and sideloads start at the pot's stand** on the other
  device, like podcasts; every class whose stand travels asks the pot
  before it starts.
- **"Playing on another device" for every source.** Netlabels, radio and
  catalogue titles show the hint too, with the title from the other device.
- **The pot is written on occasions, not on echoes.** A foreign change is
  taken in and never answered with a write; while playing, the pot goes up
  at most once a minute, and at once on pause, stop, jump or a change of
  played state. Before: four whole-pot writes in 25 seconds.
- **Show tile counts no longer recompute every five seconds** while an
  episode plays.
- **Catalogue no longer indexes again after an update**: the popularity
  gatherer writes on the current stock instead of an old snapshot, and the
  daily delta says "Updating", not "Indexing n of n".
- **Funkwhale libraries load**: numeric ids on albums decode like every
  other id.
- **iCloud refusing writes is visible** in the sync history, and the import
  preview says how much of the shared space an import takes.

### Please try
- Start something on device A, then play it on device B: A stops, B starts
  near where A stood. Then the other way round. Then play something ELSE on
  B: A stops as well and names what B plays.
- Play a netlabel album or a radio station on A: B's mini bar names it.
- Watch the podcast tab while an episode plays: no flicker, counts stay.
- After this update: does a catalogue page say "Updating" or index again?

### Known
- Over iCloud the takeover still takes several seconds to arrive; a faster
  carrier is the next release.

## v2.9 (Build 25), TestFlight

307 commits since v2.8, the "bring your listening along" release: what other
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

### Fixed since Build 24
- **Show tiles count all unplayed episodes**, as Apple Podcasts and Pocket
  Casts do. Settings → Podcasts → "Count on show tiles" offers the older
  rule ("new since last played") and off. Existing devices show the total
  from this build on.
- **The count and the sections update at once** after listening or marking,
  not at the next restart.
- The import preview says "Heard at a known time" for sources that record
  when you listened.
- A Release build now refuses a dirty or unpushed tree, so every TestFlight
  build names its commit.
- **Imported listening states reach iCloud right away.** After an import
  nothing asked the sync to run, so a second device saw the states only
  after the first one was restarted. The sync log now says how big the
  shared pot is and whether the store accepted it.
- **"View source" on a netlabel track opened a 404**: the track's own
  address carried its index into the archive.org link. One place now cuts
  the archive identifier out of any catalogue id, for links and covers.
- The takeover log names every foreign claim it sees and what it decided,
  so a takeover that does not stop a device is no longer silent.
- **Server addresses that worked once travel to your other devices** and
  appear under the address field there, like any known address. Only the
  address, the service and the date travel; usernames, passwords and
  tokens never do, and the other device connects to nothing until you sign
  in there.

### Fixed since Build 23
- **Covers from feeds with cleartext image addresses** (relay.fm, the BBC)
  load again: image bytes leave through one door that raises `http://` to
  `https://`, the way feed addresses already were.
- **The media exception in App Transport Security was misspelt** and had
  never applied; it now carries the documented key, so cleartext streams
  and enclosures are exempt as intended.
- **Pocket Casts sign-in help**: accounts signed in with Apple or Google set
  a password on pocketcasts.com under "Forgot password"; the footer and the
  rejection message say so.
- The catalogue client no longer reaches into the view models for the
  day's stock; the caller hands it in (build hygiene for the source watch).

### Fixed since Build 22
- **A tap on the cover or the website link of a show page unsubscribed the
  show.** The header row held links and the subscription button without a
  borderless style, so a tap anywhere in the row fired every control in it.
  Each control now answers only to its own tap, and unsubscribing asks first.
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
  Google) has no file entry; the "Forgot password" way replaces it.
- An export made on a second device does not carry "archived", because
  that mark does not sync.

## v2.8 (Build 19)

137 commits since v2.7, the "open shelf" release: Mär now brings a library of
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
  LibriVox, Internet Archive, Project Gutenberg, Old Time Radio, plus curated
  feed rows (public broadcasters, independent anthologies).
- **Genre shelves as the standard shape** wherever the axis actually carries:
  measured per source (Internet Archive 26 %, Old Time Radio 40 %, Jamendo
  93 % via tags). Where it does not, the source stays a browsable pool.
- **Shelves ask their own question**: each shelf queries the server with its
  own genre/subject clause and pages independently, instead of filtering the
  twelve visible preview tiles.
- **Rights are never guessed.** A recording without a licence field says
  "rights not stated by the source" with a question mark, not a green check.
  Public domain claimed by an uploader is labelled as claimed, not as derived.
- **Series bundles get show pages** with an episode list; Old Time Radio
  filenames are turned back into titles (date becomes "first aired", the
  administrative tail falls away), conservatively, and only when a date was
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
  station has no logo" and kept for fourteen days, every logo disappeared.
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
- **Netlabels and 78 rpm records as positive shelves**, an inclusion list of
  genres, never an exclusion list.
- **Jamendo genre shelves** load server-side; the catalogue tap is
  data-driven: one track plays, several open the album page.
- **Shuffle** draws from the whole shelf, not from the visible twelve ,
  random sort *and* random page, because the sort alone is cached.

### Playlists
- **Mär playlists** hold ids from every source (server music, catalogue
  titles, podcast episodes), the second playlist type next to server
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
- **The same map is the sources overview in the settings**, which is also the
  way back to it.
- **One activation answer per source** instead of the same default repeated
  35 times across eleven files; a test keeps it that way.
- Global playback settings (skip interval, default speed, smart rewind) left
  the Audiobooks pill: they govern podcasts, music and radio too.

### Project
- **Licence**: GPL-3.0 with additional terms for app-store distribution, a
  name and artwork reservation, an EULA, and a licence header in every source
  file, with a test that keeps it there.
- **One identity to the outside world**: the app introduced itself to foreign
  servers under six hand-maintained user-agent strings, one of which named a
  private host. Now there is one, derived from the bundle version.

### Reliability
- **"Played" no longer depends on a duration that changes.** Shows with
  dynamically inserted ads report a different length per request; finished
  episodes reappeared as "3 minutes left" after every refresh. The mark now
  carries the duration it was written against.
- **Knowledge that only the store has survives a refresh**, provenance and
  measured length are classified as store facts instead of being restored
  field by field.
- **Xcode self-references at the root**: the synchronised group carries
  `path = Sources`, so the project file cannot inject them any more; a test
  fails loudly if it happens.
- Bundle hygiene: only what the app needs ships.
## v2.7.1 (Build 18)

- Fix: the podcast listening history page failed to compile in Release
  builds (API stuck inside a debug-only block), v2.7 could not be
  archived for TestFlight. No functional changes.

## v2.7 (Build 17)

160 commits since v2.6, the "reach everything" release: the app now drives
cars, speaks two music-server dialects, plays radio from your own region, and
survives hostile networks without ever inventing an empty library.

### Drive Mode & CarPlay
- **Drive mode**: a big-button full-screen player layout for the car mount ,
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
- **Continue listening for albums and playlists**, server bookmarks on
  Subsonic (cross-device), local fallback elsewhere; Home "Continue" shows
  music alongside books and episodes.
- **Jellyfin (beta)**: a second music backend behind the same provider
  surface (albums, artists, playlists, search, lyrics, favorites); active
  when it is the only configured music source. Verification against a real
  server is still open, treat it as beta.
- **Booksonic**: a Subsonic source can be declared "audiobooks", albums
  become books with chapters, progress and continue-listening included.
- **Genres**: a genre browse grid (server genres with counters, curated
  glyphs) as the sixth library entry; each genre opens its albums and a
  paged song list.
- **Top songs** on album/playlist pages (client-side ranking over server
  play counts); **lyrics** in the player (server first, LRCLIB fallback with
  cache and opt-out); shuffle from cards, pages and the whole library.
- **Search**: the music scope now shows Artists · Albums · Songs · Playlists
  sections and offers Albums/Songs/Playlists/Genres category tiles. Note:
  Subsonic matches per entity, searching an artist name lists the artist;
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
  device locale, no location access).

### Podcasts
- **Listen log**: a per-person listening history that survives unsubscribes
  and feed rotation (own file, tombstones, one-time backfill), now with a
  **History page** on the Podcasts tab (finished episodes, newest first;
  entries link back while the episode still resolves).
- **Transcripts**: episodes with a `podcast:transcript` tag (SRT/VTT/JSON,
  content-sniffed) get a synced transcript view in the player, live
  highlight, tap to seek.
- **Genre chips** in the podcast search (keyless iTunes genre charts) as a
  browse entry.
- **Text-only episodes** (no audio enclosure) are kept and marked instead of
  hidden, dimmed row, "Text only" badge, tap opens the show notes; they
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
  Transcript · a "…" menu (Drive Mode, Mark Finished), and AirPlay solo,
  centered (the Apple position). Navigable titles carry a subtle chevron.
- **One card language**: playlist and music-continue cards share the exact
  Featured-card anatomy (details pill bottom-left, corner button
  bottom-right, tap plays); category tiles flattened app-wide.
- **Silent-error hardening**: broken server answers (captive portals, half
  JSON) now fail over mirrors or surface visibly instead of reading as an
  empty list; a corrupt local subscription store is preserved for recovery
  instead of being silently overwritten.
- Two-level source toggles (tab master + per-source), a disabled source
  makes zero network calls; large-title loss on tab switch damped
  (iOS 26 framework bug, FB18304716); many small fixes.

### Known open points (honest)
- iPad mini: a slight residual hitch at the bar collapse remains (damped, not
  cured); the profiling trail points at framework layout/text cost per grid
  row, a structural cut is planned (per-tab navigation stacks).
- The large-title damping is an accepted interim solution; the root fix
  arrives with the tab-structure rebuild.
- Jellyfin is beta until verified against a real server.
- The drive-mode hero cover and the reworked cards await the device pass;
  listening statistics are designed but deliberately not in this release.

## v2.6

Internet radio as a fourth media type, global full-page search, color-world
refresh, serverless onboarding, settings reorder + sync history, shared
follow grids, retry parity. (See git history for details.)
