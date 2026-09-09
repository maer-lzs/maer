# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The service as a bare ASGI application.

No web framework. The whole interface is "fetch bytes, put bytes, announce
a change", and against the written selection criteria a framework buys
routing sugar for that and little else: fewest transitive dependencies
wins outright, ASGI is the standard interface that keeps the application
server swappable, and a dispatch table this small is easier to read than
anyone's routing decorators. Flask was never a candidate — WSGI cannot
carry a WebSocket, and announcing a change is an invariant, not a wish.

It also means this file is testable with nothing installed at all: an ASGI
application is a callable taking three arguments, so the tests drive it
directly. A framework would have brought a test client and the dependency
that carries it.

WHAT IS NOT HERE YET: authentication. Until it is, the service serves one
named owner and it will not start without being told, in so many words,
that this is what is happening. A service that quietly served everyone as
one person would be the failure that no update repairs.
"""

import json
import os

from core.paths import parse_document_path, valid_scope

from .store import Store


class Insecure(Exception):
    """The service was started without authentication and without saying
    so. It stops instead of guessing."""


def _single_owner():
    owner = os.environ.get("MAER_SYNC_SINGLE_OWNER", "")
    acknowledged = os.environ.get("MAER_SYNC_NO_AUTH_I_MEAN_IT") == "1"
    if not owner or not acknowledged:
        raise Insecure(
            "this build has no authentication yet: set MAER_SYNC_SINGLE_OWNER to the one "
            "account it serves and MAER_SYNC_NO_AUTH_I_MEAN_IT=1 to say you know. Do not "
            "run it where anyone else can reach it.")
    return owner


class Listeners:
    """Who is waiting to hear that something changed.

    The announcement is what makes a service of our own worth having: the
    takeover has to reach a locked, playing device, and a silent push
    measurably does not (median 1050 ms in the foreground; on the locked
    device it did not arrive at all). Every accepted write tells everyone
    listening for that owner.

    A listener that has gone away is dropped rather than retried: an
    announcement is an ACCELERATION, never the only source of truth, and a
    device that missed one catches up at its next occasion. Holding a
    queue for an absent device would turn a nicety into a liability.
    """

    def __init__(self):
        self._by_owner = {}

    def add(self, owner, send):
        self._by_owner.setdefault(owner, []).append(send)

    def remove(self, owner, send):
        waiting = self._by_owner.get(owner)
        if waiting and send in waiting:
            waiting.remove(send)
        if waiting is not None and not waiting:
            del self._by_owner[owner]

    def count(self, owner):
        return len(self._by_owner.get(owner, []))

    async def announce(self, owner, message):
        text = json.dumps(message)
        gone = []
        for send in list(self._by_owner.get(owner, [])):
            try:
                await send({"type": "websocket.send", "text": text})
            except Exception:
                # An announcement is best effort by design; a dead socket
                # is not an error the writer needs to hear about.
                gone.append(send)
        for send in gone:
            self.remove(owner, send)


class App:
    def __init__(self, store, owner):
        self.store = store
        self.owner = owner
        self.listeners = Listeners()

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            await self._http(scope, receive, send)
        elif scope["type"] == "websocket":
            await self._websocket(scope, receive, send)
        elif scope["type"] == "lifespan":
            await self._lifespan(receive, send)

    # MARK: - HTTP

    async def _http(self, scope, receive, send):
        path = scope["path"]
        method = scope["method"]

        if path == "/v1/health":
            return await _json(send, 200, {"ok": True, "listeners": self.listeners.count(self.owner)})

        kind = parse_document_path(path)
        if kind is None:
            return await _json(send, 404, {"reason": "no such path"})

        query = _query(scope.get("query_string", b""))
        query_scope = query.get("scope", "")
        if not valid_scope(query_scope):
            return await _json(send, 400, {"reason": "the scope is not a scope"})

        if method == "GET":
            return await self._get(send, kind, query_scope)
        if method == "PUT":
            return await self._put(scope, receive, send, kind, query_scope)
        return await _json(send, 405, {"reason": f"{method} is not what this path is for"})

    async def _get(self, send, kind, query_scope):
        held = self.store.current(self.owner, kind, query_scope)
        if held is None:
            return await _json(send, 404, {"reason": "no such document"})
        body, fmt, etag = held
        await _bytes(send, 200, body, [
            (b"etag", etag.encode()),
            (b"x-maer-format", str(fmt).encode()),
        ])

    async def _put(self, scope, receive, send, kind, query_scope):
        headers = {k.decode().lower(): v.decode() for k, v in scope.get("headers", [])}
        raw_format = headers.get("x-maer-format")
        try:
            writer_format = int(raw_format)
        except (TypeError, ValueError):
            # Guessing a format would let every client that forgot the
            # header overwrite documents written by newer ones.
            return await _json(send, 400, {"reason": "the write named no format"})

        body = await _read_body(receive)
        decision, etag = self.store.write(
            self.owner, kind, body, writer_format, scope=query_scope,
            if_match=headers.get("if-match"),
            declared_shrink=headers.get("x-maer-declared-shrink") == "1")

        if not decision.accepted:
            held = self.store.current(self.owner, kind, query_scope)
            extra = [(b"etag", held[2].encode())] if held else []
            return await _json(send, decision.status, {"reason": decision.reason}, extra)

        await self.listeners.announce(self.owner, {
            "kind": kind, "scope": query_scope, "version": etag,
        })
        await _json(send, 200, {"reason": decision.reason, "version": etag},
                    [(b"etag", etag.encode())])

    # MARK: - WebSocket

    async def _websocket(self, scope, receive, send):
        if scope["path"] != "/v1/changes":
            await send({"type": "websocket.close", "code": 4004})
            return
        message = await receive()
        if message["type"] != "websocket.connect":
            return
        await send({"type": "websocket.accept"})
        self.listeners.add(self.owner, send)
        try:
            while True:
                message = await receive()
                if message["type"] == "websocket.disconnect":
                    break
                # The client has nothing to say on this socket. Anything it
                # sends is ignored rather than parsed: a channel that only
                # ever announces cannot be talked into doing something else.
        finally:
            self.listeners.remove(self.owner, send)

    # MARK: - Lifespan

    async def _lifespan(self, receive, send):
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                self.store.close()
                await send({"type": "lifespan.shutdown.complete"})
                return


# MARK: - The small amount of HTTP a byte store needs


async def _read_body(receive):
    body = b""
    while True:
        message = await receive()
        body += message.get("body", b"")
        if not message.get("more_body"):
            return body


def _query(raw):
    out = {}
    for pair in raw.decode().split("&"):
        if "=" in pair:
            key, value = pair.split("=", 1)
            out[key] = value
    return out


async def _bytes(send, status, body, headers=()):
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"application/octet-stream"),
                            (b"content-length", str(len(body)).encode())] + list(headers)})
    await send({"type": "http.response.body", "body": body})


async def _json(send, status, payload, headers=()):
    body = json.dumps(payload).encode()
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"application/json"),
                            (b"content-length", str(len(body)).encode())] + list(headers)})
    await send({"type": "http.response.body", "body": body})


def make(path=None):
    """The application, with the store it serves. Raises `Insecure` unless
    the operator has said out loud that this build has no authentication."""
    owner = _single_owner()
    return App(Store(path or os.environ.get("MAER_SYNC_DB", "maer-sync.sqlite")), owner)
