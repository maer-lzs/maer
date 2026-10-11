#!/bin/bash
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply, see LICENSE-ADDITIONAL-TERMS
#
# The null run, a PROCEDURE step before any use of a generator, not a fence
# in the suite (a fence that reaches the network fails at the network).
#
#   tools/nulllauf.sh logo-data | wikidata-cores | weltsender
#
# The generator is run against the checked-in state, and the file it
# writes must come back byte for byte, except for its run date. If it does
# not, either the source moved or the generator did, and the generator is
# not used until that is understood; a run that "just" regenerates would
# otherwise carry an unnoticed change into the app as if it were the data.
#
# Exit 0: the null run holds. Exit 1: the file moved (git diff below).
# Exit 2: not measured (the target was dirty before the run, the generator
# itself did not measure, which is its own exit 2, or it ended in a way
# that is no run at all: a crash with a traceback, or an exit code that
# generator never gives for a run).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
case "${1:-}" in
  logo-data)
    TARGET=Sources/Models/RadioLogoData.swift
    RUN=(python3 tools/radio-logo-data/generate.py)
    RAN='0'
    IGNORE='^// .*Run date: ' ;;
  wikidata-cores)
    TARGET=Sources/Models/RadioWikidataCores.swift
    RUN=(python3 tools/radio-wikidata-cores/generate.py)
    # 1 is a run with a finding (an anchor without a hit, a country off the reference).
    RAN='0 1'
    IGNORE='^// .*Run date: ' ;;
  weltsender)
    TARGET=Sources/Models/RadioWorldServices.swift
    RUN=(python3 tools/radio-weltsender/generate.py)
    # 1 is a run in which single stations failed their check.
    RAN='0 1'
    IGNORE='' ;;
  *)
    echo "usage: tools/nulllauf.sh logo-data | wikidata-cores | weltsender" >&2
    exit 2 ;;
esac
# A dirty target before the run would make the diff say nothing about the
# generator; that is an abort, never a pass.
if ! git diff --quiet -- "$TARGET"; then
  echo "NOT MEASURED: $TARGET carries uncommitted changes; commit or discard them first" >&2
  exit 2
fi
errors=$(mktemp)
"${RUN[@]}" 2> >(tee "$errors" >&2)
rc=$?
wait
if [ "$rc" -eq 2 ]; then
  echo "NOT MEASURED: the generator did not measure (exit 2), the target is untouched by design" >&2
  rm -f "$errors"; exit 2
fi
# A crash leaves the target as it was and would read as a held null run.
if grep -q '^Traceback (most recent call last):' "$errors" || ! [[ " $RAN " == *" $rc "* ]]; then
  echo "NOT MEASURED: the generator did not run to its end (exit $rc, traceback above if any)" >&2
  git checkout -- "$TARGET"
  rm -f "$errors"; exit 2
fi
rm -f "$errors"
if [ -n "$IGNORE" ]; then
  changed=$(git diff -I "$IGNORE" --stat -- "$TARGET")
else
  changed=$(git diff --stat -- "$TARGET")
fi
if [ -n "$changed" ]; then
  echo "MOVED: the null run does not hold for $TARGET; the source or the generator changed:" >&2
  git --no-pager diff -I "${IGNORE:-^$}" --stat -- "$TARGET" >&2
  exit 1
fi
# The run date alone is not a change; put the file back so the tree stays clean.
git checkout -- "$TARGET"
echo "NULL RUN HOLDS: $TARGET comes back as checked in (generator exit $rc)"
exit 0
