# Mär Sync Service

A small, self-hosted place for Mär's own data — listening stands, listening
statistics, Mär playlists, the choice family, and the playback claim.

**Optional, never required.** Mär works completely without it. It stands
beside iCloud and a WebDAV folder as a third way, and the user picks; it is
not a replacement and not a default.

**Status: the core only.** This directory holds the netless decision units
and their tests. There is no server here yet — no HTTP, no storage, no
authentication. Nothing in the Mär app talks to it.

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

Every unit answers with a verdict that carries its sentence. A refusal that
does not say why would be the failure the gates are built to prevent.

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

No dependencies: the core is standard library only, and the tests run under
`unittest`. The run prints its case count on purpose.

## Choices still open

- **Language and framework.** Python is the working assumption because the
  requirements name a standard interface (WSGI/ASGI) as a selection
  criterion, and because the core above is stdlib-only either way. The web
  framework is not chosen yet and will be, against the written criteria:
  few transitive dependencies, longevity over modernity, small enough to
  understand, versions pinned and checkable.
- **Where it runs for measurement.** Not decided.
