# Changelog

## Next build (not yet cut)

**The book page fits its window.** On the iPhone Duo, folded or open,
and in a window that shares the screen, the cover at the top of a book
takes the width of the window, and on its side the page shows the large
cover where it fits.

**Diagnostics stay with the developers.** The Diagnostics page, the sync
history with its runs and counters, the progress diagnosis on book pages
and in a show's settings, and the device measurements are no longer part
of the app you install. Reload Catalog Data, which clears only derived
caches, is back under Storage in the settings.

**The mini player stays through a title change.** When one song ends and
the next one starts, the mini player keeps showing the old one until the
new one is ready; before, it left the screen for up to a second. A title
that cannot start no longer ends a shuffle or an album: the app says
which one it skipped and plays the next, after three in a row it stops.

**The Continue Listening widget shows its cover to the edge.** In both
sizes the cover fills the whole widget, with title, author, time left and
progress over it at the bottom; before, the medium widget showed a small
cover beside the text, and the small one left a dark strip on some
devices.

**The lock and the offline mark no longer cover each other.** An episode
of a premium feed that is not downloaded while you are offline shows both
marks at the top right of its tile, the lock above; before, the offline
mark lay over the lock. The marks grow with the text up to the first
accessibility size, and where a tile still has room for one mark only,
it shows that the episode is not available offline.

**One tone for the marks on episode, catalog and recommendation tiles.**
The kind of a tile in a mixed row now stands first in the column of marks
at the top right instead of at the top left. Every mark and every corner
button on these tiles (kind, lock, offline, play, subscribe, import) is a
white symbol on the same soft disc, the tone of the Details pill over a
dark shade deep enough to read on light covers; before, they used three
different darks, and subscribe was a green check or an orange plus.

**A single tile takes the whole row.** When a deck of tiles ends with
one tile alone in its row, like Local Files on the Audiobooks tab, that
tile now spans the full width instead of standing in half of it.

**Book covers carry their marks in one column.** At the top right of a
book cover stand, one under the other, its kind in a mixed row, whether
it is downloaded, failed to download or not available offline, and
whether it is finished; before, the download state stood at the bottom
left, and a finished book hid that it is not available offline. The
downloaded arrow and the finished check sit on the same disc as the other
marks, everywhere the downloaded arrow appears. A failed download keeps
its accent colour.

**Continue Listening cards show states at the top, controls at the
bottom.** On the book and episode cards, downloaded and not available
offline now stand with the kind and the lock at the top right of the
cover; the bottom right only holds the ring while a download runs. The
Details pill, the ring and the shuffle button wear the same tone as the
marks, the pill's fill over a dark shade.

**Show tiles carry their marks in the same column.** On the podcast show
tiles, the lock, not available offline and the number of episodes stand
at the top right, one under the other; before, the offline mark stood at
the top left and the lock at the bottom right. The number keeps its red.
The Pinchflat mark stays at the bottom left, on the same disc as the
other marks.

**Albums, playlists and stations follow.** Album tiles, the playlist
card and station tiles carry their kind in a mixed row, not available
offline, downloaded and the favourite star in the same column at the top
right; before, the kind and the star stood at the top left. The play
button of a station sits on the same disc as the other marks. No tile
carries a mark at the top left any more.

**The music servers' note says what happens.** Under Settings, the note
below the music servers said that with both on only Subsonic is used.
With both on, the Music tab asks both servers and plays each title from
its own, and the note now says so.

**Drive mode writes minutes like the rest of the app.** Below an hour,
the running time and the time left in drive mode read "12 min", in German
"12 Min."; before, German showed the untranslated "12 min". From an hour
on, drive mode keeps its clock form "1:05 h", quicker to read in the car.

**Details with the symbol behind the word.** The Details pill on the
Continue Listening, episode, playlist and station cards reads "Details ⓘ"
now, the info symbol behind the word.

**A soft top edge on every page.** Pages opened from a tab (a full row,
an album, a show, a catalogue page) fade their content softly under the
top bar like the tab itself; before, they showed a hard milky band.

**Full pages fill their columns.** The pages behind Continue Listening,
Recently Added and Listen Again lay their tiles out in as many columns
as fit, each tile as wide as its column; before, every tile stood at a
fixed width with room on both sides.

**Today carries its date in the statistics.** The day labels under the
bars of the last 14 days count back from today, so today's bar always
shows its date; before, they counted from the oldest day and today's bar
had none.

**The listening history at the end of every tab.** Music and Audiobooks
show their Listening History as the last row of the tab, like Podcasts;
the tiles in the music deck and in the audiobook deck with a server are
gone. All three tabs share this one row, with the same clock symbol.

**A download keeps a track it cannot read.** When a finished download
holds a track whose first bytes cannot be read, the track keeps its name
and place and stays on the device; before, it counted as not audio and
the cleanup after the download deleted it. A file that is not audio is
still removed.

**A download that goes round in circles ends.** When a server states a
length and closes the connection early, the download started over again
and again for up to seven days without a word. After the third run that
ends at the same byte it now fails with "A track arrived incomplete",
and you can start it again. Music downloads from a Subsonic server are
held to the song's size too, when the server sends the original file:
a song that arrives shorter is not kept as finished.

**A second library keeps the first one's places.** With two audiobook
libraries on one Audiobookshelf server, loading the second one removed
the saved positions, speeds, jump backs and offline bookmarks of every
book in the first. The cleanup now runs only when the server has one
audiobook library.

**Catalogue rows share their titles evenly.** On a free catalogue's
page each title still stands once, but a title two rows hold now goes
to the shorter row instead of always the first, so later shelves no
longer shrink. Popular gives way to the shelves and fills its row from
the deeper titles it already has; nothing more is fetched.

## v3.5 (Build 55)

**Less work while you listen.** With iCloud or a Mär sync service, what
the app knows of the listening positions on your other devices now lives
in its database, one row per title, instead of one large block in the
settings. While a book or episode plays, each save writes only what
changed; with 22,000 titles a save takes about a quarter of the time on
the main thread it took before. Your choices, Mär playlists and listening
statistics travelling through iCloud are kept the same way, with a Mär
sync service the choices and playlists too, and changing a choice writes
only the moment of that choice instead of the moments of all of them.
After the update the app fetches the listening positions, choices and
playlists once from the start, and with iCloud also the statistics.

## v3.4 (Build 54)

**Drive mode keeps time.** In drive mode the progress bar and the
remaining time move while a book or episode plays, and a station shows
its running time; before, they stood still until something else changed
on the page.

**The widget keeps running past an hour.** While a book or episode plays,
the Continue Listening widget shows the right place minute by minute also
after the first hour; before, it stood at the place it had reached after
sixty minutes until the playback changed.

**A handed over podcast stays handed over.** When a podcast you
subscribed to on this device while Audiobookshelf could not be read turns
out to be on your Audiobookshelf server, its listening states go there and
the subscription here goes, now also when it was your only one; before,
it came back here after the next start, next to the one on the server.

**Air dates show their own day.** The date of an episode on an archive
series page is the day it aired everywhere; west of UTC it showed the day
before.

**Back from an author leads into the search.** An author, a series or the
authors, series or genres of your library opened from the search open
their page as before; going back now returns to the search with your
query and its results, also after opening a book from that page. Before,
back led to the start page and the search was gone.

**Covers use less memory.** Large covers are brought to their display size
before the app holds them, two at a time; while scrolling through covers
nobody has loaded before, the last ones may appear a moment later than
before. A cover whose tile has left the screen is no longer loaded for it.

**Retry looks the same.** The places that ask again after something
could not load now show the same Retry pill: the catalog and archive
pages, the shelves of the music library, the line that says the genres
could not be loaded, the library section in Audiobooks, the search, and
the page of an album or playlist whose tracks did not load. The pages for
offline, for no tracks, for an empty music list, for no music server on
this device and for a failed import show the same pill. One row keeps
its own button: a podcast that could not be followed shows Retry as a
button like the Sign in and Enter new link buttons it stands among.
Sentences no longer ask you to tap them; the pill stands beside them.
The one exception is the note at the player after a failed load, which
still says to tap play, because the play button is what tries again. In
English the button says Retry everywhere.

**An empty playlist's symbol grows with its cover.** On the page of a
server playlist without covers, the symbol takes its size from the cover,
like the placeholders of radio stations and books. On the card it stays
as before.

**Music servers keep their own spelling.** With two music servers, the
source label on albums writes a known server the way its project does,
for example gonic or LMS, and the add sheet uses the same names. Koel is
now named too.

**No server named that is not there.** Without a music server set up, the
add sheet says only that the entries fit into a Mär playlist, and the
footer of a Mär playlist page speaks of music from a server you add
instead of your server's music.

**An incomplete download no longer passes for a finished one.** When a
track of an Audiobookshelf book or podcast arrives with fewer bytes than
the server names for it, the download says it failed instead of keeping
the shorter file. A track that is already stored too short is fetched
again and plays from the server until then, so no part of it is skipped.
Without a connection the stored file stays and playback stops at that
track with the note that the download is unreadable and plays from the
server once you are online.

**A full iCloud space is named for playlists and choices too.** When your
playlists or your choices such as sort orders no longer fit into the
shared iCloud space, the sync history says so with the numbers and the
iCloud switch shows the orange line, as it already did for listening
progress and statistics. Before, iCloud refused these writes without a
word.

**TestFlight: the Measurements page shows more.** Each day also names the
time spent playing in the background, the data sent and received over
Wi-Fi and cellular, what was written to disk, the time the app hung and
how often it was ended, by reason, how long a launch took to its first
frame and a return to the app, and how much of the scrolling hitched.
The app's own measuring points now arrive there with their count and
duration, and each day names the ones that did not arrive, which either
did not run that day or were not kept. A day without a period and
without a number is no longer listed.

## v3.4 (Build 53)

**Listening History for books and music.** The Audiobooks tab and the
Music library now have a Listening History page: the books you finished
and the songs you played, newest first, in one continuous list. A song
counts once half of it or four minutes have played, and playing it again
moves it to the top. Tapping a row opens its book or the album of the
song, also for audiobooks and music from the free catalogs. The history
starts empty with this version and stays on this device.

**Your audiobook library opens through tiles.** With a server, the
Audiobooks tab shows a row of tiles for Series, Authors, Local Files and
Listening History, like the tiles in Music and Search. Series and Authors,
and Genres in Search, open a page with every group and its count, and a
group opens its books. A series page now holds every book of the series, also one whose
series name is written differently. Without a server, Local Files and
Listening History stand as rows on the tab.

**Lists of downloaded titles are called "Downloads".** The tiles, pages
and sections that list what is on this device, and the CarPlay tab, now
say "Downloads". The mark on a cover still says "Downloaded", and so does
the audiobook filter, because it names a state like "Finished".

**Tile titles keep their size.** The category tiles in Audiobooks, Music
and Search no longer shrink a long title: a title of several words takes
a second line, and where a single word does not fit beside the count, the
count moves under the title. At the largest standard text size, every
tile of a row shows its count under the title.

**Country codes on radio genre pages.** The line above the station lists
of a radio genre now shows the countries of your choice as short codes,
such as US, DE, at every text size, and VoiceOver reads the full names.
Before, a long country name was cut off at large text sizes. The country
picker still shows full names.

**A list that could not load says so.** When a server or catalog does not
answer, a page or list now says that it could not load and offers Retry,
instead of showing no results, no playlists or an artist without albums.
This covers the podcast directory search, radio drama charts, the albums
of an artist, regions in Radio, server playlists in the add sheet, further
pages of albums, and the server libraries in Settings. Retry is a small
pill; inside a list, the sentence looks like the empty line beside it, and
at large text sizes Retry stands under the sentence.

**Plain sentences instead of error codes.** Catalog pages no longer show
codes like URLError -1009 or HTTP 429. They say what happened: there is no
network, the source did not answer, the source is busy, the title is no
longer available there, or the answer could not be read. Subscribing on
your server and loading an episode say when the server refused the
request or has no podcast library, and Go to Artist says when the artist
is not on this server.

**An action the server refused is not shown as done.** Renaming or
deleting a playlist and removing a song from it, on the card and on the
page, now tell you when the server did not take it; a refused delete
keeps the page open. The favourite heart of an album changes when you tap
it and goes back if the server refuses. Mark as Finished for a book in the
player now works like on the book page, and a refusal says so there.
Before, these actions could look done when nothing had changed.

**Opening a title that cannot play leaves Up Next alone.** A tap on a
title that is not downloaded while you are offline, or an open whose
details never arrive, no longer empties the rest of the album or playlist
and no longer takes the title out of Up Next. A book page whose details
could not load now says so with Retry, instead of an empty description
and a download button that did nothing.

**Clearer words when adding to a playlist.** The add sheet now calls your
own lists "Mär playlists" and names your music server by its product, for
example Navidrome or Jellyfin, when it explains which entries can only go
into a Mär playlist. An empty playlist card shows its symbol in the middle
of the card instead of half cut off at its lower edge.

**All playback notices in one place.** Tapping the notice pill above the
mini player or in the full player opens a list of recent notices with
their title and time; the same list is in Settings under Notices. Routine
sync notes such as "Progress saved" now only go into that list. A notice
that stopped playback stays until you play again, and when progress
cannot be saved for a reason other than the network, the pill says so
once. In the full player the pill sits in free space and no longer covers
a button; where there is no room, the notice stands as a line under the
controls.

**A stream that stops says it is waiting.** When a radio stream or a
title stops delivering, the pill says "Waiting for the network" after
five seconds, and playback goes on by itself when data comes again.

**A broken download plays from the server.** When a downloaded file is
missing or cannot be read, the title continues from the server at the same
point and the pill says so, while the download is fetched again in the
background. Without a network, playback stops at that file with a note
saying the download is unreadable, instead of skipping ahead into the
next file without a word.

**Subscribing from a tile keeps your episodes.** When subscribing from a
show tile, a show page or a co-listened show does not work, for example
offline, the episodes you heard of that show keep their names and stay
playable, and a note says why the subscription failed. Before, they were
forgotten after such a tap.

**gpodder after switching accounts.** When your subscriptions move to
another account while gpodder is still signed in to the old one, Settings
now shows that gpodder is paused, with the choice to continue with this
account or to disconnect gpodder. Sync Now says the same instead of
"already synced".

**Damaged saved lists are kept aside.** When a stored list such as radio
favourites, your own stations, recent stations, recent searches or known
servers cannot be read, the next change keeps the old value aside and
starts a new list. Before, it was overwritten without a trace.

**Fewer wrong station logos.** Station logos from Wikidata now come only
from an entry for that radio station. Photos and logos of other stations,
clubs or companies that had matched by name are gone.

**Smaller fixes.** A server playlist without a duration shows its number
of songs instead of 0:00. An Internet Archive track listed with a length
like 16:31.09 no longer shows as 16 hours. A request from Shortcuts, a
quick action or a widget that finds no title now says so. A title a source
reports as removed says it is gone instead of offering Retry.

## v3.4 (Build 52)

**Next song works in a shuffled playlist.** With shuffle on, the title
keys in the player, the lock screen, your headphones and CarPlay now go
to the next song of the shuffled list, and the rest of the list keeps
playing after it. Before, the press found nothing to go to.

**A title that could not load plays again on the next tap.** When an
episode, book or song cannot load, for example with almost no signal,
playback now stops with a short note instead of staying silent, and the
next tap on play loads it again where you were. When the network comes
back, it is loaded again by itself, without starting. Before, it played
again only after the app was restarted.

**The player stays on screen between titles.** When one song ends and
the next begins, or you skip to the next title, the full player keeps
showing the title that played until the next one is ready, and then
changes to it. Before, it disappeared for a moment and came up again.

## v3.4 (Build 51)

**Mär Sync carries everything as soon as you sign in.** Your
subscriptions, known servers, choices, playlists, statistics and progress
move to the sync service the moment you sign in, and back to iCloud the
moment you sign out. Before, some of them waited for the next start of
the app.

**Server suggestions stay with their kind.** The address of your Mär
Sync service is no longer offered under the field for a media server,
and media servers are no longer offered under the Mär Sync field.

**Radio genres show their whole name.** The genre tiles in Radio now
look like the genre tiles in Search and Music. A long name first shrinks
a little and is shortened only where that is not enough; the Search tile
for audiobooks is now simply called "Audiobooks", so it fits. With the
largest text sizes, these tiles stand in one column.

**The widgets describe what they show.** In the widget gallery, Up Next
and Continue Listening no longer speak of podcasts or audiobooks only:
both show books, music and episodes.

**"Show again" without a Pinchflat server says so.** A hidden channel
that cannot come back because no Pinchflat server is set up now says
that, instead of claiming the server no longer lists it.

**Larger symbols in the Settings bar.** On smaller iPhones the round
buttons at the top of Settings show their symbols larger, and they grow
with your text size.

**Music says when this device has no server yet.** When Music is on but
the server's address and account are missing on this device, the Music
tab now says so and where to add them, instead of reporting an empty
library.

**Ready for Navidrome 0.64.** Navidrome 0.64 gives songs, playlists and,
in older libraries, albums new ids and no longer answers to the old
ones. Mär reads the version
your server reports and speaks to it in the ids it expects. After your
server's update, Mär moves what it keeps on this device to the new ids,
once: your queue, where you left off, your listening statistics, your
downloads, your playback speeds and your Mär playlists. If one of your
other devices has not been updated yet, syncing with it stays calm and
nothing appears twice.

**How to set up a server, right in the app.** The setup screen and Next
Steps now list every server Mär is tested with, Mär Sync included. Each one
has a short page: what it does, what it needs, what you enter in Mär,
and links to its documentation and its source code. The list stays
after you have connected a server, for when you want to change
something later.

**Playlists are music on the start page too.** A playlist you have
started no longer stands in Continue Listening. Like an album, it
appears in Listen Again and still picks up where you left off.

**Each radio stream once.** A station with several streams lists every
stream address once in its quality choice, in the player and on the
station page, including the stream that is shown, which was missing
from its own list before.

**Each catalog title once.** On the overview of a free catalog, a title
stands only in the first row that has it (Popular, New at LibriVox, the
shelves, the decades). A row with nothing of its own is left out.

**Switching the Mär Sync account pauses playback.** What plays is
recorded under the account you leave, then it pauses. A piece you had
just paused, whose position had not reached the service yet, is
recorded there too.

**A refused mark says why, on the tile too.** When the server refuses
to mark a book as finished from the menu of its cover, the tile now
shows the same sentence as the book page.

**Podcasts deleted on Audiobookshelf go away.** Shows the server no
longer has are removed from Mär, instead of staying because the server
answered "not found" for them.

**The source map reads cleanly at every text size.** The line under
each area and under Mär Sync starts where the title starts, also at the
largest text sizes, where it used to run under the symbol.

**The indent on the Rows page grows with your text.** The switches of a
group stay indented under the group's title, and the indent now grows
with your text size instead of staying fixed.

## v3.3 (Build 50)

**Mär now runs on iOS 18 and later.** iPhones that stay on iOS 18, such
as the iPhone XS, XS Max and XR, can now install Mär.

**"Mark as Played" works in an episode's last minute.** When an episode
or book counts as played because only its last minute or so is left, the
swipe, the menus and the button on its page now offer "Mark as Played":
it moves to the end and on to the next. Before, they offered "Mark as
Unplayed" there and sent the episode back to the beginning. "Mark as
Unplayed" appears once it has truly ended.

**"Next" brings back the song you left with "Back".** As in the Music
app: when "Back" goes to the song you played before, the song you left
waits at the front of Up Next, and "Next" plays it again. Two steps back
come forward again in turn. Books and podcasts are unchanged.

**The track buttons in the player work like your headphones.** For music,
the back and forward buttons and the swipe on the cover now go to the song
before and to Up Next, just as a headphone press does; before, they stopped
at the first and last song of an album. Books and podcasts still turn
chapters. VoiceOver names the buttons for what they do: "Previous track"
and "Next track" for music, chapters otherwise.

**Mär asks archive.org less.** A cover that the Internet Archive
answers with its own placeholder, and a book without a known length,
are remembered across sessions instead of for one, so scrolling past
the same shelves no longer asks the same questions again. And Mär asks
every outside service politely: at most four questions at once,
MusicBrainz at most one a second, Wikidata one after the other, and a
service that says "not now" is left alone for as long as it asks. And
a tile that scrolls past no longer asks at all: a cover, a length or a
logo from the network is fetched only for a tile that stays on screen
for a moment. A cover that a service could not answer right now is
asked again later instead of being written off for the session. And
when Mär plays a stream, it introduces itself by its own name, the same
name it uses for every other request.

**A plus sign arrives as a plus sign.** A user name with a "+" in the
mail address can sign in at Koel and other PHP or Go servers, and a
search for a title with a "+" finds only that title; before, those
servers read the "+" as a space.

## v3.2 (Build 49)

**Play in an episode's last minute resumes there.** An episode this close
to its end counts as played (one minute by default, set per show), and the
Play button in its row and on its page started it over from the beginning
and set its position to zero on every device. It now resumes where it
stands; only a finished episode starts over, as before.

## v3.2 (Build 48)

**You can see which way your devices sync.** In Settings, Sync, iCloud
has its own switch. With a Mär sync service set up it stands off and
locked, with a line that says Mär Sync carries your data and how to switch
back; without one, it is the switch that turns syncing over iCloud on and
off. A locked switch now looks locked everywhere in the app.

**The first screen shows Mär Sync.** The map of your sources now has a
line for Mär Sync below the five areas: it says whether your devices are
connected through it, and a tap leads to its page. The map counts three
areas that need no account. "Start without a server" now stands at the
bottom edge of the first screen, so it is visible without scrolling on
every iPhone and at every text size.

**Your second device knows the Mär Sync address.** When you sign in to
Mär Sync, your other devices that still sync through iCloud offer its
address under the address field, like the addresses of your other
servers. Only the address travels, never the password.

**A paid feed that keeps refusing you says so.** When the server has
refused a podcast feed three times in a row over at least a day, the show
tells you the subscription may have ended or the link is no longer valid,
and its tile carries a warning lock. Your episodes and listening positions
stay. Enter new link takes the new address from your subscription and
carries your positions and downloads over; a feed with a login offers
Sign in instead. The button in Not followed yet is now also called Enter
new link.

**A refused paid show offers its free feed.** If the free feed of the show
is known, because you had it before or an import skipped it, or if the
podcast directory finds it once by the show's title, the show asks whether
to switch. Yes follows the free feed and carries your listening positions
and downloads over; the paid link stays on this device for later. No keeps
the notice. Nothing switches on its own.

**Mär Sync notices a connection that went quiet.** When the network
changes, or the live connection to Mär Sync stops answering while you
listen, Mär opens a new one and fetches what your other devices changed
meanwhile, without waiting for the app to come back to the foreground.
On a network that lets nothing through it tries less and less often.

**With music, a double press on your AirPods plays the next song.** For
music, and for songs from the free catalogues, the lock screen and Control
Center now show next and previous instead of jumping by seconds, like the
Music app. Previous within the first three seconds of a song goes to the
song you heard before it, also across albums; later it goes to the start of
the song. Audiobooks, including those from the free catalogues, and
podcasts keep their jumps.

**Gutenberg audiobooks show their own rights.** Tiles no longer carry a
"Public domain" capsule for the whole source: the recordings state their
rights one by one, and some are copyrighted and freely distributed. A
title's page shows what its record says. The Gutenberg page now also has
a row with every title, so readings without a genre can be found.

**Paid feeds follow on your next device.** A paid feed whose link was
renewed kept sending its old link to your other devices, which then could
not follow it. The old link is now withdrawn when the new one takes over.
Signing in to Mär Sync, or credentials arriving from another device, now
tries every refused feed once more. A feed whose link is refused says
"access refused" instead of asking for a login it does not have, and offers
to paste a new link.

**Almost finished counts as played.** An episode or a book within a minute
of its end now counts as played, so credits and outros no longer leave it
in Continue Listening with "0 min left". Choose the margin (off, 30 s, 1,
2 or 5 min) for all shows and books, for one show in its settings, or for
one book on its page. Your position stays where it is, so the last minute
can still be heard, and servers hear "finished" at the real end as before.
A remaining time under a minute now reads "1 min left".

**Project Gutenberg's audiobooks are indexed on this device.** The
catalogue file ends its lines differently from what the reader expected,
so the whole file read as one line and no Gutenberg collection was ever
kept; every start fetched it again for nothing. The collection now builds
on the first start on Wi-Fi, and an interrupted run continues from what it
already holds instead of fetching it again. A catalogue file that holds no
audiobook is read a second time and then fetched anew, instead of holding
the collection back for good.

**Gutenberg audiobooks play in full, from the collection on this device.**
The Gutenberg shelves and the Gutenberg row in Free Audiobooks now come
from the kept collection, without asking the catalogue service. A reading
in several files plays all of them, and resuming lands in the right file
at the right place; before, only one file of such a reading was known.
The first time you open a title, Mär reads its files and their lengths
once and keeps them. A title with a part whose length cannot be read says
so instead of playing from the wrong place.

**"Load full history" now really shows on a show you are only browsing.**
Build 47 said so, but the button only appeared on shows you follow. The
older episodes stay on the page for your visit; nothing is stored.

**The listening history shows its titles again.** Episodes heard on
another device were written down before their show was known here, and
their titles never followed; they now fill in from your shows without
listening again. An episode that can no longer be found says "Title
unknown" instead of an empty line, and an entry that showed "56 years
ago" shows its date where it can be read, and no date where it cannot.

**An episode published ahead of time shows when it comes out.** Instead of
"in 8 hours" it says "today 09:05" or "tomorrow 09:05", further out the
date with the time. It stays listed and playable.

## v3.2 (Build 47)

**A show keeps all its episodes.** "Keep only latest" is gone: it cut a
show down to its newest episodes on every refresh, including the one you
were listening to, so Continue Listening lost it. A show that was cut gets
back what its feed still carries with the next refresh, and the older
episodes with "Load full history".

**Finished automatic downloads go after a day** instead of a week.
Episodes you downloaded yourself are still never touched.

**Automatic downloads keep as many episodes as you choose.** Keep
downloaded sets 1, 3, 5 or 10 per show or for all shows; for a news show
1 keeps only the newest. Over the number, the episode farthest from where
you listen goes first, never one you have begun or the one in the player.
The direction, Newest episodes or In order, now follows you to your other
devices; whether automatic downloads run and how many they keep stay with
each device.

**"Load full history" works on a show you are only browsing.** The older
episodes stay on the page for your visit and play from there; nothing is
subscribed or stored.

## v3.2 (Build 46)

**Downloads of a hidden library can still be deleted by kind.** Each kind
of download is deleted in its own settings page, and that page is gone
while its library is turned off. Settings, General, Storage now offers the
deletion for such a kind as long as it still holds downloads.

**Music search narrowed to one server no longer says "No matches" too
early.** The line now waits until the search has finished, like the one
for the whole library.

**An open show page follows your other devices.** When another device
changes a show's sort, filter, speed, notifications, new-episode setting
or episode limit, the show page and its settings show the new value right
away, without closing and opening them again.

## v3.2 (Build 45)

**Positions and speeds of music and catalog titles are kept.** Whenever
the audiobook library finished loading, Mär tidied up the settings of
audiobooks that were gone, and it removed the listening positions and
playback speeds of Subsonic, Jellyfin, Jamendo and LibriVox titles along
with them. It now removes only what belongs to an audiobook that is no
longer in the library.

**Mark All as Played and Mark All as Unplayed are quick again.** With many
listening positions on the device, for example after importing a large
library, marking a whole show held the app for several seconds. It now
takes a moment.

**Many listening positions no longer slow the app down.** Mär now keeps
your listening positions in memory and in its own database, instead of
looking each one up again in the app settings. With tens of thousands of
positions, the playback updates and the Home, Music and Statistics pages
no longer copy the whole store each time.

## v3.2 (Build 44)

**Importing a large podcast library no longer stalls on old feeds.** A
feed that does not answer used to hold the import for about a minute
before the next one started. The import now asks four feeds at a time and
moves on after a few seconds of silence. Feeds that did not answer are
listed by name at the end and wait under Not followed yet on the Podcasts
tab, where you can try each again.

**A long import shows where it is, and keeps what it did.** The import
now shows which show it is at, of how many. Your listening progress for a
show is taken over as soon as that show is subscribed, not only at the
very end, so an import that stops halfway keeps it. Running the import
again does not load the shows it already added. If you leave Mär while it
runs and the system pauses it, the import says where it stopped, and
starting it again continues from there. A library with tens of thousands
of listening states no longer freezes the app for minutes while they are
matched.

**Importing from Apple Podcasts keeps your latest progress.** The guide
now starts with quitting Podcasts on your Mac. While Podcasts is open, its
newest listening progress is not yet in the file you copy, so it went
missing from the import.

**Error messages in plain words.** When something fails, the app no longer
shows texts like "The operation couldn't be completed" followed by a type
name and a number. It says what happened, for example that there is no
internet connection, or that something went wrong and you can try again.

**Load full history only where it can work.** With the podcast directory
switched off in your sources, a show's page still offered "Load full
history" and then said no additional episodes were found, without having
asked. The button now appears only when the directory is on.

**A show's sort and filter follow you.** Oldest first or newest first, and
only unplayed episodes, chosen on one show's page, now reach your other
devices like the show's other settings, including what you chose before
this update.

**No more "RSSProvider error 404".** When another device played an older
podcast episode, this device showed that message without you touching
anything, because it had not loaded the episode yet. It now fetches the
episode, so taking over playback works. If an episode really cannot be found, you are told so in
plain words, and only when you tried to play it.

## v3.2 (Build 43)

**Your devices stop sending feed logins back and forth.** With the Mär
sync service, two devices kept sending each other the same private feed
logins many times a second, even when nothing had changed. A device now
sends its logins only when they differ from what already stands for it.

**Search says when a list could not be loaded.** When your music server or
the podcast directory does not answer, the artists, playlists and genre
shows in search now say so, instead of showing an empty page that looked
like there was nothing, and Try Again asks once more.

**Searching the catalog no longer shows a blank page.** On iOS 27, tapping
"Search the catalog" below your library results left the search page
empty. The catalog now appears as it should.

**Download with a long press.** The download arrows are gone from rows,
cards and the album and episode pages, where they read like a state. To
download or delete, press and hold the cover of an album, a playlist, an
audiobook or an episode, or a server playlist card. A download in progress still
shows its ring, and the audiobook page keeps its Save Offline button.

**One clear mark for what is on your device.** Everything you downloaded
now carries the same mark, on tiles, cards, rows and detail pages alike:
white on a dark disc, readable on any cover, never a grey glyph that fades
into the page. It grows with your text size only as far as the cover under
it can carry it.

**Music search can stay on one server.** With two music servers connected,
searching in Music shows a row under the scopes: All, and each server by
its name. Choosing a server keeps only the hits that live on it; the name
tag on each row stays. If that server has nothing, the search says so
instead of jumping to the catalog.

**Changing the sync password asks for the current one in the same place.**
While you set a new password for the Mär sync service, the field for the
password in force moves into that section, above the new one and its
repetition, instead of waiting at the top of the page. At large text sizes
every sign in field shows its name above it, where it used to shrink to a
few unreadable points inside the field.

**Podcast settings for all shows at once.** The Podcasts settings now start
with three values every show follows: whether new episodes appear in New
Episodes, automatic downloads, and how many episodes to keep. A show can
still choose its own, and its settings offer "As for all shows" to go back.
Below the three values you see every show with its own settings and what it
does differently. Changing a value for all shows first tells you which shows
have their own, and lets you overwrite them or leave them; when keeping
fewer episodes would remove some, it says how many. Nothing changes until
you choose something.

**A show's settings open from its episodes too.** Every episode page now
carries the same slider button as its show, and it opens that show's
settings. The sheet is simply called Settings and names the show in its
first row, with cover and title, so a long name is never cut off at large
text sizes.

**Deleting downloads of one kind lives with that kind.** The Audiobooks,
Podcasts and Music settings each end with their storage: how much of that
kind is on the device, and the button that deletes it. General still shows
the sizes of every kind as an overview, and there it only offers to delete
all downloads at once.

**Album pages show how often each song was played.** Instead of a "Your
most played" list above the songs, every song now carries up to three bars
beside its length: three for the songs you play most on that album, fewer
for the ones you play less, none for songs you never played. An EP no
longer shows its songs twice. The bars need play counts from your server;
without them there are none.

**A song from a downloaded album plays offline everywhere.** A song you
added to a Mär playlist is the same song as in its album, but offline the
app only knew the album as downloaded: the song in the playlist counted as
missing and did not play. Now a song that lies on the device as part of a
downloaded album or playlist from the same server plays offline from any
list, and the playlist shows it as downloaded.

**The song list is in order, with one server or two.** With Navidrome and
Jellyfin both connected, the Songs page mixed a sorted list with an
unsorted one, because a Subsonic server cannot sort all its songs. Mär now
loads a Subsonic server's songs once, sorts them on the device and later
only adds what is new, while Jellyfin sorts on the server, by the song's
name and no longer by disc and track number. The page has the
same sort button as the albums: name, artist, recently added, recently
played and most played, across both servers. A line says when the song
list was last complete, and a list that cannot be loaded says why instead
of showing no songs.

**Statistics name what they count.** "Most listened" showed internal keys
for shows you no longer follow and for stations that had dropped out of
"Listen Again". Shows now take their name from everything the app
remembers, including what you listened to while browsing, and stations
from the stations you played most. Where no name is known, the row says
"Unknown Show" or "Unknown Station". The time always sits on the right,
and anything under a minute stays out of the lists instead of showing
"0 min". With the largest text sizes the name takes the whole line and
the time stands below it on the right.

**"In order" continues where you are.** Automatic downloads set to "In
order (from the start)" fetched the first episodes that carried no mark in
the app. Someone who listened to the first hundred episodes elsewhere got
episode one again. They now start after the latest episode you finished or
began, and an episode you skipped on the way is not fetched back. Trying
the newest episode for a moment, or hearing a single special far ahead,
does not move that place: it follows where your run of episodes is. Opening a
show's settings also no longer rewrites them: it moved the cutoff of
"Newest episodes" to the moment you looked. The show's copyable report now
names the download direction this device uses, which is set per device.

**A source that is on no longer gets told it is off.** If you left a source
switched on but turned off the tab it feeds, testing the connection answered
"the switch above is off" about a switch that was on. Whether a source is
live depends on two things at once, its own switch and the area it serves,
and the message named only one of them. It now names the one that actually
holds, and says so plainly when the switch is on and no area is. The same
correction applies to re-admitting a hidden Pinchflat channel.

**A Jellyfin audiobook is an audiobook.** The app decided "music" for
everything that came from Jellyfin, so an audiobook from there behaved like
an album: the headphone buttons changed tracks instead of skipping, the
player offered the music tools, the cover placeholder was a note, and the
player's link to its source opened a music album page. It now reads what
kind of item it is. A Jellyfin audiobook skips like a book, gets the spoken
word tools and the book placeholder, and counts as an audiobook download.
Jellyfin music stays music.

**A sync service older than the app is said, once.** When the Mär sync
service had not been updated yet, the app asked it again at every occasion,
got the same refusal each time, and the settings page said nothing. It now
recognises the older service, stops asking, and the sync page says that the
service is older than the app and that syncing resumes once it is updated.
Coming back to the app, signing in again, or the next start asks once more.

**Sync recovers after a dropped connection.** When the connection to the Mär
sync service broke in the middle of a request, every request after it failed
until the session expired, because the app and the service no longer agreed
on the encrypted session. The app now starts a fresh session after any
interrupted request, so only that one request is lost and the next one
goes through.

**A catalogue that was interrupted continues.** Project Gutenberg's
catalogue arrives in several pieces, and until now they were kept only in
memory: when the app was put away or quit before the last piece, all of it
was gone and the next visit started from nothing, silently. Every piece is
now kept on the device as it arrives, so an interrupted run, an app update in
between included, continues where it stopped. The catalogue runs also start
when the app opens, one after the other and only on Wi-Fi, for every
collection whose source is switched on, so a collection is ready the first
time you open it. Project Gutenberg's catalogue is fetched on the first run
and then once a month, no longer every day.

**Two music servers at once.** With Jellyfin and a Subsonic server such as
Navidrome both connected, the Music tab asks both and mixes their lists. A
genre both servers know appears once. Album tiles, the Continue card, song,
artist and playlist rows, the queue, search and CarPlay carry the server's
name in a small capsule, the name the server reports for itself. Artists,
playlists, lyrics and chapters are asked of the server the item comes from.
If one server fails, the tab names it and still shows the other. A server
playlist only takes songs from its own server: songs from both go to a
playlist on the device, and a new playlist asks on which server it should
live.

**Nextcloud Music signs in with its API key.** A Subsonic server that refuses
the usual token sign-in and offers an API key now gets the key, negotiated
once and remembered for that server. The key only travels over https: over
plain http the app keeps the token and says why a key server cannot be
reached that way, and it follows no redirect to an unencrypted address.
Every other Subsonic server signs in as before.

**Mär Sync has one password, and a way to change it.** Signing in follows the
service's contract version 6: your password stays on the device, and only a
proof worked out from it is sent. The Sync page has a section for a new
password, typed twice, where iOS offers a strong one. A new password needs
at least twelve characters and cannot be the current one. If the operator
of the service gave you a one-time password, signing in opens that section
by itself, and the one-time password is sent once to set your own. The key
for your private feeds comes from your own password alone, stays on this
device and leaves when you sign out. A device whose sign-in ended because
the password changed elsewhere says so. Right after signing in, a device
waits until it has seen the other devices' feed credentials before it
shares its own. The usernames and passwords of private and paid feeds are
now sealed with a key that comes from your account password, the same on
every device you sign in on, so the device code on the Sync page is gone:
there is nothing to copy from one device to another any more.

**Downloaded looks the same everywhere.** A downloaded title shows the filled
arrow in a circle everywhere it is marked, and the checkmark only means
played. Tapping a downloaded album's symbol no longer deletes it: long
press it, or a song row, to delete. VoiceOver says Downloaded and offers the
delete action by name.

**Downloads are deleted by kind.** Settings, General, Storage deletes
audiobook, podcast or music downloads separately, each with its own
question, and "Delete All Downloads" is the last row there. The audiobook
tab no longer deletes everything at once. A download remembers the kind it
was loaded as; older music downloads follow their source when it only
serves music.

**Downloaded albums and playlists open offline.** A downloaded album or
playlist shows its songs from the download when there is no connection and
asks the server once there is one. An album that is not downloaded says it
is not available offline, and an error speaks a sentence, never a technical
name. Playlist cards carry the offline and downloaded marks like every
other tile. An empty answer from the server no longer replaces a downloaded
song list.

**Songs from a music server play from the queue.** A song from Jellyfin or a
Subsonic server plays from the queue even when the app has not listed it
since it started, and an entry that cannot play here says why. A song you finished
starts from the beginning again when the server knows nothing about it. The
large player closes when nothing is left in it, instead of spinning.
Chapters, song titles and lyrics work with both kinds of server, and lyrics
come from the song's own server.

**A show keeps its order and its pictures.** The sort order you choose for a
show stays, also after you subscribe from its page. An episode without its
own image shows the show's, also when PodcastIndex sends an empty one, and
a show whose image moved no longer brings the old one back. Loading a show's
whole history says when it failed instead of reporting no episodes.

**An Audiobookshelf episode knows its show again.** Episodes from an
Audiobookshelf server show the show badge, the link to the show and the
premium lock again.

**Catalogues and sources say what went wrong.** Jamendo's genre shelves say
when they could not be loaded instead of missing without a word. After a
failed catalogue request the app waits ten minutes before asking again on
its own; tapping retry, opening a title and starting playback always ask
right away. A catalogue page offers import only where there is a book to
import. Choosing a library to import from always leads somewhere: one
without a folder, or one that cannot be reached, says so. A Subsonic source
that serves no kind of media says that too. The German text for "This
could not be loaded" was missing and is there now.

**Smaller things.** The large title sits in the bar at the height of the
settings gear on every tab. Home updates when the content of a row changes,
not only its length, and the queue notices a new order. A title without
artwork shows the placeholder of its kind everywhere, including the queue,
catalogue rows, the full player and Drive mode. A running download redraws
only its own cover and controls instead of the whole page. The "With
Downloads" filter of the podcast pages updates as soon as a download
finishes.

## v3.1 (Build 41)

**A music source that is switched off now says so.** Testing a Jellyfin or
Subsonic connection while the source's own switch was off answered "Enter
server, username and password", to people whose server, username and password
were all filled in. Each reason now has its own sentence, and the one you get
is the one that holds: the address, the account, or the switch above them.

**The source list reads cleanly at every text size.** On the external sources
page the line explaining what a source feeds could run into its switch,
depending on the device and the text size. The explanation now belongs to the
switch's own label, so it can never reach into it.

**The big title is back on every tab, and it stays.** Switching between tabs
made the large heading disappear, and once it was gone it never came back,
leaving the top of the page blank. It stands on every tab again, however
often you switch.

**The audiobooks tab is called the same everywhere.** Its button said
"Audiobooks" and the heading above it said "Library", which is also the name
of the mixed search scope that holds books, shows and music together. The
heading now says what the button says. In CarPlay "Library" stays: there it
is the root of everything on offer, and that is what it means.

**Your music tiles are the same six everywhere, and "Downloaded" is one of
them.** The music tab and the search page now show the same entries in the
same order: artists, albums, songs, playlists, genres and what is on the
device. The search page never offered downloads before, and both surfaces
carried a single free Archive shelf, Classical on 78s, as an extra tile,
one shelf out of ten and not the largest. All ten shelves stay where they
belong, one tap away under "Old Records" on the music tab.

**The top edge of a scrolled page looks the way we chose.** The band at the
top of a scrolling list is now declared by the app instead of inherited from
whatever the system happens to default to, and it fades out softly instead of
ending in a hard line under the status bar.

## v3.1 (Build 39)

**A plain http server is reachable wherever it stands, and the plain http
notice says what is really open.** iOS lets the app talk plain http to
private addresses such as your home network, but refused a mesh address or
a public name without a certificate before a byte left the device, for
every server kind, not only the sync service; the app then said "The
service did not answer", though the service was never asked. The app now
declares to iOS that it may use plain http (the media exception it carried
made that declaration void when placed beside it, so it stands alone), the
sign-in and the test button name that refusal by its own sentence should it
ever return, and the notice under a plain http sync address says what is
open on the wire since the sealed session: the first fetch of the service's
key and the reachability check, not your token.

**The sync switch reaches the feed passwords at once, and "Show again"
tells you why a channel stayed hidden.** Turning sync on after the app
started now also starts the carrier of the feed passwords, and turning it
off stops it, like the other six. Re-admitting a hidden Pinchflat channel
now checks that this channel really rejoined the group; if the server no
longer lists it, or the source is off, or the server is away, the channel
stays in the hidden list and the page says which, and a second tap during
a pass does nothing.

**Feed passwords travel over exactly one way.** With a Mär sync service set
up, the passwords of private podcast feeds used to go to the service AND to
Apple's iCloud keychain. Now they take one way: the service when you are
signed in, else the iCloud keychain when sync is on. Signing in rewrites
the passwords this device holds as local items, signing out brings them
back to the iCloud keychain, and flipping the sync switch moves them the
same way. A move never loses a password: the new place is written before
the old one is cleared.

**Your podcast subscriptions say the same thing everywhere.** A device
with a gpodder server used to ignore subscription changes made on your
other devices, so unsubscribing on the iPad left the feed on gpodder and
on the iPhone. Now every device applies the family's changes, and the one
with the server hands them on to gpodder in both directions: unsubscribe
or subscribe anywhere, and gpodder and every device follow. Nothing is
lost on the way: an unsubscribe removes the feed, your listening positions
stay on the device and on the server, and subscribing again finds them.

**Four small corrections.** Re-admitting a hidden Pinchflat channel now
waits for the mirror: if the source is off or the server away, the channel
stays in the hidden list and the page says why, instead of vanishing
without ever joining the group. Recently played stations keep their order
when the lists of two devices merge. A write the sync service refused
while the Mär Sync page is open shows up on the page at once, not after
your next change there. A push for a sync zone you switched off no longer
wakes every other carrier.

**Your listening statistics are never cut on this device.** When the
statistics travelled over iCloud's key-value store, or fell back to it
because the account went away for a while, the app trimmed the per-title
pot on this device to the 500 titles that fit the shared megabyte. The
trim now applies only to what travels; the file on the device keeps every
title.

**The "playing on your other device" line goes away when that device
stops.** The mini player kept showing the other device's title after it
had gone silent (crash, dead zone, app killed) until something else
redrew the bar. The runner now ages the hint itself, so it disappears
within one poll after the claim runs out.

**Subscribing to a show you browsed clears the browsed copy, whichever
address it came under.** A show browsed under a plain `http://` address or
with tracking bits in its link and then subscribed kept a second copy of
its episodes beside the subscription, and on an Audiobookshelf podcast
server the copy was never cleared at all. The rows page now also reads
each row's switch from the stored setting every time instead of from a
snapshot taken when the page opened.

**The Mär Sync page reads the truth after every step, and says "your
devices use iCloud" only when that is so.** After signing out, a runner
that still holds the service until the next start now shows as exactly
that, instead of as iCloud; the line about a write the service refused
belongs to the sign-in it happened under and leaves with it; and the page
reads the service's state again after each sign-in and sign-out instead of
only when it opened.

**The Mär Sync page keeps up with itself.** The device link code appears
the moment you sign in and leaves when you sign out, the feed-credentials
runner starts with the sign-in instead of waiting for the next app start,
the standing of your credentials on the page follows every round of the
runner, and a "the service's key has changed" notice belongs to the address
it came from: typing another address takes it down.

**The Next Steps card no longer sends you to the login form when you are
already signed in.** Its Audiobookshelf row now leads to the source page
with your server's address and the log-out button, exactly as the same
row in the settings does.

**A feed password that could not be saved no longer counts as your newest
one.** When the keychain was locked, a password arriving from another
device was booked with its newer moment even though the write had failed,
and from then on the old password won every comparison. The moment is now
booked only for a write that landed, and a device that cannot read its own
credentials does not adopt anything.

**Your podcast feed credentials now really travel over your Mär sync
service.** The runner that seals them, puts them up and reads the other
devices' blocks was built and shown on the Mär Sync page, but nothing ever
started it: no device put a block up, none read one, and the page showed a
link code that carried nothing. It now starts with the other sync runners
when a service is set up and the sync switch is on.

**When your listening data would not fit into iCloud's shared space, the
app says so before it tries.** The key-value store holds one megabyte for
everything and refuses a write that does not fit without a word; until now
the app learned of it only afterwards, if at all. Now the size is reckoned
before every write of the progress pot and the statistics pot, beside what
the store already holds, and a pot that does not fit is refused out loud:
the orange line at the sync switch and a line in the sync history with the
numbers. Nothing is written half.

**A busy or blocking host no longer counts as "there is none" anywhere.**
One rule now says what a refused answer means, and every place that
remembers a "no" reads it: the cover for a song on the radio and an
artist's portrait are remembered as missing only when the host said so,
not after a rate limit or a block, and the picture of a podcast feed
likewise. The gpodder settings say that the server rejected the login
instead of showing a bare number, and the radio catalog stops asking the
next mirror once the service has asked for a pause.

**A radio station no longer loses its logo for two weeks because a host was
busy.** When the logo chain asked a host and got a refusal (a rate limit, a
block on this network), the answer counted as "this station has no logo"
and was booked for fourteen days. Only a real "not there" is booked now; a
refusal or a server error leaves nothing behind, and the next appearance
asks again.

**A Jellyfin audiobook made of several files reads at the right place on
your other device even after a hiccup.** When the app moved to another file
of such a book, it also wrote the neighbouring files (played, or back at the
start) and booked them as done before it knew whether each write landed. A
neighbour that failed stayed wrong until the track moved again, and the
other device could open the book in the middle of a file already heard. The
neighbours are now booked as done only when every write landed; otherwise
the next write tries them again, and the failure leaves a line in the log.

**A listening position no longer slips past gpodder.** Two small holes in
the push to a gpodder server: a real-time push that failed still blocked
the next one for eight seconds, and a position written while a batch was on
its way could fall between the batch and its bookmark and never be sent. A
failed push now frees the window and leaves a line in the log, and the
bookmark moves to the moment the batch was gathered, so such a position
goes out with the next one.

**The Mär Sync page now says when the service has refused this device's
token.** Until now the page read "signed in" off the keychain while every
sync round had stopped on the refusal, and nothing said so. The page names
it, in orange, and signing in again clears it.

**A listening position written while the previous one was still on its way
to iCloud no longer gets lost.** With the CloudKit carrier, a second write
that landed while the first was being sent could be wiped from the queue as
if it had been sent, or overtaken by the older write and overwritten in the
cloud; the app showed the newer position and your other device never got
it. Writes now go out one after the other, and only what was actually sent
leaves the queue.

**Everything between the app and your sync service now travels sealed, with
or without a certificate.** Until now a service reached over plain http, the
usual case for a self-hosted one on a home network or a mesh, carried your
sign-in token in the clear on every request, and anyone on the same network
could read it and act as you. The app now opens an encrypted session with the
service it holds the key of (see below) and sends every request inside it:
the sign-in with your password, every read and write of your listening
positions, playlists, choices and feed credentials, and the socket that says
something changed. Nobody between your phone and your server reads a byte
of it. A service restart or an hour of silence ends a session; the app opens
a new one by itself and retries, and you never see a sentence about it. Your
service needs contract version 5 for this; older devices keep working in the
clear until the operator turns the plain ways off.

**Your device now remembers your sync service's key, and a changed key is
something you see, not something that just happens.** When you sign in, the
app fetches the service's key first and holds on to it, on this device only:
it is not in your iCloud keychain and it does not move to another device,
because a phone restored from a different phone's backup has not met
anything yet. From then on, a service that offers a
different key stops the sign-in before your password goes anywhere, and the
page shows both fingerprints side by side with the two honest reasons a key
changes (a move to another machine, a restore from backup) and the one
dishonest one. You accept the new key or keep the old one; nothing is sent
until you do. The key this device holds is shown on the page so you can
compare it with what the service prints about itself. A service that has no
key yet, or that is older than this app, says so in words instead of "did not
answer".

**Move your audiobooks to a different library on your server and the shelf
follows.** The app noticed that the library had changed, but it only ever
asked whether a source still serves books, never which library it serves them
out of. Since the answer to that stayed yes, nothing happened: the shelf kept
showing the titles of the old library, and tapping one reached a server that
no longer knew them. A source now says what it is serving from, so the shelf
rebuilds when that moves and stays quiet when it does not.

**A position you listened to offline now reaches the server it belongs to.**
If a book comes from a second source (a Jellyfin library, a Subsonic server
you set to audiobooks) and the app could not send its position right away, the
position was kept and then offered to your main library server, which has
never heard of that book. It either bounced forever or landed in the wrong
place. Each waiting position now goes to the server that owns it, and the
check for "somebody else got further" asks that same server.

**With two music servers set up, the second one's albums and playlists behave
like the first one's.** Until now the app asked which music source this device
uses and then put that question to a title from the other one. A Jellyfin
album under Continue got the plain card instead of its own, its covers stayed
empty, the shuffle button found no songs, its downloads were missing from the
downloaded page, and adding it to a playlist answered "Nothing to add". A
title says in its id where it comes from, and every surface asks it that way
now.

**The usernames and passwords of your private and paid feeds can travel over
your own sync service instead of Apple's keychain.** They are sealed on the
device before they leave it, with a code that never goes anywhere near the
service, so the server carries something it cannot read. Settings, Mär Sync
shows the code once you are signed in: copy it into your password manager and
enter it on your second device. Two sentences stand beside it rather than
behind it, because both are true before you rely on it. A screenshot of the
code goes into iCloud Photos, which is the very route these credentials are
leaving. And if your last device is gone, the credentials are gone with it:
nobody else holds the code, and that is the point of it.

**A song is only remembered as having no lyrics when somebody said so.** The
lyrics cache keeps a no for sixty days, and every way of ending up without
lyrics counted as one: the open lyrics service refusing a series of questions,
or the device simply being offline. A song looked at once in airplane mode
stayed without lyrics for two months. Now only an answer counts as an answer.
And turning the online lookup on takes effect right away: a no written while
it was off was an answer about your server alone, so it no longer stands in
the way of asking the open service.

**Changing a feed password takes effect again.** With syncing on, the password
of a private or paid feed lives in the iCloud keychain. Setting a new one wrote
nothing at all: Mär cleared the old entry only on this device, the entry in the
iCloud keychain survived that, and the write that followed was turned down as a
duplicate. Nothing said so, so the feed kept failing with the old password.
Turning syncing off and setting a password again also left the old entry in the
iCloud keychain, where the person had just asked for the opposite. Both are
fixed, and a write that fails now leaves a line in the log instead of silence.

**Jellyfin and Subsonic tell a refusal from a dead network.** A server of your
own that only answers inside your network refuses a device outside it, and Mär
made two different wrong things of that: for Jellyfin it said the sign-in
failed and to check username and password, which sends you to change a password
that is correct, and at two other doors it said the server could not be reached.
For Subsonic every answer except a rejected sign-in became "cannot reach the
server", so a server that answered with an error of its own looked like a dead
network. Both now say that the server is not reachable from this network, and
any other answer arrives with its HTTP number instead of a guess.

**A title that fails to open no longer becomes the standby on every device.**
Tapping play tells your other devices right away which title you took over,
before it is loaded, so they can stand down without waiting. If the load then
failed, nothing took that back: every device showed a title on standby that
never played, and this device showed the error. The message is withdrawn now,
and the title you really played last is the one that stands again.

**The Mär sync page says what actually carries, not what is set up.** Setting
the service up while the app runs used to be confirmed with "what is set up
here is in use", although every kind of data kept travelling the old way until
the next cold start: the carriers are chosen once, when the app starts. The
page now says "from the next app start" until that has happened, and "in use"
only when it is.

**The Mär sync page says whether syncing is on at all.** You could sign in to
your own service, read "Signed in as", and nothing would travel, because the
one switch that covers every way across devices sits on another page and was
off. The page now names that switch and its state in both cases, and says
where it lives.

**The Mär sync page tells a refusal apart from silence.** Testing the address
of a service that only answers inside your own network said "The service did
not answer", although it had answered, with a refusal. That sentence points at
the service, where the thing to look at is the network, and it cost hours once.
The test button now says the same as signing in does: the service is not
reachable from this network.

## v3.0 (Build 37), TestFlight

### Since Build 36

**Turning every source off asks first.** The one tap on the sources page
wrote eleven switches at once, and there is no collective way back: each
source is turned on again by itself. It now names how many sources it is
about to switch off and waits for a second, deliberate tap, the way
deleting all downloads and emptying the cache already do. A source whose
switch the page cannot show, PodcastIndex without a key of its own, is no
longer part of it either; an OFF nobody could see would have surfaced
weeks later, when a key is entered, with nothing in sight explaining it.

**Listening positions save again after a connection drops mid-write.** If the
connection broke while a write was on its way, the sync service could keep the
half that had arrived. Every device reading that document afterwards could
make nothing of it, kept naming the version it had read last, and the service
kept turning the write down for naming a version that had moved. The result
was a device that saved no listening position at all, for hours, with nothing
on screen to say so. The service now refuses a write that ended early or that
it cannot read back, so a broken half never replaces what is held, and a
device that meets a document it cannot read carries on instead of asking for
that same document forever.

## v3.0 (Build 36), TestFlight

### Since Build 35

**A playlist you make on one device reaches the other one.** When both
devices wrote at nearly the same moment, the service asked the second one to
read what is there, merge it and write again. Mär did that for listening
positions, statistics and settings, but for playlists it only tried again
when that re-read happened to bring something new. If another part of the
app had already picked the change up, no second attempt was made and the
list was gone without a message. Every one of these documents now merges and
writes again after such a refusal, whether or not the re-read finds
something new.

**Settings and radio favourites arrive while both apps are open.** With the
sync service they used to show up only after the app was started again: the
service tells the app about a change through a connection that a while in
the background closes, and nothing opened it again until the next start. The
service now answers the same two occasions the iCloud families already do,
so a sort order or a radio favourite lands on the other device while you
watch.

## v3.0 (Build 35), TestFlight

### Since Build 34

**Statistics, playlists and choices arrive while both apps are open.**
Until now these three reached the other device only at its next cold
start; the podcast positions already arrived on their own. Now every
family listens the way the positions do: when the app comes back to the
front, and when iCloud says that a zone changed. A playlist you make or
change here also sets off by itself right away instead of at the next
start.

**A dead spot no longer rewinds you.** When the connection came back
after a gap, the app could take the server's copy of its own last write
(from up to thirty seconds earlier) for another device's play and jump
back by that much. The check now knows what it wrote and what it still
owes the server, and only a genuinely foreign play moves the position.
The log says what the check saw.

**The mini player says one thing at a time.** Under a song it now shows
the artist and the remaining time instead of repeating the title. And
while another device plays and this one stands by, the bar shows what
plays there in the title line with the device underneath, instead of the
standby title with the hint squeezed below it; the standby title returns
when the other device stops.

## v3.0 (Build 34), TestFlight

### Since Build 33

**A sync service of your own.** Under Settings, Sync, Mär can be pointed
at a Mär sync service you host yourself. Signing in trades the password
for a token the device keeps; the password is not stored. From the next
start, podcast progress, the playback claim (which device is playing),
the listening statistics, your Mär playlists and your choices (sorts,
favorites, stations, searches, subscriptions and the like) travel over
that service instead of iCloud, and the service tells the other device
about a change instead of waiting to be asked. A write the service
refuses is shown on the page with the service's own sentence. Without a
service set up nothing changes.

**Listening statistics travel whole.** The statistics now go through
iCloud's database, one record per device, like the podcast progress
already does, and over your own Mär sync service when one is set up.
Nothing is cut on either way: the shared key-value space used to force
the per-title list to its five hundred longest and let only radio time
travel, now every title keeps its time. That space stays only as the
fallback without an iCloud account and as the reader for a device on an
older build. And days are no longer folded into months after two years
on any way; a day costs a few bytes. Months already folded by an
earlier build stay as they are.

**Playlists travel through iCloud's database too.** Your Mär playlists
now sync as one record per list through iCloud's database, like the
podcast progress and the statistics, instead of the shared key-value
space, and over your own Mär sync service when one is set up. Nothing
changes about the lists themselves; the shared space stays only as the
fallback without an iCloud account and as the reader for a device on an
older build.

**Your choices travel through iCloud's database too.** Sorts, favorites,
stations, searches, subscriptions and the other choices that follow you
between devices now sync as one record per choice through iCloud's
database, like the podcast progress, the statistics and the playlists,
instead of the shared key-value space, and over your own Mär sync service
when one is set up. Nothing changes about the choices themselves; the
shared space stays only as the fallback without an iCloud account and as
the reader for a device on an older build.

**Jellyfin works with the new server version.** Jellyfin 12 turned off
the older ways apps used to identify their requests, and Mär relied on
them, so on a version 12 server signing in still looked fine while
browsing, playing and cover art quietly stopped. Mär now identifies
every request the way version 12 expects, both in the request header for
browsing and in the link the stream and cover art travel on, a form
older Jellyfin servers accept too, so both keep working.

**A Jellyfin audiobook in several files is one book.** Jellyfin 12 lists
every file of an audiobook folder as its own entry, and Mär showed a
three-file book as three books with three positions. The files of one
folder that carry the same album tag are now one book, in track order,
with one position that carries across files, restarts and your other
device. Files with different tags, or without one, stay separate books,
so a folder that holds several single-file books keeps them apart, and
a book that is one file stays exactly as it was.

**Moved documents stay out of your backup.** When a document has been
moved into the database, the copy Mär keeps aside for one more release
no longer travels with every iCloud or computer backup. Nothing is
deleted; the copy leaves with the release after this one.

**A recommendation says which of your shows it came from.** When a
suggestion arrives because it shares a publisher with something you
follow, it now says "From the same publisher as" and names that show,
instead of naming the publisher alone. Where the show behind it is not
known, the older wording stays.

**An album page asks the server the album is from.** With a Subsonic and
a Jellyfin library set up at once, opening a Jellyfin album from the
player asked Subsonic about it: no tracks, no star, no album details.
The page now asks whichever server the album came from. With a single
music library nothing changes.

**A download that cannot even start says so.** Six places fetched a
title's details and then began the download, and every one of them gave
up in silence when the fetch failed: the button did nothing and said
nothing. The failure now shows on the item like any other download
failure. Two of the six also asked the wrong source for the details,
which is what made the fetch fail for titles from another library.

**Imported audio files are no longer offered a download.** They are on
your device already, so there is nothing to fetch. The entry appeared
after the last build stopped offering to delete a download they never
had, and it would have failed anyway. Sources that cannot hand out a
file, the free catalogs and radio among them, no longer offer one
either.

**Unsubscribing with iCloud sync switched off is remembered.** The
unsubscribe took effect on the device, but nothing recorded it for the
other one. Turning the sync back on let the older statement win, and the
show came back. Such an unsubscribe is now kept and said as soon as the
sync runs again. Subscribing to the same show again while the sync is
off still wins, because it is the newer of the two.

**Shows whose feed dates the app could not read are back in the podcasts
tab.** Some feeds write their dates in a form Mär did not read, and every
episode of such a show ended up without a date. The tab sorts by date, so
the show never appeared there while standing in your subscription list
with all its episodes. Three more date forms are read now, including the
one Dublin Core feeds use.

**An import counts feeds without episodes instead of naming one.**
Importing many subscriptions at once showed a message about the last
feed that brought nothing, and said nothing about the others. The import
summary now counts them alongside the other numbers of that run.

**A feed with no episodes says so when you subscribe.** Some feeds are
valid but carry nothing yet. Such a show was added to your subscriptions
and then stayed invisible in the podcasts tab, with no way to find out
why. You now hear it at the moment you subscribe. The subscription still
happens, because the feed may carry episodes tomorrow.

**Unsubscribing removes the show everywhere, whichever way you do it.**
Swiping a show away in the podcast settings, and removing a premium
feed, only ended the RSS half: a copy of the same show on your
Audiobookshelf server stayed active and kept standing in the podcasts
tab, while the settings list said the show was gone. All ways to
unsubscribe now do the same thing.

**Downloading a server podcast episode works from the Continue card and
the episode button.** Both asked your RSS subscriptions for an episode
that lives on your Audiobookshelf server, found nothing, and stopped
without a word. They now ask whichever source the episode actually comes
from. Episodes from RSS feeds were never affected.

**Album downloads and shuffle work on a Jellyfin music library.** On an
album page those two asked your Subsonic server by name, even when
Jellyfin was your music source. Downloading an album handed the wrong
server to the download, and shuffling an album asked a server that did
not know it. Both now ask whichever music source you actually use.
Nothing changes for Subsonic libraries.

**Imported audio files no longer offer to delete a download they never
had.** A book you imported from your own files showed "Delete Download"
in its menu and on its page. Tapping it did nothing at all, and said
nothing either, because there was no download to remove. The entry is
gone for imported files; your files were never at risk, and downloads
you really made are deleted as before.

**Recommendations no longer favour the shows you imported.** A show that
lives both in your subscriptions and on your server counted twice
towards your taste, and that hit exactly the shows that came from an
import or from gpodder, because those are the ones that get mirrored to
the server. Each show now counts once, and it keeps its full listening
time. Switching a source off still does not make Mär forget what you
heard there.

**A private mirror stays out of the public catalog search.** A mirrored
feed was meant to be excluded from what your recommendations are built
from. Once it had been copied to your server, the copy slipped past that
exclusion. It no longer does.

**Switching the server off as a podcast source now switches it off
everywhere.** Its shows kept standing in the podcast tab and kept being
picked to continue with, while CarPlay and the background refresh had
already dropped them. All four ask the same question in the same place
now. Nothing changes if you leave the source on.

**VoiceOver can tell the playlist card's buttons apart again.** The card,
its details pill and its shuffle corner all announced the same name, so
there was no way to say which one you were on. Each control carries its
own name again.

**Shows you hear without following them count towards your
recommendations.** Listening a show through says something about your
taste, so it now lifts its publisher and its topics, at half the weight
of a show you follow and only from the second episode on. It still does
not follow anything: nothing appears in your subscriptions, and nothing
is synced, exported, notified or downloaded because of it. Hidden shows
stay out entirely.

**Search puts the best hit first.** Results used to stand in the order
their source happened to send them. Now a hit that opens the title
comes before one that carries the word somewhere in the middle, a whole
word before a part of one, the title before the author line, and
something you already have or are listening to before a catalog find.
The sections you know stay; the one with the best hit leads. One
mistyped or swapped letter is forgiven, and never at the cost of a hit
that matches exactly.

**Stations you entered by hand are on both devices.** They travel like
your radio favourites now, one statement each, and deleting one removes
it on the other device too. The stream you picked for a station travels
with it.

**Turning on new episode notifications counts on both devices.** The
switch is your choice and travels; the permission belongs to each
device. A device that has not been asked yet asks the first time you
open Podcasts, and a device where you said no to iOS says so under the
switch instead of turning it off for both.

**Positions arrive sooner while both apps are open.** iCloud now tells
the other device that something changed instead of waiting for its next
look. The look itself is unchanged and stays the promise: while a device
plays, it checks every ten seconds, whatever the notification does.

**Your devices are set up the same way.** What you choose now holds on
both devices: skip intervals and speed, light or dark, which tabs,
sources and rows you want, what the app may look up online, and the
podcast behaviour switches. Premium feeds are part of the shared
subscription list by default. What stays with each device is named:
the iCloud switch itself, the cellular warning, drive mode, the sleep
timer, the tab you left open, and what is missing on that device. Switch the iCloud sync off and nothing travels at all.

**Two devices stop passing the same positions back and forth.** A
finished episode of a show you unfollowed left the shared pot to save
room, but the other device, where you still follow that show, wrote it
straight back. In the roomier CloudKit pot nothing is dropped for that
reason any more; the old key-value pot keeps the rule, because there
room really is scarce.

**Playlists say "Mär" instead of "on your devices".** A Mär playlist
travels between your devices, so the old capsule said the wrong thing.
The two worlds are now named the same way everywhere: a Mär playlist
mixes everything and travels; a server playlist holds your server's
music and is seen by every client of that server. Server lists carry no
capsule.

**The progress bar follows the song.** With music the bar spans the song
that plays, with its own elapsed and remaining time, and dragging moves
inside the song, as every music player does. Audiobooks, readings and
podcasts keep the bar over the whole work.

**A tap on the handle closes the full player.** The bar at the top could
only be pulled, and its tap area was a few points high. It now closes on
a tap as well, from the same closing move the pull uses.

**Counters in the sync history say "1 position", not "1 positions".**
Every counter of the history has singular and plural forms now, in
English and German.

**What plays stays first in Continue.** The running title's position is
written every thirty seconds, so a position arriving from the other
device in between looked newer and pushed it down the row. What plays is
now the newest thing there is, and its card says "Playing now" instead
of a relative time that counted up while you listened. The audiobooks
tab and the start page also ask the same question about a title now, so
they can no longer name two different times for it.

**The mini player shows the station's logo.** It asked the station's
favicon alone, so a station whose tile carried its logo showed the plain
radio symbol below. It now asks the same picture the full player does.

**A station logo that stopped loading is decided again.** A stored logo
whose address no longer serves was only re-decided on one of the two
paths. Both paths now count the failure, and after the second one the
chain looks for a new logo. An icon file the system can read is read:
the door tries a second decoder before it gives up.

**Test entries leave your account.** A station from the test harness
("Seed Radio Two") could reach a real account and stand among your own
stations. Such an entry never travels now, is never taken over, and one
still in iCloud is removed from both devices.

**An author in search opens that author's books.** Tapping an author or
a series hit did nothing visible: it opened a level that is only drawn
when the search field is empty. It now opens the same page the books tab
opens, and it finds the books even when the field writes the name the
other way round or names several people at once.

**Light and dark hold in every sheet.** Settings, the next steps card,
the player's panels, the import and every other sheet stayed with the
system appearance while the rest of the app followed your choice. Each
of them is a presentation of its own, and each now carries the same
choice. Drive mode stays dark on purpose.

**Co-listened shows get their own row.** Every show you heard through
without subscribing, within the last sixty days, stands in a row
"Co-listened" on the podcasts tab, the most recently heard first, with
the same tile, capsule and menu as Latest Episodes. The old limit of
ten shows and thirty days is gone; the window is the only limit. The
row writes one log line that says how many shows it holds and why the
others fell out, so an empty row can be read.

**A netlabel album page shows its tracks.** The page read only the
chapter list a server album states; a catalogue release carries its
songs as audio tracks and states no chapters, so the page stayed on
"Loading" although the answer had arrived. It now lists one row per
track, and an answer without any track ends in "No tracks" with Try
Again instead of a spinner. The metadata log line names its path and
how many files the answer carried.

**Play on the other device's episode opens that episode, never its
neighbour.** When the mini player showed "Playing on iPad" and this
device did not yet know that episode (its feed was not refreshed
here), Play started the newest episode it did know, one next to the
right one. Now the tap fetches the show's feed once and opens exactly
the claimed episode at the other device's stand; a twin of the show
under another address counts as the same episode; and an episode this
device still cannot name is said on the bar instead of replaced. The
mirror that follows the other device's pointer takes no neighbour any
more either; only the restore at start may still fall back to a show's
newest episode when the last one left a rotating feed.

## v2.9.1 (Build 33), TestFlight

Build 32 was never uploaded; everything below is new since Build 31.

### Since Build 31

**Listening positions move to iCloud's roomier store.** The positions of
podcasts, catalog works and sideloads now live as one record each in
your private CloudKit database instead of one shared key-value entry,
which had room for about five thousand. The first start folds your
existing positions in once; a device on an older build keeps writing
the old entry and is still heard. Without an iCloud account everything
runs as before, and as long as the cloud refuses the records (a schema
not yet published, a full quota) the old entry stays the pot for every
device and the log says why.

**A takeover reaches a locked device within ten seconds.** While this
device plays, it looks for the other device's play every ten seconds
instead of thirty; the position sync and the heartbeat keep their pace.
Underneath, the listening positions now travel through a carrier with
iCloud's key-value store as the first one, so a roomier store can follow.

**Starting an episode you never opened no longer wipes the other
device's position.** A play start on a device that had no position of
its own wrote an "unplayed" mark into the shared pot and so erased the
stand the other device had just pushed. The play start now only takes
positions in; only a deliberate mark sends one out.

**Pocket Casts import asks for the episodes its listing does not name.**
A listening state whose episode is missing from the show's public listing
(the feed moved hosts, was rebuilt, or is private) used to stay
unplaceable. The import now asks Pocket Casts for that episode alone, up
to three hundred per import, and places the state through the same
ladder as before. The preview says per show how many states this gained;
a refusal ends the asking and the import goes on without it.

**A Booksonic book resumes on your other device.** The playing device
writes its position into the server's own bookmarks, and the other
device starts there, even for a book it never opened. Every write and
every read leaves a log line.

**Pictures pass one door.** Every cover the app shows, colours, stores
or sweeps now goes through a single place. Before, nine files fetched
and decoded covers on their own, each with its own retry. Nothing changes
on screen; the fence keeps it that way. The cover sweep log line now
names how many covers it found and how long it took.

**One list of remembered picture answers.** Podcast channel pictures and
radio logos used to keep separate lists of what was found and what was
not. They now share one list behind the same door, with one rule for how
long an answer counts. Your stored answers move over on first start;
nothing is looked up again that was already known.

**Groundwork for other sync paths.** The "playing on another device"
signal now travels through a carrier with iCloud as the first one, so a
self-hosted sync service can join later. Nothing changes in how the
takeover works today.

**Continue listening follows a takeover sooner.** When another device
starts a book from your server, this device refreshes its stands once
right away and once more fifteen seconds later, so the row catches the
stand the other device pushed after the first look.

**Airsonic Advanced says why a sign-in fails.** An account whose password
is stored in a form the token sign-in cannot use now gets a clear message
instead of a generic error. Mär never sends the password in clear text.

### Please try
- Start the build once: no take-over of your data runs again, and every
  cover you saw on Build 31 is still there (books, podcasts, music, radio,
  lock screen, widget, CarPlay).
- With both devices on the same iCloud account: the log shows the
  positions folding into CloudKit once, and a position heard on one
  device reaches the other within ten seconds while it plays.
- On the iPad, listen to an episode the iPhone never opened, then start
  it on the iPhone within a minute: it starts where the iPad stopped, and
  the iPad keeps its position.
- On the other device, start a book from your server: Continue on this
  device shows it, at the latest after the second refresh a few seconds
  later.
- Radio logos and podcast channel pictures known on Build 31 appear at
  once, without a new lookup.
- Import from Pocket Casts: the preview names per show how many states
  were placed by asking for single episodes.
- Everything from the Build 31 list that was not tried yet.

## v2.9.1 (Build 31), TestFlight

**Your listening data now lives in a database.** Listening positions,
subscriptions with their episodes, the library cache, the listening log
and the statistics move from single documents into one database file on
the device. The first start on this build takes them over once (a few
seconds at most, the log says how many rows); afterwards every change
writes only the rows it touched, so a large podcast library no longer
rewrites everything on each refresh. The old documents stay beside the
database as `.migrated` files. Going back to Build 30 would only restore
the state of that moment; everything heard on 31 stays in the database.

### Since Build 30
- **Available areas are ticked on the next steps card.** Radio, the free
  catalogs and podcasts without a sync server are ready at once, so their
  tick is there from the first start; only an area that still needs a
  server stays open.
- **One sentence about the Pocket Casts password.** The import guide and
  the sign-in sheet show the same line: your email and password go to
  Pocket Casts only and are not stored; nothing runs in the background.
- **No dashes in app text.** Every sentence that used a dash as a joint
  is rebuilt with a full stop, a colon or a comma, in English and German;
  chapter and station subtitles use a middle dot. A fence keeps it so.
- **Catalog albums say why they could not load.** The album page and the
  catalog detail page name the measured reason (a status, a transport
  error) next to Try Again. A cancelled fetch, which happens when a row is
  recomputed under a card, is not a failure any more and asks again the
  next time the page or card appears. Every archive.org metadata fetch
  writes one log line with status, bytes, duration and reason.
- **Sync History stops filling with empty iCloud entries.** A pass that
  only took the other device's heartbeat in wrote an entry every ten
  seconds; now an entry appears only when positions were taken in or
  actually pushed.
- **"Add to Playlist" once per menu.** The catalog track row showed the
  entry twice; a fence keeps every menu at one.
- **Music lives in "Listen Again", never in "Continue".** An album used to
  flip between the two rows as its position travelled. Albums and songs,
  from your server or the free catalogs, now stand in Listen Again with
  or without a position, sorted by the last listening; playing one still
  resumes where you were. Books, podcasts and readings stay in Continue.
  A music playlist in progress keeps its continue card.
- **A playlist changed on two devices becomes one list, not a copy.** An
  entry added here and an entry added there both land in the list; a
  removal travels as a mark per entry, so a removed title does not come
  back from the other device, and adding it again later works. Copies
  named "Copy of …" are no longer created for that; the ones you have can
  be deleted.
- **One playlist row.** Server playlists and the lists on your devices
  share one row, newest change first, with the same card; the device lists
  carry the capsule "On your devices", and the "+" card stands once at the
  end. A device list from before the cover snapshots fills its mosaic when
  it appears.
- **Co-listened shows: capsule beside the show badge, hiding acts at once.**
  On the Latest Episodes page the capsule no longer covers the small show
  cover, and "Don't show this show" removes the show from that page
  without a tab switch.
- **Continue ranks episodes by the moment the card shows.** The row used to
  rank an episode by its local stand while the card named the newer server
  stand, so an episode heard eight minutes ago on the other device could
  sit behind one heard three hours ago.
- **A book the other device plays reaches Continue within seconds.** When
  the other device claims a library book or a server podcast episode, this
  device refreshes its progress from the server once per claimed title
  (and then at most once a minute), so the rows follow without a trip to
  the background and back.
- **Listen Again: recently played stations travel, and every tile has a
  grip.** The stations you played on one device stand in Listen Again on
  the other too, newest first. A long press on a station or a catalog
  title offers "Remove from Listen Again"; the removal travels, so the
  tile does not return from the other device, and the position of a
  catalog title stays.
- **The music library as tiles.** Artists, Albums, Songs, Playlists,
  Genres and Downloaded appear on the Music tab as the same tiles the
  search page shows, with a count where it is known: artists and albums
  from the loaded library, playlists including the lists on your devices,
  downloaded music; the old 78s shelf entry joins when its area is on.
- **Two installation guides point at the right address again**
  (Audiobookshelf moved its docs host, oPodSync moved its repository).

### Please try
- Start the build once and check that subscriptions, episode lists,
  listening positions, the listening log, statistics and your playlists
  are all still there.
- On the other device, start a book: it should appear in Continue on this
  device within a minute without leaving the app.
- Add a title to the same playlist on both devices: one list, no copy.
- A title removed from a playlist before this build may come back once;
  remove it again and it stays gone.
- Music albums stand in Listen Again only, never in Continue.

## v2.9.1 (Build 30), TestFlight

### Since Build 29
- **A book or a song starts and stays while the other device plays
  something else.** The standby mirror used to swap a session that was
  still waiting for the server against the other device's pointer, so a
  book never started while the iPad played a podcast. A session this
  device opened itself is its own from the first moment. Podcasts
  unchanged.
- **Log lines never carry a server address with credentials.** The cover
  trace names host and path only; feed addresses in the log are masked.
- **Next steps after the first start.** Once a server is connected or you
  start without one, a card shows what else you can attach and how to
  bring your listening history from Apple Podcasts, Overcast, AntennaPod,
  Pocket Casts or any OPML export, step by step with the other app's own
  menu names and with what each source carries. Connected areas are
  ticked, and where an area still needs a server, the projects' own
  installation guides are one tap away. The card returns at every start
  until you dismiss it; afterwards it lives under Settings, Next Steps.

### Please try
- Start a book or a song while the other device plays something else: it
  plays and stays. Podcasts unchanged.

## v2.9.1 (Build 29), TestFlight

Build 28 was never uploaded; everything since Build 27 ships here.

### Since Build 27
- **Shows you listen to without subscribing appear under Latest Episodes.**
  When you play an episode of a show to the end without subscribing, the
  show's newest episode joins Latest Episodes on Home and in the Podcasts
  tab for thirty days, marked "Not subscribed". A long press offers the
  subscription or takes the show out of the row. Nothing about this reaches
  your subscription list, gpodder, OPML exports, notifications or
  automatic downloads; the shows live on this device only.
- **Music skips shorter.** A song jumps ten seconds by default, a book or
  an episode still thirty. The width you pick in the player is remembered
  for music and for the spoken word separately, so a song never resets
  your audiobook habit. The lock screen follows.
- **Sleep timer: one clock for all three modes.** Minutes, end of chapter and
  end of track now share one tick; a paused player no longer rewrites the
  remaining time every second.
- **Every network request goes through one door.** Feeds, covers, catalog
  dumps, stream checks and server calls now share one place that sets the
  app's identity, raises plain http to https where it must, retries by one
  policy and logs every failure with its reason (the host, never a URL).
  A swallowed network error in the networking code is now counted and may
  only become rarer.
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
- Playlists travel with their titles and say why an entry cannot play here.
- The mini player names the device that plays.
- Songs skip ten seconds, books and episodes thirty.
- Play an episode of a show you do not subscribe to the end: its newest
  episode appears under Latest Episodes, marked "Not subscribed".
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
