# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The gate that keeps the promise "if it eats data, we are to blame"."""

import unittest

from core.admission import DEFAULT_SHRINK_FLOOR, admit


class TheEmptyWriteOverAFullState(unittest.TestCase):
    """The case we have actually lost data to, three times in this project:
    a valid, empty answer written over a full stock, reported as success."""

    def test_an_empty_state_never_replaces_a_full_one(self):
        v = admit(stored_bytes=325_000, incoming_bytes=0)
        self.assertFalse(v.accepted)
        # The refusal says what it refused, or nobody can tell a defended
        # store from a broken client.
        self.assertIn("325000", v.reason)
        # And it says WHICH rule refused. A red probe that removed the
        # empty branch stayed green: zero is below every floor, so the
        # shrink branch caught the same input with a vaguer sentence and
        # nothing tore. The known loss case gets its own words, and this
        # line is what holds them.
        self.assertIn("empty", v.reason)

    def test_the_shrink_refusal_does_not_borrow_the_empty_words(self):
        # The other half of the same test: if either branch could answer
        # for the other, both sentences would be decoration.
        v = admit(stored_bytes=1000, incoming_bytes=100)
        self.assertFalse(v.accepted)
        self.assertNotIn("empty", v.reason)
        self.assertIn("shrank", v.reason)

    def test_the_client_may_say_it_meant_it(self):
        v = admit(stored_bytes=325_000, incoming_bytes=0, declared_shrink=True)
        self.assertTrue(v.accepted)
        self.assertIn("declared", v.reason)
        self.assertIn("empty", v.reason)

    def test_an_empty_state_over_an_empty_one_loses_nothing(self):
        self.assertTrue(admit(stored_bytes=0, incoming_bytes=0).accepted)

    def test_the_first_state_is_always_taken(self):
        # A fresh install that could not write its first state would be a
        # gate that defends an empty store against its only user.
        v = admit(stored_bytes=None, incoming_bytes=0)
        self.assertTrue(v.accepted)
        self.assertTrue(admit(stored_bytes=None, incoming_bytes=325_000).accepted)


class TheCollapseShortOfEmpty(unittest.TestCase):
    """The second shape: not empty, but a fraction of what was there."""

    def test_a_state_below_the_floor_is_refused(self):
        v = admit(stored_bytes=1000, incoming_bytes=400)
        self.assertFalse(v.accepted)
        self.assertIn("40%", v.reason)

    def test_a_state_at_the_floor_is_taken(self):
        # Exactly at the floor is not below it. Named, so that moving the
        # comparison by one step has to change this line.
        self.assertTrue(admit(stored_bytes=1000, incoming_bytes=500).accepted)

    def test_a_declared_shrink_passes_and_still_says_what_happened(self):
        v = admit(stored_bytes=1000, incoming_bytes=10, declared_shrink=True)
        self.assertTrue(v.accepted)
        self.assertIn("1%", v.reason)

    def test_the_floor_is_a_parameter_not_a_law_of_nature(self):
        # A deployment whose clients prune hard sets it lower; one that
        # never prunes sets it higher. The number is not the rule.
        self.assertTrue(admit(stored_bytes=1000, incoming_bytes=400, shrink_floor=0.1).accepted)
        self.assertFalse(admit(stored_bytes=1000, incoming_bytes=900, shrink_floor=0.95).accepted)

    def test_growth_and_standing_still_pass(self):
        self.assertTrue(admit(stored_bytes=1000, incoming_bytes=1000).accepted)
        self.assertTrue(admit(stored_bytes=1000, incoming_bytes=50_000).accepted)


class TheGateRefusesNonsenseLoudly(unittest.TestCase):
    """A gate handed a bad argument raises. It does not pick a reading and
    carry on: a size that is not a size means the caller is broken, and a
    verdict would hide that behind an answer."""

    def test_a_missing_or_negative_size_raises(self):
        with self.assertRaises(ValueError):
            admit(stored_bytes=10, incoming_bytes=None)
        with self.assertRaises(ValueError):
            admit(stored_bytes=10, incoming_bytes=-1)
        with self.assertRaises(ValueError):
            admit(stored_bytes=-5, incoming_bytes=10)

    def test_a_floor_outside_the_range_raises(self):
        with self.assertRaises(ValueError):
            admit(stored_bytes=10, incoming_bytes=10, shrink_floor=0)
        with self.assertRaises(ValueError):
            admit(stored_bytes=10, incoming_bytes=10, shrink_floor=1.5)


class EveryVerdictCarriesItsSentence(unittest.TestCase):
    """No verdict is silent — not even the accepting ones. A store that
    took a write it should have questioned leaves a line either way."""

    def test_no_reason_is_empty(self):
        cases = [
            (None, 100, False), (0, 100, False), (100, 0, False), (100, 0, True),
            (1000, 400, False), (1000, 400, True), (1000, 2000, False),
        ]
        for stored, incoming, declared in cases:
            v = admit(stored_bytes=stored, incoming_bytes=incoming, declared_shrink=declared)
            self.assertTrue(v.reason.strip(), f"silent verdict for {stored} -> {incoming}")

    def test_the_default_floor_is_the_one_the_tests_assume(self):
        # Without this the floor cases above would quietly measure whatever
        # the constant happens to be.
        self.assertEqual(DEFAULT_SHRINK_FLOOR, 0.5)


if __name__ == "__main__":
    unittest.main()
