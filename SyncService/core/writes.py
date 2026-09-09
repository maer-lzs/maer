# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The whole decision behind one write, in one place and with no I/O.

The gates beside this file each answer one question. Something has to ask
them in an order, and the ORDER is itself a decision that can lose data or
confuse a client, so it lives here with tests instead of in a request
handler where it would read like plumbing.

Why this order:

1. **The precondition first.** A client holding a stale version has to be
   told to re-read, merge and come back — that is the whole CAS loop. If a
   shrink refusal came first, the client would hear "your state is too
   small" when the truth is "you are looking at an old one", and it would
   fix the wrong thing. Measured on Nextcloud that this matters: a server
   that answers the wrong conflict makes the client treat a stale read as
   a content problem.
2. **The format next.** A client older than the document must not write,
   whatever the size, and it must hear that reason and not a size reason.
3. **The size last.** By now we know the writer is current and looking at
   the right version, so a collapse really is a collapse.

An accepted write returns 200 and a refused one returns a status the
client can act on. None of them returns silence.
"""

from dataclasses import dataclass

from .admission import DEFAULT_SHRINK_FLOOR, admit
from .formats import write_verdict

# The stored state is not what the client last saw. It re-reads, merges,
# and writes again — the loop every path needs, because no transport merges
# for us.
STALE = 412
# The client may not write this document at all in its present shape: too
# old a format, or a state that would eat the stored one.
REFUSED = 409
WRITTEN = 200


@dataclass(frozen=True)
class WriteDecision:
    """What the handler does next, and the sentence it says while doing it."""

    status: int
    reason: str

    @property
    def accepted(self):
        return self.status == WRITTEN


def decide(*, stored_bytes, stored_format, stored_etag, incoming_bytes,
           writer_format, if_match=None, declared_shrink=False,
           shrink_floor=DEFAULT_SHRINK_FLOOR):
    """Judge one write against what is stored.

    `stored_*` are all None when the document does not exist yet.
    `if_match` is the version the client believes it holds, or None when it
    did not say. A client that does not say is NOT treated as holding the
    current one — see below.
    """
    exists = stored_etag is not None

    if exists:
        if if_match is None:
            # Silence is not a claim to be current. A client that writes
            # over an existing document without naming the version it read
            # is the blind overwrite this service exists to prevent, and
            # it is exactly what iCloud cannot refuse.
            return WriteDecision(STALE, "this document exists and the write named no version; "
                                        "read it, merge, and write again naming what you read")
        if if_match != stored_etag:
            return WriteDecision(STALE, f"version {if_match} is not the stored one; "
                                        f"read it, merge, and write again")
    elif if_match is not None:
        # A client holding a version of a document that is not there lost a
        # race with a delete, or is talking to the wrong store. Either way
        # its assumption is wrong and it has to look again.
        return WriteDecision(STALE, f"no such document, but the write named version {if_match}")

    formats = write_verdict(stored_format=stored_format, writer_format=writer_format)
    if not formats.accepted:
        return WriteDecision(REFUSED, formats.reason)

    sizes = admit(stored_bytes=stored_bytes, incoming_bytes=incoming_bytes,
                  declared_shrink=declared_shrink, shrink_floor=shrink_floor)
    if not sizes.accepted:
        return WriteDecision(REFUSED, sizes.reason)

    return WriteDecision(WRITTEN, sizes.reason)
