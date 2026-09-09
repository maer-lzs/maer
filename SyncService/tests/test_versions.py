# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""Rotation: the construction that covers a broken update and a client that
wrote nonsense with the same few lines."""

import unittest

from core.versions import rotate


class RotationKeepsTheNewest(unittest.TestCase):
    def test_it_drops_the_oldest_first(self):
        kept, dropped = rotate(["v1", "v2", "v3", "v4", "v5"], keep=3)
        self.assertEqual(kept, ["v3", "v4", "v5"])
        self.assertEqual(dropped, ["v1", "v2"])

    def test_a_store_under_the_limit_loses_nothing(self):
        kept, dropped = rotate(["v1", "v2"], keep=5)
        self.assertEqual(kept, ["v1", "v2"])
        self.assertEqual(dropped, [])

    def test_exactly_at_the_limit_loses_nothing(self):
        kept, dropped = rotate(["v1", "v2", "v3"], keep=3)
        self.assertEqual(kept, ["v1", "v2", "v3"])
        self.assertEqual(dropped, [])

    def test_an_empty_store_stays_empty(self):
        self.assertEqual(rotate([], keep=3), ([], []))

    def test_keeping_one_keeps_the_newest_and_only_the_newest(self):
        kept, dropped = rotate(["v1", "v2", "v3"], keep=1)
        self.assertEqual(kept, ["v3"])
        self.assertEqual(dropped, ["v1", "v2"])


class RotationNeverEmptiesTheStore(unittest.TestCase):
    """Keeping zero versions would delete the state that was just written.
    That is a caller with a bug, and it hears about it."""

    def test_keeping_none_raises(self):
        with self.assertRaises(ValueError):
            rotate(["v1", "v2"], keep=0)
        with self.assertRaises(ValueError):
            rotate(["v1", "v2"], keep=-1)

    def test_it_raises_even_when_there_is_nothing_to_lose(self):
        # An empty store would make the bad argument harmless TODAY and
        # let it through to the day it is not.
        with self.assertRaises(ValueError):
            rotate([], keep=0)


class RotationDoesNotDisturbTheCaller(unittest.TestCase):
    def test_the_given_sequence_is_left_alone(self):
        given = ["v1", "v2", "v3", "v4"]
        rotate(given, keep=2)
        self.assertEqual(given, ["v1", "v2", "v3", "v4"])

    def test_it_takes_any_sequence_not_only_a_list(self):
        kept, dropped = rotate(("v1", "v2", "v3"), keep=2)
        self.assertEqual(kept, ["v2", "v3"])
        self.assertEqual(dropped, ["v1"])


if __name__ == "__main__":
    unittest.main()
