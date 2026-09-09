# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The two version numbers that make a rollback safe, kept apart."""

import unittest

from core.formats import serve_verdict, write_verdict


class AnOlderClientDoesNotOverwriteANewerDocument(unittest.TestCase):
    """The live case: a phone updates, a tablet stays behind, the tablet
    writes the pot in the older form. On iCloud nothing can stop that."""

    def test_an_older_writer_is_refused(self):
        v = write_verdict(stored_format=3, writer_format=2)
        self.assertFalse(v.accepted)
        self.assertIn("drop", v.reason)

    def test_the_same_format_writes(self):
        self.assertTrue(write_verdict(stored_format=3, writer_format=3).accepted)

    def test_a_newer_writer_writes(self):
        self.assertTrue(write_verdict(stored_format=3, writer_format=4).accepted)

    def test_the_first_document_has_nothing_to_be_older_than(self):
        self.assertTrue(write_verdict(stored_format=None, writer_format=1).accepted)

    def test_a_writer_without_a_format_raises(self):
        # Silently treating "no format given" as format 1 would let every
        # client that forgot the field overwrite everything.
        with self.assertRaises(ValueError):
            write_verdict(stored_format=3, writer_format=None)
        with self.assertRaises(ValueError):
            write_verdict(stored_format=3, writer_format=0)
        with self.assertRaises(ValueError):
            write_verdict(stored_format=0, writer_format=3)


class ARolledBackServiceDoesNotDamageItsStore(unittest.TestCase):
    """"Rollback before every update" is only a way back if the older
    service notices the newer store and stops."""

    def test_a_store_ahead_of_the_service_is_refused(self):
        v = serve_verdict(store_schema=5, service_schema=4)
        self.assertFalse(v.accepted)
        self.assertIn("backwards", v.reason)

    def test_a_store_at_or_below_the_service_opens(self):
        self.assertTrue(serve_verdict(store_schema=4, service_schema=4).accepted)
        self.assertTrue(serve_verdict(store_schema=3, service_schema=4).accepted)

    def test_an_empty_store_is_laid_out_at_the_running_schema(self):
        v = serve_verdict(store_schema=None, service_schema=4)
        self.assertTrue(v.accepted)
        self.assertIn("4", v.reason)

    def test_a_nonsense_schema_raises(self):
        with self.assertRaises(ValueError):
            serve_verdict(store_schema=4, service_schema=None)
        with self.assertRaises(ValueError):
            serve_verdict(store_schema=0, service_schema=4)


class TheTwoNumbersAreNotTheSameNumber(unittest.TestCase):
    """Conflating them would make a client's format bump look like a store
    migration, and every device would be locked out by an app update."""

    def test_a_document_format_far_ahead_says_nothing_about_serving(self):
        self.assertTrue(serve_verdict(store_schema=1, service_schema=1).accepted)
        self.assertFalse(write_verdict(stored_format=9, writer_format=1).accepted)

    def test_a_store_schema_far_ahead_says_nothing_about_writing(self):
        self.assertFalse(serve_verdict(store_schema=9, service_schema=1).accepted)
        self.assertTrue(write_verdict(stored_format=1, writer_format=1).accepted)


if __name__ == "__main__":
    unittest.main()
