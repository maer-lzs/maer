# The contract between Mär and the Mär sync service

**Version: 1**

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
version: 1
paths: /v1/health /v1/token /v1/doc /v1/docs /v1/changes
headers: Authorization X-Maer-Format If-Match X-Maer-Declared-Shrink
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

**403 is NOT in this list, and that is the point of naming it.** The service
never sends one. A 403 therefore comes from something standing IN FRONT of the
service, a proxy or a mesh that refuses a device outside the tunnel, and the app
reads it as "the service answered, but not from this network" rather than as a
refusal by the service. This sentence exists because the contract first claimed
403 and the fence tore on it.

**409 and 412 are not errors on the app side.** 412 means someone else wrote
first and the app merges and repeats; 409 means the app must say what it meant.
A carrier that treats them as failures loses data by giving up.

## The kinds in use

`stands` · `claim` · `stats` · `playlists` · `choices` · `feedauth`

Their formats are each side's business and travel in `X-Maer-Format`; the
service never reads them, it only hands them back.

## What is deliberately NOT in here

The media stream. It does not go through the service at all, and no sentence in
this file covers it.
