# Mär Sync Service

A small, self-hosted place for Mär's own data — listening stands, listening
statistics, Mär playlists, the choice family, and the playback claim.

**Optional, never required.** Mär works completely without it. It stands
beside iCloud and a WebDAV folder as a third way, and the user picks; it is
not a replacement and not a default.

**Status: core, shell, accounts, and the carrier in the app.** The netless
decision units, a SQLite store, a bare ASGI application, bearer-token
authentication and the backup with its rehearsal, all under test. The app
reaches it through `MaerSyncCarriers.swift` (the pot and the playback
claim). Nothing here has been run behind a live application server yet.

## Why it exists

Five kinds of data run over iCloud today, and only one of them (podcast
positions) is redundant with a media server. The other four are Mär's own
and no media server knows them. There is no server that all Mär users
have, iCloud blocks Android, and its one-megabyte key-value pot is about
eighty percent full.

The full reasoning, and the requirements this is built against, live in the
deliveries repo: `kontext/sync-dienst-anforderungen.md`. That document is
binding as a whole. What follows is only what this directory implements.

## What the core decides

Four units, pure and netless, each with its own tests. They exist as units
and not as lines inside request handlers because these are the decisions
that lose people's data when they are wrong.

- **`core/admission.py`** — may this state replace the stored one? Refuses
  an empty state over a full one, and a collapse below a floor, unless the
  client says it meant it. The known loss case is not a broken update; it
  is a device that writes an empty state at start-up before it has loaded.
- **`core/versions.py`** — which stored versions survive a write. Keeping
  the last N covers a broken update and a client that wrote nonsense with
  one construction, and it is what "restore yesterday" is built on.
- **`core/restore.py`** — did a rehearsed restore actually come back? Three
  outcomes, and the third is the point: a rehearsal that could not run is
  not a passing rehearsal.
- **`core/formats.py`** — the two version numbers that make a rollback
  safe, kept apart: the document format (the client's) and the store schema
  (the service's).

- **`core/writes.py`** — the three gates in an order, which is a decision
  of its own: precondition, then format, then size. A client behind the
  current version usually has a SMALLER state, so telling it "too small"
  before "read again" would send it to fix the wrong thing.
- **`core/paths.py`** — the shape of a kind and a scope, never the
  membership. A list of the five known kinds would make "add a sixth" a
  service update.

Every unit answers with a verdict that carries its sentence. A refusal that
does not say why would be the failure the gates are built to prevent.

## The shell

- **`service/store.py`** — SQLite, one row per version. The rotation IS the
  backup, and "restore yesterday" needs no second construction. The read,
  the decision and the insert happen inside one `BEGIN IMMEDIATE`, or the
  compare-and-set would be a story: two devices holding the same version
  would both be told they are current and the second would overwrite the
  first.
- **`service/app.py`** — a bare ASGI application. `GET`/`PUT`
  `/v1/doc/<kind>[?scope=]` with `ETag`/`If-Match`, a WebSocket at
  `/v1/changes` that announces every accepted write, and `/v1/health`.
- **`service/__main__.py`** — binds the application to an application
  server. Written, not yet run.

### The interface

| | |
|---|---|
| `GET /v1/doc/<kind>` | the bytes, with `ETag` and `X-Maer-Format` |
| `PUT /v1/doc/<kind>` | the bytes; needs `X-Maer-Format` and, for an existing document, `If-Match` |
| `412` | you are looking at an old version — read, merge, write again |
| `409` | refused, and the body says which gate refused it |
| `X-Maer-Declared-Shrink: 1` | "I meant to make it smaller" |
| `GET /v1/docs/<kind>` | the scopes that hold a document of that kind, each with its version and format; names only, never bodies |
| `GET /v1/changes` | WebSocket; a line per accepted write: kind, scope, version |

A write that names no version at all is a `412` too. Silence is not a claim
to be current, and the blind overwrite is precisely what iCloud cannot
refuse and this can.

## Accounts

Every path but `/v1/health` and `/v1/token` needs `Authorization: Bearer
<token>`, and the account the request acts on comes from the store's answer
to that token — never from anything the caller wrote.

    python3 -m service account the-owner     # secret on stdin, never in argv

`POST /v1/token` with `{"owner", "secret", "device"}` hands back a token for
one device. A wrong secret and an account that is not here get the same
answer and take the same time, so the path cannot be used to find out who
has an account. Secrets are stored with scrypt at parameters carried in the
stored form; tokens are stored as digests, so a leaked store hands out no
working credential.

The token rides in a header, never in the address: a query string is copied
into every access log and proxy record between the device and the service.
The WebSocket handshake takes headers too — a native client sets them, and
it is only browsers that cannot, which is why so many services end up
putting tokens in URLs.

## What the service will NOT understand

It holds documents as bytes and does not parse them. The merge stays in the
client on every path — no transport can do it, measured (a WebDAV server
under a real collision keeps the last write and makes no conflict file), so
there is nothing to gain by teaching the service what a listening stand is,
and every piece of meaning it held would make a later change more
expensive.

The one thing it will do that no other path can: **announce a change**
instead of waiting to be asked. The takeover has to reach a locked, playing
device, and a silent push measurably does not.

## Operation

**Only behind TLS.** The token rides in a header, and over plain http a
header is readable by everything between the device and the service. The
service itself binds to `127.0.0.1` and a proxy with a certificate stands
in front of it; that proxy has to carry the WebSocket upgrade on
`/v1/changes`.

    MAER_SYNC_DB=maer-sync.sqlite       # the store
    MAER_SYNC_HOST=127.0.0.1            # bind address
    MAER_SYNC_PORT=8099
    MAER_SYNC_MAX_BODY_BYTES=67108864   # host protection, 413 above it

**The runtime is uvicorn plus a WebSocket library, both pinned.** The
service code and its tests are standard library only, but serving it is
not: uvicorn without its `[standard]` extra carries no WebSocket ("No
supported WebSocket library detected", measured), and `/v1/changes` needs
one, so the deployment installs `websockets` (or `wsproto`) alongside
uvicorn. One package, not the whole `[standard]` set. No web framework was
taken: the interface is "fetch bytes, put bytes, announce a change", and a
framework buys routing sugar for that and little else; Flask was never a
candidate, because WSGI cannot carry a WebSocket. Pin both with hashes.

**An unauthorized socket is refused in the handshake.** The service closes
a token-less `/v1/changes` with WebSocket code 4401 before it accepts the
connection; uvicorn surfaces that pre-accept close to the client as an
HTTP 403 on the handshake, not as a close frame. A client reads that as
"not authorized" the same as a REST 401, never as "unreachable" — its REST
calls carry the same token and answer 401 first, so the authorization
state is driven there and the socket is only a silently reopened
accelerator.

**Every refusal leaves a line** on stderr (`maer.sync`): the source
address, the owner, the document, the status and the gate's sentence; a
failed sign-in leaves the source address and the owner. Never a token,
never a secret, never a body, and a case in the suite reads this file to
hold that. Without those lines the case the service is built for, a device
that writes empty at start-up and a client that swallows the 409, would be
invisible for as long as it lasts.

**The body limit is host protection, not a data ceiling.** A document
larger than `MAER_SYNC_MAX_BODY_BYTES` is refused with 413 before it is
held in memory. It is generous on purpose and set per deployment; the
shrink gate protects the data, this protects the machine.

**The backup rehearses its own restore:**

    python3 -m service backup /backups/maer-sync-$(date +%F).sqlite

copies the live store through SQLite's backup API, opens the copy in a
throwaway directory the way a restore would, compares every document
version by size, and exits 0 only when the copy came back fitting. The
operator schedules it and alarms on the exit code; a backup that was
never opened is a file, not a backup.

## Running the tests

    ./run-tests.sh

No dependencies: the whole service is standard library only, and the tests
run under `unittest`. The run prints its case count on purpose.

It takes a few seconds rather than a few milliseconds, and all of that is
scrypt: the account cases run the real password hashing at the real
parameters. Turning those down for the suite would make it quick and would
stop it testing the thing that matters.

## Choices still open

- **Where it runs for measurement.** A host with a TLS name at the test
  bench, ordered once the carrier in the app stands. Measuring the takeover
  end to end needs two devices, and that measurement is the device test's.
