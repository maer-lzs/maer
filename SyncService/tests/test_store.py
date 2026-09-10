# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The store: versions that survive, a compare-and-set that is real, and a
service that stops rather than damage a store it does not know."""

import os
import sqlite3
import tempfile
import unittest

from core.authorization import token_digest
from core.writes import REFUSED, STALE, WRITTEN
from service.store import SCHEMA, Store, StoreAheadOfService


class StoreCase(unittest.TestCase):
    def setUp(self):
        handle, self.path = tempfile.mkstemp(suffix=".sqlite")
        os.close(handle)
        os.unlink(self.path)
        self.store = Store(self.path, keep=3)

    def tearDown(self):
        self.store.close()
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.unlink(self.path + suffix)

    def put(self, body, fmt=1, **kw):
        return self.store.write("the-owner", "stands", body, fmt, **kw)


class WritingAndReadingBack(StoreCase):
    def test_a_first_write_comes_back_byte_for_byte(self):
        decision, etag = self.put(b"\x00\x01hello")
        self.assertEqual(decision.status, WRITTEN)
        self.assertEqual(etag, "1")
        body, fmt, tag = self.store.current("the-owner", "stands")
        self.assertEqual(body, b"\x00\x01hello")
        self.assertEqual(fmt, 1)
        self.assertEqual(tag, "1")

    def test_a_document_that_is_not_there_reads_as_nothing(self):
        self.assertIsNone(self.store.current("the-owner", "stands"))
        self.assertIsNone(self.store.current("the-owner", "nosuchkind"))

    def test_scopes_are_separate_documents(self):
        # The statistics are one document PER DEVICE — that is what makes
        # them conflict-free by construction, and it only holds if the
        # scope really separates them.
        self.store.write("the-owner", "stats", b"phone", 1, scope="dev-a")
        self.store.write("the-owner", "stats", b"tablet", 1, scope="dev-b")
        self.assertEqual(self.store.current("the-owner", "stats", "dev-a")[0], b"phone")
        self.assertEqual(self.store.current("the-owner", "stats", "dev-b")[0], b"tablet")

    def test_owners_are_separate_documents(self):
        # The one failure class nobody repairs with an update: another
        # person's listening stands showing up.
        self.store.write("the-owner", "stands", b"mine", 1)
        self.store.write("someone-else", "stands", b"theirs", 1)
        self.assertEqual(self.store.current("the-owner", "stands")[0], b"mine")
        self.assertEqual(self.store.current("someone-else", "stands")[0], b"theirs")


class TheCompareAndSetIsReal(StoreCase):
    def test_writing_over_without_naming_a_version_is_refused(self):
        self.put(b"a" * 100)
        decision, etag = self.put(b"b" * 100)
        self.assertEqual(decision.status, STALE)
        self.assertIsNone(etag)
        # And the stored document is untouched.
        self.assertEqual(self.store.current("the-owner", "stands")[0], b"a" * 100)

    def test_naming_the_current_version_writes_and_moves_it_on(self):
        self.put(b"a" * 100)
        decision, etag = self.put(b"b" * 100, if_match="1")
        self.assertEqual(decision.status, WRITTEN)
        self.assertEqual(etag, "2")

    def test_naming_a_version_that_has_moved_on_is_refused(self):
        self.put(b"a" * 100)
        self.put(b"b" * 100, if_match="1")
        decision, _ = self.put(b"c" * 100, if_match="1")
        self.assertEqual(decision.status, STALE)


class TheGatesReachThroughTheStore(StoreCase):
    def test_an_empty_state_over_a_full_one_never_lands(self):
        self.put(b"x" * 1000)
        decision, _ = self.put(b"", if_match="1")
        self.assertEqual(decision.status, REFUSED)
        self.assertEqual(self.store.current("the-owner", "stands")[0], b"x" * 1000)

    def test_a_refused_write_leaves_no_version_behind(self):
        # A rolled-back transaction that still burned a version number
        # would make the next honest write look stale.
        self.put(b"x" * 1000)
        self.put(b"", if_match="1")
        self.assertEqual(self.store.versions("the-owner", "stands"), [1])

    def test_an_older_format_never_lands(self):
        self.put(b"x" * 1000, fmt=3)
        decision, _ = self.put(b"y" * 1000, fmt=2, if_match="1")
        self.assertEqual(decision.status, REFUSED)

    def test_the_floor_can_be_set_for_the_deployment(self):
        loose = Store(self.path + "-loose", shrink_floor=0.01)
        try:
            loose.write("l", "stands", b"x" * 1000, 1)
            decision, _ = loose.write("l", "stands", b"y" * 20, 1, if_match="1")
            self.assertEqual(decision.status, WRITTEN)
        finally:
            loose.close()
            for suffix in ("", "-wal", "-shm"):
                if os.path.exists(self.path + "-loose" + suffix):
                    os.unlink(self.path + "-loose" + suffix)


class TwoWritersAtOnce(StoreCase):
    """The claim in `store.write` is that the read, the decision and the
    insert are ONE step. Every case above is single-threaded and would
    stay green if the decision moved outside the transaction — so the
    claim was untested until this class existed.

    Two connections, both holding version 1, both writing. Exactly one may
    win: the other has to be told to look again, or a device's state was
    silently thrown away."""

    def test_exactly_one_of_two_concurrent_writers_wins(self):
        import threading

        self.put(b"a" * 100)

        results = []
        barrier = threading.Barrier(2)

        def writer(payload):
            store = Store(self.path, keep=3)
            try:
                barrier.wait(timeout=10)
                decision, etag = store.write("the-owner", "stands", payload, 1, if_match="1")
                results.append((decision.status, etag))
            finally:
                store.close()

        threads = [threading.Thread(target=writer, args=(bytes([c]) * 100,))
                   for c in (b"b"[0], b"c"[0])]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=20)

        self.assertEqual(len(results), 2, "a writer did not finish")
        won = [r for r in results if r[0] == WRITTEN]
        lost = [r for r in results if r[0] == STALE]
        self.assertEqual(len(won), 1, f"not exactly one winner: {results}")
        self.assertEqual(len(lost), 1, f"the loser was not told to look again: {results}")
        # And the store carries the winner's version, not a mixture.
        self.assertEqual(self.store.versions("the-owner", "stands"), [1, 2])


class VersionsRotate(StoreCase):
    def test_only_the_last_few_survive(self):
        etag = None
        for n in range(6):
            _, etag = self.put(bytes([65 + n]) * 100, if_match=etag)
        # keep=3
        self.assertEqual(self.store.versions("the-owner", "stands"), [4, 5, 6])

    def test_the_newest_is_still_the_one_that_reads_back(self):
        etag = None
        for n in range(6):
            _, etag = self.put(bytes([65 + n]) * 100, if_match=etag)
        self.assertEqual(self.store.current("the-owner", "stands")[0], b"F" * 100)

    def test_rotation_does_not_reach_into_another_document(self):
        etag = None
        for n in range(6):
            _, etag = self.put(bytes([65 + n]) * 100, if_match=etag)
        self.store.write("the-owner", "playlists", b"kept", 1)
        self.assertEqual(self.store.versions("the-owner", "playlists"), [1])


class TheRestoreRehearsalHasSomethingToCompare(StoreCase):
    def test_sizes_name_every_stored_version(self):
        self.put(b"x" * 10)
        self.put(b"y" * 20, if_match="1")
        self.store.write("the-owner", "stats", b"z" * 30, 1, scope="dev-a")
        sizes = self.store.sizes()
        self.assertEqual(sizes["the-owner/stands//1"], 10)
        self.assertEqual(sizes["the-owner/stands//2"], 20)
        self.assertEqual(sizes["the-owner/stats/dev-a/1"], 30)

    def test_an_empty_store_hands_back_nothing_to_compare(self):
        # And `restore_verdict` calls that "not measured" rather than a
        # pass — the two halves have to meet here.
        self.assertEqual(self.store.sizes(), {})


class AccountsAndTokens(StoreCase):
    def test_a_token_comes_back_for_the_right_secret(self):
        self.store.create_account("the-owner", "a passphrase with some length")
        token = self.store.issue_token("the-owner", "a passphrase with some length", "phone")
        self.assertTrue(token)
        self.assertEqual(self.store.owner_of_token(token_digest(token)), "the-owner")

    def test_a_wrong_secret_gets_nothing(self):
        self.store.create_account("the-owner", "a passphrase with some length")
        self.assertIsNone(self.store.issue_token("the-owner", "a passphrase with some lengt"))

    def test_an_account_that_is_not_here_gets_nothing(self):
        self.assertIsNone(self.store.issue_token("nobody", "whatever"))

    def test_an_account_is_never_overwritten_by_accident(self):
        # Re-creating one would replace the secret and lock the person out
        # of data they still own.
        self.store.create_account("the-owner", "a passphrase with some length")
        with self.assertRaises(ValueError):
            self.store.create_account("the-owner", "a different passphrase")
        self.assertTrue(self.store.issue_token("the-owner", "a passphrase with some length"))

    def test_the_stored_secret_is_not_the_secret(self):
        self.store.create_account("the-owner", "hunter2 and then some more")
        row = self.store.db.execute("SELECT secret FROM accounts WHERE owner='the-owner'").fetchone()
        self.assertNotIn("hunter2", row[0])
        self.assertTrue(row[0].startswith("scrypt$"))

    def test_the_stored_token_is_not_the_token(self):
        # A store that held live credentials would hand them out the
        # moment it leaked, and a backup would carry them further.
        self.store.create_account("the-owner", "a passphrase with some length")
        token = self.store.issue_token("the-owner", "a passphrase with some length")
        rows = [r[0] for r in self.store.db.execute("SELECT digest FROM tokens")]
        self.assertNotIn(token, rows)
        self.assertIn(token_digest(token), rows)

    def test_two_devices_get_two_tokens_that_both_work(self):
        self.store.create_account("the-owner", "a passphrase with some length")
        phone = self.store.issue_token("the-owner", "a passphrase with some length", "phone")
        tablet = self.store.issue_token("the-owner", "a passphrase with some length", "tablet")
        self.assertNotEqual(phone, tablet)
        self.assertEqual(self.store.owner_of_token(token_digest(phone)), "the-owner")
        self.assertEqual(self.store.owner_of_token(token_digest(tablet)), "the-owner")

    def test_revoking_one_device_leaves_the_other_alone(self):
        self.store.create_account("the-owner", "a passphrase with some length")
        phone = self.store.issue_token("the-owner", "a passphrase with some length", "phone")
        tablet = self.store.issue_token("the-owner", "a passphrase with some length", "tablet")
        self.store.revoke_token(token_digest(phone))
        self.assertIsNone(self.store.owner_of_token(token_digest(phone)))
        self.assertEqual(self.store.owner_of_token(token_digest(tablet)), "the-owner")

    def test_an_unknown_account_costs_what_a_known_one_costs(self):
        # Not a timing measurement, which would be flaky. It pins the
        # CONSTRUCTION: a request for an account that is not here must
        # still run the slow hash, or the difference in how long a refusal
        # takes says who has an account here.
        import time as clock

        self.store.create_account("the-owner", "a passphrase with some length")
        started = clock.perf_counter()
        self.store.issue_token("the-owner", "wrong")
        known = clock.perf_counter() - started

        started = clock.perf_counter()
        self.store.issue_token("nobody-at-all", "wrong")
        unknown = clock.perf_counter() - started

        # A whole order of magnitude apart would mean one path skipped the
        # hash entirely. Deliberately loose: this is a construction check,
        # not a stopwatch.
        self.assertGreater(unknown, known / 10)


class ListingTheScopesOfAKind(StoreCase):
    """A device that joins knows its own scope and none of the others."""

    def test_every_scope_is_listed_once_at_its_newest_version(self):
        self.store.write("the-owner", "claim", b"phone-1", 1, scope="dev-a")
        self.store.write("the-owner", "claim", b"phone-2", 1, scope="dev-a", if_match="1")
        self.store.write("the-owner", "claim", b"tablet", 1, scope="dev-b")
        self.assertEqual(self.store.scopes("the-owner", "claim"),
                         [("dev-a", "2", 1), ("dev-b", "1", 1)])

    def test_the_format_listed_is_the_newest_versions(self):
        self.store.write("the-owner", "claim", b"old", 1, scope="dev-a")
        self.store.write("the-owner", "claim", b"new", 2, scope="dev-a", if_match="1")
        self.assertEqual(self.store.scopes("the-owner", "claim"), [("dev-a", "2", 2)])

    def test_a_kind_nobody_wrote_lists_nothing(self):
        self.assertEqual(self.store.scopes("the-owner", "claim"), [])

    def test_another_owners_scopes_are_not_listed(self):
        self.store.write("the-owner", "claim", b"mine", 1, scope="dev-a")
        self.store.write("someone", "claim", b"theirs", 1, scope="dev-z")
        self.assertEqual([s for s, _, _ in self.store.scopes("the-owner", "claim")], ["dev-a"])

    def test_another_kinds_scopes_are_not_listed(self):
        self.store.write("the-owner", "claim", b"a claim", 1, scope="dev-a")
        self.store.write("the-owner", "stats", b"some stats", 1, scope="dev-b")
        self.assertEqual([s for s, _, _ in self.store.scopes("the-owner", "claim")], ["dev-a"])


class ARolledBackServiceStops(StoreCase):
    def test_a_store_from_a_newer_service_refuses_to_open(self):
        self.store.close()
        db = sqlite3.connect(self.path)
        db.execute("UPDATE meta SET value=? WHERE key='schema'", (str(SCHEMA + 1),))
        db.commit()
        db.close()
        with self.assertRaises(StoreAheadOfService):
            Store(self.path)
        # Re-open at the right schema so tearDown has something to close.
        db = sqlite3.connect(self.path)
        db.execute("UPDATE meta SET value=? WHERE key='schema'", (str(SCHEMA),))
        db.commit()
        db.close()
        self.store = Store(self.path)

    def test_a_store_at_the_same_schema_opens_again(self):
        self.put(b"x" * 10)
        self.store.close()
        self.store = Store(self.path)
        self.assertEqual(self.store.current("the-owner", "stands")[0], b"x" * 10)


if __name__ == "__main__":
    unittest.main()
