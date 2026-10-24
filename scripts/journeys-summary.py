#!/usr/bin/env python3
# Reads an xcodebuild test log and prints the summary table rows, one per
# journey, red first.
#
# Two line forms exist, and the reader once knew only one. A parallel run
# writes    Test case 'Class.test()' passed on 'Clone 1 of …' (12.3 seconds)
# a serial run (the default since 07.09.2026) writes
#           Test Case '-[MaerUITests.Class test]' passed (12.345 seconds).
# Reading only the first, every default run produced an EMPTY table while the
# header said red or green, and nobody saw that the table measured nothing.
#
# The invariant: the table has as many rows as the run executed journeys
# (xcodebuild's own „Executed N tests"). If it does not, this prints why and
# exits 3, so the run is not green on a summary that counted nothing. A run
# that executed no journey at all is no green run either (an `--only` that
# matched nothing, a build that never started the tests): it exits 3 too.
#
# Usage: journeys-summary.py <log>      rows on stdout
#        journeys-summary.py --selbstprobe
import re
import sys

PARALLEL = re.compile(r"Test case '([^']*)' (passed|failed|skipped) on '[^']*' \(([0-9.]+) seconds\)")
SERIAL = re.compile(r"Test Case '-\[(?:[\w]+\.)?(\w+) (\w+)\]' (passed|failed|skipped) \(([0-9.]+) seconds\)")
EXECUTED = re.compile(r"Executed (\d+) tests?, with")
# A skip names its reason on a line of its own before the closing line (a
# server journey that did not reach its server says so there).
SKIP_REASON = re.compile(r"-\[(?:[\w]+\.)?(\w+) (\w+)\] : Test skipped - (.*)$")


def rows(text):
    found = []
    reasons = {}
    for line in text.splitlines():
        m = SKIP_REASON.search(line)
        if m:
            reasons[f"{m.group(1)}/{m.group(2)}"] = m.group(3).strip()
            continue
        m = SERIAL.search(line)
        if m:
            found.append((f"{m.group(1)}/{m.group(2)}", m.group(3), float(m.group(4))))
            continue
        m = PARALLEL.search(line)
        if m:
            name = m.group(1).replace("()", "").replace(".", "/", 1)
            found.append((name, m.group(2), float(m.group(3))))
    return [(n, r if r != "skipped" else f"skipped:{reasons.get(n, 'ohne Grund')}", d) for n, r, d in found]


def verdict(result):
    if result == "failed":
        return "ROT"
    if result.startswith("skipped:"):
        return "übersprungen: " + result[len("skipped:"):]
    return "grün"


def executed(text):
    counts = [int(n) for n in EXECUTED.findall(text)]
    return max(counts) if counts else 0


def table(text):
    """(lines, error) for a log: the table rows and why they cannot be trusted."""
    found = sorted(rows(text), key=lambda r: (r[1] != "failed", r[0]))
    lines = [f"| {n} | {verdict(r)} | {d:.0f} s |" for n, r, d in found]
    ran = executed(text)
    error = None
    if ran == 0 and not found:
        error = "LAUF UNGUELTIG: xcodebuild meldet keine ausgefuehrte Journey, die Tabelle misst nichts"
    elif ran != len(found):
        error = f"LAUF UNGUELTIG: xcodebuild meldet {ran} ausgefuehrte Journeys, die Tabelle hat {len(found)} Zeilen"
    return lines, error


def selbstprobe():
    serial = ("Test Case '-[MaerUITests.SourcesAllOffJourney testTurningOff]' passed (12.345 seconds).\n"
              "Test Case '-[MaerUITests.RadioJourney testStation]' failed (40.100 seconds).\n"
              "\t Executed 2 tests, with 1 failure (0 unexpected) in 52.4 (52.5) seconds\n")
    parallel = ("Test case 'SourcesAllOffJourney.testTurningOff()' passed on 'Clone 1 of iPhone 17' (12.3 seconds)\n"
                "\t Executed 1 test, with 0 failures (0 unexpected) in 12.3 (12.4) seconds\n")
    lines, error = table(serial)
    assert error is None, error
    assert lines == ["| RadioJourney/testStation | ROT | 40 s |",
                     "| SourcesAllOffJourney/testTurningOff | grün | 12 s |"], lines
    lines, error = table(parallel)
    assert error is None and lines == ["| SourcesAllOffJourney/testTurningOff | grün | 12 s |"], lines
    # A server journey that did not reach its server is its own outcome,
    # with the reason, and still counts as a row.
    skipped = ("/x/ServerJourneys.swift:220: -[MaerUITests.ServerJourneys testMusic] : Test skipped - Server nicht erreichbar: https://gonic.example\n"
               "Test Case '-[MaerUITests.ServerJourneys testMusic]' skipped (0.512 seconds).\n"
               "\t Executed 1 test, with 1 test skipped and 0 failures (0 unexpected) in 0.5 (0.6) seconds\n")
    lines, error = table(skipped)
    assert error is None, error
    assert lines == ["| ServerJourneys/testMusic | übersprungen: Server nicht erreichbar: https://gonic.example | 1 s |"], lines
    # The failure this reader had: tests ran, the table stayed empty.
    lines, error = table("\t Executed 10 tests, with 1 failure (0 unexpected) in 1 (1) seconds\n")
    assert lines == [] and error and "10" in error, error
    # A run that executed nothing measured nothing: no table, and an error.
    for empty in ("", "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n"):
        lines, error = table(empty)
        assert lines == [] and error and "keine" in error, error
    print("selbstprobe: gruen")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selbstprobe"]:
        selbstprobe()
        sys.exit(0)
    lines, error = table(open(sys.argv[1], encoding="utf-8", errors="replace").read())
    print("\n".join(lines))
    if error:
        print()
        print(f"**{error}**")
        sys.exit(3)
