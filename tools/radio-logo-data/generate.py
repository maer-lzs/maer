#!/usr/bin/env python3
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 🔴 e32454e (GO nach dem Messbericht): generierte LOGO-DATEN je Kern-Sender.
#
# Zwei Quellen, in dieser Reihenfolge — beide liefern einen Commons-DATEINAMEN,
# nie eine fertige URL (cb8bac1: Abgeleitetes entsteht beim Lesen):
#   1. Wikidata P154 des zugeordneten Objekts (die Laufzeit-Kette macht es auch,
#      nur eben pro Gerät und pro Kachel).
#   2. Commons-DATEISUCHE nach Sendername — die Klasse "Logo existiert, ist nur
#      nicht mit dem Objekt verknüpft" (3 der 9 Quellenlosen im Audit).
#
# Die Laufzeit-Kette bleibt Rückfall für den langen Schwanz.
#
# tooling gates (unverändert gültig): jede Abfrage liefert (Zeilen, Befund); eine
# leere oder unerreichbare Antwort schreibt NICHTS und endet auf Exit 2; der
# Schreibweg ist atomar.
#
# Nenner-Auflage (e32454e): das Ergebnis trägt seine ZIELMENGE — Laufdatum und
# den Stand der Kern-Tabellen —, damit zwei Quoten vergleichbar bleiben.

import hashlib
import io
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

UA = "Maer-radio-logo-data/1.0 (https://git.lschroeder.eu/the-owner/maer)"
MIN_SIDE = 48          # RadioFaviconGate.touchIconMinSide
COMMONS_WIDTH = 800    # RadioLogoService.commonsWidth
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def get(url, raw=False, timeout=25):
    """→ (payload, verdict). verdict: ok | empty | failed."""
    try:
        request = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = response.read()
            if not data:
                return None, "empty"
            return (data if raw else json.loads(data)), "ok"
    except Exception:
        return None, "failed"


def image_side(data):
    try:
        from PIL import Image
        with Image.open(io.BytesIO(data)) as image:
            return min(image.size)
    except Exception:
        return None


def fold(raw):
    import unicodedata
    text = unicodedata.normalize("NFKD", raw or "")
    text = "".join(c for c in text if not unicodedata.combining(c))
    return "".join(c for c in text.lower() if c.isalnum())


def core_names():
    """The target set: every name in the core tables (the app's own data)."""
    out = []
    for name in ("RadioListenerCores.swift", "RadioWikidataCores.swift"):
        path = os.path.join(ROOT, "Sources", "Models", name)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        for hit in re.findall(r'"((?:[^"\\]|\\.)*)"', text):
            if len(hit) >= 2 and not hit.endswith(":") and hit not in out:
                out.append(hit)
    return out


def wikidata_file(name):
    """Stage 1 — P154 of the matched entity."""
    for language in ("de", "en"):
        url = "https://www.wikidata.org/w/api.php?" + urllib.parse.urlencode(
            {"action": "wbsearchentities", "search": name, "language": language,
             "format": "json", "limit": 10})
        payload, verdict = get(url)
        if verdict == "failed":
            return None, "failed"
        wanted = fold(name)
        for hit in (payload or {}).get("search", []):
            have = fold(hit.get("label", ""))
            if not have or not (wanted in have or have in wanted):
                continue
            entity = hit.get("id")
            data, verdict = get(f"https://www.wikidata.org/wiki/Special:EntityData/{entity}.json")
            if verdict == "failed":
                return None, "failed"
            try:
                claims = data["entities"][entity].get("claims", {})
                return claims["P154"][0]["mainsnak"]["datavalue"]["value"], "ok"
            except Exception:
                break
        time.sleep(0.2)
    return None, "ok"      # measured, no result — that is a finding, not a failure


def commons_file(name):
    """Stage 2 — the Commons FILE SEARCH ("logo exists, just not linked")."""
    url = "https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode(
        {"action": "query", "list": "search",
         "srsearch": f"{name} logo filetype:bitmap|drawing",
         "srnamespace": "6", "srlimit": "5", "format": "json"})
    payload, verdict = get(url)
    if verdict == "failed":
        return None, "failed"
    for hit in (payload or {}).get("query", {}).get("search", []):
        title = hit["title"].replace("File:", "")
        thumb = "https://commons.wikimedia.org/w/thumb.php?" + urllib.parse.urlencode(
            {"f": title, "width": COMMONS_WIDTH})
        data, verdict = get(thumb, raw=True)
        if verdict == "failed":
            return None, "failed"
        side = image_side(data) if data else None
        if side and side >= MIN_SIDE:
            return title, "ok"
        time.sleep(0.2)
    return None, "ok"


def swift_file(entries, names, failures):
    """The data file. Names → Commons FILE NAME; the width is applied at read
    time from the app's one constant."""
    lines = []
    for name in sorted(entries):
        file_name = entries[name].replace("\\", "\\\\").replace('"', '\\"')
        key = name.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'        "{key}": "{file_name}",')
    stamp = time.strftime("%Y-%m-%d")
    digest = hashlib.sha256("\n".join(sorted(names)).encode()).hexdigest()[:12]
    return f'''// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

// GENERATED by tools/radio-logo-data/generate.py — edit the script, not this
// file. Run date: {stamp}.
//
// THE TARGET SET OF THIS RUN (the denominator, e32454e): {len(names)} core
// names, fingerprint {digest}. A later quota is only comparable to this one
// if the fingerprint matches — the core tables move with every maintenance
// round, and a wandering denominator makes two percentages meaningless.
// Measured: {len(entries)} of them carry a declared logo.

import Foundation

/// 🔴 e32454e: the logos of the CORE stations as generated DATA — Wikidata
/// P154 first, then the Commons FILE SEARCH (the class "a logo exists, it is
/// just not linked to the object"). Only the file NAME is stored; the width
/// is applied at read time from `RadioLogoService.commonsWidth`, so the next
/// width change is a constant, not a migration (the cb8bac1 lesson).
///
/// The runtime chain stays the fallback for the long tail — this table only
/// spares it the work for the stations everyone actually sees.
nonisolated enum RadioLogoData {{
    /// Station name (as in the core tables) → Commons file name.
    static let commonsFiles: [String: String] = [
{chr(10).join(lines)}
    ]

    /// Lookup by the name the core tables use.
    static func commonsFile(forName name: String) -> String? {{
        commonsFiles[name]
    }}
}}
'''


def main():
    dry = "--trocken" in sys.argv
    names = core_names()
    print(f"target set: {len(names)} core names", file=sys.stderr)
    entries, failures = {}, 0
    for index, name in enumerate(names, 1):
        file_name, verdict = wikidata_file(name)
        if verdict == "failed":
            failures += 1
        if not file_name:
            file_name, verdict = commons_file(name)
            if verdict == "failed":
                failures += 1
        if file_name:
            entries[name] = file_name
        if index % 25 == 0:
            print(f"  {index}/{len(names)} — {len(entries)} logos, {failures} failures",
                  file=sys.stderr)
        time.sleep(0.2)

    # tooling gate: nothing measured (or the service broke down) ⇒ write NOTHING.
    if not entries or failures > len(names) // 4:
        print(f"NICHT GEMESSEN — {len(entries)} Treffer, {failures} Fehlschlaege. "
              f"Keine Datei geschrieben.", file=sys.stderr)
        return 2

    print(f"\n{len(entries)}/{len(names)} = {100 * len(entries) / len(names):.1f} % "
          f"tragen ein deklariertes Logo ({failures} Transport-Fehlschlaege)")
    if dry:
        print("(trocken — nichts geschrieben)")
        return 0
    target = os.path.join(ROOT, "Sources", "Models", "RadioLogoData.swift")
    temporary = target + ".neu"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(swift_file(entries, names, failures))
    os.replace(temporary, target)      # atomic — never a half-written state
    print(f"Geschrieben: {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
