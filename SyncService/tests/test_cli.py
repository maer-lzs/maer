# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The operator commands. `--help` prints help and never starts the server;
an account can be laid down and taken away again."""

import glob
import io
import os
import tempfile
import unittest
from contextlib import redirect_stdout

from service import __main__ as cli
from service.store import Store


class TheParserNeverServesByAccident(unittest.TestCase):
    def test_help_asks_to_print_and_exits_rather_than_serving(self):
        # argparse turns --help into a SystemExit(0) after printing; the
        # point is that it does NOT fall through to serve().
        with self.assertRaises(SystemExit) as caught:
            with redirect_stdout(io.StringIO()):
                cli.parser().parse_args(["--help"])
        self.assertEqual(caught.exception.code, 0)

    def test_no_command_is_serve(self):
        self.assertIsNone(cli.parser().parse_args([]).command)

    def test_the_commands_route_to_their_names(self):
        self.assertEqual(cli.parser().parse_args(["backup", "x.sqlite"]).command, "backup")
        self.assertEqual(cli.parser().parse_args(["account", "the-owner"]).command, "account")
        self.assertEqual(cli.parser().parse_args(["account-remove", "the-owner"]).command, "account-remove")

    def test_backup_without_a_path_is_refused_not_served(self):
        with self.assertRaises(SystemExit):
            with redirect_stdout(io.StringIO()):
                cli.parser().parse_args(["backup"])


class RemovingAnAccountThroughTheCommand(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "cli.sqlite")
        self._old = os.environ.get("MAER_SYNC_DB")
        os.environ["MAER_SYNC_DB"] = self.path

    def tearDown(self):
        if self._old is None:
            os.environ.pop("MAER_SYNC_DB", None)
        else:
            os.environ["MAER_SYNC_DB"] = self._old

    def test_account_remove_takes_the_account_away(self):
        store = Store(self.path)
        store.create_account("the-owner", "a passphrase with some length")
        store.write("the-owner", "stands", b"{}", 1)
        store.close()

        out = io.StringIO()
        with redirect_stdout(out):
            code = cli.main(["account-remove", "the-owner"])
        self.assertEqual(code, 0)
        self.assertIn("removed", out.getvalue())

        # A dated safety backup was made and verified before the removal, and
        # it carries the document the removal then dropped.
        backups = glob.glob(self.path + ".before-remove-the-owner-*.sqlite")
        self.assertEqual(len(backups), 1, "one dated safety backup beside the store")
        saved = Store(backups[0])
        try:
            self.assertIsNotNone(saved.current("the-owner", "stands"), "the backup holds what was removed")
        finally:
            saved.close()

        again = Store(self.path)
        try:
            self.assertIsNone(again.current("the-owner", "stands"))
        finally:
            again.close()

    def test_removing_an_absent_account_says_so_and_still_succeeds(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = cli.main(["account-remove", "nobody"])
        self.assertEqual(code, 0)
        self.assertIn("no account", out.getvalue())


if __name__ == "__main__":
    unittest.main()
