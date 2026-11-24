#!/bin/sh
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS
#
# release-keys.sh: the app's keys (Jamendo, Podcast Index) live outside git
# in Config/AppKeys.local.xcconfig, which Config/AppKeys.xcconfig includes
# when it is there and skips silently when not. Builds 66 and 67 were
# archived in work trees without the file and went out with empty keys.
# An archive of the app (a Release build Xcode installs, ACTION install:
# what goes to TestFlight and the store) stops here when a key is empty.
# The message names the key, the file and its folder, never a value.
# Debug, the tests and a Release build that is no archive (the check
# build of lauf.sh in a work tree) build without keys.
[ "${CONFIGURATION}" = "Release" ] && [ "${ACTION}" = "install" ] || exit 0
missing=""
[ -n "${MAER_JAMENDO_CLIENT_ID}" ] || missing="$missing MAER_JAMENDO_CLIENT_ID"
[ -n "${MAER_PODCASTINDEX_KEY}" ] || missing="$missing MAER_PODCASTINDEX_KEY"
[ -n "${MAER_PODCASTINDEX_SECRET}" ] || missing="$missing MAER_PODCASTINDEX_SECRET"
if [ -n "$missing" ]; then
    echo "error: empty app keys:$missing. Copy AppKeys.local.xcconfig into ${SRCROOT}/Config (it stays outside git) and build again."
    exit 1
fi
exit 0
