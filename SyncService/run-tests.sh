#!/bin/sh
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

# The service's own suite. Separate from the app's: it needs no simulator
# and no Xcode, so it runs in a second and can run on every save.
#
# It prints the case count, and that is not decoration. A run of this
# project's app suite once reported green against a stale binary and the
# only tell was the number of cases; the rule that came out of it is that
# a red probe counts only when the run reports the count you expect.
set -e
cd "$(dirname "$0")"
exec python3 -m unittest discover -s tests -t . -v "$@"
