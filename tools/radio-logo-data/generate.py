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
# 87c77c4: die KACHEL ist quadratisch, also will sie eine quadratische
# Bildmarke; ein Schriftzug ist die Rueckfallebene. Die Regel ist das
# SEITENVERHAELTNIS, nicht der Sendername — DLF war nur der Melder.
#   <= MARK_MAX      Bildmarke (rund/quadratisch, fuellt die Kachel)
#   >  WORDMARK_MIN  Schriftzug (ein Etikett, kein Logo)
#   dazwischen       Grauzone: brauchbar, aber eine Marke schlaegt sie
MARK_MAX = 1.6
WORDMARK_MIN = 3.0
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


def image_size(data):
    try:
        from PIL import Image
        with Image.open(io.BytesIO(data)) as image:
            return image.size
    except Exception:
        return None


def image_side(data):
    size = image_size(data)
    return min(size) if size else None


def aspect(size):
    """Laengere Seite geteilt durch kuerzere — 1.0 ist quadratisch."""
    width, height = size
    if width <= 0 or height <= 0:
        return None
    return max(width, height) / min(width, height)


# Woerter, die eine Datei ueber den Sendernamen hinaus tragen DARF, ohne dass
# sie einen anderen Gegenstand meint. Alles andere ist ein fremdes Wort — und
# ein fremdes Wort heisst meist ein fremder Gegenstand.
GENERIC_EXTRA = {
    "logo", "logos", "klein", "gross", "big", "small", "neu", "new",
    "radio", "svg", "png", "jpg", "jpeg", "gif", "de", "the", "of",
    "final", "rgb", "official", "icon", "wortmarke", "bildmarke",
}

# NICHT generisch, obwohl es danach aussieht: "alt"/"old" benennen ausdruecklich
# eine VERALTETE Fassung. Gemessen im ersten Lauf: "SWR3 Logo.svg" wurde zu
# "SWR3 Logo alt.svg" — dieselbe Marke, nur die abgeloeste.
OUTDATED_MARKERS = {"alt", "old", "ehemalig", "former", "historic", "historisch"}


def tokens(raw):
    import re as _re
    return [w for w in _re.split(r"[^a-z0-9]+", fold_words(raw)) if w]


def fold_words(raw):
    """Wie `fold`, aber mit erhaltenen Wortgrenzen."""
    import re as _re, unicodedata
    text = unicodedata.normalize("NFKD", raw or "")
    text = "".join(c for c in text if not unicodedata.combining(c))
    return _re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def only_generic_extra(name, title):
    """Traegt die Datei NUR generische Zusatzwoerter zum Sendernamen?

    Gemessen an einem vollen Lauf ueber 786 Kern-Namen: die reine
    Namens-Wache (Sendername steht im Dateinamen) laesst 76 Aenderungen durch,
    davon **35 Rueckschritte** — „Radio Pilatus logo" wurde zur
    „Pilatus PC-7 silhouette", „BBC Radio 5 Live" zum Logo von „5 Live Sports
    Extra", „Mecklenburg-Vorpommern" zum SPD-Logo. Der Grund ist immer
    derselbe: der Name steht drin, gemeint ist etwas anderes.

    Diese Regel verlangt zusaetzlich, dass die Datei NICHTS anderes benennt.
    Sie kostet ein paar echte Verbesserungen (das Wikidata-Logo bleibt dann
    stehen) und verhindert alle gemessenen Rueckschritte. Ein falsches Logo ist
    schlimmer als eine Farbkachel — und ein Rueckschritt ist schlimmer als ein
    ausgebliebener Fortschritt.
    """
    import re as _re
    name_words = set(tokens(name))
    stem = _re.sub(r"\.[a-z0-9]+$", "", title)
    extra = [w for w in tokens(stem) if w not in name_words]
    return all(w in GENERIC_EXTRA or w.isdigit() for w in extra)


def year_in(title):
    """Die groesste vierstellige Jahreszahl im Dateinamen, oder None."""
    import re as _re
    years = [int(y) for y in _re.findall(r"\b(19\d{2}|20\d{2})\b", title or "")]
    return max(years) if years else None


def keep_previous(name, previous, candidate):
    """Darf die BISHERIGE Zuordnung durch die neue ersetzt werden?

    Der Generator laeuft gegen einen bestehenden Bestand, und ein Lauf, der ihn
    verschlechtert, ist schlimmer als einer, der nichts findet. Gemessen an zwei
    vollen Laeufen ueber 786 Namen bleiben drei Klassen uebrig, die die
    Namens-Wache passieren und trotzdem Rueckschritte sind:

      * die ausdruecklich ALTE Fassung derselben Marke ("SWR3 Logo alt"),
      * eine AELTERE Jahresfassung ("… Logo 2024" → "… Logo 2012"),
      * der Verlust des Namens ("Rai Radio 1 - Logo 2017" → "Logo of RAI Radio").

    Alle drei sind am Dateinamen allein entscheidbar — kein Netz noetig, und
    deshalb steht die Regel hier und nicht in einem Nachbearbeitungsschritt.
    """
    if not previous or previous == candidate:
        return False
    stem = candidate.rsplit(".", 1)[0]
    if any(w in OUTDATED_MARKERS for w in tokens(stem)):
        return True
    old_year, new_year = year_in(previous), year_in(candidate)
    if old_year and new_year and new_year < old_year:
        return True
    # Der Name darf nicht verlorengehen: was ihn traegt, schlaegt was ihn nicht
    # traegt — auch wenn das neue Bild quadratischer waere.
    if carries_name(name, previous) and not carries_name(name, candidate):
        return True
    # Ein unterscheidendes Zeichen, das die bisherige Datei BEWAHRT, darf nicht
    # wegfallen. Gemessen: "NRK P1+" bekam das Logo von "NRK P1" — die Faltung
    # wirft das "+" weg, und damit sehen zwei VERSCHIEDENE Sender gleich aus.
    # Die bisherige Datei hiess "NRK P1+ logo.svg" und wusste es besser.
    for mark in set(name) - set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 "):
        if mark in previous and mark not in candidate:
            return True
    return False


def existing_mapping():
    """Der bisherige Bestand als Vergleichsgrundlage."""
    import re as _re
    path = os.path.join(ROOT, "Sources", "Models", "RadioLogoData.swift")
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return {}
    return dict(_re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)",?\s*$',
                            text, _re.M))


def carries_name(name, title):
    """Traegt der Dateiname den Sendernamen? Die WACHE gegen Fremdbilder.

    Gemessen: ohne sie holt die Verhaeltnis-Regel fuer "Bayern 2" das Logo des
    FC Bayern, fuer "Bremen NEXT" ein NASA-Foto und fuer "Bremen Eins" das von
    Marktkauf — die Dateisuche liefert nach RELEVANZ, und der quadratischste
    Treffer ist oft der unaehnlichste. In 176 geprueften Schriftzuegen hat die
    Wache 55 Fremdbilder abgewehrt. Ein falsches Logo ist schlimmer als eine
    Farbkachel."""
    folded_name, folded_title = fold(name), fold(title)
    return len(folded_name) >= 4 and folded_name in folded_title


def rank(size, name=None, title=None):
    """Kleiner ist besser: Klasse → wenigster ZUSATZ → Naehe zu 1:1.

    Eine Grauzonen-Datei bleibt brauchbar — sie verliert nur gegen eine echte
    Marke. So behaelt ein Sender OHNE quadratische Variante seinen Schriftzug,
    statt gar nichts zu bekommen.

    Der Zusatz entscheidet innerhalb einer FAMILIE: fuer "Deutschlandfunk"
    liegen "Deutschlandfunk Logo klein.png", "… Kultur Logo klein.png" und
    "… Nova Logo klein.png" alle bei 1:1 — nur die WENIGSTEN Zusatzzeichen
    treffen den gemeinten Sender. Ohne dieses Kriterium bekaeme der
    Deutschlandfunk das Logo von DLF Kultur, gemessen."""
    ratio = aspect(size)
    extra = 0
    if name and title:
        extra = max(0, len(fold(title)) - len(fold(name)))
    if ratio is None:
        return (9, extra, 0)
    if ratio <= MARK_MAX:
        return (0, extra, ratio)
    if ratio <= WORDMARK_MIN:
        return (1, extra, ratio)
    return (2, extra, ratio)


def fold(raw):
    import unicodedata
    text = unicodedata.normalize("NFKD", raw or "")
    text = "".join(c for c in text if not unicodedata.combining(c))
    return "".join(c for c in text.lower() if c.isalnum())


# f837dc0: Namen, die der AUFTRAG ausdruecklich nennt, aber in keiner
# Kern-Tabelle stehen — the owner's DLF-Familie war MEHRZAHL, die Tabellen kennen
# nur den Hauptsender. Katalog-Anzeigenamen (displayName-Form, gemessen).
EXTRA_NAMES = [
    "Deutschlandfunk Kultur",
    "Deutschlandfunk Nova",
]


def core_names():
    """The target set: every name in the core tables (the app's own data)."""
    out = list(EXTRA_NAMES)
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
    # 87c77c4: NICHT der erste Treffer, sondern der quadratischste. Fuer
    # Deutschlandfunk liegen "Logo 2017.svg" (676x100, 6.8:1) und
    # "Logo klein.png" (1920x1920, 1:1) nebeneinander — die Auswahl griff
    # bisher zur breitesten Variante, weil sie zuerst kam.
    # ZWEI Stufen, und die Trennung ist der ganze Punkt:
    #
    #   * Die Verhaeltnis-Bevorzugung gilt NUR fuer Dateien, die den
    #     Sendernamen TRAGEN. Ohne diese Wache holt sie Fremdbilder — gemessen:
    #     das Logo des FC Bayern fuer "Bayern 2", ein NASA-Foto fuer
    #     "Bremen NEXT", Marktkauf fuer "Bremen Eins".
    #   * Alles andere bleibt wie bisher: der erste Treffer in RELEVANZ-Ordnung.
    #     Eine harte Wache haette 48,6 % des Bestands verworfen (der Name
    #     "105'5 Spreeradio" steht nicht in "Spreeradio-logo.svg", und die Datei
    #     ist trotzdem richtig) — die Deckung darf nicht sinken, damit ein paar
    #     Karten quadratischer werden.
    best_named, first_relevant = None, None
    for hit in (payload or {}).get("query", {}).get("search", []):
        title = hit["title"].replace("File:", "")
        thumb = "https://commons.wikimedia.org/w/thumb.php?" + urllib.parse.urlencode(
            {"f": title, "width": COMMONS_WIDTH})
        data, verdict = get(thumb, raw=True)
        if verdict == "failed":
            return None, "failed"
        size = image_size(data) if data else None
        # GT-Nachtrag (2b7c857/f837dc0-Klasse): HOCHFORMAT fliegt ganz raus.
        # Gemessen an allen sechs hochformatigen Neuzuordnungen des letzten
        # Laufs: JEDE war ein Rueckschritt — vier Stapel aus Marke+Textzeile
        # (SRF 3, Musikwelle, RTL2, Oesterreich 1: die Kachel rendert fill,
        # die Marke wird gesprengt, unten stehen Textreste) und einmal sogar
        # ein FREMDER Sender (das indische Big FM, Hindi-Claim — durch
        # Namens-Wache UND Generik-Regel gerutscht, weil Name und Zusaetze
        # passten). Die Zielflaeche ist quadratisch: eine echte Bildmarke ist
        # quadratisch oder quer; hochformatige "Logos" sind auf Commons fast
        # immer Kombi-Stapel. Lieber der Schriftzug (zentriert, sauber) oder
        # zur Laufzeit das Touch-Icon als ein gesprengtes Stapelbild.
        if size and size[1] > size[0]:
            time.sleep(0.2)
            continue
        if size and min(size) >= MIN_SIDE:
            if first_relevant is None:
                first_relevant = title
            if carries_name(name, title) and only_generic_extra(name, title):
                score = rank(size, name=name, title=title)
                if best_named is None or score < best_named[0]:
                    best_named = (score, title)
        time.sleep(0.2)
    # Eine echte Bildmarke mit dem richtigen Namen schlaegt die Relevanz;
    # sonst bleibt es beim bisherigen Verhalten.
    if best_named and best_named[0][0] == 0:
        return best_named[1], "ok"
    return first_relevant, "ok"


def is_wordmark(title):
    """Ist die Datei ein Schriftzug? Eine Messung, keine Namensregel."""
    thumb = "https://commons.wikimedia.org/w/thumb.php?" + urllib.parse.urlencode(
        {"f": title, "width": COMMONS_WIDTH})
    data, verdict = get(thumb, raw=True)
    if verdict == "failed" or not data:
        return False          # unbekannt ist kein Befund — nichts ersetzen
    size = image_size(data)
    ratio = aspect(size) if size else None
    return ratio is not None and ratio > WORDMARK_MIN


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
    previous = existing_mapping()
    print(f"target set: {len(names)} core names", file=sys.stderr)
    entries, failures = {}, 0
    for index, name in enumerate(names, 1):
        file_name, verdict = wikidata_file(name)
        if verdict == "failed":
            failures += 1
        # 87c77c4 Punkt 2: liefert Wikidata einen SCHRIFTZUG, die Dateisuche
        # aber eine quadratische Marke, gewinnt die Marke — die Flaeche ist
        # quadratisch, nicht die Datenquelle.
        if file_name and is_wordmark(file_name):
            mark, mark_verdict = commons_file(name)
            if mark_verdict == "failed":
                failures += 1
            elif mark and not is_wordmark(mark) and only_generic_extra(name, mark):
                # Punkt 2 des Auftrags, aber ENGER: eine Wikidata-P154-Datei
                # stammt aus einem zugeordneten OBJEKT, ein Suchtreffer nur aus
                # einer Zeichenkette. Objekt-Beleg schlaegt Zeichenketten-Beleg,
                # also darf die Marke nur uebernehmen, wenn sie zweifelsfrei
                # denselben Sender benennt.
                file_name = mark
        if not file_name:
            file_name, verdict = commons_file(name)
            if verdict == "failed":
                failures += 1
        if file_name and keep_previous(name, previous.get(name), file_name):
            # Ein Lauf, der den Bestand verschlechtert, ist schlimmer als einer,
            # der nichts findet.
            file_name = previous[name]
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
