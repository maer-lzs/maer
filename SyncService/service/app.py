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

Every request names itself with a bearer token and the OWNER comes from
the store's answer to it, never from anything the caller wrote. The one
exception is the path that hands out a token in the first place, and it
gives the same answer for a wrong secret and for an account that is not
here.

The token rides in a header and never in the address. A query string is
copied into every access log and proxy record between the device and the
service, so an address that carries a credential leaks it to places
nobody thought about. The WebSocket handshake takes headers too — a
native client sets them, and it is only browsers that cannot, which is
why so many services end up putting tokens in URLs.
"""

import json
import logging
import os
from urllib.parse import unquote

from core.authorization import DENIED, caller_for
from core.paths import parse_document_path, parse_listing_path, valid_scope

from .store import Store

# Every refusal and every failed sign-in leaves a line here, with the
# source address, the owner, the document and the sentence. Never a token,
# never a secret, never a body: a fence in the suite reads this file and
# holds that. Without the lines the case the service is built for (a device
# writes empty at start-up, is refused, and the client swallows the 409) is
# invisible to the operator for as long as it lasts.
log = logging.getLogger("maer.sync")

# Host protection, NOT a data ceiling: a body larger than this is refused
# with 413 before it is held in memory. The shrink gate protects the data;
# this protects the machine from a broken carrier or a token holder that
# sends a gigabyte, tenfold over the kept versions. Generous on purpose and
# set per deployment; it is not the iCloud megabyte in another coat.
DEFAULT_MAX_BODY_BYTES = 64 * 1024 * 1024


class BodyTooLarge(Exception):
    pass


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
    def __init__(self, store, max_body_bytes=None):
        self.store = store
        self.listeners = Listeners()
        self.max_body_bytes = max_body_bytes or int(
            os.environ.get("MAER_SYNC_MAX_BODY_BYTES", DEFAULT_MAX_BODY_BYTES))

    def _caller(self, scope):
        # A header that is not UTF-8 is a bad request, not a crash of the
        # worker: replaced characters make an unknown token, and that is
        # a 401 like any other.
        headers = {k.decode("utf-8", "replace").lower(): v.decode("utf-8", "replace")
                   for k, v in scope.get("headers", [])}
        return caller_for(headers.get("authorization"), self.store.owner_of_token), headers

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

        # The only path that answers without a token, because it is the one
        # that hands tokens out. It says nothing about the store.
        if path == "/v1/health":
            return await _json(send, 200, {"ok": True})
        if path == "/v1/token":
            if method != "POST":
                return await _json(send, 405, {"reason": f"{method} is not what this path is for"})
            return await self._token(scope, receive, send)

        caller, headers = self._caller(scope)
        if not caller.authorized:
            log.warning("unauthorized from=%s method=%s path=%s", _client(scope), method, path)
            return await _json(send, 401, {"reason": caller.reason},
                               [(b"www-authenticate", b"Bearer")])

        listed = parse_listing_path(path)
        if listed is not None:
            if method != "GET":
                return await _json(send, 405, {"reason": f"{method} is not what this path is for"})
            return await self._list(send, caller.owner, listed)

        kind = parse_document_path(path)
        if kind is None:
            return await _json(send, 404, {"reason": "no such path"})

        query = _query(scope.get("query_string", b""))
        query_scope = query.get("scope", "")
        if not valid_scope(query_scope):
            return await _json(send, 400, {"reason": "the scope is not a scope"})

        if method == "GET":
            return await self._get(send, caller.owner, kind, query_scope)
        if method == "PUT":
            return await self._put(scope, receive, send, caller.owner, headers, kind, query_scope)
        return await _json(send, 405, {"reason": f"{method} is not what this path is for"})

    async def _token(self, scope, receive, send):
        try:
            body = await _read_body(receive, self.max_body_bytes)
        except BodyTooLarge:
            log.warning("sign-in too large from=%s", _client(scope))
            return await _json(send, 413, {"reason": "the request is larger than this host takes"})
        try:
            asked = json.loads(body)
            owner, secret = asked["owner"], asked["secret"]
            device = asked.get("device", "")
        except (ValueError, KeyError, TypeError):
            return await _json(send, 400, {"reason": "this path wants an owner and a secret"})

        token = self.store.issue_token(owner, secret, device)
        if token is None:
            # The same answer a wrong secret gets, and the same one an
            # account that is not here gets. Anything else makes this a
            # list of who has an account. The log line carries the source
            # address so the operator can count tries per address.
            log.warning("sign-in refused from=%s owner=%s", _client(scope), owner)
            return await _json(send, 401, {"reason": DENIED})
        log.info("sign-in from=%s owner=%s device=%s", _client(scope), owner, device)
        return await _json(send, 200, {"token": token})

    async def _list(self, send, owner, kind):
        documents = [{"scope": scope, "version": etag, "format": fmt}
                     for scope, etag, fmt in self.store.scopes(owner, kind)]
        await _json(send, 200, {"kind": kind, "documents": documents})

    async def _get(self, send, owner, kind, query_scope):
        held = self.store.current(owner, kind, query_scope)
        if held is None:
            return await _json(send, 404, {"reason": "no such document"})
        body, fmt, etag = held
        await _bytes(send, 200, body, [
            (b"etag", etag.encode()),
            (b"x-maer-format", str(fmt).encode()),
        ])

    async def _put(self, scope, receive, send, owner, headers, kind, query_scope):
        raw_format = headers.get("x-maer-format")
        try:
            writer_format = int(raw_format)
        except (TypeError, ValueError):
            # Guessing a format would let every client that forgot the
            # header overwrite documents written by newer ones.
            return await _json(send, 400, {"reason": "the write named no format"})

        try:
            body = await _read_body(receive, self.max_body_bytes)
        except BodyTooLarge:
            log.warning("write too large from=%s owner=%s kind=%s scope=%s limit=%d",
                        _client(scope), owner, kind, query_scope, self.max_body_bytes)
            return await _json(send, 413, {"reason": "the document is larger than this host takes"})
        decision, etag = self.store.write(
            owner, kind, body, writer_format, scope=query_scope,
            if_match=headers.get("if-match"),
            declared_shrink=headers.get("x-maer-declared-shrink") == "1")

        if not decision.accepted:
            held = self.store.current(owner, kind, query_scope)
            extra = [(b"etag", held[2].encode())] if held else []
            log.warning("refused from=%s owner=%s kind=%s scope=%s status=%d reason=%s",
                        _client(scope), owner, kind, query_scope, decision.status, decision.reason)
            return await _json(send, decision.status, {"reason": decision.reason}, extra)

        await self.listeners.announce(owner, {
            "kind": kind, "scope": query_scope, "version": etag,
        })
        await _json(send, 200, {"reason": decision.reason, "version": etag},
                    [(b"etag", etag.encode())])

    # MARK: - WebSocket

    async def _websocket(self, scope, receive, send):
        if scope["path"] != "/v1/changes":
            await send({"type": "websocket.close", "code": 4004})
            return

        # The handshake carries the token in a header like every other
        # request. An unauthorized socket is closed before it is accepted:
        # accepting first and closing after would put a stranger on the
        # announcement list for as long as that takes.
        caller, _ = self._caller(scope)
        if not caller.authorized:
            log.warning("unauthorized socket from=%s", _client(scope))
            await send({"type": "websocket.close", "code": 4401})
            return

        message = await receive()
        if message["type"] != "websocket.connect":
            return
        await send({"type": "websocket.accept"})
        self.listeners.add(caller.owner, send)
        try:
            while True:
                message = await receive()
                if message["type"] == "websocket.disconnect":
                    break
                # The client has nothing to say on this socket. Anything it
                # sends is ignored rather than parsed: a channel that only
                # ever announces cannot be talked into doing something else.
        finally:
            self.listeners.remove(caller.owner, send)

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


async def _read_body(receive, limit):
    """The whole body, or `BodyTooLarge` as soon as it passes the limit,
    so an oversized request never sits in memory in full."""
    body = b""
    while True:
        message = await receive()
        body += message.get("body", b"")
        if len(body) > limit:
            raise BodyTooLarge()
        if not message.get("more_body"):
            return body


def _query(raw):
    """The query as a dict, values URL-decoded: a client that encodes the
    colon in a device id must find its own document again."""
    out = {}
    for pair in raw.decode("utf-8", "replace").split("&"):
        if "=" in pair:
            key, value = pair.split("=", 1)
            out[key] = unquote(value)
    return out


def _client(scope):
    """The source address for the log line, or a dash."""
    client = scope.get("client")
    if not client:
        return "-"
    return f"{client[0]}:{client[1]}"


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
    """The application, with the store it serves."""
    return App(Store(path or os.environ.get("MAER_SYNC_DB", "maer-sync.sqlite")))
