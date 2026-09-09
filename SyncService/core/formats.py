# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""What a version number is FOR: making a rollback safe.

The requirement chain is "rollback before every update", and it names its
own precondition: "format changes only additive, every version writes its
number with it. Otherwise the rollback is worthless, because the old
version cannot read the new data."

TWO numbers live here and they must not be confused:

- The DOCUMENT format is the client's. The service never parses a document,
  so it cannot lose a field itself — but it can stop a device that would.
  The case is real and lives today: a phone updates, a tablet stays on the
  old build, the tablet writes the pot in the older form and the fields the
  newer build added are gone. On iCloud nothing can stop that. Here
  something can, so it does.
- The STORE schema is the service's own. A service rolled back below the
  schema of the store it opens does not migrate backwards and does not
  guess: it refuses to serve and says so. A rollback that quietly damages
  the store is not a way back.

Both answers are verdicts with a sentence, like every other gate here: a
refusal that does not say why is the failure it was built to prevent.
"""

from .admission import Verdict


def write_verdict(stored_format, writer_format):
    """May a client at `writer_format` overwrite a document written at
    `stored_format`? `stored_format` is None when nothing is stored yet."""
    if writer_format is None or writer_format < 1:
        raise ValueError(f"a writer names its format: {writer_format!r}")
    if stored_format is not None and stored_format < 1:
        raise ValueError(f"a stored document names its format: {stored_format!r}")

    if stored_format is None:
        return Verdict(True, f"first state at format {writer_format}")
    if writer_format >= stored_format:
        return Verdict(True, f"format {writer_format} over {stored_format}")
    return Verdict(False, f"a client at format {writer_format} must not overwrite a document "
                          f"written at format {stored_format}: the newer form carries fields "
                          f"the older one would drop")


def serve_verdict(store_schema, service_schema):
    """May a service at `service_schema` open a store at `store_schema`?"""
    if service_schema is None or service_schema < 1:
        raise ValueError(f"the service names its schema: {service_schema!r}")
    if store_schema is None:
        return Verdict(True, f"empty store, laid out at schema {service_schema}")
    if store_schema < 1:
        raise ValueError(f"the store names its schema: {store_schema!r}")

    if store_schema <= service_schema:
        return Verdict(True, f"store at schema {store_schema}, service at {service_schema}")
    return Verdict(False, f"the store is at schema {store_schema} and this service only knows "
                          f"{service_schema}: a rolled-back service does not migrate backwards")
