# Mär Sync Service

A small, self-hosted place for Mär's own data — listening stands, listening
statistics, Mär playlists, the choice family, and the playback claim.

**Optional, never required.** Mär works completely without it. It stands
beside iCloud and a WebDAV folder as a third way, and the user picks; it is
not a replacement and not a default.

**Status: core, shell and accounts.** The netless decision units, a SQLite
store, a bare ASGI application and bearer-token authentication, all under
test. Nothing in the Mär app talks to it yet, and nothing here has been run
behind a live application server.

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

## Running the tests

    ./run-tests.sh

No dependencies: the whole service is standard library only, and the tests
run under `unittest`. The run prints its case count on purpose.

It takes a few seconds rather than a few milliseconds, and all of that is
scrypt: the account cases run the real password hashing at the real
parameters. Turning those down for the suite would make it quick and would
stop it testing the thing that matters.

## Choices still open

- **The application server.** uvicorn is the reference. It is the only
  runtime dependency the service will have, it is not installed here yet,
  and installing it belongs with pinning and hash-checking rather than
  before them. No web framework was taken: the whole interface is "fetch
  bytes, put bytes, announce a change", and against the written criteria a
  framework buys routing sugar for that and little else. Flask was never a
  candidate, because WSGI cannot carry a WebSocket.
- **Where it runs for measurement.** Not decided. And measuring the
  takeover end to end needs two devices, which is a limit outside this
  directory.
