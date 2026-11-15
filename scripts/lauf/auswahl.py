#!/usr/bin/env python3
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS
"""The selection of the run script: from a change to the test files to run.

`auswahl.py [--basis REV] [--kopf REV] [--nur PREFIX] [--voll]` prints one
line per decision:
  datei <TestFile>    a test file under MaerTests/ to run
  voll                a build file changed: the full run
  art: doku           only documents changed
  ui: ja              a path of the journeys changed
  keine UI-Tests: kein Pfad der Liste beruehrt
  keine eigene Suite getroffen: <path>

The one map from file to suite:
  - a changed test file selects itself;
  - a changed Swift source selects every test file that names one of its
    types or its file name, read at the base for a deleted or renamed file
    and at the head otherwise;
  - karte.txt maps path prefixes to test files, each line with its reason;
  - the fences always run: every test file that reads the whole source
    (sourceFiles, allSources, a directory walk) and those in zaeune.txt;
  - the measurements in nur-voll.txt run only with --voll;
  - project, package, xcconfig, Info.plist and entitlements select the full
    run, since a type name finds nothing there and the effect reaches all.
Without --kopf the head is the working tree, uncommitted changes included.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = "MaerTests/"
UI_PREFIXES = ("Sources/Views/", "Sources/Localizable.xcstrings", "MaerWidgets/", "LiveActivityWidget/", "MaerUITests/")
DOCUMENT = re.compile(r"(^docs/|^site/|\.md$|^README)")
TYPE = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|final|nonisolated|indirect)\s+)*"
                  r"(?:class|struct|enum|actor|protocol|extension|typealias)\s+([A-Z]\w*)", re.M)


def git(*args, check=True):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def is_build_file(path):
    name = os.path.basename(path)
    return (name in ("project.pbxproj", "Package.resolved") or name.endswith((".xcconfig", ".entitlements"))
            or name.endswith("Info.plist"))


def is_ui(path):
    return path.startswith(UI_PREFIXES) or "Assets.xcassets/" in path


def read_list(name):
    """Names of a list beside this file, one per line, comments dropped."""
    path = os.path.join(HERE, name)
    if not os.path.exists(path):
        return []
    return [line.split("#", 1)[0].strip() for line in open(path, encoding="utf-8")
            if line.split("#", 1)[0].strip()]


# A test file that reads the whole source is a fence: any change of a source
# can move what it counts or finds, so it runs with every selection.
WHOLE_SOURCE = re.compile(r"sourceFiles\(|allSources|enumerator\(at")


def whole_source_fences():
    found = set()
    for path in git("ls-files", "--cached", "--others", "--exclude-standard", "--", TESTS).split("\n"):
        if path.endswith(".swift") and WHOLE_SOURCE.search(content(None, path)):
            found.add(os.path.basename(path)[:-6])
    return found


def read_map(existing):
    """karte.txt: `<path prefix> <TestFile> ... # reason`. A line without a
    reason, or naming a test file that is not there, stops the selection."""
    path = os.path.join(HERE, "karte.txt")
    entries = []
    if not os.path.exists(path):
        return entries
    for number, line in enumerate(open(path, encoding="utf-8"), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        body, _, reason = line.partition("#")
        words = body.split()
        if not reason.strip():
            raise SystemExit(f"karte.txt:{number}: a line without its reason: {line.strip()}")
        if len(words) < 2:
            raise SystemExit(f"karte.txt:{number}: a prefix and at least one test file: {line.strip()}")
        unknown = [w for w in words[1:] if w not in existing]
        if unknown:
            raise SystemExit(f"karte.txt:{number}: no such test file: {' '.join(unknown)}")
        entries.append((words[0], words[1:]))
    return entries


def test_files(rev):
    """The test files at a revision, or in the working tree for None."""
    if rev is None:
        out = git("ls-files", "--cached", "--others", "--exclude-standard", "--", TESTS)
    else:
        out = git("ls-tree", "-r", "--name-only", rev, "--", TESTS)
    return {os.path.basename(p)[:-6] for p in out.split("\n") if p.endswith(".swift")}


def content(rev, path):
    if rev is None:
        try:
            return open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            return ""
    return git("show", f"{rev}:{path}", check=False)


def names_of(rev, path):
    """The type names a Swift file declares, and its file name."""
    names = set(TYPE.findall(content(rev, path)))
    stem = os.path.basename(path)[:-6].split("+", 1)[0]
    if re.fullmatch(r"\w+", stem):
        names.add(stem)
    return names


def files_naming(rev, names):
    if not names:
        return set()
    args = ["grep", "-l", "-w", "-F"]
    for name in sorted(names):
        args += ["-e", name]
    if rev is None:
        args += ["--untracked", "--", TESTS]
    else:
        args += [rev, "--", TESTS]
    out = git(*args, check=False)
    found = set()
    for line in out.split("\n"):
        path = line.split(":", 1)[1] if rev is not None and ":" in line else line
        if path.endswith(".swift"):
            found.add(os.path.basename(path)[:-6])
    return found


def changes(basis, kopf, only):
    args = ["diff", "--name-status", "-M", basis] + ([kopf] if kopf else [])
    if kopf is None:
        # Untracked files of the working tree count as added.
        extra = [("A", p, p) for p in git("ls-files", "--others", "--exclude-standard").split("\n") if p]
    else:
        extra = []
    found = []
    for line in git(*args).split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        status = parts[0][0]
        old, new = (parts[1], parts[2]) if status in "RC" else (parts[1], parts[1])
        found.append((status, old, new))
    found += extra
    if only:
        found = [c for c in found if c[1].startswith(only) or c[2].startswith(only)]
    return found


def main():
    args = sys.argv[1:]
    def option(name):
        if name in args:
            i = args.index(name)
            return args[i + 1] if i + 1 < len(args) else None
        return None
    full = "--voll" in args
    kopf = option("--kopf")
    only = option("--nur")
    os.chdir(git("rev-parse", "--show-toplevel").strip())
    existing = test_files(None)
    fences = read_list("zaeune.txt")
    measurements = read_list("nur-voll.txt")
    unknown = [n for n in fences + measurements if n not in existing]
    if unknown:
        raise SystemExit(f"zaeune.txt or nur-voll.txt: no such test file: {' '.join(unknown)}")
    mapping = read_map(existing)

    if full:
        for name in sorted(existing):
            print(f"datei {name}")
        return 0

    basis = option("--basis")
    if not basis:
        basis = git("merge-base", "origin/dev", kopf or "HEAD").strip()
    at_head = test_files(kopf)
    chosen, lines = set(fences) | whole_source_fences(), []
    whole, ui, all_documents = False, False, True
    changed = changes(basis, kopf, only)
    for status, old, new in changed:
        paths = {old, new}
        if not any(DOCUMENT.search(p) for p in paths):
            all_documents = False
        if any(is_build_file(p) for p in paths):
            whole = True
        if any(is_ui(p) for p in paths):
            ui = True
        for prefix, files in mapping:
            if any(p.startswith(prefix) for p in paths):
                chosen.update(files)
        if new.startswith(TESTS) and new.endswith(".swift") and status != "D":
            chosen.add(os.path.basename(new)[:-6])
            continue
        if new.endswith(".swift") and not new.startswith(TESTS):
            names = names_of(basis, old) if status != "A" else set()
            if status != "D":
                names |= names_of(kopf, new)
            # A test that named the type at the base may break as well as one
            # that names it at the head: both are read.
            hits = files_naming(basis, names)
            if status != "D":
                hits |= files_naming(kopf, names)
            hits &= existing | at_head
            if hits:
                chosen.update(hits)
            else:
                lines.append(f"keine eigene Suite getroffen: {new}")
    if whole:
        print("voll")
    if changed and all_documents:
        print("art: doku")
    for name in sorted(chosen - set(measurements)):
        print(f"datei {name}")
    for line in lines:
        print(line)
    print("ui: ja" if ui else "keine UI-Tests: kein Pfad der Liste beruehrt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
