#!/bin/bash
# test-hooks.sh: the witnesses of the commit hooks. Builds a throwaway
# repository with these hooks, and for every rule commits one case the hook
# must refuse and one it must let through. Prints one line per case and
# exits non-zero when any case goes the wrong way.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hooks-witness.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
git init -q "$REPO"
cd "$REPO" || exit 2
git config core.hooksPath "$HOOKS"
git config user.name lzs
git config user.email 352619651+maer-lzs@users.noreply.github.com
# The witness repository lies in a temporary path on purpose: it carries the
# throwaway mark, so only the rule about such trees decides there.
echo "witness repository of the commit hooks" > .wegwerf
mkdir -p Sources docs
echo "base" > docs/base.md
git add -A && git commit -q -m "Base of the witness repository" --no-verify

failures=0
# expect <refuse|pass> <name> <file> <content> <message>
expect() {
    local want="$1" name="$2" file="$3" content="$4" message="$5"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$content" >> "$file"
    git add "$file"
    if git commit -q -m "$message" >/dev/null 2>"$WORK/err"; then got=pass; else got=refuse; fi
    if [ "$got" = "$want" ]; then
        echo "ok   $want  $name"
    else
        echo "FAIL want $want, got $got: $name"; sed 's/^/     /' "$WORK/err" | head -3
        failures=$((failures + 1))
    fi
    # Leave the index clean for the next case.
    git reset -q --hard HEAD
}

expect refuse "message names a role"        docs/a.md "one" "The fable session adds a line"
expect pass   "message without a name"      docs/a.md "two" "A line about the queue"
expect refuse "message carries a trailer"   docs/b.md "one" $'Adds a line\n\nCo-Authored-By: Someone <a@b.c>'
expect refuse "message names a channel code" docs/b.md "two" "Builds K-EQ-13 in the sheet"
expect refuse "message cites a decision"    docs/b.md "three" "Entscheid A is built"
expect refuse "message carries a dash"      docs/c.md "one" "The row — four buttons"
expect refuse "message is German"           docs/c.md "two" "Die Taste wird nicht mehr gezeigt"
expect pass   "message quotes one German word" docs/c.md "three" "The notice says Schon abonniert"
expect pass   "message quotes a German sentence in quotation marks" docs/c.md "four" 'The line said "Wenn an, erscheinen Künstler und Alben" before'
expect refuse "comment is German"           Sources/A.swift "// Die Zeile wird nicht mehr gezeigt" "A comment in the source"
expect pass   "comment is English"          Sources/B.swift "// The row is shown once" "A comment in the source"
expect refuse "comment names a role"        Sources/C.swift "// Momo asked for this" "A comment in the source"
expect refuse "line carries an access value" Sources/D.swift 'let token = "abcdef0123456789abcdef0123"' "A constant in the source"
expect pass   "line names a key without its value" Sources/E.swift 'let tokenKey = AppKeys.podcastIndex' "A constant in the source"
expect refuse "new markdown line carries a dash" docs/d.md "The row – four buttons" "A line in the docs"
expect pass   "new markdown line without a dash" docs/e.md "The row, four buttons" "A line in the docs"

# What already stands in the code and must pass.
expect pass   "message names the app with its umlaut" docs/i.md "one" "Mär shows the sheet"
expect pass   "comment names the app with its umlaut" Sources/G.swift "// Mär keeps the row" "A comment in the source"
expect pass   "new Swift file with the licence header" Sources/H.swift $'// Mär — an audio player for self-hosted open ecosystems\n// Copyright (C) 2026 Laurenz Schröder\n// SPDX-License-Identifier: GPL-3.0-or-later\n// Additional terms apply — see LICENSE-ADDITIONAL-TERMS' "A new file in the source"
expect pass   "German text in a string literal" Sources/I.swift 'Text("Schon abonniert, die Taste wird nicht mehr gezeigt")' "A display text in the source"
expect pass   "German text in the catalog"  Sources/Localizable.xcstrings '"value" : "Die Taste wird nicht mehr gezeigt"' "A display text in the catalog"
expect pass   "German line in the inventory" docs/components.md "| Die Reihe zeigt vier Tasten und nicht mehr fuenf |" "A row of the inventory"

# What would slip through otherwise.
expect refuse "message names a channel hash" docs/j.md "one" "Follows the order as in a2caecfd"
expect refuse "message names a role in capitals" docs/j.md "two" "The MOMO review adds a line"
expect refuse "message names a role inside a word" docs/j.md "three" "A fable-built row"
expect refuse "string holds 40 hex characters" Sources/J.swift 'let seed = "0123456789abcdef0123456789abcdef01234567"' "A constant in the source"
expect refuse "line carries an authorization value" docs/k.md "Authorization: token ghp0123456789abcdefABCDEF" "A line in the docs"
expect refuse "Swift comment carries a dash" Sources/K.swift "// The row — four buttons" "A comment in the source"

# The author: another identity is refused.
git config user.email someone@example.com
expect refuse "another author"              docs/f.md "one" "A line by someone else"
git config user.email 352619651+maer-lzs@users.noreply.github.com

# A tree in a temporary path without the throwaway mark is refused.
rm .wegwerf && git commit -q -am "Drop the mark" --no-verify
expect refuse "tree in a temporary path without the mark" docs/g.md "one" "A line in a temporary tree"
echo "witness repository of the commit hooks" > .wegwerf
git add .wegwerf && git commit -q -m "Mark again" --no-verify

# The changelog hint does not refuse: a change under Sources without the
# changelog passes and says so.
printf '// The rest of the row\n' > Sources/F.swift
git add Sources/F.swift
if git commit -q -m "Another line in the source" 2>"$WORK/err"; then
    grep -q "CHANGELOG" "$WORK/err" && echo "ok   pass  changelog hint without refusal" \
        || { echo "FAIL changelog hint missing"; failures=$((failures + 1)); }
else
    echo "FAIL changelog hint refused the commit"; failures=$((failures + 1))
fi

# The time a commit takes with both hooks: under two seconds.
printf 'speed\n' > docs/h.md && git add docs/h.md
start=$(python3 -c 'import time; print(time.time())')
git commit -q -m "A line to time the hooks" 2>/dev/null
end=$(python3 -c 'import time; print(time.time())')
seconds=$(python3 -c "print(round($end - $start, 2))")
if python3 -c "import sys; sys.exit(0 if $end - $start < 2 else 1)"; then
    echo "ok   time  $seconds s for one commit"
else
    echo "FAIL time  $seconds s for one commit"; failures=$((failures + 1))
fi

echo "failures: $failures"
[ "$failures" -eq 0 ]
