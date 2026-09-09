# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""Where the documents live: SQLite, one row per version.

SQLite because it is the most boring thing that does the job, ships with
the language, needs no second process to operate, and makes a backup a
file copy. The selection criteria in the requirements read like a
description of it: few transitive dependencies (none), longevity over
modernity, small enough to understand.

One row per version is the whole of the version rotation: the current
document is the highest version, the older ones are the rollback, and
dropping the oldest is a DELETE. There is no separate backup construction
because there does not need to be one.

The one thing worth reading closely is `write`. The decision that guards a
write compares against what is stored, so if it were made outside the
transaction, two devices could both read version 7, both be told they are
current, and the second would overwrite the first — the lost update the
whole compare-and-set exists to prevent. So the read, the decision and the
insert happen inside ONE `BEGIN IMMEDIATE`, and `decide` is called from in
there.
"""

import sqlite3
import time

from core.formats import serve_verdict
from core.versions import rotate
from core.writes import decide

# The layout of THIS file's tables. Bumped when the tables change, never
# when a document's format changes — they are different numbers with
# different jobs (see `core/formats.py`).
SCHEMA = 1

# How many versions of a document survive. Enough to roll back past a bad
# release without holding a history nobody asked for.
DEFAULT_KEEP = 10


class StoreAheadOfService(Exception):
    """The store was written by a newer service. A rolled-back service
    stops here instead of migrating backwards."""


class Store:
    def __init__(self, path, keep=DEFAULT_KEEP, shrink_floor=None):
        self.keep = keep
        self.shrink_floor = shrink_floor
        self.db = sqlite3.connect(path, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self._lay_out()

    def _lay_out(self):
        self.db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
        row = self.db.execute("SELECT value FROM meta WHERE key='schema'").fetchone()
        found = int(row[0]) if row else None

        verdict = serve_verdict(store_schema=found, service_schema=SCHEMA)
        if not verdict.accepted:
            raise StoreAheadOfService(verdict.reason)

        self.db.execute("""
            CREATE TABLE IF NOT EXISTS documents (
                owner      TEXT    NOT NULL,
                kind       TEXT    NOT NULL,
                scope      TEXT    NOT NULL DEFAULT '',
                version    INTEGER NOT NULL,
                body       BLOB    NOT NULL,
                format     INTEGER NOT NULL,
                written_at REAL    NOT NULL,
                PRIMARY KEY (owner, kind, scope, version)
            )""")
        if found is None:
            self.db.execute("INSERT INTO meta (key, value) VALUES ('schema', ?)", (str(SCHEMA),))

    # MARK: - Reading

    def current(self, owner, kind, scope=""):
        """The newest version of a document as `(body, format, etag)`, or
        None. The etag is the version number: it is already unique per
        document and already ordered, so inventing a hash beside it would
        be a second truth to keep in step."""
        row = self.db.execute(
            "SELECT body, format, version FROM documents "
            "WHERE owner=? AND kind=? AND scope=? ORDER BY version DESC LIMIT 1",
            (owner, kind, scope)).fetchone()
        if row is None:
            return None
        return row[0], row[1], str(row[2])

    def versions(self, owner, kind, scope=""):
        """Every stored version, oldest first — the rollback material."""
        return [r[0] for r in self.db.execute(
            "SELECT version FROM documents WHERE owner=? AND kind=? AND scope=? "
            "ORDER BY version ASC", (owner, kind, scope))]

    def sizes(self):
        """Every document's byte length by id, for the restore rehearsal.
        Sizes, not bodies: the rehearsal compares what a byte store can
        honestly testify to, and holding every body in memory to do it
        would be the one operation that scales with the store."""
        out = {}
        for owner, kind, scope, version, length in self.db.execute(
                "SELECT owner, kind, scope, version, length(body) FROM documents"):
            out[f"{owner}/{kind}/{scope}/{version}"] = length
        return out

    # MARK: - Writing

    def write(self, owner, kind, body, writer_format, scope="",
              if_match=None, declared_shrink=False):
        """Store `body` if the gates let it. Returns the `WriteDecision`
        and, when it was written, the new etag.

        Everything below happens under `BEGIN IMMEDIATE`: the read the
        decision is made against and the insert that follows it are one
        step, or the compare-and-set is a story we tell.
        """
        self.db.execute("BEGIN IMMEDIATE")
        try:
            held = self.current(owner, kind, scope)
            stored_bytes = len(held[0]) if held else None
            stored_format = held[1] if held else None
            stored_etag = held[2] if held else None

            kwargs = dict(stored_bytes=stored_bytes, stored_format=stored_format,
                          stored_etag=stored_etag, incoming_bytes=len(body),
                          writer_format=writer_format, if_match=if_match,
                          declared_shrink=declared_shrink)
            if self.shrink_floor is not None:
                kwargs["shrink_floor"] = self.shrink_floor
            decision = decide(**kwargs)

            if not decision.accepted:
                self.db.execute("ROLLBACK")
                return decision, None

            version = (int(stored_etag) + 1) if stored_etag else 1
            self.db.execute(
                "INSERT INTO documents (owner, kind, scope, version, body, format, written_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (owner, kind, scope, version, body, writer_format, time.time()))

            _, dropped = rotate(self.versions(owner, kind, scope), self.keep)
            for old in dropped:
                self.db.execute(
                    "DELETE FROM documents WHERE owner=? AND kind=? AND scope=? AND version=?",
                    (owner, kind, scope, old))

            self.db.execute("COMMIT")
            return decision, str(version)
        except Exception:
            self.db.execute("ROLLBACK")
            raise

    def close(self):
        self.db.close()
