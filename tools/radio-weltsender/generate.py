#!/usr/bin/env python3
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Weltsender-Kern: eine POSITIVE Liste der internationalen Dienste
# aktiver EBU-Mitglieder fuer die Weltweit-Reihen. Kein Feld bewertet
# einen Sender; wer nicht drin ist, ueber den sagt die Liste nichts.
#
# Warum werkzeugseitig: die Wikidata-Rohdaten zur EBU-Mitgliedschaft
# sind gemessen verschmutzt (eine Person, ein Festival, label-lose
# QIDs in denselben 108 Treffern). Deshalb entdeckt dieses Werkzeug
# NICHTS selbst; es prueft eine benannte Saat und faellt je Eintrag
# ein lautes Urteil. Die vier Tore des Kerne-Generators gelten:
#   1. je Eintrag ein Urteil (bestanden / durchgefallen mit Grund),
#      nie ein stilles Verschwinden;
#   2. geschrieben wird ATOMISCH und NUR, wenn jeder Eintrag ein
#      Urteil bekommen hat (keine Netzluecke wird zu Daten);
#   3. Durchgefallene stehen IM Lauf-Bericht und in der Exit-Codes;
#   4. die Rohbefunde (Label, Klassenpfad, Katalogtreffer) stehen im
#      Bericht, damit der Lauf gegen den Auftrag pruefbar ist.
# Exit: 0 alle bestanden · 1 gemessen mit Durchfaellen · 2 nicht
# gemessen (Netz/Endpunkt), nichts geschrieben.
#
# Usage: python3 tools/radio-weltsender/generate.py

import json
import os
import sys
import time
import urllib.parse
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, "..", "..", "Sources", "Models", "RadioWorldServices.swift")
WDQS = "https://query.wikidata.org/sparql"
UA = "MaerWeltsenderGenerator/1.0 (tools/radio-weltsender)"

# Die Saat: (Anzeigename im Radio-Browser, Wikidata-Suchname).
# Nur Dienste, deren Haus ein AKTIVES EBU-Mitglied ist; die
# Mitgliedschaft prueft der Lauf an Wikidata (P463 -> Q166400, auch
# ueber die Eigentums-/Teil-Kette). Nicht-europaeische Ergaenzungen
# sind entschieden Einzel-Kuration und kommen erst mit einem Wort dazu.
SEEDS = [
    ("BBC World Service", "BBC World Service"),
    # Der Katalogname traegt das "Radio" hinten (gemessen; die nackte
    # Form faengt sonst die Musikrichtung Neue Deutsche Welle).
    ("Deutsche Welle Radio", "Deutsche Welle"),
    ("RFI Monde", "Radio France Internationale"),
    ("RFI Afrique", "Radio France Internationale"),
    ("Radio Exterior de España", "Radio Exterior de España"),
    ("Radio Romania International", "Radio Romania International"),
]

# Dieselben Spiegel wie RadioBrowserClient in der App (fi1 ist tot,
# DNS loest nicht mehr auf; am 30.08. gemessen).
RB_MIRRORS = [
    "https://de1.api.radio-browser.info",
    "https://at1.api.radio-browser.info",
    "https://nl1.api.radio-browser.info",
]


_LAST_WIKIDATA = [0.0]


def fetch_json(url, timeout=45):
    # Wikidata-Anfragen laufen mit festem Abstand und 429-Geduld: die
    # Kette je Saat stellt mehrere Anfragen, und der Dienst weist dichte
    # Folgen ab. Ein abgewiesener Dienst ist kein Messwert.
    is_wikidata = "wikidata.org" in url
    for attempt in range(4):
        if is_wikidata:
            elapsed = time.time() - _LAST_WIKIDATA[0]
            if elapsed < 5:
                time.sleep(5 - elapsed)
            _LAST_WIKIDATA[0] = time.time()
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": UA, "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"HTTP {resp.status}")
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as err:
            if err.code in (429, 503) and attempt < 3:
                print(f"  ({err.code}, warte 60 s)", flush=True)
                time.sleep(60)
                continue
            raise
    raise RuntimeError("unreachable")


def wikidata_entity(search_name):
    """wbsearchentities: erster Treffer, dessen Label den Suchnamen traegt."""
    url = ("https://www.wikidata.org/w/api.php?action=wbsearchentities&format=json"
           "&language=en&limit=5&search=" + urllib.parse.quote(search_name))
    data = fetch_json(url)
    for hit in data.get("search", []):
        label = (hit.get("label") or "").casefold()
        if search_name.casefold() in label or label in search_name.casefold():
            return hit["id"], hit.get("label", "")
    return None, None


# Die Klassen-Positivliste fuer P31, DIREKT gelesen (der SPARQL-Weg mit
# Unterklassen-Schluss stand beim Bau unter Ausfall-Drossel; die
# Entity-API traegt dieselbe Aussage ohne Schluss). Der Lauf DRUCKT die
# gesehenen P31-Werte, eine fehlende Klasse faellt also laut auf und
# wird bewusst ergaenzt statt still akzeptiert.
BROADCAST_CLASSES = {
    "Q14350",       # radio station
    "Q1268563",     # international broadcaster
    "Q104836811",   # radio channel
    "Q15265344",    # broadcaster
    "Q141683",      # broadcasting organisation
    "Q1616075",     # television station (Mehrspartenhaeuser wie DW)
    "Q10689397",    # television production company
    "Q7094076",     # public broadcaster (alte Form)
    "Q11033",       # mass media (nur als LETZTE Stufe sichtbar im Bericht)
}
EBU = "Q166400"


def entity_claims(qid):
    url = ("https://www.wikidata.org/w/api.php?action=wbgetentities&format=json"
           "&props=claims&ids=" + qid)
    data = fetch_json(url)
    return data.get("entities", {}).get(qid, {}).get("claims", {})


def claim_targets(claims, prop):
    out = []
    for st in claims.get(prop, []):
        value = st.get("mainsnak", {}).get("datavalue", {}).get("value", {})
        if isinstance(value, dict) and value.get("id"):
            out.append(value["id"])
    return out


def is_broadcast_service(claims):
    p31 = claim_targets(claims, "P31")
    return bool(set(p31) & BROADCAST_CLASSES), p31


def is_ebu_linked(qid, claims):
    # Mitglied selbst ODER ueber die Eigentums-/Betreiber-/Teil-Kette
    # eines Mitglieds (RFI gehoert France Medias Monde), Tiefe 2.
    if EBU in claim_targets(claims, "P463"):
        return True
    parents = []
    for prop in ("P127", "P749", "P361"):
        parents += claim_targets(claims, prop)
    for parent in parents[:6]:
        time.sleep(1)
        parent_claims = entity_claims(parent)
        if EBU in claim_targets(parent_claims, "P463"):
            return True
        for prop in ("P127", "P749", "P361"):
            for grand in claim_targets(parent_claims, prop)[:3]:
                time.sleep(1)
                if EBU in claim_targets(entity_claims(grand), "P463"):
                    return True
    return False


def fold(name):
    return "".join(ch for ch in name.casefold() if ch.isalnum())


def radio_browser_alive(name):
    # Zwei Runden ueber die Spiegel mit Abstand: eine dichte Folge von
    # Suchanfragen kann einen Spiegel kurz abweisen, und ein kurz
    # abweisender Spiegel ist kein Messwert ueber den Sender.
    #
    # Der Treffer muss dem Namen GEHOEREN: Falt-Schluessel gleich oder
    # der Katalogname BEGINNT mit dem Saat-Namen (Zusaetze wie "[REE]"
    # davor sind erlaubt, der Vergleich laeuft auf dem gefalteten Rest).
    # Die weiche Enthaltensein-Probe hat im ersten Lauf "Deutsche Welle"
    # auf ein NDW-Musikradio gebucht; genau die Klasse faengt der Zaun.
    query = urllib.parse.quote(name)
    wanted = fold(name)
    for round_no in range(2):
        for mirror in RB_MIRRORS:
            try:
                hits = fetch_json(
                    mirror + "/json/stations/search?limit=20&name=" + query, timeout=30)
            except Exception:
                time.sleep(3)
                continue
            for st in hits:
                st_fold = fold(st.get("name") or "")
                owns = st_fold == wanted or st_fold.startswith(wanted) \
                    or st_fold.endswith(wanted)
                if owns and st.get("lastcheckok") == 1:
                    return True, st.get("name"), st.get("votes")
            return False, None, None
        if round_no == 0:
            time.sleep(10)
    raise RuntimeError("kein Radio-Browser-Spiegel erreichbar")


def main():
    verdicts = []
    for rb_name, wd_name in SEEDS:
        row = {"name": rb_name, "wikidata": wd_name}
        try:
            qid, label = wikidata_entity(wd_name)
            if not qid:
                row["urteil"] = "durchgefallen: Wikidata kennt kein passendes Label"
                verdicts.append(row)
                continue
            row["qid"] = qid
            row["label"] = label
            time.sleep(1)
            claims = entity_claims(qid)
            broadcast, p31 = is_broadcast_service(claims)
            row["p31"] = ",".join(p31)
            if not broadcast:
                row["urteil"] = f"durchgefallen: {qid} ist keine Rundfunk-Klasse (P31: {p31})"
                verdicts.append(row)
                continue
            if not is_ebu_linked(qid, claims):
                row["urteil"] = f"durchgefallen: {qid} ohne EBU-Pfad (P463 {EBU})"
                verdicts.append(row)
                continue
            alive, matched, votes = radio_browser_alive(rb_name)
            if not alive:
                row["urteil"] = "durchgefallen: kein spielbarer Katalog-Treffer"
                verdicts.append(row)
                continue
            row["katalog"] = matched
            row["votes"] = votes
            row["urteil"] = "bestanden"
            verdicts.append(row)
            time.sleep(1)
        except Exception as err:
            print(f"NICHT GEMESSEN bei {rb_name}: {err}", file=sys.stderr)
            print("Nichts geschrieben.", file=sys.stderr)
            return 2

    passed = [v for v in verdicts if v["urteil"] == "bestanden"]
    failed = [v for v in verdicts if v["urteil"] != "bestanden"]

    print("== Lauf-Bericht Weltsender ==")
    for v in verdicts:
        extra = f" ({v.get('qid', '?')}, Katalog: {v.get('katalog', '-')}, votes {v.get('votes', '-')})"
        print(f"  {v['name']}: {v['urteil']}{extra}")

    if not passed:
        print("Kein Eintrag bestanden. Nichts geschrieben.", file=sys.stderr)
        return 2

    stamp = time.strftime("%d.%m.%Y")
    names = sorted(v["name"] for v in passed)
    lines = []
    lines.append("// Mär — an audio player for self-hosted open ecosystems")
    lines.append("// Copyright (C) 2026 Laurenz Schröder")
    lines.append("// SPDX-License-Identifier: GPL-3.0-or-later")
    lines.append("// Additional terms apply — see LICENSE-ADDITIONAL-TERMS")
    lines.append("")
    lines.append("// GENERATED by tools/radio-weltsender/generate.py. Edit the script,")
    lines.append(f"// not this file. Run date: {stamp}.")
    lines.append("")
    lines.append("import Foundation")
    lines.append("")
    lines.append("/// The WORLD SERVICES core of the worldwide spoken-genre rows: a")
    lines.append("/// positive list (these we show), criterion membership of the house")
    lines.append("/// in the EBU, verified at wikidata (P463 to Q166400, ownership")
    lines.append("/// chain included) plus a playable entry in the live catalog on the")
    lines.append("/// run date. Votes cannot carry this row: the vote spread between")
    lines.append("/// the services is three orders of magnitude, so a vote sort shows")
    lines.append("/// one of them and buries the rest. No field rates a station and")
    lines.append("/// absence states nothing; the order is alphabetical on purpose so")
    lines.append("/// the list itself claims no ranking. Non-European additions are")
    lines.append("/// curated one by one, never derived from a criterion that only")
    lines.append("/// holds inside the European broadcasting zone.")
    lines.append("nonisolated enum RadioWorldServices {")
    lines.append(f"    /// EBU membership checked at wikidata on {stamp}.")
    lines.append("    static let services: [String] = [")
    for v in sorted(passed, key=lambda x: x["name"]):
        lines.append(f"        \"{v['name']}\",  // {v['qid']}")
    lines.append("    ]")
    lines.append("}")
    lines.append("")

    tmp = TARGET + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    os.replace(tmp, TARGET)
    print(f"geschrieben: {os.path.relpath(TARGET, os.path.join(HERE, '..', '..'))} "
          f"({len(passed)} Eintraege, {len(failed)} durchgefallen)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
