# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""Reading a request path, without knowing what any of it means.

The service checks the SHAPE of a kind and a scope, never the membership.
A list of the five kinds it knows would refuse junk, but it would also
make "add a sixth kind" a service update — and the requirement is that the
service understands as little as possible, and that format changes stay
additive. Checking that a name is a short, plain identifier refuses a
client bug without the service ever learning what a listening stand is.

Pure, so that the shape rules can be argued with in a test rather than
discovered in a log.
"""

import re

# Short, lowercase, no punctuation but a dash. Long enough for the names we
# have, short enough that nothing hides in one.
NAME = re.compile(r"[a-z][a-z0-9-]{0,31}\Z")
# A scope is a device id today, so it may carry more shapes, and it may be
# absent. It still may not be long enough to be a payload.
SCOPE = re.compile(r"[A-Za-z0-9._:-]{0,64}\Z")

VERSION = "v1"


def parse_document_path(path):
    """`/v1/doc/<kind>` to `kind`, or None when the path is not one.

    Returns None rather than raising: an unmatched path is a 404, which is
    an ordinary answer, not an error.
    """
    parts = [p for p in path.split("/") if p]
    if len(parts) != 3 or parts[0] != VERSION or parts[1] != "doc":
        return None
    kind = parts[2]
    return kind if NAME.match(kind) else None


def parse_listing_path(path):
    """`/v1/docs/<kind>` to `kind`, or None when the path is not one.

    The listing exists for the kinds that keep one document PER DEVICE: a
    device that joins knows its own scope and none of the others, and the
    announcement only names a scope once it has been written to. The
    listing hands back names and versions, never bodies, so the service
    still learns nothing about what it holds.
    """
    parts = [p for p in path.split("/") if p]
    if len(parts) != 3 or parts[0] != VERSION or parts[1] != "docs":
        return None
    kind = parts[2]
    return kind if NAME.match(kind) else None


def valid_scope(scope):
    """Whether a scope may be used as an address. The empty scope is the
    ordinary case: a document that is not per-device has one."""
    return bool(SCOPE.match(scope or ""))
