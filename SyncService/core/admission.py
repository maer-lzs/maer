# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The one gate every write passes: may this state replace the stored one?

"If it eats data, we are to blame" (the owner, 24.08.). The loss case we
actually know is not a broken update — it is a device that writes an EMPTY
state at start-up, BEFORE it has loaded. Mär has fought that class twice
already ("unreadable is not empty", the `[0, now]` tombstone) and once more
in the generators, where a valid but empty answer wrote an empty table over
567 rows of real data and returned exit 0. The service inherits the lesson
instead of learning it a fourth time.

The gate looks at BYTES and nothing else. It does not parse a document:
every bit of meaning the service holds makes a later change more expensive
(requirement: "the service understands as little as possible"), and the
byte length already sees both shapes that lose data — the empty write and
the sudden collapse.

A refusal is never silent. Every verdict carries the sentence that explains
it, the caller logs it and answers with it. A gate that drops a write
without a word would be the very failure it exists to prevent.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Verdict:
    """Accepted or not, and always WHY — in one sentence fit for a log line
    and for the answer to the client."""

    accepted: bool
    reason: str


# How much of a state may vanish in one write before the gate wants the
# client to say it meant it. A CHOSEN default, not a measurement: half is
# the point where "the client pruned something" stops being a plausible
# reading of a single write. It is configurable per deployment because the
# honest number depends on pots we have not seen yet.
DEFAULT_SHRINK_FLOOR = 0.5


def admit(stored_bytes, incoming_bytes, declared_shrink=False,
          shrink_floor=DEFAULT_SHRINK_FLOOR):
    """Whether `incoming_bytes` may replace a stored state of `stored_bytes`.

    `stored_bytes` is None when nothing is stored yet. `declared_shrink` is
    the client saying "I meant to make this smaller" — a deliberate prune,
    a user who deleted their playlists. It turns a refusal into an accepted
    write that still names what happened, because the older versions stay
    either way and nothing is actually lost by keeping the gate strict.
    """
    if incoming_bytes is None or incoming_bytes < 0:
        raise ValueError(f"incoming size is not a size: {incoming_bytes!r}")
    if stored_bytes is not None and stored_bytes < 0:
        raise ValueError(f"stored size is not a size: {stored_bytes!r}")
    if not 0 < shrink_floor <= 1:
        raise ValueError(f"shrink floor outside (0, 1]: {shrink_floor!r}")

    # Nothing stored: there is no stock to lose, and refusing here would
    # mean a fresh install could never write its first state.
    if stored_bytes is None:
        return Verdict(True, f"first state, {incoming_bytes} bytes, nothing to lose")

    # An empty stock loses nothing either, whatever arrives.
    if stored_bytes == 0:
        return Verdict(True, f"stored state was empty, {incoming_bytes} bytes accepted")

    # THE case: empty over full. This is the start-up write, and it is
    # refused even when it is honestly meant, unless the client says so.
    if incoming_bytes == 0:
        if declared_shrink:
            return Verdict(True, f"empty state accepted, the client declared it "
                                 f"(was {stored_bytes} bytes)")
        return Verdict(False, f"an empty state never replaces a full one "
                              f"({stored_bytes} bytes stored)")

    share = incoming_bytes / stored_bytes
    if share < shrink_floor:
        if declared_shrink:
            return Verdict(True, f"shrink to {share:.0%} accepted, the client declared it "
                                 f"({stored_bytes} to {incoming_bytes} bytes)")
        return Verdict(False, f"state shrank to {share:.0%}, below the {shrink_floor:.0%} "
                              f"floor ({stored_bytes} to {incoming_bytes} bytes)")

    return Verdict(True, f"{incoming_bytes} bytes, {share:.0%} of the stored state")
