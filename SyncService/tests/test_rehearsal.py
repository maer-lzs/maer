# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The backup as a process: the copy is opened and compared in the same
run, so a backup that was never played back cannot exist here."""

import os
import sqlite3
import tempfile
import unittest

from core.restore import DIFFERS, FITS, NOT_MEASURED
from service.rehearsal import backup_and_rehearse
from service.store import Store


class BackupCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.store = Store(os.path.join(self.dir, "live.sqlite"))
        self.copy = os.path.join(self.dir, "copy.sqlite")

    def tearDown(self):
        self.store.close()
        for name in os.listdir(self.dir):
            os.unlink(os.path.join(self.dir, name))
        os.rmdir(self.dir)


class ABackupThatComesBack(BackupCase):
    def test_every_version_of_every_document_is_in_the_copy(self):
        self.store.write("the-owner", "stands", b"a" * 100, 1)
        self.store.write("the-owner", "stands", b"b" * 120, 1, if_match="1")
        self.store.write("the-owner", "claim", b"phone", 1, scope="dev-a")
        verdict = backup_and_rehearse(self.store, self.copy)
        self.assertEqual(verdict.outcome, FITS, verdict.reason)
        self.assertTrue(verdict.passed)
        # The copy is a store the service would open after a restore.
        restored = Store(self.copy)
        try:
            self.assertEqual(restored.current("the-owner", "stands")[0], b"b" * 120)
            self.assertEqual(restored.current("the-owner", "claim", "dev-a")[0], b"phone")
        finally:
            restored.close()

    def test_the_accounts_travel_with_the_copy(self):
        self.store.create_account("the-owner", "a passphrase with some length")
        self.store.write("the-owner", "stands", b"a" * 100, 1)
        self.assertEqual(backup_and_rehearse(self.store, self.copy).outcome, FITS)
        restored = Store(self.copy)
        try:
            self.assertIsNotNone(restored.issue_token("the-owner", "a passphrase with some length"))
        finally:
            restored.close()


class ABackupThatCannotBeJudged(BackupCase):
    def test_an_empty_store_is_not_measured_not_green(self):
        verdict = backup_and_rehearse(self.store, self.copy)
        self.assertEqual(verdict.outcome, NOT_MEASURED)
        self.assertFalse(verdict.passed)

    def test_a_copy_that_cannot_be_written_is_not_measured_and_says_why(self):
        self.store.write("the-owner", "stands", b"a" * 100, 1)
        verdict = backup_and_rehearse(self.store, os.path.join(self.dir, "no", "such", "dir.sqlite"))
        self.assertEqual(verdict.outcome, NOT_MEASURED)
        self.assertIn("did not get written", verdict.reason)


class ALossyBackup(Store):
    """A backup mechanism that drops a document on the way: the class the
    rehearsal exists to catch. The verdict must come from reading the
    copy, not from reading the live store twice."""

    def backup(self, path):
        super().backup(path)
        db = sqlite3.connect(path)
        db.execute("DELETE FROM documents WHERE kind='claim'")
        db.commit()
        db.close()


class ABackupThatDiffers(unittest.TestCase):
    def test_a_copy_that_lost_a_document_on_the_way_differs(self):
        directory = tempfile.mkdtemp()
        store = ALossyBackup(os.path.join(directory, "live.sqlite"))
        try:
            store.write("the-owner", "stands", b"a" * 100, 1)
            store.write("the-owner", "claim", b"phone", 1, scope="dev-a")
            verdict = backup_and_rehearse(store, os.path.join(directory, "copy.sqlite"))
        finally:
            store.close()
            for name in os.listdir(directory):
                os.unlink(os.path.join(directory, name))
            os.rmdir(directory)
        self.assertEqual(verdict.outcome, DIFFERS, verdict.reason)
        self.assertFalse(verdict.passed)
        self.assertIn("claim", verdict.reason)


if __name__ == "__main__":
    unittest.main()
