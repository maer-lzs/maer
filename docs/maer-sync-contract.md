# The contract between Mär and the Mär sync service

**Version: 2**

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
version: 2
paths: /v1/health /v1/token /v1/doc /v1/docs /v1/changes
headers: Authorization X-Maer-Format If-Match X-Maer-Declared-Shrink ETag
kinds: stands claim stats playlists choices feedauth
status: 200 400 401 404 405 409 412 413
-->

## The paths

| path | what it is |
| --- | --- |
| `/v1/health` | is anything there. Answers a status and nothing else |
| `/v1/token` | trades owner and secret for a bearer token |
| `/v1/doc/<kind>?scope=<scope>` | one document: `GET` reads, `PUT` writes |
| `/v1/docs/<kind>` | the listing of a kind: which scopes exist, at which version |
| `/v1/changes` | the socket that says a document moved |

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
| 412 | `If-Match` named a version that has moved |
| 413 | the body is larger than the host accepts |

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
