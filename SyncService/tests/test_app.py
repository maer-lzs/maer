# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The ASGI shell, driven directly.

No server and no client library: an ASGI application is a callable taking
`(scope, receive, send)`, so these cases are the whole protocol. That is
the practical half of the argument for building the shell without a
framework — the tests need nothing installed.
"""

import asyncio
import json
import os
import tempfile
import unittest

from service.app import App, Insecure, make
from service.store import Store


def run(coro):
    return asyncio.run(coro)


class Exchange:
    """One request: collects what the application sends back."""

    def __init__(self, *incoming):
        self.incoming = list(incoming)
        self.start = None
        self.body = b""
        self.sent = []

    async def receive(self):
        if self.incoming:
            return self.incoming.pop(0)
        return {"type": "http.disconnect"}

    async def send(self, message):
        self.sent.append(message)
        if message["type"] == "http.response.start":
            self.start = message
        elif message["type"] == "http.response.body":
            self.body += message.get("body", b"")

    @property
    def status(self):
        return self.start["status"]

    @property
    def headers(self):
        return {k.decode().lower(): v.decode() for k, v in self.start["headers"]}

    @property
    def json(self):
        return json.loads(self.body)


class AppCase(unittest.TestCase):
    def setUp(self):
        handle, self.path = tempfile.mkstemp(suffix=".sqlite")
        os.close(handle)
        os.unlink(self.path)
        self.app = App(Store(self.path), owner="the-owner")

    def tearDown(self):
        self.app.store.close()
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.unlink(self.path + suffix)

    def get(self, path):
        ex = Exchange()
        run(self.app({"type": "http", "method": "GET", "path": path,
                      "query_string": b"", "headers": []}, ex.receive, ex.send))
        return ex

    def put(self, path, body, fmt="1", if_match=None, declared=False, query=b""):
        headers = [(b"x-maer-format", fmt.encode())] if fmt is not None else []
        if if_match:
            headers.append((b"if-match", if_match.encode()))
        if declared:
            headers.append((b"x-maer-declared-shrink", b"1"))
        ex = Exchange({"type": "http.request", "body": body, "more_body": False})
        run(self.app({"type": "http", "method": "PUT", "path": path,
                      "query_string": query, "headers": headers}, ex.receive, ex.send))
        return ex


class FetchingAndPutting(AppCase):
    def test_a_document_that_is_not_there_is_a_404(self):
        self.assertEqual(self.get("/v1/doc/stands").status, 404)

    def test_a_put_then_a_get_comes_back_byte_for_byte(self):
        put = self.put("/v1/doc/stands", b"\x00\xffbytes")
        self.assertEqual(put.status, 200)
        got = self.get("/v1/doc/stands")
        self.assertEqual(got.status, 200)
        self.assertEqual(got.body, b"\x00\xffbytes")
        self.assertEqual(got.headers["etag"], "1")
        self.assertEqual(got.headers["x-maer-format"], "1")

    def test_the_version_travels_on_both_ways(self):
        self.assertEqual(self.put("/v1/doc/stands", b"a" * 50).headers["etag"], "1")
        second = self.put("/v1/doc/stands", b"b" * 50, if_match="1")
        self.assertEqual(second.headers["etag"], "2")

    def test_a_scope_addresses_its_own_document(self):
        self.put("/v1/doc/stats", b"phone", query=b"scope=dev-a")
        self.put("/v1/doc/stats", b"tablet", query=b"scope=dev-b")
        ex = Exchange()
        run(self.app({"type": "http", "method": "GET", "path": "/v1/doc/stats",
                      "query_string": b"scope=dev-b", "headers": []}, ex.receive, ex.send))
        self.assertEqual(ex.body, b"tablet")

    def test_health_answers_without_a_document(self):
        self.assertEqual(self.get("/v1/health").status, 200)


class WhatTheShellRefuses(AppCase):
    def test_an_unknown_path_is_a_404(self):
        for path in ("/v1/nonsense", "/", "/v2/doc/stands", "/v1/doc/a/b"):
            ex = self.get(path)
            self.assertEqual(ex.status, 404)
            self.assertEqual(ex.json["reason"], "no such path", path)

    def test_a_kind_that_is_not_a_name_is_refused_as_a_path(self):
        # A red probe that removed the shape check stayed green: every one
        # of these reads back as "no such document", which is also a 404.
        # The case could not tell a refused path from a missing one, so it
        # was testing nothing. Now it reads the reason — and it writes,
        # because a PUT is where an unchecked kind would actually create
        # something.
        for kind in ("..", "x" * 40, "Stands", "9lives", "with space"):
            ex = self.get("/v1/doc/" + kind)
            self.assertEqual(ex.status, 404, kind)
            self.assertEqual(ex.json["reason"], "no such path", kind)

            wrote = self.put("/v1/doc/" + kind, b"x" * 50)
            self.assertEqual(wrote.status, 404, kind)
            self.assertEqual(wrote.json["reason"], "no such path", kind)

    def test_a_missing_document_says_something_else_than_a_missing_path(self):
        # The other half: the two 404s must not be the same answer, or the
        # case above passes on whichever one it happens to get.
        ex = self.get("/v1/doc/stands")
        self.assertEqual(ex.status, 404)
        self.assertEqual(ex.json["reason"], "no such document")

    def test_a_scope_that_is_not_a_scope_is_a_400(self):
        ex = Exchange()
        run(self.app({"type": "http", "method": "GET", "path": "/v1/doc/stats",
                      "query_string": b"scope=" + b"x" * 100, "headers": []},
                     ex.receive, ex.send))
        self.assertEqual(ex.status, 400)

    def test_a_write_without_a_format_is_a_400(self):
        # Guessing would let every client that forgot the header overwrite
        # a document written by a newer one.
        self.assertEqual(self.put("/v1/doc/stands", b"x" * 10, fmt=None).status, 400)
        self.assertEqual(self.put("/v1/doc/stands", b"x" * 10, fmt="soon").status, 400)

    def test_a_method_the_path_is_not_for_is_a_405(self):
        ex = Exchange()
        run(self.app({"type": "http", "method": "DELETE", "path": "/v1/doc/stands",
                      "query_string": b"", "headers": []}, ex.receive, ex.send))
        self.assertEqual(ex.status, 405)


class TheGatesAnswerThroughHttp(AppCase):
    def test_a_blind_overwrite_is_a_412_and_hands_back_the_version(self):
        self.put("/v1/doc/stands", b"a" * 100)
        again = self.put("/v1/doc/stands", b"b" * 100)
        self.assertEqual(again.status, 412)
        # The client needs the current version to get anywhere, so the
        # refusal carries it rather than making it ask again.
        self.assertEqual(again.headers["etag"], "1")

    def test_an_empty_state_over_a_full_one_is_a_409(self):
        self.put("/v1/doc/stands", b"a" * 100)
        refused = self.put("/v1/doc/stands", b"", if_match="1")
        self.assertEqual(refused.status, 409)
        self.assertIn("empty", refused.json["reason"])

    def test_a_declared_shrink_goes_through(self):
        self.put("/v1/doc/stands", b"a" * 100)
        self.assertEqual(self.put("/v1/doc/stands", b"", if_match="1", declared=True).status, 200)

    def test_an_older_format_is_a_409(self):
        self.put("/v1/doc/stands", b"a" * 100, fmt="3")
        refused = self.put("/v1/doc/stands", b"b" * 100, fmt="2", if_match="1")
        self.assertEqual(refused.status, 409)

    def test_every_refusal_says_why(self):
        self.put("/v1/doc/stands", b"a" * 100)
        for ex in (self.put("/v1/doc/stands", b"b" * 100),
                   self.put("/v1/doc/stands", b"", if_match="1"),
                   self.put("/v1/doc/stands", b"x", fmt=None)):
            self.assertTrue(ex.json.get("reason", "").strip(), f"silent refusal: {ex.status}")


class AnnouncingAChange(AppCase):
    """The one thing no other path can do. A takeover has to reach a
    locked, playing device, and a silent push measurably does not."""

    def test_a_listener_hears_an_accepted_write(self):
        heard = []

        async def socket():
            incoming = [{"type": "websocket.connect"}]

            async def receive():
                if incoming:
                    return incoming.pop(0)
                await asyncio.sleep(0.05)
                return {"type": "websocket.disconnect"}

            async def send(message):
                heard.append(message)

            task = asyncio.create_task(self.app(
                {"type": "websocket", "path": "/v1/changes"}, receive, send))
            await asyncio.sleep(0)
            self.app.store.write("the-owner", "stands", b"x" * 10, 1)
            await self.app.listeners.announce("the-owner", {"kind": "stands", "version": "1"})
            await task

        run(socket())
        self.assertEqual(heard[0]["type"], "websocket.accept")
        payload = json.loads(heard[1]["text"])
        self.assertEqual(payload["kind"], "stands")

    def test_a_listener_that_left_is_dropped_not_retried(self):
        # An announcement is an acceleration, never the only source of
        # truth. Queuing for an absent device would turn a nicety into a
        # liability.
        async def dead(message):
            raise ConnectionResetError("gone")

        self.app.listeners.add("the-owner", dead)
        self.assertEqual(self.app.listeners.count("the-owner"), 1)
        run(self.app.listeners.announce("the-owner", {"kind": "stands"}))
        self.assertEqual(self.app.listeners.count("the-owner"), 0)

    def test_a_refused_write_announces_nothing(self):
        # Otherwise a device would re-read on every rejected start-up
        # write of its neighbour.
        sent = []
        self.app.listeners.add("the-owner", lambda m: _record(sent, m))
        self.put("/v1/doc/stands", b"a" * 100)
        sent.clear()
        self.put("/v1/doc/stands", b"b" * 100)  # no version named: 412
        self.assertEqual(sent, [])

    def test_a_socket_on_another_path_is_closed(self):
        closed = []

        async def receive():
            return {"type": "websocket.connect"}

        async def send(message):
            closed.append(message)

        run(self.app({"type": "websocket", "path": "/v1/nonsense"}, receive, send))
        self.assertEqual(closed[0]["type"], "websocket.close")


async def _record(sink, message):
    sink.append(message)


class ItWillNotStartUnauthenticatedInSilence(unittest.TestCase):
    """Until authentication exists, the service serves one named owner and
    says so out loud. A service that quietly served everyone as one person
    would be the one failure an update does not repair."""

    def setUp(self):
        self.saved = {k: os.environ.get(k) for k in
                      ("MAER_SYNC_SINGLE_OWNER", "MAER_SYNC_NO_AUTH_I_MEAN_IT")}
        for key in self.saved:
            os.environ.pop(key, None)

    def tearDown(self):
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_it_refuses_with_nothing_set(self):
        with self.assertRaises(Insecure):
            make(":memory:")

    def test_naming_an_owner_alone_is_not_enough(self):
        os.environ["MAER_SYNC_SINGLE_OWNER"] = "the-owner"
        with self.assertRaises(Insecure):
            make(":memory:")

    def test_acknowledging_alone_is_not_enough(self):
        os.environ["MAER_SYNC_NO_AUTH_I_MEAN_IT"] = "1"
        with self.assertRaises(Insecure):
            make(":memory:")

    def test_both_together_start_it(self):
        os.environ["MAER_SYNC_SINGLE_OWNER"] = "the-owner"
        os.environ["MAER_SYNC_NO_AUTH_I_MEAN_IT"] = "1"
        app = make(":memory:")
        try:
            self.assertEqual(app.owner, "the-owner")
        finally:
            app.store.close()


if __name__ == "__main__":
    unittest.main()
