# Changelog

## Next build (not yet cut)

**A music source that is switched off now says so.** Testing a Jellyfin or
Subsonic connection while the source's own switch was off answered "Enter
server, username and password", to people whose server, username and password
were all filled in. Each reason now has its own sentence, and the one you get
is the one that holds: the address, the account, or the switch above them.

**The source list reads cleanly at every text size.** On the external sources
page the line explaining what a source feeds could run into its switch,
depending on the device and the text size. The explanation now belongs to the
switch's own label, so it can never reach into it.

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
