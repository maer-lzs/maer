#!/usr/bin/env python3
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS
"""The rules every commit of this repository keeps, in one place.

`rules.py msg <file>` reads a commit message, `rules.py staged` the added
lines of the staged change. Each prints what breaks a rule, one line each,
and exits 1; a clean change exits 0. A change under Sources/ without the
changelog only earns a hint. English is an approximation: umlauts and a list
of German function words, two hits make a German line; a false alarm goes
into english-exceptions.txt with its reason.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

AUTHORS = {"lzs <352619651+maer-lzs@users.noreply.github.com>"}

# The names of roles and people live in ONE place, the list of the fence that
# keeps them out of the repository; the workshop may not carry them itself.
# MAER_ROLE_FENCE points elsewhere for a witness repository without the tests.
FENCE = os.environ.get("MAER_ROLE_FENCE",
                       os.path.join(HERE, "..", "..", "MaerTests", "PublicReadmeFenceTests.swift"))
# Names the fence does not list and the hooks refuse as well.
FURTHER_NAMES = ["lechonk", "chonk", "kreide"]


def role_names():
    try:
        text = open(FENCE, encoding="utf-8").read()
    except OSError:
        raise SystemExit(f"rules.py: the list of names is missing: {FENCE}")
    match = re.search(r"static let roleNames = \[([^\]]*)\]", text)
    if not match:
        raise SystemExit(f"rules.py: no roleNames in {FENCE}")
    names = re.findall(r'"([^"]+)"', match.group(1))
    return sorted({n.lower() for n in names} | set(FURTHER_NAMES))


ROLES = re.compile(r"\b(" + "|".join(role_names()) + r")\b", re.I)
TRAILER = re.compile(r"^(co-authored-by|generated with|signed-off-by: claude)", re.I | re.M)
# Technical terms with a hyphen and digits that look like channel codes but
# name a standard; they are taken out before the search for channel codes.
TECH_TERMS = re.compile(r"\b(UTF-(8|16|32)|HTTP-[123]|SHA-(1|224|256|384|512)|AES-(GCM|CBC|128|256)|ISO-8601|ISO-639-[123]|X-25519|ChaCha20-Poly1305)\b")
CHANNEL_CODE = re.compile(r"(^|[^A-Za-z])[A-Z]{1,4}[0-9]{0,3}-[A-Za-z0-9]{1,6}(-[A-Za-z0-9]{1,6})*([^A-Za-z0-9]|$)")
# A hash of the channel or the repository: seven to forty hex characters with
# at least one digit and one letter.
HASH = re.compile(r"\b(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b")
DECISION = re.compile(r"\bentscheid", re.I)
DASH = re.compile(r"[—–]")

GERMAN_WORDS = {
    "und", "nicht", "ist", "ein", "eine", "einen", "einem", "einer", "mit", "für", "fuer", "auf", "von",
    "zu", "dem", "des", "wird", "werden", "sind", "noch", "nur", "schon", "auch", "oder", "aber", "wenn",
    "weil", "dass", "zum", "zur", "bei", "nach", "aus", "wie", "sich", "mehr", "kein", "keine", "jetzt",
    "hier", "dort", "immer", "der", "das", "zeile", "taste", "gezeigt", "steht", "geht",
}
WORD = re.compile(r"[A-Za-zÄÖÜäöüß]+")
# German names of commands of the run script that slipped through as single
# words in English messages; one of them alone makes the message German.
GERMAN_COMMANDS = {"zweig", "wiederhole"}
UMLAUT = re.compile(r"[ÄÖÜäöüß]")

# The licence header every source file opens with: a dash and a name stand in
# it by design.
HEADER = [
    re.compile(r"^(//|#) Mär — an audio player for self-hosted open ecosystems$"),
    re.compile(r"^(//|#) Copyright \(C\) \d{4} .+$"),
    re.compile(r"^(//|#) SPDX-License-Identifier: .+$"),
    re.compile(r"^(//|#) Additional terms apply — see LICENSE-ADDITIONAL-TERMS$"),
]

ACCESS = [
    re.compile(r"(?i)(token|secret|password|passwd|api[_-]?key|apikey)\w*\s*[:=]\s*[\"'][^\"'\s]{16,}[\"']"),
    re.compile(r"[\"'][0-9A-Fa-f]{32,}[\"']"),
    re.compile(r"(?i)authorization:\s*(token|bearer|basic)\s+\S{8,}"),
]

TEMP_ROOTS = ("/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/")


def exceptions():
    path = os.path.join(HERE, "english-exceptions.txt")
    words = set()
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            word = line.split("#", 1)[0].strip().lower()
            if word:
                words.add(word)
    return words


QUOTED = re.compile(r"\"[^\"]*\"|„[^“]*“|“[^”]*”")


def is_german(text, allowed):
    """Two German words outside quotation marks: a quoted display text is
    not a German sentence of the line."""
    hits = 0
    for word in WORD.findall(QUOTED.sub(" ", text)):
        lower = word.lower()
        if lower in allowed or lower == "mär":
            continue
        if lower in GERMAN_WORDS or UMLAUT.search(word):
            hits += 1
    return hits >= 2


def check_message(text):
    allowed = exceptions()
    body = "\n".join(line for line in text.split("\n") if not line.startswith("#"))
    found = []
    if ROLES.search(body):
        found.append("the message names a role or a person")
    if TRAILER.search(body):
        found.append("the message carries an attribution trailer")
    if CHANNEL_CODE.search(TECH_TERMS.sub(" ", body)) or HASH.search(body):
        found.append("the message carries a channel code or a hash")
    if DECISION.search(body):
        found.append("the message cites a decision")
    if DASH.search(body):
        found.append("the message carries a dash")
    command_words = {w.lower() for w in WORD.findall(QUOTED.sub(" ", body))} & GERMAN_COMMANDS
    if command_words or any(is_german(line, allowed) for line in body.split("\n")):
        found.append("the message is not English")
    return found


def added_lines():
    diff = subprocess.run(["git", "diff", "--cached", "-U0", "--no-color"], capture_output=True, text=True).stdout
    path = None
    for line in diff.split("\n"):
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("+") and path is not None:
            yield path, line[1:]


def outside_strings(line, marker, quotes):
    """The text from the first marker outside a string literal, or None."""
    quote = None
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in quotes:
            quote = c
        elif line.startswith(marker, i):
            return line[i:]
        i += 1
    return None


def comment_of(path, line, doc):
    """The comment part of a source line, or None: a whole comment line, a
    comment after code, or a line of a Python docstring. `doc` carries per
    file whether an added line lies inside a docstring."""
    stripped = line.strip()
    if path.endswith((".swift", ".kt", ".js", ".ts")):
        if stripped.startswith(("/*", "*")):
            return stripped
        return outside_strings(line, "//", "\"")
    if path.endswith(".py"):
        triple = stripped.count('"""') + stripped.count("'''")
        if doc.get(path) or (triple and stripped.startswith(('"""', "'''"))):
            if triple % 2 == 1:
                doc[path] = not doc.get(path)
            # The quotes of the docstring are no quotation of a display text.
            return stripped.replace('"""', " ").replace("'''", " ")
        return outside_strings(line, "#", "\"'")
    if path.endswith(".sh"):
        if stripped.startswith("#!"):
            return None
        return outside_strings(line, "#", "\"'")
    return None


def check_staged():
    allowed = exceptions()
    found = []
    ident = subprocess.run(["git", "var", "GIT_AUTHOR_IDENT"], capture_output=True, text=True).stdout
    author = re.sub(r"\s+\d+\s+[+-]\d{4}\s*$", "", ident.strip())
    if author not in AUTHORS:
        found.append(f"the author is not the agreed one: {author}")
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
    real = os.path.realpath(top) + "/"
    if real.startswith(TEMP_ROOTS) or "/scratchpad/" in real:
        # The mark counts in the index, as everything the hook reads.
        marked = subprocess.run(["git", "cat-file", "-e", ":.wegwerf"], capture_output=True).returncode == 0
        if not marked:
            found.append(f"the working tree lies in a temporary path without .wegwerf: {top}")
    files = set()
    doc = {}
    for path, line in added_lines():
        files.add(path)
        where = f"{path}: {line.strip()[:80]}"
        if any(pattern.search(line) for pattern in ACCESS):
            found.append(f"an access value: {where}")
        if path.endswith(".md") and DASH.search(line):
            found.append(f"a dash in a new markdown line: {where}")
        comment = comment_of(path, line, doc)
        if comment is not None and not any(h.match(comment) for h in HEADER):
            if ROLES.search(comment):
                found.append(f"a comment names a role or a person: {where}")
            if DASH.search(comment):
                found.append(f"a comment carries a dash: {where}")
            if is_german(comment, allowed):
                found.append(f"a comment is not English: {where}")
    hints = []
    if any(f.startswith("Sources/") for f in files) and "CHANGELOG.md" not in files:
        hints.append("hint: Sources/ changes without CHANGELOG.md; say why in the report if it needs no paragraph")
    return found, hints


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "rolle":
        # One name of the list, for the witnesses that must be refused.
        print([n for n in role_names() if n not in FURTHER_NAMES][0])
        return 0
    if len(sys.argv) >= 3 and sys.argv[1] == "msg":
        found, hints = check_message(open(sys.argv[2], encoding="utf-8").read()), []
    elif len(sys.argv) >= 2 and sys.argv[1] == "staged":
        found, hints = check_staged()
    else:
        print("usage: rules.py msg <file> | rules.py staged", file=sys.stderr)
        return 2
    for hint in hints:
        print(hint, file=sys.stderr)
    for item in found:
        print(f"refused: {item}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
