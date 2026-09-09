# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""Which stored versions of a state survive a write, and which go.

The requirement says "versioned states instead of a backup", and it says
why: ONE construction covers both losses we can name — a broken update and
a client that wrote nonsense — and it is at the same time what "restore
yesterday's state" is built on. A backup taken once a night covers neither
of those within the night.

Rotation is the whole of it: keep the newest N, drop the rest. The unit is
here and pure so the number of kept versions is a decision with a test
behind it, not a slice of SQL in a request handler.
"""


def rotate(version_ids, keep):
    """Split `version_ids` into what stays and what goes.

    `version_ids` are ordered oldest first — the order the store hands them
    back. Returns `(kept, dropped)`, both in that same order.
    """
    if keep < 1:
        # Keeping zero versions would delete the state that was just
        # written. A store that holds nothing is not a store, and the
        # caller that asked for it has a bug, not a preference.
        raise ValueError(f"a store keeps at least one version, asked for {keep}")

    ids = list(version_ids)
    if len(ids) <= keep:
        return ids, []
    cut = len(ids) - keep
    return ids[cut:], ids[:cut]
