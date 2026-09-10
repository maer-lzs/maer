# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The verdict on a rehearsed restore: did the backup actually come back?

"A backup that was never played back is none" (the operator's rule card, line 1:
"the way back before the way there"; twice paid for in this project). So
the backup command (`service/rehearsal.py`) opens its own copy in a
throwaway store in the same run and asks this unit whether it fits; the
operator schedules the command and alarms on the exit code.

The unit has THREE outcomes, and the third is the point. A rehearsal that
could not run is NOT a passing rehearsal — that is the generator lesson in
its purest form: a failure that looks like a measurement. Anything that
reports two outcomes will one day report "fits" for a rehearsal that never
happened.

The comparison is on sizes per document id, not on content: the service
does not read what it holds (it "understands as little as possible"), and a
document that comes back with the right id and the right length is as far
as a byte store can honestly testify.
"""

from dataclasses import dataclass

FITS = "fits"
DIFFERS = "differs"
NOT_MEASURED = "not_measured"


@dataclass(frozen=True)
class RestoreVerdict:
    """One of the three outcomes and the sentence that explains it."""

    outcome: str
    reason: str

    @property
    def passed(self):
        """Only `FITS` passes. `NOT_MEASURED` is not a pass, and reading
        this property is the one place that could be tempted to think so."""
        return self.outcome == FITS


def restore_verdict(backed_up, read_back, error=None):
    """Judge one rehearsal.

    `backed_up` and `read_back` map document id to byte length: what the
    backup claimed to hold, and what came out of the throwaway store.
    `error` is the text of whatever stopped the rehearsal, or None.
    """
    if error:
        return RestoreVerdict(NOT_MEASURED, f"not measured, the rehearsal stopped: {error}")

    if backed_up is None or read_back is None:
        return RestoreVerdict(NOT_MEASURED, "not measured, the rehearsal handed back nothing to compare")

    # A rehearsal on an empty backup compares nothing with nothing and
    # would come out green. That is the failure that looks like a
    # measurement, so it gets its own answer.
    if not backed_up:
        return RestoreVerdict(NOT_MEASURED, "not measured, the backup held no documents")

    missing = sorted(set(backed_up) - set(read_back))
    if missing:
        return RestoreVerdict(DIFFERS, f"{len(missing)} of {len(backed_up)} documents did not come "
                                       f"back: {', '.join(missing[:5])}")

    extra = sorted(set(read_back) - set(backed_up))
    if extra:
        return RestoreVerdict(DIFFERS, f"{len(extra)} documents came back that were not backed up: "
                                       f"{', '.join(extra[:5])}")

    wrong = sorted(k for k in backed_up if backed_up[k] != read_back[k])
    if wrong:
        first = wrong[0]
        return RestoreVerdict(DIFFERS, f"{len(wrong)} of {len(backed_up)} documents came back at a "
                                       f"different size, first {first}: {backed_up[first]} bytes "
                                       f"out, {read_back[first]} bytes back")

    total = sum(backed_up.values())
    return RestoreVerdict(FITS, f"{len(backed_up)} documents, {total} bytes, came back unchanged")
