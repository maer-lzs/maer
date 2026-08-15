#!/usr/bin/env python3
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 🟡 f291df3: HARDENED generator — replaces the version that wrote
# unconditionally. A valid but EMPTY WDQS answer (HTTP 200, no bindings —
# it happens during endpoint hiccups) used to overwrite the real table with
# an empty one, report "0 countries" and exit 0: a failure that looked like
# a measurement and destroyed the stock with a success message. The queries
# (EBU = Q166400, anchors, the two-stage toplist) are unchanged; the four
# gates around them are the point:
#   1. every query returns (rows, verdict) — the ladder asks "was anything
#      measured at all?" BEFORE it asks what was measured;
#   2. the file is written ATOMICALLY (os.replace) and ONLY on a real
#      measurement — a failed EBU query (the backbone) writes nothing;
#   3. countries below MIN_CORE are NAMED, not silently dropped;
#   4. raw counts before the cap go into the run report, so the result can
#      be compared against an order's magnitudes at all.
# Exit: 0 measured and within range · 1 measured with deviations · 2 NOT
# measured (network, empty answer, tool error) — nothing is written then.
#
# Usage: python3 tools/radio-wikidata-cores/generate.py
#        (defaults to Sources/Models/RadioWikidataCores.swift in this repo)
"""Ballon 41 — Wikidata-Kerne fuer die Radio-Reihen (Nicht-DACH), gehaertet.

## Warum dieses Werkzeug the implementer's Skript nicht ersetzt, sondern uebernimmt

Der Auftrag loest den Generator aus the implementer's Auftrag heraus („the implementer verdrahtet, du
generierst"). the implementer war schneller als die Korrektur und hat auf `dev@52744e8`
bereits `tools/radio-wikidata-cores/generate.py` geliefert. Ein zweiter Generator
daneben waere genau die Doppelfassung, die ich in Ballon 39 als Begruendung gegen
einen Nachbau geschrieben habe — zwei Fassungen derselben Liste driften.

Die ABFRAGEN stammen deshalb unveraendert aus the implementer's Skript; sie tragen the reviewer's am
echten Endpunkt verifizierte Form (EBU = Q166400, Sitelink-Rang, Anker fuer
Nicht-EBU-Maerkte) und seine zweistufige Toplist (erst ranken ohne Label-Dienst,
dann nur die Spitze beschriften — die Antwort auf ein 504). Was hier dazukommt,
ist das, was die vier Tore des Auftrags verlangen und was messbar fehlte.

## Was gemessen fehlte (Attrappenlauf vom 15.08., Belege in `ergebnisse/`)

**Eine gueltige, LEERE Antwort schrieb eine leere Tabelle ueber die 567 Zeilen
echter Daten, meldete „0 countries" und kehrte normal zurueck — Exit 0.** Das ist
Always-On-Test Nr. 4 in Reinform: ein Fehlschlag, der wie ein Messwert aussieht,
und hier zerstoert er obendrein den Bestand. (Die andere Haelfte hielt: ein
unerreichbares Ziel warf sichtbar und liess die Datei unangetastet.)

Dazu drei kleinere, aber gleichartige Stellen:
* `MAX_CORE` kappte die Zahlen VOR jeder Ausgabe — gegen the reviewer's Groessenordnung
  „DE 117" laesst sich eine gekappte 30 nicht abgleichen. Die Rohzahl wurde nie
  festgehalten, also war Tor 1 gar nicht erfuellbar.
* Laender unter `MIN_CORE` verschwanden STILL. Wer „UK fehlt" liest, erfaehrt
  nicht, ob nicht gemessen oder weggefiltert wurde.
* Der Lauf berichtete fuenf Namen je Land; Tor 4 verlangt zehn fuer die
  Stichprobenlaender.

## Der Kern der Haertung: kein Weg von einer Antwort zu Daten ohne Urteil

Jede einzelne Abfrage geht durch `u2_antworturteil.antwort_urteil` — die Leiter
stellt ZUERST die Frage „wurde ueberhaupt gemessen?" und erst danach die nach dem
Inhalt (Verdikt-Umdeutungs-Regel A). Es gibt in diesem Werkzeug keine Stelle, an
der eine Zeilenliste ohne dieses Urteil weiterwandert.

Scheitert die EBU-Abfrage — das Rueckgrat —, wird **nichts geschrieben** und der
Lauf endet auf 2. Scheitert eine Laender-Abfrage, ist dieses Land
`nicht_geprueft` und ausdruecklich NICHT 0 (Always-On Nr. 4, Regel C: ein
gescheiterter Vorbereitungsschritt entwertet den Befund, er fusst ihn nicht an).

Aufruf:

    python3 sources/generate.py --aus /pfad/RadioWikidataCores.swift
    python3 sources/generate.py --json --aus /pfad/datei.swift
    python3 sources/generate.py --endpunkt http://127.0.0.1:9/sparql --aus /tmp/x.swift
    python3 sources/generate.py --trocken            # misst, schreibt nichts

Exit: 0 alles gemessen und im Rahmen · 1 gemessen, aber Abweichungen gegen die
Referenz · 2 nicht gemessen (Netz, leere Antwort, Werkzeugfehler) — dann wird
KEINE Datei geschrieben.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HIER = os.path.dirname(os.path.abspath(__file__))
WURZEL = os.path.dirname(HIER)
sys.path.insert(0, os.path.join(HIER, "_parts"))
from u1_laenderurteil import laender_urteil    # noqa: E402
from u2_antworturteil import antwort_urteil    # noqa: E402
from u3_swifttabelle import swift_tabelle      # noqa: E402

# --- unveraendert aus the implementer's Skript (dev@52744e8) ---------------------------
ENDPUNKT_VORGABE = "https://query.wikidata.org/sparql"
KENNUNG = "Maer-radio-core-generator/1.0 (https://git.lschroeder.eu/the-owner/maer)"
ERSTHAND = {"DE", "AT", "CH"}          # dort gelten die Ersthand-Tabellen
# Anker-Laender: der EBU-Mitgliedschaftsfilter wird hier durch eine benannte
# Anstalt ersetzt. `None` heisst: fuer dieses Land greift kein Anker, der Kern
# kommt allein aus der laenderweiten Toplist — beim NPR-Anker war das der
# gemessene Ballon-41-Befund (NPR ist ein VERBUND; die Mitgliedssender gehoeren
# ihm nicht ueber P127/P137/P749), e9ee804 nimmt ihn deshalb ersatzlos raus.
ANKER = {
    "US": None,          # NPR greift strukturell nicht (Verbund)
    "AU": "Q781365",     # Australian Broadcasting Corporation
    "JP": "Q212128",     # NHK
    "KR": "Q498825",     # Korean Broadcasting System
    "NZ": "Q1626518",    # Radio New Zealand
    "ZA": "Q1419926",    # South African Broadcasting Corporation
    "IN": "Q1321122",    # All India Radio
}
# e9ee804 (owner decision, Option A): DATEN-Flag, kein Code-Sonderweg —
# in diesen Laendern verlangt die Toplist zusaetzlich die Inlands-Lizenzstadt
# (`wdt:P1408`, "licensed to broadcast to"). Sitelinks messen BEKANNTHEIT:
# ohne den Filter fuehren die Auslandsdienste (VOA/RFE/RFA/TWR) die US-Liste
# an, obwohl sie kein US-Publikum haben. Mit dem Filter fallen sie
# STRUKTURELL raus (sie haben keine Lizenzstadt) — positive Einschluss-
# Konstruktion statt Ausschlussliste. Ein Land mit demselben Problem ist
# morgen eine Datenzeile hier.
NUR_INLANDSLIZENZ = {"US"}

MIN_KERN = 5
MAX_KERN = 30
LABEL_SPRACHEN = ("en,fr,de,it,es,pl,cs,nl,sv,da,no,fi,pt,hu,ro,el,tr,uk,ja,ko,zh")

# the reviewer's Groessenordnungen, am echten Endpunkt gemessen (Auftrag Ballon 41).
# Das ist die Referenz fuer Tor 1 — sie steht hier als DATEN, damit eine
# Korrektur ein Diff ist und kein Programmierakt.
#
# ACHTUNG beim Schluessel: der Auftrag nennt das Vereinigte Koenigreich "UK",
# Wikidatas P297 liefert aber "GB". Gegen "UK" verglichen stand das Land im
# ersten Referenzlauf dauerhaft und faelschlich auf `fehlt` — der Schluessel
# MUSS der ISO-Code der Abfrage sein, nicht der Umgangsname aus dem Auftrag.
REFERENZ = {"DE": 117, "GB": 47, "FR": 31, "CZ": 31, "PL": 24, "BE": 20,
            "CH": 17, "AT": 15, "IT": 14}
TOLERANZ = 0.35

# Wie viele Zeilen eine Abfrageart mindestens liefern muss, damit ihr Ergebnis
# deutbar ist. Unterhalb davon ist es `leer_gemessen` — kein Messwert.
MINDEST_ZEILEN = {"ebu": 50, "anker": 1, "toplist": 1}


def sparql(abfrage, endpunkt, kennung=KENNUNG, timeout=180, versuche=3,
           wartezeit=10, schlafen=time.sleep, oeffnen=None):
    """Eine SPARQL-Abfrage stellen. → (zeilen, befund).

    Gibt IMMER beides zurueck: die Zeilen (moeglicherweise None) UND einen
    Befund, aus dem `antwort_urteil` ablesen kann, ob ueberhaupt gemessen wurde.
    Es gibt bewusst keinen Rueckgabeweg, der nur Zeilen liefert — genau daran
    haengt die Klasse, die dieses Werkzeug behebt.

    `schlafen` und `oeffnen` sind eingehaengt, damit ein Test den GESENDETEN
    Aufruf beobachten kann statt des Rueckgabewerts (Always-On Nr. 4, Regel B).
    """
    oeffnen = oeffnen or urllib.request.urlopen
    url = endpunkt + "?" + urllib.parse.urlencode({"query": abfrage, "format": "json"})
    anfrage = urllib.request.Request(url, headers={"User-Agent": kennung})
    letzter_status, letzter_fehler = None, None

    for versuch in range(versuche):
        try:
            with oeffnen(anfrage, timeout=timeout) as antwort:
                status = getattr(antwort, "status", 200)
                daten = json.load(antwort)
            zeilen = daten.get("results", {}).get("bindings")
            if not isinstance(zeilen, list):
                return None, {"fehler": "Antwort ohne results.bindings",
                              "http_status": status, "zeilen": None}
            return zeilen, {"fehler": None, "http_status": status,
                            "zeilen": len(zeilen)}
        except urllib.error.HTTPError as fehler:
            letzter_status = fehler.code
            letzter_fehler = f"HTTP {fehler.code}"
            if fehler.code in (429, 500, 502, 503, 504) and versuch < versuche - 1:
                schlafen(wartezeit * (versuch + 1))
                continue
            break
        except Exception as fehler:                       # Netz, DNS, JSON, TLS
            letzter_fehler = f"{type(fehler).__name__}: {fehler}"
            if versuch < versuche - 1:
                schlafen(wartezeit * (versuch + 1))
                continue
            break

    return None, {"fehler": letzter_fehler or "unbekannter Fehlschlag",
                  "http_status": letzter_status, "zeilen": None}


def _mit_urteil(abfrage, endpunkt, art, **kw):
    """Abfrage stellen und das Urteil daranheften. → (zeilen, urteil-dict)."""
    zeilen, befund = sparql(abfrage, endpunkt, **kw)
    befund = dict(befund, erwartet_mindestens=MINDEST_ZEILEN[art])
    urteil = antwort_urteil(befund)
    urteil["art"] = art
    urteil["zeilen"] = befund["zeilen"]
    return (zeilen if urteil["ergebnis"] == "gemessen" else None), urteil


def abfrage_ebu():
    return f"""
SELECT DISTINCT ?station ?stationLabel ?ccode ?sitelinks WHERE {{
  ?station wdt:P31 wd:Q14350 .
  ?station wdt:P17 ?country .
  ?country wdt:P297 ?ccode .
  ?station (wdt:P127|wdt:P137|wdt:P749) ?org .
  ?org ((wdt:P361|wdt:P749|wdt:P463)?/wdt:P463) wd:Q166400 .
  ?station wikibase:sitelinks ?sitelinks .
  FILTER(?sitelinks > 0)
  SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{LABEL_SPRACHEN}" . }}
}}"""


def abfrage_anker(ccode, anker_qid):
    return f"""
SELECT DISTINCT ?station ?stationLabel ?sitelinks WHERE {{
  ?station wdt:P31 wd:Q14350 .
  ?station wdt:P17 ?country .
  ?country wdt:P297 "{ccode}" .
  ?station (wdt:P127|wdt:P137|wdt:P749)/((wdt:P361|wdt:P749)?) wd:{anker_qid} .
  ?station wikibase:sitelinks ?sitelinks .
  FILTER(?sitelinks > 0)
  SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{LABEL_SPRACHEN}" . }}
}}"""


def abfrage_toplist_rang(ccode):
    # Die Flag-Abfrage ist dieselbe Toplist mit einer Tripel-Zeile mehr.
    lizenz = "  ?station wdt:P1408 ?lizenzstadt .\n" if ccode in NUR_INLANDSLIZENZ else ""
    return f"""
SELECT DISTINCT ?station ?sitelinks WHERE {{
  ?station wdt:P31 wd:Q14350 .
  ?station wdt:P17 ?country .
  ?country wdt:P297 "{ccode}" .
{lizenz}  ?station wikibase:sitelinks ?sitelinks .
  FILTER(?sitelinks >= 5)
}} ORDER BY DESC(?sitelinks) LIMIT 60"""


def abfrage_toplist_label(qids):
    werte = " ".join("wd:" + q for q in qids)
    return f"""
SELECT ?station ?stationLabel ?sitelinks WHERE {{
  VALUES ?station {{ {werte} }}
  ?station wikibase:sitelinks ?sitelinks .
  SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{LABEL_SPRACHEN}" . }}
}}"""


def _toplist(ccode, endpunkt, pause, je_land, urteile, kw, schlafen):
    """Die zweistufige Landes-Toplist (erst ranken ohne Label-Dienst, dann nur
    die Spitze beschriften — die Antwort auf ein 504). EINE Stelle fuer beide
    Wege: mit Anker und ohne (e9ee804). `schlafen` kommt wie ueberall von
    aussen herein, damit ein Test die Pause nicht wirklich abwartet."""
    r_zeilen, r_urteil = _mit_urteil(abfrage_toplist_rang(ccode), endpunkt,
                                     "toplist", **kw)
    r_urteil["land"] = ccode
    urteile.append(r_urteil)
    if r_zeilen is None:
        return
    qids = [z["station"]["value"].rsplit("/", 1)[1] for z in r_zeilen]
    schlafen(pause)
    l_zeilen, l_urteil = _mit_urteil(abfrage_toplist_label(qids), endpunkt,
                                     "toplist", **kw)
    l_urteil["land"] = ccode
    urteile.append(l_urteil)
    if l_zeilen is not None:
        # setdefault, NICHT je_land[ccode]: ohne Anker gibt es den Eintrag
        # noch gar nicht — genau der US-Fall.
        sammeln(l_zeilen, je_land.setdefault(ccode, {}))


def sammeln(zeilen, hinein):
    """Zeilen in {qid: (name, sitelinks)} einsammeln. Aus the implementer uebernommen."""
    for zeile in zeilen:
        qid = zeile["station"]["value"].rsplit("/", 1)[1]
        name = zeile["stationLabel"]["value"]
        if name == qid:                    # kein Label in unseren Sprachen
            continue
        sitelinks = int(zeile["sitelinks"]["value"])
        if qid not in hinein or hinein[qid][1] < sitelinks:
            hinein[qid] = (name, sitelinks)


def rangfolge(stationen):
    """{qid: (name, sitelinks)} → Liste (name, qid) in Rangfolge, Namen einmalig."""
    sortiert = sorted(stationen.items(), key=lambda kv: (-kv[1][1], kv[0]))
    gesehen, raus = set(), []
    for qid, (name, _) in sortiert:
        if name.casefold() in gesehen:
            continue
        gesehen.add(name.casefold())
        raus.append((name, qid))
    return raus


def messen(endpunkt, schlafen=time.sleep, oeffnen=None, nur_laender=None,
           pause=1.0, wartezeit=10):
    """Alle Abfragen fahren. → dict mit Rohzahlen, Kernen und allen Urteilen.

    `pause` ist die Hoeflichkeitspause zwischen zwei Abfragen und kommt
    AUSSCHLIESSLICH von hier; es gibt keinen zweiten Ort, an dem sie steht
    (Always-On Nr. 4, Regel A). Die Wiederhol-Wartezeit nach einem 5xx ist
    etwas anderes und liegt in `sparql`.
    """
    kw = {"schlafen": schlafen, "oeffnen": oeffnen, "wartezeit": wartezeit}
    urteile = []
    je_land = {}

    zeilen, urteil = _mit_urteil(abfrage_ebu(), endpunkt, "ebu", **kw)
    urteile.append(urteil)
    if zeilen is None:
        # Das Rueckgrat fehlt. Kein Teilergebnis, kein Schreiben — der Lauf hat
        # nicht gemessen, und das ist etwas anderes als „nichts gefunden".
        return {"gemessen": False, "urteile": urteile, "roh": {}, "kerne": {},
                "nicht_geprueft": sorted(set(REFERENZ) | set(ANKER)),
                "gefiltert": {}, "anker_ohne_treffer": [],
                "grund": f"EBU-Abfrage {urteil['ergebnis']}: {urteil['grund']}"}

    for zeile in zeilen:
        ccode = zeile["ccode"]["value"]
        if nur_laender and ccode not in nur_laender:
            continue
        # Die Ersthand-Laender werden MITGEMESSEN, aber nicht ausgeliefert.
        # Der erste Referenzlauf verwarf sie schon hier — damit war the reviewer's
        # staerkste Eichzahl (DE 117) gegen nichts mehr zu pruefen.
        sammeln([zeile], je_land.setdefault(ccode, {}))

    nicht_geprueft, anker_ohne_treffer = [], []
    for ccode, anker in sorted(ANKER.items()):
        if nur_laender and ccode not in nur_laender:
            continue
        if anker is None:
            # Datenlage, kein Fehlschlag: dieses Land traegt seinen Kern
            # allein aus der Toplist (siehe ANKER-Kommentar).
            anker_ohne_treffer.append(ccode)
            schlafen(pause)
            _toplist(ccode, endpunkt, pause, je_land, urteile, kw, schlafen)
            continue
        schlafen(pause)
        a_zeilen, a_urteil = _mit_urteil(abfrage_anker(ccode, anker), endpunkt,
                                         "anker", **kw)
        a_urteil["land"] = ccode
        urteile.append(a_urteil)

        # u2 kennt DREI Werte, und die ersten beiden bedeuten Verschiedenes.
        # Die erste Fassung dieser Schleife warf sie zusammen ("a_zeilen is
        # None") und machte damit denselben Fehler, gegen den die Einheit
        # gebaut ist — eine Ebene hoeher. Gefunden hat es der echte Lauf:
        # die US-Anker-Abfrage liefert 0 Zeilen, weil NPR ein Verbund ist und
        # die Mitgliedssender ihm nicht ueber P127/P137/P749 gehoeren. Das ist
        # ein MESSERGEBNIS ueber den Markt, kein Fehlschlag der Messung.
        if a_urteil["ergebnis"] == "nicht_gemessen":
            nicht_geprueft.append(ccode)
            continue
        if a_urteil["ergebnis"] == "leer_gemessen":
            # Der Anker greift hier nicht. Das Land bleibt drin und traegt
            # seinen Kern allein aus der Toplist — aber der Lauf sagt es.
            anker_ohne_treffer.append(ccode)
        else:
            sammeln(a_zeilen, je_land.setdefault(ccode, {}))

        schlafen(pause)
        _toplist(ccode, endpunkt, pause, je_land, urteile, kw, schlafen)

    # Die ROHZAHL vor jeder Kappung — sie ist das, was gegen the reviewer's
    # Groessenordnungen abgeglichen wird. the implementer's Skript kappte zuerst und
    # machte den Abgleich damit unmoeglich.
    roh = {c: len(s) for c, s in je_land.items()}

    kerne, gefiltert = {}, {}
    for ccode, stationen in je_land.items():
        if ccode in ERSTHAND:
            # Dort gelten die Ersthand-Tabellen (RadioListenerCores). Gemessen
            # wurde das Land trotzdem — die Zahl steht in `roh`.
            continue
        geordnet = rangfolge(stationen)
        if len(geordnet) < MIN_KERN:
            # NICHT still fallen lassen — wer das Land vermisst, muss den
            # Grund sehen koennen.
            gefiltert[ccode] = len(geordnet)
            continue
        kerne[ccode] = geordnet[:MAX_KERN]

    return {"gemessen": True, "urteile": urteile, "roh": roh, "kerne": kerne,
            "nicht_geprueft": sorted(nicht_geprueft), "gefiltert": gefiltert,
            "anker_ohne_treffer": sorted(anker_ohne_treffer), "grund": ""}


KOPF = """// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

// GENERATED by tools/radio-wikidata-cores/generate.py — edit the script,
// not this file. Run date: {datum}.

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
{tabelle}
    ]
}}
"""


def swift_datei(kerne, datum):
    """Die vollstaendige Swift-Datei. Kopf aus the implementer's Bestand, Rumpf aus u3."""
    return KOPF.format(datum=datum, tabelle=swift_tabelle(kerne))


def verdikt(ergebnis, zeilen_urteil):
    """Das Lauf-Verdikt. → (exit, wort, grund).

    Die Leiter fragt ZUERST nach der Messung und erst danach nach dem Inhalt —
    dieselbe Reihenfolge wie in u2, hier eine Stufe hoeher.
    """
    if not ergebnis["gemessen"]:
        return 2, "nicht_gemessen", ergebnis["grund"]
    if ergebnis["nicht_geprueft"]:
        return 2, "nicht_gemessen", ("Anker-Laender ohne Messung: "
                                     + ", ".join(ergebnis["nicht_geprueft"]))
    if not ergebnis["kerne"]:
        return 2, "nicht_gemessen", "kein einziges Land ueber der Mindestbreite"
    if ergebnis["anker_ohne_treffer"]:
        return 1, "befund", ("Anker ohne Treffer (der Anker greift in diesem "
                             "Markt nicht): " + ", ".join(ergebnis["anker_ohne_treffer"]))
    abweichend = [z for z in zeilen_urteil if z["urteil"] != "passt"]
    if abweichend:
        return 1, "abweichung", ("%d Laender ausserhalb der Referenz: %s" % (
            len(abweichend), ", ".join("%s %s" % (z["land"], z["urteil"])
                                       for z in abweichend)))
    return 0, "gruen", "alle Referenzlaender im Rahmen"


def render(e):
    a = ["# Wikidata-Kerne — Lauf vom %s" % e["datum"], ""]
    a.append("Endpunkt: `%s`" % e["endpunkt"])
    a.append("")
    a.append("## Abfragen — wurde gemessen?")
    a.append("")
    a.append("| Art | Land | Zeilen | Ergebnis |")
    a.append("|---|---|---|---|")
    for u in e["urteile"]:
        a.append("| %s | %s | %s | %s |" % (
            u["art"], u.get("land", "—"),
            "—" if u["zeilen"] is None else u["zeilen"], u["ergebnis"]))
    a += ["", "## Laender gegen the reviewer's Groessenordnungen", ""]
    if not e["laender"]:
        a += ["*Nicht geprueft — es wurde nicht gemessen. Ueber die Laender laesst "
              "sich aus diesem Lauf nichts sagen, weder im Guten noch im Schlechten.*"]
        return _schluss(a, e)
    a += ["| Land | gemessen (roh) | Referenz | Abweichung | Urteil |",
          "|---|---|---|---|---|"]
    for z in e["laender"]:
        a.append("| %s | %s | %s | %s | %s |" % (
            z["land"], z["gemessen"],
            "—" if z["referenz"] is None else z["referenz"],
            "—" if z["abweichung"] is None else "%.1f %%" % (100 * z["abweichung"]),
            z["urteil"]))
    if e["anker_ohne_treffer"]:
        a += ["", "## Anker ohne Treffer — gemessen, aber der Anker greift nicht", ""]
        for c in e["anker_ohne_treffer"]:
            a.append("* **%s** (Anker `%s`): 0 Stationen ueber Besitz/Betrieb. "
                     "Der Kern kommt allein aus der laenderweiten Toplist." % (c, ANKER[c]))
    if e["gefiltert"]:
        a += ["", "## Unter der Mindestbreite (%d) — nicht ausgeliefert" % MIN_KERN, ""]
        a += ["* %s: %d Stationen" % (c, n) for c, n in sorted(e["gefiltert"].items())]
    if e["stichproben"]:
        a += ["", "## Stichproben — die ersten zehn Namen je Land", ""]
        for ccode, namen in sorted(e["stichproben"].items()):
            a.append("* **%s**: %s" % (ccode, " · ".join(namen)))
    return _schluss(a, e)


def _schluss(a, e):
    a += ["", "**%s** — %s" % (e["verdikt"].upper(), e["grund"])]
    if e["geschrieben"]:
        a.append("")
        a.append("Geschrieben: `%s` (%d Laender)" % (e["geschrieben"], len(e["kerne"])))
    else:
        a.append("")
        a.append("**Keine Datei geschrieben.**")
    return "\n".join(a)


def main(argv=None):
    p = argparse.ArgumentParser(description="Ballon 41 — Wikidata-Kerne, gehaertet")
    p.add_argument("--endpunkt", default=ENDPUNKT_VORGABE)
    p.add_argument("--aus", default=os.path.join(
                       os.path.dirname(os.path.dirname(HIER)),
                       "Sources", "Models", "RadioWikidataCores.swift"),
                   help="Zieldatei fuer die erzeugte Swift-Tabelle")
    p.add_argument("--trocken", action="store_true",
                   help="messen und berichten, aber nichts schreiben")
    p.add_argument("--stichprobe", default="UK,FR,US",
                   help="Laender, deren Top-10 in den Bericht kommen")
    p.add_argument("--nur", help="nur diese Laender messen (Komma), fuer Probelaeufe")
    p.add_argument("--wartezeit", type=float, default=10.0,
                   help="Grundabstand zwischen zwei Wiederholversuchen in Sekunden")
    p.add_argument("--pause", type=float, default=1.0,
                   help="Hoeflichkeitspause zwischen zwei Abfragen in Sekunden")
    p.add_argument("--json", action="store_true")
    a = p.parse_args(argv)

    nur = set(x.strip().upper() for x in a.nur.split(",")) if a.nur else None
    ergebnis = messen(a.endpunkt, nur_laender=nur, pause=a.pause,
                      wartezeit=a.wartezeit)

    # Der Vergleich gegen die Referenz ist NUR sinnvoll, wenn gemessen wurde.
    # Sonst stuende in der Tabelle bei jedem Land "fehlt / 100 % Abweichung" —
    # ein Urteil ueber Wikidata, wo in Wahrheit nichts gemessen wurde. Genau
    # die Umdeutung, gegen die dieses Werkzeug gebaut ist, im eigenen Bericht.
    # Aufgefallen beim LESEN der Abnahme-Ausgabe, nicht am Exit-Code.
    laender = (laender_urteil(ergebnis["roh"], REFERENZ, TOLERANZ)
               if ergebnis["gemessen"] else [])
    rc, wort, grund = verdikt(ergebnis, laender)

    stichproben = {}
    for ccode in (x.strip().upper() for x in a.stichprobe.split(",") if x.strip()):
        if ccode in ergebnis["kerne"]:
            stichproben[ccode] = [n for n, _ in ergebnis["kerne"][ccode][:10]]

    datum = time.strftime("%Y-%m-%d")
    geschrieben = None
    # Geschrieben wird NUR, wenn gemessen wurde. Das ist der ganze Punkt:
    # ein Fehlschlag darf den Bestand nicht ueberschreiben.
    if a.aus and not a.trocken and rc != 2:
        text = swift_datei(ergebnis["kerne"], datum)
        os.makedirs(os.path.dirname(os.path.abspath(a.aus)), exist_ok=True)
        vorlaeufig = a.aus + ".neu"
        with open(vorlaeufig, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(vorlaeufig, a.aus)      # atomar — kein halb geschriebener Stand
        geschrieben = a.aus

    e = {"datum": datum, "endpunkt": a.endpunkt, "urteile": ergebnis["urteile"],
         "laender": laender, "roh": ergebnis["roh"],
         "kerne": {c: [{"name": n, "qid": q} for n, q in v]
                   for c, v in ergebnis["kerne"].items()},
         "gefiltert": ergebnis["gefiltert"],
         "nicht_geprueft": ergebnis["nicht_geprueft"],
         "anker_ohne_treffer": ergebnis["anker_ohne_treffer"],
         "stichproben": stichproben, "verdikt": wort, "grund": grund,
         "geschrieben": geschrieben, "exit": rc}

    # Exit EINMAL vor der Ausgabe-Verzweigung gebunden; --json und Text geben
    # denselben zurueck (die wiederkehrende Anti-Pattern-Klasse aus dem METRONOM).
    print(json.dumps(e, ensure_ascii=False, indent=1) if a.json else render(e))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
