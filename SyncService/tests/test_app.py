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
import re
import tempfile
import unittest

from service.app import App
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
        self.app = App(Store(self.path))
        self.app.store.create_account("the-owner", "a passphrase with some length")
        self.token = self.app.store.issue_token("the-owner", "a passphrase with some length")
        self.auth = [(b"authorization", f"Bearer {self.token}".encode())]

    def tearDown(self):
        self.app.store.close()
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.unlink(self.path + suffix)

    def get(self, path, headers=None):
        ex = Exchange()
        run(self.app({"type": "http", "method": "GET", "path": path,
                      "query_string": b"",
                      "headers": self.auth if headers is None else headers},
                     ex.receive, ex.send))
        return ex

    def put(self, path, body, fmt="1", if_match=None, declared=False, query=b""):
        headers = list(self.auth)
        if fmt is not None:
            headers.append((b"x-maer-format", fmt.encode()))
        if if_match:
            headers.append((b"if-match", if_match.encode()))
        if declared:
            headers.append((b"x-maer-declared-shrink", b"1"))
        ex = Exchange({"type": "http.request", "body": body, "more_body": False})
        run(self.app({"type": "http", "method": "PUT", "path": path,
                      "query_string": query, "headers": headers}, ex.receive, ex.send))
        return ex


class NothingAnswersWithoutAToken(AppCase):
    """The one kind of mistake an update does not repair. Every path but
    the two that cannot need one."""

    def test_every_document_path_is_a_401_without_a_token(self):
        self.put("/v1/doc/stands", b"a" * 100)
        for headers in ([], [(b"authorization", b"Bearer nonsense")],
                        [(b"authorization", b"Basic the-owner:secret")]):
            ex = self.get("/v1/doc/stands", headers=headers)
            self.assertEqual(ex.status, 401, headers)
            self.assertEqual(ex.json["reason"], "not authorized")

    def test_a_write_without_a_token_never_reaches_the_store(self):
        ex = Exchange({"type": "http.request", "body": b"x" * 100, "more_body": False})
        run(self.app({"type": "http", "method": "PUT", "path": "/v1/doc/stands",
                      "query_string": b"", "headers": [(b"x-maer-format", b"1")]},
                     ex.receive, ex.send))
        self.assertEqual(ex.status, 401)
        self.assertIsNone(self.app.store.current("the-owner", "stands"))

    def test_the_refusal_says_how_to_ask(self):
        ex = self.get("/v1/doc/stands", headers=[])
        self.assertEqual(ex.headers["www-authenticate"], "Bearer")

    def test_health_answers_without_one_and_says_nothing_about_the_store(self):
        ex = self.get("/v1/health", headers=[])
        self.assertEqual(ex.status, 200)
        # It used to report the listener count. That is a fact about who is
        # connected, handed to anyone who can reach the port.
        self.assertEqual(set(ex.json), {"ok"})


class NothingTheCallerWroteIsAnIdentity(unittest.TestCase):
    """A fence, because a behavioural case cannot reach this.

    The red probe was `headers.get("x-maer-owner", caller.owner)` — a door
    left open for a later edit to read an account name out of a request.
    It stayed green, and rightly so: no case sends that header, so nothing
    observable changed. The property is real all the same, and what is
    left is to count the sites and let the stock only fall.

    Every handler that touches a document takes its owner, and the only
    thing ever passed is `caller.owner`, which came from the store.
    """

    def source(self):
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(os.path.join(here, "service", "app.py"), encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        return [line for line in lines if not line.strip().startswith("#")]

    def test_every_handler_is_handed_the_caller_that_the_store_named(self):
        # `self._get(` matches the CALLS only: the definitions are
        # `async def _get(self, ...)` and carry no receiver. Counted, not
        # assumed — the first version of this fence expected four and
        # found two, which is the difference between counting a thing and
        # counting its use.
        calls = [line for line in self.source()
                 if "self._get(" in line or "self._put(" in line]
        self.assertEqual(len(calls), 2, f"the handlers moved: {calls}")
        for line in calls:
            # `, caller.owner,` and not merely `caller.owner`: the second
            # red probe wrapped it as `headers.get("x-maer-owner",
            # caller.owner)`, which CONTAINS the name and passed a
            # substring check. The commas pin it as the whole argument.
            self.assertIn(", caller.owner,", line,
                          f"a handler is handed something other than the caller: {line.strip()}")

    def test_the_listener_list_is_keyed_by_the_caller_too(self):
        adds = [line for line in self.source() if "listeners.add(" in line]
        self.assertEqual(len(adds), 1, f"the listener list gained a writer: {adds}")
        self.assertIn("caller.owner", adds[0])


class HandingOutAToken(AppCase):
    def token_request(self, payload):
        body = json.dumps(payload).encode() if isinstance(payload, dict) else payload
        ex = Exchange({"type": "http.request", "body": body, "more_body": False})
        run(self.app({"type": "http", "method": "POST", "path": "/v1/token",
                      "query_string": b"", "headers": []}, ex.receive, ex.send))
        return ex

    def test_the_right_secret_gets_a_token_that_works(self):
        ex = self.token_request({"owner": "the-owner", "secret": "a passphrase with some length"})
        self.assertEqual(ex.status, 200)
        fresh = ex.json["token"]
        got = self.get("/v1/health", headers=[(b"authorization", f"Bearer {fresh}".encode())])
        self.assertEqual(got.status, 200)
        self.assertEqual(self.app.store.owner_of_token(_digest(fresh)), "the-owner")

    def test_a_wrong_secret_and_an_unknown_account_sound_identical(self):
        wrong = self.token_request({"owner": "the-owner", "secret": "not it"})
        unknown = self.token_request({"owner": "nobody-here", "secret": "not it"})
        self.assertEqual(wrong.status, 401)
        self.assertEqual((wrong.status, wrong.json), (unknown.status, unknown.json))

    def test_a_request_that_is_not_one_is_a_400_not_a_500(self):
        for payload in (b"not json", {"owner": "the-owner"}, {"secret": "x"}, b"[]"):
            self.assertEqual(self.token_request(payload).status, 400)

    def test_the_token_path_is_only_for_posting(self):
        self.assertEqual(self.get("/v1/token").status, 405)


class OneOwnerNeverSeesAnother(AppCase):
    """The failure nobody repairs with an update."""

    def setUp(self):
        super().setUp()
        self.app.store.create_account("someone-else", "their own long passphrase")
        other = self.app.store.issue_token("someone-else", "their own long passphrase")
        self.other_auth = [(b"authorization", f"Bearer {other}".encode())]

    def test_a_document_is_invisible_to_the_other_account(self):
        self.put("/v1/doc/stands", b"my listening")
        ex = self.get("/v1/doc/stands", headers=self.other_auth)
        self.assertEqual(ex.status, 404)

    def test_a_write_by_one_does_not_touch_the_other(self):
        self.put("/v1/doc/stands", b"mine")
        ex = Exchange({"type": "http.request", "body": b"theirs", "more_body": False})
        run(self.app({"type": "http", "method": "PUT", "path": "/v1/doc/stands",
                      "query_string": b"",
                      "headers": self.other_auth + [(b"x-maer-format", b"1")]},
                     ex.receive, ex.send))
        self.assertEqual(ex.status, 200)
        self.assertEqual(self.app.store.current("the-owner", "stands")[0], b"mine")
        self.assertEqual(self.app.store.current("someone-else", "stands")[0], b"theirs")

    def test_an_announcement_reaches_only_its_own_owner(self):
        heard = []

        async def theirs(message):
            heard.append(message)

        self.app.listeners.add("someone-else", theirs)
        self.put("/v1/doc/stands", b"mine")
        self.assertEqual(heard, [])

    def test_a_revoked_token_stops_working(self):
        self.assertEqual(self.get("/v1/doc/stands").status, 404)
        self.app.store.revoke_token(_digest(self.token))
        self.assertEqual(self.get("/v1/doc/stands").status, 401)


class TheSocketNeedsATokenToo(AppCase):
    def open_socket(self, headers):
        seen = []
        # Connect, then disconnect — what a server actually does. A
        # `receive` that answered "connect" forever made the red probe
        # hang instead of tearing, which is a probe that proves nothing.
        incoming = [{"type": "websocket.connect"}, {"type": "websocket.disconnect"}]

        async def receive():
            return incoming.pop(0) if incoming else {"type": "websocket.disconnect"}

        async def send(message):
            seen.append(message)

        run(self.app({"type": "websocket", "path": "/v1/changes", "headers": headers},
                     receive, send))
        return seen

    def test_an_unauthorized_socket_is_closed_before_it_is_accepted(self):
        # Accepting first and closing after would put a stranger on the
        # announcement list for as long as that takes.
        seen = self.open_socket([])
        self.assertEqual(seen[0]["type"], "websocket.close")
        self.assertNotIn("websocket.accept", [m["type"] for m in seen])
        self.assertEqual(self.app.listeners.count("the-owner"), 0)

    def test_a_bad_token_is_closed_too(self):
        seen = self.open_socket([(b"authorization", b"Bearer nope")])
        self.assertEqual(seen[0]["type"], "websocket.close")


def _digest(token):
    from core.authorization import token_digest

    return token_digest(token)


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
                      "query_string": b"scope=dev-b", "headers": self.auth}, ex.receive, ex.send))
        self.assertEqual(ex.body, b"tablet")

    def test_health_answers_without_a_document(self):
        self.assertEqual(self.get("/v1/health").status, 200)


class ListingWhatOtherDevicesWrote(AppCase):
    """The claim is one document per device. A device that joins knows its
    own scope and none of the others, so it asks for the list."""

    def test_the_listing_names_every_scope_with_its_version(self):
        self.put("/v1/doc/claim", b"phone", query=b"scope=dev-a")
        self.put("/v1/doc/claim", b"tablet", query=b"scope=dev-b")
        ex = self.get("/v1/docs/claim")
        self.assertEqual(ex.status, 200)
        self.assertEqual(ex.json, {"kind": "claim", "documents": [
            {"scope": "dev-a", "version": "1", "format": 1},
            {"scope": "dev-b", "version": "1", "format": 1},
        ]})

    def test_the_listing_carries_no_bodies(self):
        self.put("/v1/doc/claim", b"the whole claim", query=b"scope=dev-a")
        self.assertNotIn(b"the whole claim", self.get("/v1/docs/claim").body)

    def test_an_empty_kind_lists_nothing_and_is_not_a_404(self):
        ex = self.get("/v1/docs/claim")
        self.assertEqual(ex.status, 200)
        self.assertEqual(ex.json["documents"], [])

    def test_the_listing_needs_a_token_like_everything_else(self):
        ex = self.get("/v1/docs/claim", headers=[])
        self.assertEqual(ex.status, 401)

    def test_the_listing_is_only_for_getting(self):
        ex = self.put("/v1/docs/claim", b"x" * 100)
        self.assertEqual(ex.status, 405)

    def test_a_listing_of_a_name_that_is_not_one_is_a_404(self):
        ex = self.get("/v1/docs/Not%20A%20Kind")
        self.assertEqual(ex.status, 404)
        self.assertEqual(ex.json["reason"], "no such path")


class TheOperatorSeesEveryRefusal(AppCase):
    """The case the service is built for is a device that writes empty at
    start-up and a client that swallows the 409. Without a line for the
    operator that is invisible for as long as it lasts."""

    def test_a_refused_write_leaves_a_line_with_who_what_and_why(self):
        self.put("/v1/doc/stands", b"a" * 100)
        with self.assertLogs("maer.sync", level="WARNING") as captured:
            ex = self.put("/v1/doc/stands", b"", if_match="1")
        self.assertEqual(ex.status, 409)
        line = captured.output[-1]
        for word in ("refused", "owner=the-owner", "kind=stands", "status=409", "empty"):
            self.assertIn(word, line)

    def test_a_failed_sign_in_leaves_a_line_with_the_source_address(self):
        ex = Exchange({"type": "http.request",
                       "body": json.dumps({"owner": "the-owner", "secret": "wrong"}).encode(),
                       "more_body": False})
        with self.assertLogs("maer.sync", level="WARNING") as captured:
            run(self.app({"type": "http", "method": "POST", "path": "/v1/token",
                          "query_string": b"", "headers": [], "client": ("10.0.0.7", 51234)},
                         ex.receive, ex.send))
        self.assertEqual(ex.status, 401)
        self.assertIn("from=10.0.0.7:51234", captured.output[-1])
        self.assertNotIn("wrong", captured.output[-1], "the secret never reaches the log")

    def test_an_unauthorized_request_leaves_a_line_too(self):
        with self.assertLogs("maer.sync", level="WARNING") as captured:
            self.get("/v1/doc/stands", headers=[(b"authorization", b"Bearer nonsense")])
        self.assertIn("unauthorized", captured.output[-1])
        self.assertNotIn("nonsense", captured.output[-1], "the token never reaches the log")

    def test_an_accepted_write_leaves_no_warning(self):
        # assertNoLogs is the exact claim: nothing at WARNING or above.
        with self.assertNoLogs("maer.sync", level="WARNING"):
            self.put("/v1/doc/stands", b"a" * 100)

    def test_no_log_statement_names_a_token_a_secret_or_a_body(self):
        # A source fence: the words that must never reach a log line do
        # not appear in any log statement of the shell. The value of a
        # header or a body is exactly what a log must not carry.
        path = os.path.join(os.path.dirname(__file__), "..", "service", "app.py")
        with open(path, encoding="utf-8") as source:
            text = source.read()
        statements = _log_statements(text)
        self.assertGreaterEqual(len(statements), 5, "the fence still finds log statements")
        for statement in statements:
            for word in ("token", "secret", "body", "headers"):
                # Whole words: `max_body_bytes` is a number, `body` is
                # the thing that must not be logged.
                self.assertIsNone(re.search(rf"\b{word}\b", statement), statement)


def _log_statements(text):
    """Every `log.<level>(...)` call in the text, parentheses balanced."""
    out = []
    start = 0
    while True:
        index = text.find("log.", start)
        if index < 0:
            return out
        open_paren = text.find("(", index)
        depth = 0
        for cursor in range(open_paren, len(text)):
            if text[cursor] == "(":
                depth += 1
            elif text[cursor] == ")":
                depth -= 1
                if depth == 0:
                    out.append(text[index:cursor + 1])
                    break
        start = cursor + 1


class TheHostIsProtectedFromAboveToo(AppCase):
    """The shrink gate protects the data; this protects the machine."""

    def test_a_body_over_the_limit_is_a_413_and_never_reaches_the_store(self):
        self.app = App(self.app.store, max_body_bytes=100)
        with self.assertLogs("maer.sync", level="WARNING") as captured:
            ex = self.put("/v1/doc/stands", b"x" * 101)
        self.assertEqual(ex.status, 413)
        self.assertIn("larger", ex.json["reason"])
        self.assertIn("too large", captured.output[-1])
        self.assertIsNone(self.app.store.current("the-owner", "stands"))
        self.assertEqual(self.put("/v1/doc/stands", b"x" * 100).status, 200, "the limit itself still fits")

    def test_the_limit_is_read_from_the_environment(self):
        os.environ["MAER_SYNC_MAX_BODY_BYTES"] = "50"
        try:
            self.assertEqual(App(self.app.store).max_body_bytes, 50)
        finally:
            del os.environ["MAER_SYNC_MAX_BODY_BYTES"]
        self.assertGreater(App(self.app.store).max_body_bytes, 1_000_000, "generous by default")

    def test_a_scope_with_an_encoded_colon_finds_its_own_document(self):
        self.put("/v1/doc/claim", b"phone", query=b"scope=dev%3Aa")
        ex = Exchange()
        run(self.app({"type": "http", "method": "GET", "path": "/v1/doc/claim",
                      "query_string": b"scope=dev:a", "headers": self.auth}, ex.receive, ex.send))
        self.assertEqual(ex.body, b"phone")

    def test_a_header_that_is_not_utf8_is_a_401_not_a_crash(self):
        ex = self.get("/v1/doc/stands", headers=[(b"authorization", b"Bearer \xff\xfe")])
        self.assertEqual(ex.status, 401)


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
                      "query_string": b"scope=" + b"x" * 100, "headers": self.auth},
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
                      "query_string": b"", "headers": self.auth}, ex.receive, ex.send))
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
                {"type": "websocket", "path": "/v1/changes", "headers": self.auth},
                receive, send))
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

        run(self.app({"type": "websocket", "path": "/v1/nonsense", "headers": self.auth},
                     receive, send))
        self.assertEqual(closed[0]["type"], "websocket.close")


async def _record(sink, message):
    sink.append(message)


if __name__ == "__main__":
    unittest.main()
