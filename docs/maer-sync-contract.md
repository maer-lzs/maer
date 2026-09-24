# The contract between Mär and the Mär sync service

**Version: 6**

The app and the service live in two repositories now. This file is what keeps
them meaning the same thing, and it exists in BOTH of them, byte for byte.

## What this file is, and what it is not

It is the wire: the paths, the headers, the kinds and the answers. It is not a
description of what the service does with them, and it is not a description of
what the app puts inside a document. **The service understands nothing about
the content**, on purpose: it carries bytes, holds versions, and refuses what
it cannot read as a document.

**Each side has a fence that reads this file and holds the local code against
it.** Neither fence can see the other repository, and it would be dishonest to
pretend otherwise. What the two fences buy is this: a change to the wire that
touches only one side goes red at the first run on that side, instead of going
quiet until a device stops syncing. Whoever changes the wire changes this file
in both repositories and bumps the version in both.

<!-- maer-sync-contract
version: 6
paths: /v1/health /v1/token /v1/doc /v1/docs /v1/changes /v2/key /v1/session /v1/salt /v1/password
headers: Authorization X-Maer-Format If-Match X-Maer-Declared-Shrink ETag X-Maer-Session X-Maer-Contract X-Maer-Refusal Retry-After
kinds: stands claim stats playlists choices feedauth
status: 200 400 401 404 405 409 410 412 413 426 428 429 503
-->

## The paths

| path | what it is |
| --- | --- |
| `/v1/health` | is anything there. Answers a status and nothing else |
| `/v1/token` | trades owner and a sign-in proof for a bearer token (below, version 6) |
| `/v1/doc/<kind>?scope=<scope>` | one document: `GET` reads, `PUT` writes |
| `/v1/docs/<kind>` | the listing of a kind: which scopes exist, at which version |
| `/v1/changes` | the socket that says a document moved |
| `/v2/key` | the service's static public key, so a device can pin it, and the contract version it speaks |
| `/v1/session` | without `X-Maer-Session`: trades a Noise handshake for an encrypted session. With it: carries one sealed request in that session |
| `/v1/salt?owner=<owner>` | the salt and the stretching an owner's password is derived with |
| `/v1/password` | sets a new password: the current credential proves who asks, the new one arrives only as a proof |

**`/v2/key` and `/v1/session` carry no token, and that is the pattern rather
than an omission.** The caller proves who it is INSIDE the session, which is
what lets a SIGN IN be protected: a sign in carries the account secret and
happens before there is any token to prove anything with. Version 3 is these
two paths and the header below; nothing about the five older ones changed.

**`/v2/key` is the trust on first use channel.** Over a plain connection
whoever sits in the middle can answer it with their own key. That is the
migration the operator chose: trust the first time, hold on afterwards, and
the holding is what turns a later swap into an EVENT instead of a silence.

## One secret (version 6)

**An owner has one secret, the password, and it never reaches the service in
any form a person could use.** Before version 6 the password travelled at
every sign in, inside the session but in the clear to the service's own
process, and a second code on the devices sealed the feed credentials. Version
6 derives both from the password ON THE DEVICE: one value signs in, the other
seals, and the service only ever sees the first.

**The derivation, byte for byte:**

    P      = the password, Unicode NFC, UTF-8, nothing trimmed
    S      = the owner's salt, 16 bytes, from /v1/salt
    M      = PBKDF2-HMAC-SHA256(P, S, rounds, 32 bytes)
    proof  = HKDF-SHA256(IKM = M, salt = none, info = "maer sign in v1", 32 bytes)
    feed   = HKDF-SHA256(IKM = M, salt = none, info = "maer feed auth v2", 32 bytes)

`rounds` is 600000 in version 6 and comes with the salt, so a later version
can raise it without a new wire. `proof` travels as standard base64 with
padding. **`feed` never leaves the device**; what the device seals with it is
the app's business, like every document format. The vectors in
`sign-in-v6.json` hold both sides to the same bytes; each side's fence reads
them.

**The service stores `proof` the way it stored the password before**, behind
its own stretching. A thief of the service's data can still guess passwords,
at the cost of both stretchings per guess; the running service learns nothing
it could open a sealed document with.

**The three sign-in paths speak only inside a session.** `/v1/salt`,
`/v1/token` and `/v1/password` answer a plain request with `426`, whatever
the plain ways switch says: they carry the only values that stand for a
person.

**`/v1/salt?owner=<owner>`** answers

    {"salt": "<base64, 16 bytes>", "kdf": "pbkdf2-hmac-sha256", "rounds": 600000, "form": "proof"}

for every owner name, known or not: for a name without an account the salt is
derived from the service's own secret and the name, the same on every
question, so the answer does not say who has an account. `"form": "secret"`
marks an account whose password the service already knows: one that has not
moved to version 6 yet, or one whose password the operator set (below). That
one answer does tell an account apart, for as long as it holds, and only
inside a session. **A device that reads `"form": "secret"` never signs in; it
changes the password** (`/v1/password` with `current.secret`), because a
password the service knows must never become `feed`.

**`/v1/token`** takes `{"owner", "proof", "device"}` and answers `{"token"}`,
or `401` for a wrong proof and an unknown owner alike; an account in form
`secret` answers a proof with `401` too. **A body with `secret` instead of
`proof` is refused with `401` for a moved account without being stretched,
compared or logged**. "Logged" means the password: the refusal itself is
logged like every refusal, without it. For an account whose password the
operator set it
answers `428`, and no token comes from that password; for an account that has
not moved it is the sign in of version 5, unchanged.

**`/v1/password`** takes

    {"owner": "<owner>", "device": "<device>",
     "current": {"proof": "<base64>"} or {"secret": "<a password the service knows>"},
     "new": {"proof": "<base64>", "salt": "<base64, 16 bytes>", "kdf": "pbkdf2-hmac-sha256", "rounds": 600000}}

and answers `{"token"}` for this device. `current` proves who asks: the proof
of the password in force, or, for an account in form `secret`, that password
itself (`secret`): the old password once per account, which is the move to
version 6, or the one the operator set. The device picks the new salt at
random. After it: the new proof is the only
one that signs in, **every other token of the owner is withdrawn**, the
earlier tokens of the asking device included (it holds only the one this
answer brings), and a
request with one of them answers `401` with `X-Maer-Refusal: password-changed`,
so the device can say why instead of asking as if nothing happened. A wrong
`current` is `401`, a `new` the service cannot read (salt not 16 bytes, rounds
below 600000, proof not 32 bytes) is `400`.

**Guessing has a limit.** Ten failed attempts on `/v1/token` and
`/v1/password` for one owner name from one address within fifteen minutes,
unknown names counted the same, and the next one is answered `429` with
`Retry-After: <seconds>`, before any stretching. The device says when to try
again; it does not retry by itself.

**What counts.** A failed attempt is a `401` on `/v1/token` or
`/v1/password`, whatever its reason. `400`, `413`, `428` and `429` are not
attempts. A token, or the `428` for a password the operator set, clears the
count for that owner and address. The fifteen minutes run from the first
failed attempt; after the tenth the pair is held until they end. The count
may live in memory only, so a restart clears it.

**The service cannot see a password, so it cannot judge one.** The rule for a
new password, at least twelve characters, lives in every client, before the
derivation; a client built from this file must hold it.

**The move of an existing account is a password CHANGE, never a keeping.**
Every password in use before version 6 has reached the service; none of them
may ever become `feed`. So the move signs in with the old password once more
(`current.secret`) and sets a new one in the same request. The device checks
that they differ; the service cannot.

**`/v1/key` answers `404` in version 6, on purpose.** An app of version 5
asks it before every sign in and every session, and a `404` there stops it
BEFORE it sends a password: it says the service is older than itself (the
wrong sentence, and the only one it has) and stops syncing. That is the price
of the rule above: an app that still sent `secret` would send the new
password to the service the first time someone typed it there. **Every device
of an account is updated before the operator switches.**

**`/v2/key` carries `X-Maer-Contract: 6`.** A device that finds a version
higher than its own says so before it asks for a password.

## Inside a session (version 5)

**Every one of the five older ways can be spoken INSIDE a session, and then
nobody between the device and the service reads a byte of it: not the token,
not the path, not the document.** The device opens a handshake on
`/v1/session`, gets a name back in `X-Maer-Session`, and from then on sends
each request as ONE sealed message: `POST /v1/session` with `X-Maer-Session:
<name>` and the sealed frame as the body, `application/octet-stream`. The
service unseals it, runs it through the very same doors a plain request goes
through, and answers `200` with the sealed reply as the body. The statuses of
the inner request live INSIDE the reply, untouched; the outer status speaks
only about the session.

**The frame is the ordinary wire, whole.** Two bytes of length, big endian,
then a small JSON head, then the raw body:

    request head: {"method": "GET", "target": "/v1/doc/stands?scope=", "headers": {"Authorization": "Bearer <token>", ...}}
    reply head:   {"status": 200, "headers": {"ETag": "3", "X-Maer-Format": "1", ...}}

So the token rides in `Authorization` exactly as above, only sealed, and a
second client built from this file learns nothing twice. The body is bytes on
purpose: documents are the bulk, and base64 would make each a third larger.
`/v1/session` and `/v2/key` are not answered inside (a session does not nest,
and the key is what the session was made from); `/v1/health` is a question
about reach and stays outside.

**The sealing is the transport phase of `Noise_NK_25519_ChaChaPoly_SHA256`,
messages in order, one counter per direction.** A device therefore sends one
request at a time per session and waits for its reply; two in flight could
arrive in the other order and the second would not open. **The changes socket
wants a session of its own** for the same reason: a stream of announcements
interleaved with the replies of a request session would race its counter. On
that socket the upgrade request carries `X-Maer-Session` instead of
`Authorization`, the FIRST frame the device sends is a sealed request head
carrying its `Authorization`, and every announcement afterwards comes back as
sealed bytes of the same JSON text. Close codes: `4410` no such session,
`4401` the first frame carried no valid token, `4400` the first frame was not
sealed, `4426` plain sockets are off (below).

**A session ends, and that is not an error.** It ends after an hour without a
message, after a day in any case, after a minute if it never carried a request
that proved who was asking, and whenever the service restarts, because its keys
live in memory and nowhere else. The service says `410` on the session path,
and the device's answer is ONE new handshake and ONE retry of the request,
never a sentence to a person. A message that does not open under a live name
is `400`, and the session survives it.

**The plain ways stay on until the operator turns them off.** A device that
was not updated speaks in the clear, and it must keep syncing until it is.
`MAER_SYNC_PLAIN_WAYS=off` (default `on`) makes every plain request to the
five older ways answer `426` with a sentence, and a plain socket close with
`4426`; the three paths above it never sit behind that switch. **When to turn
it off is a decision about the devices in use, not about the code.**

A `kind` is a name, and the service checks its FORM, never a list of known
names. That is why a new kind needs no deployment: the feed credentials became
the sixth kind without the service learning a word about feeds.

## The headers

| header | direction | meaning |
| --- | --- | --- |
| `Authorization: Bearer <token>` | app to service | who is asking |
| `X-Maer-Format: <n>` | both ways | the format of the BODY, per kind |
| `If-Match: <etag>` | app to service | write only if the version still stands |
| `X-Maer-Declared-Shrink: 1` | app to service | "I meant to make it smaller" |
| `ETag: <version>` | service to app | the version this document now has |
| `X-Maer-Contract: <n>` | service to app | on `/v2/key`: the version of this file the service speaks |
| `X-Maer-Refusal: password-changed` | service to app | on a `401`: this token was withdrawn because the password changed |
| `Retry-After: <seconds>` | service to app | on a `429`: how long until the next attempt is taken |

**`ETag` is where `If-Match` gets its value, and version 1 of this file forgot
to say so.** The service sets it on every read and on every accepted write; the
app keeps it and sends it back as `If-Match` on the next write. The whole
version discipline rests on that one round trip, and the file described the
discipline while leaving out where the number comes from. A second client built
from this document alone, which is exactly the Android case, would not have
found it.

**The shrink header is the one that carries real weight.** Without it, a write
that makes a document smaller is refused, because the usual cause of a shrink
is a device that lost its state and is about to publish that loss. With it, the
caller says the shrink is the point (a claim released, a credential removed).

## The answers

| status | when |
| --- | --- |
| 200 | read or write went through |
| 400 | the request is not a request: bad scope, unreadable body |
| 401 | no token, or not this owner's |
| 404 | no such path, or no such document |
| 405 | the path exists and not for this method |
| 409 | the write shrank the document and did not say so |
| 410 | on `/v1/session` with a name: that session has ended; handshake again and retry once |
| 412 | `If-Match` named a version that has moved |
| 413 | the body is larger than the host accepts |
| 426 | the plain ways are off on this service; speak inside a session. On the three sign-in paths always |
| 428 | on `/v1/token` with `secret`: the operator set this password; it only changes itself on `/v1/password` |
| 429 | on `/v1/token` and `/v1/password`: too many failed attempts for this owner from this address; wait for `Retry-After` |
| 503 | this service has no static key, so it cannot answer a handshake |

**428 and 429 are the two of version 6, and both reach a person**: 428 as the
question for a new password, since nothing else happens with the password the
operator set, and 429 as the sentence that says when to try again.

**410 and 426 are the two of version 5, and neither reaches a person.** A 410
costs a device one handshake; a 426 tells a device that still speaks in the
clear where to go, and until every device has been updated the operator leaves
the plain ways on, so it is not answered at all.

**503 is the newest, and it was missing from this list while the service
already answered it.** That is worth saying rather than quietly adding,
because it is the shape of mistake this file exists against: the fence held
that every declared PATH exists in the service and the other way round, and
for statuses it held only one direction. A status the code answers and the
contract does not name stayed green. Version 4 is this line plus the fence
that would have caught it.

**And it is a status a person can act on**, which is why it must not arrive
as a bare number: it says the operator has not yet let the service make its
identity, and the answer carries that sentence.

**403 is not in the list above, and it needs two sentences rather than one.**
The service's own code never writes one, and the fence on the service side holds
that. But a 403 can still arrive, from two different places, and telling them
apart is the whole value of this paragraph:

- **On `/v1/changes`, a 403 means NOT AUTHORIZED.** The application closes an
  unauthorized socket before accepting it, and the ASGI server in front turns
  that pre-accept close into an HTTP 403 on the handshake. Measured on a real
  run: with a token the handshake answers `101 Switching Protocols`, without one
  `403`.
- **On any other path, a 403 comes from something IN FRONT of the service**, a
  proxy or a mesh refusing a device outside the tunnel, and the app reads it as
  "the service answered, but not from this network".

Reading the first case as the second would tell a person their network is wrong
when their token is. The first version of this file claimed the service simply
never sends a 403; the fence tore on the literal, and running the thing found
the rest.

**409 and 412 are not errors on the app side.** 412 means someone else wrote
first and the app merges and repeats; 409 means the app must say what it meant.
A carrier that treats them as failures loses data by giving up.

## What the socket says

`/v1/changes` carries one message shape and nothing else, as JSON text:

    {"kind": "<kind>", "scope": "<scope>", "version": "<etag>"}

It is sent to every socket of the owner after an accepted write, and it names
only WHERE something moved, never what. The receiver fetches.

**A message it cannot read is not an error.** The socket is an accelerator: a
client that fails to parse one simply misses a nudge and falls back to its own
polling, so the takeover gets slower and nothing breaks. That is a comfortable
failure and therefore a dangerous one, because nothing looks wrong. **It is the
reason this shape is written down here instead of living in two
implementations that happen to agree today.**

## The kinds in use

`stands` · `claim` · `stats` · `playlists` · `choices` · `feedauth`

Their formats are each side's business and travel in `X-Maer-Format`; the
service never reads them, it only hands them back.

## What is deliberately NOT in here

The media stream. It does not go through the service at all, and no sentence in
this file covers it.
