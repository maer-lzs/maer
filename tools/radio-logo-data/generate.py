#!/usr/bin/env python3
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Generated LOGO DATA per core station: a Commons FILE NAME, never a finished
# URL (the width is applied when the app reads it).
#
# One source, and an entry only with a binding: the logo (P154) of a Wikidata
# object that is a radio station (instance of Q14350 or of a subclass). A
# station named in the Wikidata core table carries its object in a comment
# there and is asked directly; every other name is searched by its exact
# label, and when several radio stations share that name, only the country of
# the core table decides, otherwise no entry. A file name match is no binding:
# the Commons file search booked photos and foreign logos whose names held the
# station name, so it is not asked any more.
#
# The table probe (`names_only_station`) and the tile gate (a raster the app's
# 48 px gate rejects never shows) hold in addition. A vouched entry
# (belegt.json) only lets a BOUND file pass the probe, for exactly that file;
# without a binding it makes no entry, unless it names why no station object
# can carry its logo (`unbound`, a family of match streams).
#
# Measuring gates: an answer that is empty or unreachable writes NOTHING and
# ends with exit 2; the write is atomic. Every request is counted, and the
# count goes into the report (`--bericht <path>`, JSON).
#
# The result carries its TARGET SET (run date, count, fingerprint over the
# names), so two quotas are only compared over the same set.

import hashlib
import json
import os
import re
import struct
import sys
import time
import urllib.parse
import urllib.request

UA = "Maer/1.0 (+https://maer.fm)"
MIN_SIDE = 48            # RadioFaviconGate.touchIconMinSide
RADIO_STATION = "Q14350"
PAUSE = 0.2              # seconds between two requests to the same service
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REQUESTS = 0             # every request of this run, counted in `get`


def get(url, raw=False, timeout=25):
    """(payload, verdict); verdict is ok, empty or failed. Counts the request
    and waits the pause after it."""
    global REQUESTS
    REQUESTS += 1
    try:
        request = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = response.read()
        if not data:
            return None, "empty"
        return (data if raw else json.loads(data)), "ok"
    except Exception:
        return None, "failed"
    finally:
        time.sleep(PAUSE)


def image_size(data):
    """Width and height of a PNG, GIF, JPEG or WebP, read from its header with
    the standard library; None for anything else or a header too short."""
    if not data:
        return None
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return struct.unpack(">II", data[16:24])
    if data[:6] in (b"GIF87a", b"GIF89a") and len(data) >= 10:
        return struct.unpack("<HH", data[6:10])
    if data[:2] == b"\xff\xd8":
        index = 2
        while index + 9 < len(data):
            if data[index] != 0xFF:
                index += 1
                continue
            marker = data[index + 1]
            if marker in (0xD8, 0x01, 0xFF) or 0xD0 <= marker <= 0xD7:
                index += 2 if marker != 0xFF else 1
                continue
            length = struct.unpack(">H", data[index + 2:index + 4])[0]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                height, width = struct.unpack(">HH", data[index + 5:index + 9])
                return width, height
            index += 2 + length
        return None
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP" and len(data) >= 30:
        chunk = data[12:16]
        if chunk == b"VP8X":
            return 1 + int.from_bytes(data[24:27], "little"), 1 + int.from_bytes(data[27:30], "little")
        if chunk == b"VP8L":
            bits = int.from_bytes(data[21:25], "little")
            return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        if chunk == b"VP8 ":
            return (struct.unpack("<H", data[26:28])[0] & 0x3FFF,
                    struct.unpack("<H", data[28:30])[0] & 0x3FFF)
    return None


# Words a file may carry besides the station name without meaning another
# thing. Every other word names something else, mostly another thing.
GENERIC_EXTRA = {
    "logo", "logos", "klein", "gross", "big", "small", "neu", "new",
    "radio", "svg", "png", "jpg", "jpeg", "gif", "de", "the", "of",
    "final", "rgb", "official", "icon", "wortmarke", "bildmarke",
}


def fold(raw):
    import unicodedata
    text = unicodedata.normalize("NFKD", raw or "")
    text = "".join(c for c in text if not unicodedata.combining(c))
    return "".join(c for c in text.lower() if c.isalnum())


def existing_mapping():
    """The table as it stands, the basis of the comparison."""
    path = os.path.join(ROOT, "Sources", "Models", "RadioLogoData.swift")
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return {}
    return dict(re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)",?\s*$', text, re.M))


def vouched():
    """Entries that keep a file whose name does not carry the station name
    alone, each with its file and its reason (belegt.json): a family logo,
    another spelling, a call sign. A name under four characters is only kept
    here."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "belegt.json")
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def names_only_station(name, title):
    """The probe of the table (`RadioLogoLookup.fileNamesOnlyTheLabel`): the
    file name carries the station name AND names nothing else, only generic
    words and digits around it. Measured: each of these carried the name
    and showed something else: "WFUV" a stadium photo, "Radio 1" the BBC
    logo, "All India Radio, Kolkata" an interview photo, "Antenne Tirol" a
    T-shirt."""
    wanted, folded = fold(name), fold(re.sub(r"\.[A-Za-z0-9]+$", "", title))
    if len(wanted) < 4:
        return False
    start = folded.find(wanted)
    while start >= 0:
        if only_generic_words(folded[:start]) and only_generic_words(folded[start + len(wanted):]):
            return True
        start = folded.find(wanted, start + 1)
    return False


def only_generic_words(rest):
    """Whether a folded rest splits entirely into generic words and digits."""
    reachable = [True] + [False] * len(rest)
    for end in range(1, len(rest) + 1):
        if rest[end - 1].isdigit() and reachable[end - 1]:
            reachable[end] = True
            continue
        for word in GENERIC_EXTRA:
            if len(word) <= end and reachable[end - len(word)] and rest[end - len(word):end] == word:
                reachable[end] = True
                break
    return reachable[len(rest)]


def label_ok(name, file_name, held):
    """The probe of the table (`names_only_station`), or the vouched entry for
    exactly this file. Measured: the table booked Wikidata P154 files without
    a probe, and "Ö 3" carried the logo of a football club; with the looser
    probe of the runtime (the name carried anywhere) it booked photos whose
    names held the station name."""
    if names_only_station(name, file_name):
        return True
    entry = held.get(name)
    return bool(entry) and entry.get("file") == file_name and bool(entry.get("reason"))


def renders_at_tile_size(file_name, size):
    """MediaWiki never upscales a raster, so a raster whose smaller side is
    under the app's 48 px gate can never show on a tile, and a table entry the
    gate always rejects shadows a working stored logo. An SVG scales and
    passes."""
    if file_name.lower().endswith(".svg"):
        return True
    if not size:
        return False   # an unknown raster size cannot be checked, so it is out
    return min(size) >= MIN_SIDE


def final_render_size(file_name):
    """The size the APP gets: the width 800 FilePath render. MediaWiki serves
    rasters unscaled, so only this render answers how big the logo is."""
    url = ("https://commons.wikimedia.org/wiki/Special:FilePath/"
           + urllib.parse.quote(file_name) + "?width=800")
    data, verdict = get(url, raw=True)
    return image_size(data) if verdict == "ok" and data else None


# Names the catalog shows that stand in no core table: the further stations
# of the Deutschlandfunk family, and the head of the two Bundesliga families
# whose tiles are "Fußball-Bundesliga: Spiel 1" and "Fußball-Bundesliga 2:
# Spiel 1"; `RadioLogoService.curatedFile` carries the one entry to both over
# its prefix rule.
EXTRA_NAMES = [
    "Deutschlandfunk Kultur",
    "Deutschlandfunk Nova",
    "Fußball-Bundesliga",
]


def core_names():
    """The target set: every station name in the core tables (the app's own
    data). Comments are cut first, country codes skipped, and so are the keys
    of the regional tables (a key that opens a block, `"Bayern": [` at the
    end of its line): read as names, "Beliebt in …" from a comment, "DE"
    from a `case "DE":` and "Bayern" from its block were searched and booked
    logos of strangers (a football club, party logos). A key with its
    aliases on the same line (`"Österreich 1": ["Ö1"]`) is a station."""
    out = list(EXTRA_NAMES)
    for name in ("RadioListenerCores.swift", "RadioWikidataCores.swift"):
        path = os.path.join(ROOT, "Sources", "Models", name)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        code = "\n".join(line.split("//", 1)[0] if not line.lstrip().startswith("///") else ""
                         for line in text.split("\n"))
        for match in re.finditer(r'"((?:[^"\\]|\\.)*)"', code):
            hit = match.group(1)
            if re.match(r"\s*:\s*\[[ \t]*\n", code[match.end():]):
                continue
            if re.fullmatch(r"[A-Z]{2}", hit):
                continue
            if len(hit) >= 2 and not hit.endswith(":") and hit not in out:
                out.append(hit)
    return out


def core_facts():
    """Per core name the countries of the tables it stands in, and the
    Wikidata object the Wikidata core table names for it in a comment
    (`"Triple J",  // Q1522899`). The listener tables are the German,
    Austrian and Swiss ones; the extra names are German."""
    facts = {name: {"countries": {"DE"}, "qid": None} for name in EXTRA_NAMES}

    def note(name, country, qid=None):
        entry = facts.setdefault(name, {"countries": set(), "qid": None})
        if country:
            entry["countries"].add(country)
        if qid and not entry["qid"]:
            entry["qid"] = qid

    country = None
    for line in open(os.path.join(ROOT, "Sources", "Models", "RadioWikidataCores.swift"), encoding="utf-8"):
        block = re.match(r'\s*"([A-Z]{2})":\s*\[\s*$', line)
        if block:
            country = block.group(1)
            continue
        hit = re.match(r'\s*"((?:[^"\\]|\\.)*)",?\s*(?://\s*(Q\d+))?', line)
        if hit and country:
            note(hit.group(1), country, hit.group(2))
    country = None
    for line in open(os.path.join(ROOT, "Sources", "Models", "RadioListenerCores.swift"), encoding="utf-8"):
        stripped = line.split("//", 1)[0]
        for prefix, code in (("germany", "DE"), ("austria", "AT"), ("switzerland", "CH")):
            if f"static let {prefix}" in stripped:
                country = code
        inline = re.search(r'case "([A-Z]{2})":', stripped)
        for match in re.finditer(r'"((?:[^"\\]|\\.)*)"', stripped):
            name = match.group(1)
            if re.fullmatch(r"[A-Z]{2}", name) or name.endswith(":"):
                continue
            if re.match(r"\s*:\s*\[[ \t]*$", stripped[match.end():]):
                continue
            note(name, inline.group(1) if inline else country)
    return facts


def sparql(query):
    url = "https://query.wikidata.org/sparql?" + urllib.parse.urlencode({"query": query, "format": "json"})
    payload, verdict = get(url, timeout=90)
    if verdict != "ok":
        return None
    return [{key: value["value"] for key, value in row.items()} for row in payload["results"]["bindings"]]


def radio_classes():
    """The radio station class and every subclass of it."""
    rows = sparql(f"SELECT ?c WHERE {{ ?c wdt:P279* wd:{RADIO_STATION} }}")
    return None if rows is None else {row["c"].rsplit("/", 1)[-1] for row in rows}


def country_codes():
    """Country object to its ISO code (P297)."""
    rows = sparql("SELECT ?c ?iso WHERE { ?c wdt:P297 ?iso }")
    return None if rows is None else {row["c"].rsplit("/", 1)[-1]: row["iso"].upper() for row in rows}


def search(name):
    """The objects whose label or alias is exactly the name, in German and
    English; None when a search failed."""
    found = []
    wanted = fold(name)
    for language in ("de", "en"):
        url = "https://www.wikidata.org/w/api.php?" + urllib.parse.urlencode(
            {"action": "wbsearchentities", "search": name, "language": language,
             "type": "item", "format": "json", "limit": 10})
        payload, verdict = get(url)
        if verdict == "failed":
            return None
        for hit in (payload or {}).get("search", []):
            texts = {hit.get("label", ""), (hit.get("match") or {}).get("text", "")}
            if any(fold(text) == wanted for text in texts) and hit.get("id") not in found:
                found.append(hit["id"])
    return found


def entities(ids):
    """Per object: its classes (P31), its logo (P154) and its countries (P17);
    None when the request failed."""
    if not ids:
        return {}
    url = "https://www.wikidata.org/w/api.php?" + urllib.parse.urlencode(
        {"action": "wbgetentities", "ids": "|".join(ids[:50]), "props": "claims", "format": "json"})
    payload, verdict = get(url)
    if verdict != "ok":
        return None

    def values(claims, prop):
        out = []
        for claim in claims.get(prop, []):
            value = (claim.get("mainsnak", {}).get("datavalue") or {}).get("value")
            if isinstance(value, dict) and "id" in value:
                out.append(value["id"])
            elif isinstance(value, str):
                out.append(value)
        return out

    result = {}
    for entity_id, entity in (payload.get("entities") or {}).items():
        claims = entity.get("claims", {})
        result[entity_id] = {"classes": set(values(claims, "P31")),
                             "logo": next(iter(values(claims, "P154")), None),
                             "countries": set(values(claims, "P17"))}
    return result


def bound_file(name, fact, radio, isos, search=search, entities=entities):
    """(file, object, reason, failed): the logo of the one radio station this
    name means, or the reason there is none. A name in the tables of several
    countries gets none: the table is keyed by the name alone, so one logo
    would show for every country's station of that name ("Radio 1" stands in
    the Belgian and the Swiss table). Several radio stations of the name are
    decided by the country of the core table over the STATIONS, not over
    their logos: a foreign station that alone carries a logo is still a
    foreign station. `search` and `entities` are the two lookups, handed in
    by the self check."""
    countries = (fact or {}).get("countries") or set()
    if len(countries) > 1:
        return None, None, f"name in the tables of {len(countries)} countries ({', '.join(sorted(countries))})", False
    ids = [fact["qid"]] if fact and fact.get("qid") else search(name)
    if ids is None:
        return None, None, "search failed", True
    if not ids:
        return None, None, "no Wikidata object with this exact name", False
    objects = entities(ids)
    if objects is None:
        return None, None, "object request failed", True
    stations = [(entity_id, data) for entity_id, data in objects.items() if data["classes"] & radio]
    if not stations:
        return None, None, "no object of the class radio station", False
    if len(stations) > 1:
        in_country = [(entity_id, data) for entity_id, data in stations
                      if {isos.get(c) for c in data["countries"]} & countries]
        if len({data["logo"] for _, data in in_country if data["logo"]}) != 1:
            return None, None, f"ambiguous: {len(stations)} radio stations, the country does not decide", False
        stations = in_country
    with_logo = [(entity_id, data) for entity_id, data in stations if data["logo"]]
    if not with_logo:
        return None, None, "radio station without a logo (P154)", False
    entity_id, data = with_logo[0]
    return data["logo"], entity_id, None, False


def resolve(name, fact, radio, isos, held):
    """The verdict of one name: (file, object, status, reason, failed)."""
    file_name, entity_id, reason, failed = bound_file(name, fact, radio, isos)
    if file_name and not label_ok(name, file_name, held):
        reason, file_name = f"probe: {file_name}", None
    if file_name and not renders_at_tile_size(file_name, final_render_size(file_name)):
        reason, file_name = f"tile gate: {file_name}", None
    if file_name:
        return file_name, entity_id, "bound", None, failed
    entry = held.get(name)
    if entry and entry.get("unbound") and entry.get("reason"):
        return entry["file"], None, "unbound", entry["unbound"], failed
    return None, None, "none", reason, failed


def swift_file(entries, names, single=None, check=False):
    """The data file. Names to Commons FILE NAME; the width is applied at read
    time from the app's one constant. The vouched entries travel along, so
    the suite holds every entry to the same probe."""
    def quoted(text):
        return text.replace("\\", "\\\\").replace('"', '\\"')
    lines = [f'        "{quoted(name)}": "{quoted(entries[name])}",' for name in sorted(entries)]
    held = vouched()
    vouched_lines = []
    for name in sorted(entries):
        entry = held.get(name)
        if entry and entry.get("file") == entries[name]:
            vouched_lines.append(f'        "{quoted(name)}": (file: "{quoted(entry["file"])}", reason: "{quoted(entry["reason"])}"),')
    stamp = time.strftime("%Y-%m-%d")
    digest = hashlib.sha256("\n".join(sorted(names)).encode()).hexdigest()[:12]
    note = ""
    if single:
        note = (f"\n// SINGLE-NAME RUN: only \"{single}\" was measured, every other"
                f"\n// entry comes unchanged from the last full run.")
    if check:
        note = ("\n// CHECK RUN: no source was asked. The entries of the last run were"
                "\n// held to the table probe (the file names the station and nothing"
                "\n// else); what failed it and is not vouched left.")
    return f'''// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

// GENERATED by tools/radio-logo-data/generate.py. Edit the script, not this
// file. Run date: {stamp}.{note}
//
// THE TARGET SET OF THIS RUN (the denominator): {len(names)} core
// names, fingerprint {digest}. A later quota is only comparable to this one
// if the fingerprint matches. The core tables move with every maintenance
// round, and a wandering denominator makes two percentages meaningless.
// Measured: {len(entries)} of them carry a declared logo.

import Foundation

/// 🔴 The logos of the CORE stations as generated DATA: the logo (P154) of
/// the one Wikidata object of the class radio station a name means, held to
/// the table probe, or vouched for exactly its bound file.
/// Only the file NAME is stored; the width is applied at read time from
/// `RadioLogoService.commonsWidth`, so the next width change is a constant,
/// not a migration.
///
/// The runtime chain stays the fallback for the long tail. This table only
/// spares it the work for the stations everyone actually sees.
nonisolated enum RadioLogoData {{
    /// Station name (as in the core tables) → Commons file name.
    static let commonsFiles: [String: String] = [
{chr(10).join(lines)}
    ]

    /// Entries whose file name does not name the station alone, kept with
    /// their reason (tools/radio-logo-data/belegt.json). Every other entry
    /// passes `RadioLogoLookup.fileNamesOnlyTheLabel`.
    static let vouched: [String: (file: String, reason: String)] = [
{chr(10).join(vouched_lines)}
    ]

    /// Lookup by the name the core tables use.
    static func commonsFile(forName name: String) -> String? {{
        commonsFiles[name]
    }}
}}
'''


def write_table(entries, names, **mode):
    target = os.path.join(ROOT, "Sources", "Models", "RadioLogoData.swift")
    temporary = target + ".neu"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(swift_file(entries, names, **mode))
    os.replace(temporary, target)      # atomic: never a half-written state
    print(f"Geschrieben: {target} ({len(entries)} Eintraege)")


def offline_check(dry):
    """`--pruefen`: the last run's entries held to the table probe, without
    asking any source. What fails and is not vouched leaves the table."""
    previous = existing_mapping()
    if not previous:
        print("Kein Bestand gefunden.", file=sys.stderr)
        return 2
    names = core_names()
    held = vouched()
    entries, gone = {}, []
    for name, file_name in sorted(previous.items()):
        if name in names and label_ok(name, file_name, held):
            entries[name] = file_name
        else:
            gone.append((name, file_name))
    for name, file_name in gone:
        print(f"  raus: {name} -> {file_name}", file=sys.stderr)
    stale = sorted(n for n in held if entries.get(n) != held[n].get("file"))
    if stale:
        print(f"Belegt, aber nicht in der Tabelle: {stale}", file=sys.stderr)
        return 2
    print(f"{len(entries)} bleiben, {len(gone)} raus, {len(names)} Kern-Namen")
    if dry:
        print("(trocken: nichts geschrieben)")
        return 0
    write_table(entries, names, check=True)
    return 0


def lookups():
    """The class set and the country codes, asked once per run."""
    radio, isos = radio_classes(), country_codes()
    if not radio or not isos:
        print("NICHT GEMESSEN: Klassen oder Laendercodes nicht gelesen. Keine Datei geschrieben.",
              file=sys.stderr)
        return None
    return radio, isos


def single_run(name, dry):
    """`--nur "<Name>"`: ONE name measured by the same rule and put into the
    table; every other entry stays byte for byte."""
    previous = existing_mapping()
    if not previous:
        print("Kein Bestand gefunden: ein Einzelnamen-Lauf braucht eine bestehende Tabelle.", file=sys.stderr)
        return 2
    found = lookups()
    if not found:
        return 2
    radio, isos = found
    file_name, entity_id, status, reason, failed = resolve(name, core_facts().get(name), radio, isos, vouched())
    if failed or not file_name:
        print(f"NICHT GEMESSEN: {name}: {reason}. Keine Datei geschrieben.", file=sys.stderr)
        return 2
    entries = dict(previous)
    entries[name] = file_name
    print(f"{name}: {previous.get(name) or '(neu)'} -> {file_name} ({status}, {entity_id}); Abrufe {REQUESTS}")
    if dry:
        print("(trocken: nichts geschrieben)")
        return 0
    write_table(entries, core_names(), single=name)
    return 0


def full_run(dry, report_path):
    names = core_names()
    facts = core_facts()
    previous = existing_mapping()
    held = vouched()
    found = lookups()
    if not found:
        return 2
    radio, isos = found
    print(f"target set: {len(names)} core names, {len(radio)} radio classes", file=sys.stderr)
    entries, rows, failures = {}, [], 0
    for index, name in enumerate(names, 1):
        # A truncated name ("… Premium") is an artifact of the source tables;
        # a search on its tail matches foreign brands.
        if name.startswith("…") or name.startswith("..."):
            continue
        file_name, entity_id, status, reason, failed = resolve(name, facts.get(name), radio, isos, held)
        failures += failed
        if file_name:
            entries[name] = file_name
        before = previous.get(name)
        change = ("kept" if before == file_name else "new" if before is None and file_name
                  else "dropped" if file_name is None and before else "changed" if file_name else "none")
        rows.append({"name": name, "status": status, "change": change, "file": file_name,
                     "before": before, "object": entity_id, "reason": reason})
        if index % 25 == 0:
            print(f"  {index}/{len(names)}: {len(entries)} logos, {failures} failures, {REQUESTS} requests",
                  file=sys.stderr)
    summary = {"names": len(names), "entries_before": len(previous), "entries_after": len(entries),
               "bound": sum(r["status"] == "bound" for r in rows),
               "unbound": sum(r["status"] == "unbound" for r in rows),
               "failures": failures, "requests": REQUESTS}
    if report_path:
        with open(report_path, "w", encoding="utf-8") as handle:
            json.dump({"summary": summary, "rows": rows}, handle, ensure_ascii=False, indent=1)
    print(json.dumps(summary))
    # Measuring gate: nothing measured, or the service broke down: write NOTHING.
    if not entries or failures > len(names) // 4:
        print(f"NICHT GEMESSEN: {len(entries)} Treffer, {failures} Fehlschlaege. Keine Datei geschrieben.",
              file=sys.stderr)
        return 2
    if dry:
        print("(trocken: nichts geschrieben)")
        return 0
    write_table(entries, names)
    return 0


def self_check():
    """`--selbstpruefung`: the binding rule over fixed answers, no request.
    Exit 0 when every case holds, 1 when one does not."""
    radio, isos = {RADIO_STATION}, {"Q183": "DE", "Q142": "FR"}

    def station(country, logo):
        return {"classes": {RADIO_STATION}, "logo": logo, "countries": {country}}

    cases = [
        ("two stations, only the foreign one with a logo", {"countries": {"DE"}},
         {"Q1": station("Q183", None), "Q2": station("Q142", "Fremd.svg")}, None),
        ("two stations, the own one with a logo", {"countries": {"DE"}},
         {"Q1": station("Q183", "Eigen.svg"), "Q2": station("Q142", None)}, "Eigen.svg"),
        ("two stations with different logos, the country decides", {"countries": {"DE"}},
         {"Q1": station("Q183", "Eigen.svg"), "Q2": station("Q142", "Fremd.svg")}, "Eigen.svg"),
        # The foreign station first: only the country, not the order of the
        # answer, may pick the own one.
        ("two stations with logos, the foreign one first", {"countries": {"DE"}},
         {"Q2": station("Q142", "Fremd.svg"), "Q1": station("Q183", "Eigen.svg")}, "Eigen.svg"),
        ("two own stations with one logo and a foreign one first", {"countries": {"DE"}},
         {"Q3": station("Q142", "Fremd.svg"), "Q1": station("Q183", "Eigen.svg"),
          "Q2": station("Q183", "Eigen.svg")}, "Eigen.svg"),
        ("two stations and no country", None,
         {"Q1": station("Q183", "Eigen.svg"), "Q2": station("Q142", "Fremd.svg")}, None),
        ("one station with a logo", None, {"Q1": station("Q142", "Einzig.svg")}, "Einzig.svg"),
    ]
    failed = 0
    for title, fact, objects, expected in cases:
        file_name, _, reason, _ = bound_file("X", fact, radio, isos,
                                             search=lambda _name, ids=list(objects): ids,
                                             entities=lambda _ids, objects=objects: objects)
        held = file_name == expected
        failed += not held
        print(f"{'ok ' if held else 'ROT'} {title}: {file_name or reason}")
    return 1 if failed else 0


def main():
    if "--selbstpruefung" in sys.argv:
        return self_check()
    dry = "--trocken" in sys.argv
    report_path = None
    if "--bericht" in sys.argv:
        index = sys.argv.index("--bericht")
        if index + 1 >= len(sys.argv):
            print("--bericht braucht einen Pfad", file=sys.stderr)
            return 2
        report_path = sys.argv[index + 1]
    if "--nur" in sys.argv:
        index = sys.argv.index("--nur")
        if index + 1 >= len(sys.argv):
            print("--nur braucht einen Namen", file=sys.stderr)
            return 2
        return single_run(sys.argv[index + 1], dry)
    if "--pruefen" in sys.argv:
        return offline_check(dry)
    return full_run(dry, report_path)


if __name__ == "__main__":
    raise SystemExit(main())
