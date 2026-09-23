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
# exits 3, so the run is not green on a summary that counted nothing.
#
# Usage: journeys-summary.py <log>      rows on stdout
#        journeys-summary.py --selbstprobe
import re
import sys

PARALLEL = re.compile(r"Test case '([^']*)' (passed|failed) on '[^']*' \(([0-9.]+) seconds\)")
SERIAL = re.compile(r"Test Case '-\[(?:[\w]+\.)?(\w+) (\w+)\]' (passed|failed) \(([0-9.]+) seconds\)")
EXECUTED = re.compile(r"Executed (\d+) tests?, with")


def rows(text):
    found = []
    for line in text.splitlines():
        m = SERIAL.search(line)
        if m:
            found.append((f"{m.group(1)}/{m.group(2)}", m.group(3), float(m.group(4))))
            continue
        m = PARALLEL.search(line)
        if m:
            name = m.group(1).replace("()", "").replace(".", "/", 1)
            found.append((name, m.group(2), float(m.group(3))))
    return found


def executed(text):
    counts = [int(n) for n in EXECUTED.findall(text)]
    return max(counts) if counts else 0


def table(text):
    """(lines, error) for a log: the table rows and why they cannot be trusted."""
    found = sorted(rows(text), key=lambda r: (r[1] != "failed", r[0]))
    lines = [f"| {n} | {'ROT' if r == 'failed' else 'grün'} | {d:.0f} s |" for n, r, d in found]
    ran = executed(text)
    error = None
    if ran != len(found):
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
    # The failure this reader had: tests ran, the table stayed empty.
    lines, error = table("\t Executed 10 tests, with 1 failure (0 unexpected) in 1 (1) seconds\n")
    assert lines == [] and error and "10" in error, error
    # A run that executed nothing is no table and no error of the reader.
    assert table("") == ([], None)
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
