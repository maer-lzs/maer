#!/bin/sh
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS
#
# store-languages.sh: a language whose translation waits for its review
# stays in the string catalogs but leaves a Release build. The project's
# Release names it in MAER_STORE_LANGUAGES_OUT ("es it"); a build phase of
# the app and one of the widget run this script on their own bundle, before
# the bundle is signed. A Debug build keeps every language. English, German
# and French never leave: the store carries them.
[ "${CONFIGURATION}" = "Release" ] || exit 0
bundle="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
[ -d "$bundle" ] || { echo "error: no bundle at $bundle"; exit 1; }
for lang in ${MAER_STORE_LANGUAGES_OUT}; do
    case "$lang" in
        en|de|fr|Base) echo "error: $lang cannot leave the build"; exit 1;;
        [a-z][a-z]|[a-z][a-z]-[A-Za-z]*) ;;
        *) echo "error: no language: $lang"; exit 1;;
    esac
    if [ -d "$bundle/$lang.lproj" ]; then
        rm -rf "$bundle/$lang.lproj"
        echo "STORE languages: $lang.lproj left ${PRODUCT_NAME}"
    fi
done
exit 0
