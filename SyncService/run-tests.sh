#!/bin/sh
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

# The service's own suite. Separate from the app's: it needs no simulator
# and no Xcode.
#
# It does NOT run in a second, whatever this comment said for weeks:
# measured 182 cases in 11.6 seconds, and the sentence had already been
# copied from here into an order as if it were a measurement. A run on every
# save is therefore a choice with a price, not a free one.
#
# It prints the case count, and that is not decoration. A run of this
# project's app suite once reported green against a stale binary and the
# only tell was the number of cases; the rule that came out of it is that
# a red probe counts only when the run reports the count you expect.
set -e
cd "$(dirname "$0")"
exec python3 -m unittest discover -s tests -t . -v "$@"
