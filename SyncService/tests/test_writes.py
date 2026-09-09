# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""One write, three gates, and the order they are asked in."""

import unittest

from core.writes import REFUSED, STALE, WRITTEN, decide


def stored(bytes_=1000, format_=2, etag="v7"):
    return {"stored_bytes": bytes_, "stored_format": format_, "stored_etag": etag}


class AWriteThatGoesThrough(unittest.TestCase):
    def test_the_current_version_at_the_current_format(self):
        d = decide(**stored(), incoming_bytes=1200, writer_format=2, if_match="v7")
        self.assertEqual(d.status, WRITTEN)
        self.assertTrue(d.accepted)

    def test_the_first_write_of_a_document_names_no_version(self):
        d = decide(stored_bytes=None, stored_format=None, stored_etag=None,
                   incoming_bytes=500, writer_format=1)
        self.assertEqual(d.status, WRITTEN)


class TheStaleWriterIsToldToLookAgain(unittest.TestCase):
    """The CAS loop is the only thing standing between two devices and a
    lost update, because no transport merges for us."""

    def test_a_wrong_version_is_stale(self):
        d = decide(**stored(), incoming_bytes=1200, writer_format=2, if_match="v3")
        self.assertEqual(d.status, STALE)
        self.assertIn("v3", d.reason)

    def test_naming_no_version_at_all_is_stale_too(self):
        # Silence is not a claim to be current. This is the blind
        # overwrite iCloud cannot refuse, and the one thing a service of
        # our own can.
        d = decide(**stored(), incoming_bytes=1200, writer_format=2, if_match=None)
        self.assertEqual(d.status, STALE)
        self.assertIn("named no version", d.reason)

    def test_a_version_for_a_document_that_is_not_there_is_stale(self):
        d = decide(stored_bytes=None, stored_format=None, stored_etag=None,
                   incoming_bytes=500, writer_format=1, if_match="v9")
        self.assertEqual(d.status, STALE)


class TheOrderOfTheGates(unittest.TestCase):
    """Each case sets up a write that FAILS TWO gates at once and pins
    which answer comes back. Without these, reordering the checks would
    change what clients are told and nothing would tear."""

    def test_stale_beats_a_bad_format(self):
        # Told "read again" rather than "your build is too old": the
        # client's next step is the same either way, and re-reading is
        # what actually resolves it.
        d = decide(**stored(format_=5), incoming_bytes=1200, writer_format=1, if_match="v3")
        self.assertEqual(d.status, STALE)

    def test_stale_beats_a_collapse(self):
        # The important one. A client on an old version often has a
        # SMALLER state — that is what being behind looks like. Telling it
        # "too small" would send it to fix the wrong thing.
        d = decide(**stored(), incoming_bytes=1, writer_format=2, if_match="v3")
        self.assertEqual(d.status, STALE)
        self.assertNotIn("shrank", d.reason)

    def test_a_bad_format_beats_a_collapse(self):
        # An older build must hear that it is an older build. Its state
        # being small is a consequence, not the cause.
        d = decide(**stored(format_=5), incoming_bytes=1, writer_format=2, if_match="v7")
        self.assertEqual(d.status, REFUSED)
        self.assertIn("format", d.reason)
        self.assertNotIn("shrank", d.reason)

    def test_a_collapse_is_only_reported_once_nothing_else_is_wrong(self):
        d = decide(**stored(), incoming_bytes=1, writer_format=2, if_match="v7")
        self.assertEqual(d.status, REFUSED)
        self.assertIn("shrank", d.reason)


class TheGatesStillWorkThroughThisDoor(unittest.TestCase):
    """The composition must not quietly lose a gate. If `decide` stopped
    calling one of them, everything above could still pass."""

    def test_an_empty_state_over_a_full_one_is_refused(self):
        d = decide(**stored(), incoming_bytes=0, writer_format=2, if_match="v7")
        self.assertEqual(d.status, REFUSED)
        self.assertIn("empty", d.reason)

    def test_an_older_writer_is_refused(self):
        d = decide(**stored(format_=5), incoming_bytes=1200, writer_format=4, if_match="v7")
        self.assertEqual(d.status, REFUSED)
        self.assertIn("drop", d.reason)

    def test_a_declared_shrink_passes_all_three(self):
        d = decide(**stored(), incoming_bytes=1, writer_format=2, if_match="v7",
                   declared_shrink=True)
        self.assertEqual(d.status, WRITTEN)

    def test_the_floor_reaches_through(self):
        d = decide(**stored(), incoming_bytes=400, writer_format=2, if_match="v7",
                   shrink_floor=0.1)
        self.assertEqual(d.status, WRITTEN)


class NoDecisionIsSilent(unittest.TestCase):
    def test_every_answer_carries_a_sentence(self):
        cases = [
            dict(**stored(), incoming_bytes=1200, writer_format=2, if_match="v7"),
            dict(**stored(), incoming_bytes=1200, writer_format=2, if_match="v3"),
            dict(**stored(), incoming_bytes=1200, writer_format=2),
            dict(**stored(format_=5), incoming_bytes=1200, writer_format=1, if_match="v7"),
            dict(**stored(), incoming_bytes=0, writer_format=2, if_match="v7"),
            dict(stored_bytes=None, stored_format=None, stored_etag=None,
                 incoming_bytes=5, writer_format=1),
        ]
        for case in cases:
            self.assertTrue(decide(**case).reason.strip(), f"silent decision for {case}")


if __name__ == "__main__":
    unittest.main()
