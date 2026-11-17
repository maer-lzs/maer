#!/bin/bash
# test-hooks.sh: the witnesses of the commit hooks. Builds a throwaway
# repository with these hooks, and for every rule commits one case the hook
# must refuse and one it must let through. Prints one line per case and
# exits non-zero when any case goes the wrong way.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
# A name the hooks refuse, taken from their one list: the workshop does not
# carry the names itself.
ROLE="$(python3 -I "$HOOKS/rules.py" rolle)" || exit 2
ROLE_CAPITAL="$(echo "${ROLE:0:1}" | tr '[:lower:]' '[:upper:]')${ROLE:1}"
ROLE_UPPER="$(echo "$ROLE" | tr '[:lower:]' '[:upper:]')"
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

expect refuse "message names a role"        docs/a.md "one" "The $ROLE session adds a line"
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
expect refuse "comment names a role"        Sources/C.swift "// $ROLE_CAPITAL asked for this" "A comment in the source"
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
expect refuse "message names a role in capitals" docs/j.md "two" "The $ROLE_UPPER review adds a line"
expect refuse "message names a role inside a word" docs/j.md "three" "A $ROLE-built row"
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

expect refuse "message names the branch push in German" docs/e.md "one" "Witnesses refused by push zweig"
expect refuse "message names the repeat in German"      docs/e.md "two" "wiederhole runs one case many times"

expect refuse "trailing comment in Swift is German" Sources/H.swift 'let a = 1 // Die Zeile wird nicht mehr gezeigt' "A constant in the source"
expect refuse "Python docstring on one line is German" tools/a.py '"""Die Zeile wird nicht mehr gezeigt."""' "A tool in Python"
expect refuse "Python docstring over lines is German" tools/b.py $'def f():\n    """Reads the file.\n\n    Die Zeile wird nicht mehr gezeigt.\n    """' "A tool in Python"
expect refuse "trailing comment in Python is German" tools/c.py 'x = 1  # Die Zeile wird nicht mehr gezeigt' "A tool in Python"
expect refuse "trailing comment in bash is German" tools/d.sh 'x=1  # Die Zeile wird nicht mehr gezeigt' "A tool in bash"
expect pass   "an address in a Swift string is no comment" Sources/I.swift 'let u = "https://example.org/die/zeile/wird/nicht/mehr/gezeigt"' "A constant in the source"
expect pass   "a hash sign in a bash string is no comment" tools/e.sh 'echo "# Die Zeile wird nicht mehr gezeigt"' "A tool in bash"
expect pass   "technical terms are no channel codes" docs/f.md "one" "Reads UTF-8 names, HTTP-2 and SHA-256 sums with AES-GCM"
expect refuse "a channel code stays refused beside them" docs/f.md "two" "Reads UTF-8 names for K-EQ-13"

# Comments are read from the whole staged file, one tokenizer per language:
# a line inserted into an existing docstring, a block comment or a heredoc
# is judged by where it stands, not by its own text alone.
mkdir -p tools
printf 'def f():\n    """Reads the file.\n\n    Returns the rows.\n    """\n    return 1\n' > tools/doc.py
git add tools/doc.py && git commit -q -m "A tool in Python" >/dev/null 2>&1
python3 - <<'EOF'
p = "tools/doc.py"
lines = open(p).read().split("\n")
lines.insert(3, "    Die Zeile wird nicht mehr gezeigt.")
open(p, "w").write("\n".join(lines))
EOF
git add tools/doc.py
if git commit -q -m "A line in the documentation of a tool" >/dev/null 2>"$WORK/err"; then
    echo "FAIL want refuse: a German line inserted into an existing docstring"; failures=$((failures + 1))
else
    echo "ok   refuse  a German line inserted into an existing docstring"
fi
git reset -q --hard HEAD
expect pass   "a comment marker inside a Swift multiline string is text" Sources/J.swift $'let s = """\n    // Die Zeile wird nicht mehr gezeigt\n    """' "A text in the source"
expect pass   "a comment marker inside a Swift raw string is text" Sources/K.swift 'let s = #"a // Die Zeile wird nicht mehr gezeigt"#' "A text in the source"
expect refuse "a German line inside a nested block comment" Sources/L.swift $'/* outer /* inner */\n   Die Zeile wird nicht mehr gezeigt\n*/' "A comment in the source"
expect refuse "an open quote before a hash sign leaves the shell file unread" tools/f.sh "echo don't # Die Zeile wird nicht mehr gezeigt" "A tool in bash"
expect pass   "a hash sign inside a heredoc is its content" tools/g.sh $'cat <<EOF\n# Die Zeile wird nicht mehr gezeigt\nEOF' "A tool in bash"
expect pass   "a length of a variable is no comment" tools/h.sh 'n=${#list}' "A tool in bash"
expect pass   "an extended Swift regex with quotes is a literal" Sources/N.swift 'let r = #/static let (\w+) = "([^"]+)"/#' "A pattern in the source"
expect pass   "a bare Swift regex with a quote is a literal" Sources/O.swift 'let r = /label: "([^"]+)"/' "A pattern in the source"
expect refuse "a division before a German comment is code" Sources/P.swift 'let q = a / b // Die Zeile wird nicht mehr gezeigt' "A constant in the source"
expect refuse "a Python file that does not parse is not read" tools/i.py 'def f(:' "A tool in Python"
expect refuse "a Swift file with an open string is not read" Sources/M.swift 'let s = "open' "A text in the source"

# The hooks read the index, never the working tree: a file changed after it
# was staged does not change what the hook sees.
printf 'clean\n' > Sources/F.swift && git add Sources/F.swift
printf '// Die Zeile wird nicht mehr gezeigt\n' >> Sources/F.swift
if git commit -q -m "A clean line staged, the working tree changed after" >/dev/null 2>"$WORK/err"; then
    echo "ok   pass  the working tree changed after the staging does not count"
else
    echo "FAIL want pass: the working tree changed after the staging does not count"; failures=$((failures + 1))
fi
git reset -q --hard HEAD
printf '// Die Zeile wird nicht mehr gezeigt\n' > Sources/G.swift && git add Sources/G.swift
printf '// The row is shown once\n' > Sources/G.swift
if git commit -q -m "A German comment staged, the working tree cleaned after" >/dev/null 2>"$WORK/err"; then
    echo "FAIL want refuse: the staged German comment counts though the working tree is clean"; failures=$((failures + 1))
else
    echo "ok   refuse  the staged German comment counts though the working tree is clean"
fi
git reset -q --hard HEAD
rm -f Sources/G.swift
# The throwaway mark counts only in the index: an untracked .wegwerf in a
# temporary tree is no mark.
UNMARKED="$WORK/unmarked"
git init -q "$UNMARKED"
(
    cd "$UNMARKED" || exit 2
    git config core.hooksPath "$HOOKS"; git config user.name lzs; git config user.email 352619651+maer-lzs@users.noreply.github.com
    echo "not staged" > .wegwerf
    echo "a line" > a.md && git add a.md
    git commit -q -m "A line in a temporary tree" >/dev/null 2>&1
) && marked=pass || marked=refuse
if [ "$marked" = refuse ]; then
    echo "ok   refuse  an untracked throwaway mark is no mark"
else
    echo "FAIL want refuse: an untracked throwaway mark is no mark"; failures=$((failures + 1))
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
