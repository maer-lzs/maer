#!/usr/bin/env python3
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 🔴 8360dac: END-TO-END audit of the radio logo chain, with a NUMBER.
# Seven stage fixes did not close the topic because none of them defined
# what "solved" means. This does: it walks the WHOLE chain per station of
# the target set and counts every stage's losses.
#
# The chain it replicates (Sources/Networking/RadioLogoService.swift):
#   RB entry → favicon (gate: decodable AND min side 64)
#           → Wikidata search (searchTerms × [de,en], conservative fold match)
#           → entity → P154 → Commons thumb (width 800)
#           → gate again → tile
#
# Usage: python3 tools/radio-logo-audit/audit.py [--limit N] [--out FILE]
# Output: one row per station — source of the shown image (favicon / chain /
# NONE) and, on failure, the STAGE that lost it.

import argparse
import io
import json
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request

UA = "Maer-radio-logo-audit/1.0 (https://git.lschroeder.eu/the-owner/maer)"
MIN_SIDE = 64            # RadioFaviconGate.minSide (favicons)
TOUCH_MIN_SIDE = 48      # RadioFaviconGate.touchIconMinSide (declared logos)
COMMONS_WIDTH = 800      # RadioLogoService.commonsWidth
RB = "https://de1.api.radio-browser.info"


def get(url, timeout=20):
    """→ (status, bytes) ; status None = transport failure (never a finding)."""
    try:
        request = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, None
    except Exception:
        return None, None


def fold(raw):
    text = unicodedata.normalize("NFKD", raw or "")
    text = "".join(c for c in text if not unicodedata.combining(c))
    return "".join(c for c in text.lower() if c.isalnum())


def search_terms(name):
    """RadioLogoLookup.searchTerms, replicated."""
    terms = [name]
    if " - " in name:
        prefix = name.split(" - ")[0].strip()
        if len(prefix) >= 4 and prefix not in terms:
            terms.append(prefix)
    words = name.split()
    if len(words) >= 2 and len(words[0]) >= 4 and words[0] not in terms:
        terms.append(words[0])
    return terms


def image_side(data):
    """Shortest side in pixels, or None when undecodable (SVG included)."""
    if not data:
        return None
    try:
        from PIL import Image
        with Image.open(io.BytesIO(data)) as image:
            return min(image.size)
    except Exception:
        return None


def wikidata_entity(term, language, station_name):
    url = "https://www.wikidata.org/w/api.php?" + urllib.parse.urlencode(
        {"action": "wbsearchentities", "search": term, "language": language,
         "format": "json", "limit": 10})
    status, body = get(url)
    if status != 200 or not body:
        return None, ("wikidata-search" if status is None else None)
    try:
        hits = json.loads(body).get("search", [])
    except Exception:
        return None, None
    wanted = fold(station_name)
    for hit in hits:
        have = fold(hit.get("label", ""))
        if have and (wanted in have or have in wanted):
            return hit.get("id"), None
    return None, None


def p154_file(entity):
    url = f"https://www.wikidata.org/wiki/Special:EntityData/{entity}.json"
    status, body = get(url)
    if status != 200 or not body:
        return None
    try:
        claims = json.loads(body)["entities"][entity].get("claims", {})
        return claims["P154"][0]["mainsnak"]["datavalue"]["value"]
    except Exception:
        return None


def commons_thumb(file_name, width=COMMONS_WIDTH):
    return ("https://commons.wikimedia.org/w/thumb.php?"
            + urllib.parse.urlencode({"f": file_name, "width": width}))


def display_name(raw):
    """RadioMapping.displayName — the app searches Wikidata with THIS, not
    with the raw catalog name (first audit run used the raw one)."""
    text = raw.strip()
    for separator in ("|", "•", "–", "—"):
        if separator in text:
            head = text.split(separator)[0].strip()
            if len(head) >= 3:
                text = head
                break
    stripped = re.sub(r"((\b(mp3|aac\+?|he-?aac|opus|ogg|vorbis|flac|wma)\b|\b\d{2,3}\s?k(bps)?\b|\bstream\s?\d+\b)[\s.]*)+$",
                      "", text, flags=re.I).strip()
    return stripped if len(stripped) >= 3 else text


def audit_station(station, pause):
    """→ dict: source, stage (on failure), detail."""
    name = display_name(station["name"])
    result = {"station": name, "raw": station["name"], "source": "NONE",
              "stage": None, "detail": ""}

    # --- stage A: the catalog favicon, gated ---------------------------------
    favicon = (station.get("favicon") or "").strip()
    if favicon:
        status, body = get(favicon)
        side = image_side(body)
        if status is None:
            result["stage"] = "favicon-unreachable"
        elif status != 200:
            result["stage"] = f"favicon-http-{status}"
        elif side is None:
            result["stage"] = "favicon-undecodable"     # SVG lands here
        elif side < MIN_SIDE:
            result["stage"] = f"favicon-too-small-{side}"
        else:
            result["source"] = "favicon"
            result["detail"] = f"{side}px"
            return result
    else:
        result["stage"] = "favicon-missing"
    favicon_stage = result["stage"]

    # --- stage B: Wikidata P154 ---------------------------------------------
    entity = None
    for term in search_terms(name):
        for language in ("de", "en"):
            entity, failure = wikidata_entity(term, language, name)
            time.sleep(pause)
            if entity:
                break
        if entity:
            break
    if not entity:
        icon, why = touch_icon(station.get("homepage"), pause)
        if icon:
            result["source"] = "chain"
            result["detail"] = f"touch-icon {icon[:60]}"
            return result
        result["stage"] = f"{favicon_stage} + wikidata-no-entity + {why}"
        return result

    file_name = p154_file(entity)
    time.sleep(pause)
    if not file_name:
        icon, why = touch_icon(station.get("homepage"), pause)
        if icon:
            result["source"] = "chain"
            result["detail"] = f"touch-icon {icon[:60]}"
            return result
        result["stage"] = f"{favicon_stage} + no-P154 ({entity}) + {why}"
        return result

    status, body = get(commons_thumb(file_name))
    side = image_side(body)
    if status is None:
        result["stage"] = f"{favicon_stage} + commons-unreachable"
    elif status != 200:
        result["stage"] = f"{favicon_stage} + commons-http-{status}"
    elif side is None:
        result["stage"] = f"{favicon_stage} + commons-undecodable"
    elif side < MIN_SIDE:
        result["stage"] = f"{favicon_stage} + commons-gate-{side}"
    else:
        result["source"] = "chain"
        result["detail"] = f"{file_name} {side}px"
        result["stage"] = None
    return result


TOUCH_ICON = re.compile(
    r'<link[^>]+rel=["\'][^"\']*apple-touch-icon[^"\']*["\'][^>]*>', re.I)
HREF = re.compile(r'href=["\']([^"\']+)["\']', re.I)


def touch_icon(homepage, pause):
    """Chain STAGE 2 — the homepage's apple-touch-icon, plus the convention
    URL the app also tries. Missing from the first audit run, which made the
    measured ceiling look lower than the chain actually is."""
    if not homepage or not homepage.startswith("http"):
        return None, "no-homepage"
    status, body = get(homepage, timeout=15)
    time.sleep(pause)
    if status is None:
        return None, "homepage-unreachable"
    if status != 200 or not body:
        return None, f"homepage-http-{status}"
    html = body.decode("utf-8", errors="replace")
    candidates = []
    tag = TOUCH_ICON.search(html)
    if tag:
        href = HREF.search(tag.group(0))
        if href:
            candidates.append(urllib.parse.urljoin(homepage, href.group(1)))
    candidates.append(urllib.parse.urljoin(homepage, "/apple-touch-icon.png"))
    for url in candidates:
        status, data = get(url, timeout=15)
        time.sleep(pause)
        if status != 200:
            continue
        side = image_side(data)
        if side is None:
            return None, "touchicon-undecodable"
        if side < TOUCH_MIN_SIDE:
            return None, f"touchicon-too-small-{side}"
        return url, None
    return None, "touchicon-missing"


def resolve_in_catalog(names, country):
    """Name → RB entry (best votes), replicating the core resolver roughly."""
    url = (f"{RB}/json/stations/search?"
           + urllib.parse.urlencode({"countrycode": country, "limit": 600,
                                     "hidebroken": "true", "order": "votes",
                                     "reverse": "true"}))
    status, body = get(url, timeout=40)
    pool = json.loads(body) if status == 200 and body else []
    by_key = {}
    for station in pool:
        for key in {fold(station["name"])}:
            by_key.setdefault(key, station)
    out = []
    for name in names:
        wanted = fold(name)
        hit = by_key.get(wanted)
        if not hit:
            for key, station in by_key.items():
                if wanted and (wanted in key or key in wanted):
                    hit = station
                    break
        if hit:
            out.append(hit)
    return out


def target_set(limit):
    """The set the owner actually sees: DACH cores + Wikidata heads."""
    root = __file__.rsplit("/tools/", 1)[0]
    cores = open(f"{root}/Sources/Models/RadioListenerCores.swift", encoding="utf-8").read()
    wikidata = open(f"{root}/Sources/Models/RadioWikidataCores.swift", encoding="utf-8").read()

    def names_of(text, marker, count=None):
        block = text[text.index(marker):]
        block = block[:block.index("\n    ]")]
        found = re.findall(r'"((?:[^"\\]|\\.)*)"', block)
        found = [n for n in found if not n.startswith(("DE", "AT", "CH"))]
        return found[:count] if count else found

    groups = []
    groups.append(("DE", names_of(cores, "static let germanyNational", 25)))
    nrw = cores[cores.index('"Nordrhein-Westfalen": ['):]
    groups.append(("DE", re.findall(r'"((?:[^"\\]|\\.)*)"', nrw[:nrw.index("],")])[1:]))
    groups.append(("AT", names_of(cores, "static let austriaNational")))
    groups.append(("CH", names_of(cores, "static let switzerlandNational", 20)))
    for code in ("FR", "GB", "US"):
        block = wikidata[wikidata.index(f'"{code}": ['):]
        names = re.findall(r'"((?:[^"\\]|\\.)*)"', block[:block.index("],")])
        groups.append((code, names[1:13]))

    stations, seen = [], set()
    for country, names in groups:
        for station in resolve_in_catalog(names, country):
            if station["stationuuid"] in seen:
                continue
            seen.add(station["stationuuid"])
            stations.append(station)
        if limit and len(stations) >= limit:
            break
    return stations[:limit] if limit else stations


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--pause", type=float, default=0.3)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    stations = target_set(args.limit)
    print(f"target set: {len(stations)} stations\n", file=sys.stderr)

    rows = []
    for index, station in enumerate(stations, 1):
        row = audit_station(station, args.pause)
        rows.append(row)
        print(f"{index:3}/{len(stations)}  {row['source']:8} {row['station'][:38]:38} "
              f"{row['stage'] or row['detail']}", file=sys.stderr)

    total = len(rows)
    by_source = {}
    for row in rows:
        by_source[row["source"]] = by_source.get(row["source"], 0) + 1
    real = by_source.get("favicon", 0) + by_source.get("chain", 0)
    print("\n" + "=" * 64)
    print(f"REAL LOGO: {real}/{total} = {100 * real / max(total, 1):.1f} %   (target ≥ 90 %)")
    for source, count in sorted(by_source.items()):
        print(f"  {source:8} {count}")
    print("\nchain contribution (the owner's first question — does it EVER deliver?):"
          f" {by_source.get('chain', 0)}")
    stages = {}
    for row in rows:
        if row["source"] == "NONE" and row["stage"]:
            key = row["stage"].split(" + ")[-1].split("-")[0] + "-" + \
                  row["stage"].split(" + ")[-1].split("-")[1] if "-" in row["stage"] else row["stage"]
            stages[row["stage"]] = stages.get(row["stage"], 0) + 1
    if stages:
        print("\nlosses by stage:")
        for stage, count in sorted(stages.items(), key=lambda kv: -kv[1]):
            print(f"  {count:3}  {stage}")
    if args.out:
        json.dump(rows, open(args.out, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
