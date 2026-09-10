# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The backup as a process, with its rehearsal built in.

`python3 -m service backup <copy.sqlite>` copies the live store and, in
the same run, opens the copy the way the service would after a restore
and compares what it holds with what the live store held. The verdict is
the exit code and a sentence, so the operator's schedule can alarm on it.

That is the whole point of doing both in one step: a backup that was
never opened is a file, not a backup. The comparison is on sizes per
document version, the one thing a byte store can honestly testify to.
"""

import os
import tempfile

from core.restore import restore_verdict

from .store import Store


def backup_and_rehearse(live, copy_path):
    """Copy `live` to `copy_path`, open the copy as a store, compare.

    The sizes of the live store are read right before the copy; a write
    that lands between the two shows as DIFFERS, and the sentence says
    which document. That is a rehearsal to repeat, not a false alarm to
    silence.
    """
    try:
        backed_up = live.sizes()
        live.backup(copy_path)
    except Exception as failure:
        return restore_verdict(None, None, error=f"the copy did not get written: {failure}")

    # The copy is opened in a throwaway directory, exactly as a restore
    # would open it, and it must pass the schema check like any store.
    with tempfile.TemporaryDirectory() as throwaway:
        restored = os.path.join(throwaway, "restored.sqlite")
        try:
            with open(copy_path, "rb") as source, open(restored, "wb") as target:
                target.write(source.read())
            store = Store(restored)
        except Exception as failure:
            return restore_verdict(backed_up, None, error=f"the copy did not open as a store: {failure}")
        try:
            read_back = store.sizes()
        finally:
            store.close()
    return restore_verdict(backed_up, read_back)
