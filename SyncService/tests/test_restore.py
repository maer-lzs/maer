# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The three outcomes of a rehearsed restore, and why the third exists."""

import unittest

from core.restore import DIFFERS, FITS, NOT_MEASURED, restore_verdict


class ARestoreThatFits(unittest.TestCase):
    def test_the_same_documents_at_the_same_sizes_pass(self):
        v = restore_verdict({"a": 100, "b": 250}, {"a": 100, "b": 250})
        self.assertEqual(v.outcome, FITS)
        self.assertTrue(v.passed)
        self.assertIn("350 bytes", v.reason)


class ARestoreThatDiffers(unittest.TestCase):
    def test_a_document_that_did_not_come_back(self):
        v = restore_verdict({"a": 100, "b": 250}, {"a": 100})
        self.assertEqual(v.outcome, DIFFERS)
        self.assertFalse(v.passed)
        self.assertIn("b", v.reason)

    def test_a_document_that_came_back_uninvited(self):
        # A throwaway store that was not thrown away is a rehearsal
        # measuring the leftovers of the last one.
        v = restore_verdict({"a": 100}, {"a": 100, "stale": 7})
        self.assertEqual(v.outcome, DIFFERS)
        self.assertIn("stale", v.reason)

    def test_a_document_that_came_back_the_wrong_size(self):
        v = restore_verdict({"a": 100}, {"a": 99})
        self.assertEqual(v.outcome, DIFFERS)
        self.assertIn("100 bytes out", v.reason)
        self.assertIn("99 bytes back", v.reason)


class ARestoreThatWasNotMeasured(unittest.TestCase):
    """The whole reason this unit has three outcomes. A rehearsal that did
    not run is not a passing rehearsal — that failure looks exactly like a
    measurement, and it is the one the generators shipped for weeks."""

    def test_a_rehearsal_that_stopped_is_not_a_pass(self):
        v = restore_verdict({"a": 100}, None, error="throwaway store unreachable")
        self.assertEqual(v.outcome, NOT_MEASURED)
        self.assertFalse(v.passed)
        self.assertIn("unreachable", v.reason)

    def test_an_error_wins_over_a_comparison_that_would_have_passed(self):
        # If the error branch came second, a rehearsal that failed AND
        # happened to hand back matching leftovers would report "fits".
        v = restore_verdict({"a": 100}, {"a": 100}, error="backup file truncated")
        self.assertEqual(v.outcome, NOT_MEASURED)

    def test_nothing_to_compare_is_not_a_pass(self):
        self.assertEqual(restore_verdict(None, {"a": 1}).outcome, NOT_MEASURED)
        self.assertEqual(restore_verdict({"a": 1}, None).outcome, NOT_MEASURED)

    def test_a_rehearsal_on_an_empty_backup_proves_nothing(self):
        # Nothing compared with nothing comes out equal. This is the false
        # green the unit exists to refuse.
        v = restore_verdict({}, {})
        self.assertEqual(v.outcome, NOT_MEASURED)
        self.assertFalse(v.passed)
        self.assertIn("no documents", v.reason)


class OnlyFitsPasses(unittest.TestCase):
    """`passed` is the property a scheduler will read at three in the
    morning. It must not be generous."""

    def test_every_outcome_maps_the_way_its_name_says(self):
        self.assertTrue(restore_verdict({"a": 1}, {"a": 1}).passed)
        self.assertFalse(restore_verdict({"a": 1}, {"a": 2}).passed)
        self.assertFalse(restore_verdict({}, {}).passed)
        self.assertFalse(restore_verdict({"a": 1}, None, error="x").passed)


if __name__ == "__main__":
    unittest.main()
