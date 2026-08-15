#!/usr/bin/env python3
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 72d233f/9913bcd: generates Sources/Models/RadioWikidataCores.swift — the
# Wikidata popularity cores for countries WITHOUT a first-hand listener
# survey table (RadioListenerCores). Run occasionally (no fixed cadence);
# the app never talks to the SPARQL endpoint itself.
#
# Three ingredients, one mechanism:
#   1. EBU cores  — stations linked (P127|P137|P749) to an organisation that
#                   is (directly or one hop via P361|P749|P463) an EBU member
#                   (P463 → Q166400 — verified QID, do not guess).
#   2. Anchors    — for non-EBU markets the membership filter is replaced by
#                   NAMED broadcasters (verified QIDs below).
#   3. Toplists   — country-wide sitelink top for markets whose big stations
#                   are private (the anchor countries): all stations of the
#                   country ranked by sitelink count, no org filter. Dead or
#                   obscure entries drop out at RB name resolution (logged).
#
# The SITELINK COUNT (number of Wikipedia languages) is the measured
# popularity proxy — the CH probe matched Mediapulse's order. Only names,
# QIDs and rank ORDER are emitted; sitelink numbers are not frozen into the
# data (cb8bac1 rule: derived values are not persisted).
#
# Usage: python3 tools/radio-wikidata-cores/generate.py
#        (writes the Swift file relative to the repo root, prints a summary)

import json
import time
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path

ENDPOINT = "https://query.wikidata.org/sparql"
# WDQS policy asks for a descriptive UA with contact — this is the TOOLING
# identity, not the app's AppUserAgent (the app never calls WDQS).
USER_AGENT = "Maer-radio-core-generator/1.0 (https://git.lschroeder.eu/the-owner/maer)"

# First-hand tables win (RadioListenerCores) — keep their countries out.
FIRSTHAND = {"DE", "AT", "CH"}

# 9913bcd: anchor broadcasters for non-EBU markets. QIDs VERIFIED via
# wbsearchentities on 2026-08-15 — extend by adding a line.
ANCHORS = {
    "US": "Q671510",    # NPR
    "AU": "Q781365",    # Australian Broadcasting Corporation
    "JP": "Q212128",    # NHK
    "KR": "Q498825",    # Korean Broadcasting System
    "NZ": "Q1626518",   # Radio New Zealand
    "ZA": "Q1419926",   # South African Broadcasting Corporation
    "IN": "Q1321122",   # All India Radio
}

# A usable core needs some breadth; below this the row stays votes-pure.
MIN_CORE = 5
# Cap per country — a row shows 12, the resolver's head is 20.
MAX_CORE = 30

LABEL_LANGS = "en,fr,de,it,es,pl,cs,nl,sv,da,no,fi,pt,hu,ro,el,tr,uk,ja,ko,zh"


def sparql(query: str):
    url = ENDPOINT + "?" + urllib.parse.urlencode({"query": query, "format": "json"})
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                return json.load(response)["results"]["bindings"]
        except urllib.error.HTTPError as error:
            if error.code in (429, 500, 502, 503, 504) and attempt < 2:
                time.sleep(10 * (attempt + 1))
                continue
            raise


def ebu_rows():
    return sparql(f"""
SELECT DISTINCT ?station ?stationLabel ?ccode ?sitelinks WHERE {{
  ?station wdt:P31 wd:Q14350 .
  ?station wdt:P17 ?country .
  ?country wdt:P297 ?ccode .
  ?station (wdt:P127|wdt:P137|wdt:P749) ?org .
  ?org ((wdt:P361|wdt:P749|wdt:P463)?/wdt:P463) wd:Q166400 .
  ?station wikibase:sitelinks ?sitelinks .
  FILTER(?sitelinks > 0)
  SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{LABEL_LANGS}" . }}
}}""")


def anchor_rows(ccode: str, anchor_qid: str):
    return sparql(f"""
SELECT DISTINCT ?station ?stationLabel ?sitelinks WHERE {{
  ?station wdt:P31 wd:Q14350 .
  ?station wdt:P17 ?country .
  ?country wdt:P297 "{ccode}" .
  ?station (wdt:P127|wdt:P137|wdt:P749)/((wdt:P361|wdt:P749)?) wd:{anchor_qid} .
  ?station wikibase:sitelinks ?sitelinks .
  FILTER(?sitelinks > 0)
  SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{LABEL_LANGS}" . }}
}}""")


def toplist_rows(ccode: str):
    # Two stages: the country-wide scan is heavy (US: tens of thousands of
    # stations) — rank WITHOUT the label service first, then label only the
    # top slice. One 504 taught this split.
    ranked = sparql(f"""
SELECT DISTINCT ?station ?sitelinks WHERE {{
  ?station wdt:P31 wd:Q14350 .
  ?station wdt:P17 ?country .
  ?country wdt:P297 "{ccode}" .
  ?station wikibase:sitelinks ?sitelinks .
  FILTER(?sitelinks >= 5)
}} ORDER BY DESC(?sitelinks) LIMIT 60""")
    if not ranked:
        return []
    values = " ".join("wd:" + r["station"]["value"].rsplit("/", 1)[1] for r in ranked)
    time.sleep(1)
    return sparql(f"""
SELECT ?station ?stationLabel ?sitelinks WHERE {{
  VALUES ?station {{ {values} }}
  ?station wikibase:sitelinks ?sitelinks .
  SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{LABEL_LANGS}" . }}
}}""")


def collect(rows, out):
    for row in rows:
        qid = row["station"]["value"].rsplit("/", 1)[1]
        label = row["stationLabel"]["value"]
        if label == qid:  # no label in any of our languages — unusable name
            continue
        sitelinks = int(row["sitelinks"]["value"])
        if qid not in out or out[qid][1] < sitelinks:
            out[qid] = (label, sitelinks)


def main():
    per_country = defaultdict(dict)  # ccode -> {qid: (label, sitelinks)}

    for row in ebu_rows():
        ccode = row["ccode"]["value"]
        if ccode in FIRSTHAND:
            continue
        collect([row], per_country[ccode])
    time.sleep(1)

    for ccode, anchor in ANCHORS.items():
        collect(anchor_rows(ccode, anchor), per_country[ccode])
        time.sleep(1)
        collect(toplist_rows(ccode), per_country[ccode])
        time.sleep(1)

    cores = {}
    for ccode, stations in per_country.items():
        ranked = sorted(stations.items(), key=lambda kv: (-kv[1][1], kv[0]))
        # One LABEL once — the resolver matches names, so a second QID with
        # the same label (LU: two "Radio Luxembourg" entities) is the same
        # name; the better-ranked one keeps the seat.
        seen_labels = set()
        deduped = []
        for qid, (label, _) in ranked:
            if label.casefold() in seen_labels:
                continue
            seen_labels.add(label.casefold())
            deduped.append((label, qid))
        if len(deduped) >= MIN_CORE:
            cores[ccode] = deduped[:MAX_CORE]

    lines = []
    for ccode in sorted(cores):
        entries = "\n".join(
            f'            "{label.replace(chr(92), chr(92) * 2).replace(chr(34), chr(92) + chr(34))}",  // {qid}'
            for label, qid in cores[ccode]
        )
        lines.append(f'        "{ccode}": [\n{entries}\n        ],')

    run_date = time.strftime("%Y-%m-%d")
    swift = f"""// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

// GENERATED by tools/radio-wikidata-cores/generate.py — edit the script,
// not this file. Run date: {run_date}.

import Foundation

/// 72d233f/9913bcd: Wikidata popularity cores for countries WITHOUT a
/// first-hand survey table — public-broadcaster flagships via EBU
/// membership (plus named anchors and the country sitelink top for
/// non-EBU markets), ranked by SITELINK COUNT (verified proxy: the CH
/// probe matched Mediapulse's order). Names in rank order, the QID rides
/// as a comment; sitelink numbers are deliberately NOT frozen (cb8bac1).
/// Resolution against the live catalog and the core-first mixing are the
/// SAME mechanism as the first-hand cores — the cores are exchangeable
/// data, not a second code path.
nonisolated enum RadioWikidataCores {{
    static func national(countryCode: String?) -> [String]? {{
        guard let code = countryCode?.uppercased() else {{ return nil }}
        return tables[code]
    }}

    static let tables: [String: [String]] = [
{chr(10).join(lines)}
    ]
}}
"""
    root = Path(__file__).resolve().parents[2]
    target = root / "Sources" / "Models" / "RadioWikidataCores.swift"
    target.write_text(swift, encoding="utf-8")
    print(f"{len(cores)} countries -> {target}")
    for ccode in sorted(cores):
        head = " · ".join(label for label, _ in cores[ccode][:5])
        print(f"  {ccode} ({len(cores[ccode])}): {head}")


if __name__ == "__main__":
    main()
