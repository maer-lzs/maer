# Was wir je Katalog-Quelle über die Rechtelage WISSEN

Grundlage für jede Lizenz-Kapsel in der App. Regel: **Was hier nicht belegt ist, wird in
der App nicht behauptet.** Eine Kapsel ist eine Aussage über fremde Rechte — sie darf nur
stehen, wo eine Quelle sie trägt.

Angelegt nach `50aefa8` (05.08.2026): Der Fallback der Detail-Kapsel behauptete
„Public Domain" für **jeden** Titel ohne Lizenzfeld. Für die Klassik-Reihe traf das alle
**4.271** Titel. Nach der Nachschärfung `12753d8` (Schutzfristen sind ortsabhängig) lautet
die genaue Lage: für **408** Titel ist „gemeinfrei" in allen drei Rechtsräumen haltbar,
für **1.021** hängt die Antwort vom Ort des Hörers ab, und für **2.842** wissen wir
mangels Jahresangabe nirgends etwas. Die frühere Rahmung „782 nach US-Recht falsch" ist
aus US-Sicht richtig, greift aber zu kurz: Genau diese Titel sind in der Schweiz und in
der EU frei.

| Quelle | Namensraum | Was die Quelle liefert | Was die App sagt |
|---|---|---|---|
| **LibriVox** | `lv:` | Projekt-Prinzip: Aufnahmen sind gemeinfrei (Grundlage des Projekts, gilt für den gesamten Bestand) | „Gemeinfrei" — belegt |
| **Project Gutenberg** | `gut:` | Die Pruefung vom 05.08. galt den TEXTEN (Permissions-Seite: gemeinfrei in den USA). Fuer Hoerbuecher gemessen 28.09.: die RDF je Werk nennt `dcterms:rights`, und nicht alle sagen „Public domain in the USA.“; 5884 und 3002 sagen „Copyrighted. Read the copyright notice inside this book for details.“ | **Keine pauschale Kapsel mehr.** Kacheln ohne Kapsel; die Titelseite zeigt nach dem Oeffnen, was die RDF sagt: „Gemeinfrei (USA)“, „Urheberrechtlich geschuetzt, von Project Gutenberg frei verteilt“ oder „Rechtelage nicht angegeben“ (`FreeCatalog.gutenbergRightsLabel`). Die **Marke** „Project Gutenberg" darf nicht für eigene Werke verwendet werden; Quellennennung ist erlaubt und erfolgt an der Reihe |
| **archive.org — Hörbücher / Old Time Radio** | `lva:` | `licenseurl` **je Item vorhanden** (CC-Varianten, teils PD) | Die Lizenz aus dem Feld, wörtlich. Kein Feld ⇒ **keine** Kapsel |
| **archive.org — georgeblood / Klassik** | `lva:` | **Kein Lizenzfeld** (0 von 200 in der Stichprobe, 4.271 Titel gesamt). Jahr bei 1.429 davon | Nach Erscheinungsjahr gestaffelt (siehe unten): ≤ 1925 „Gemeinfrei" (408) · später die Fristen (1.021) · ohne Jahr „nicht angegeben" + Link (2.842). **Nie** eine Lizenz behaupten |
| **Jamendo** | `jam:` | CC-Lizenz je Titel, ausdrücklich ausgewiesen | Die Lizenz je Titel + Pflicht-Attribution (Künstler, „via Jamendo", Backlink). Freie API nur **nicht-kommerziell** |
| **archive.org — Netlabels** | `lva:` | CC je Item | Wie Hörbücher: Feld wörtlich, kein Feld ⇒ keine Kapsel |

## Schutzfristen sind ortsabhängig — deshalb Fristen statt Urteil

Nachgeschärft nach `12753d8`. Für **Tonaufnahmen** gilt:

| Rechtsraum | Frist | 2026 frei bis |
|---|---|---|
| Schweiz | 50 Jahre (Art. 39 URG) | ca. 1976 |
| EU | 70 Jahre (RL 2011/77/EU) | ca. 1956 |
| USA | 100 Jahre für 1923–1946 (Music Modernization Act) | 1925 |

Eine Aufnahme von 1945 ist in Zürich frei und in New York geschützt. Eine pauschale
Plakette wäre also irgendwo immer falsch. Die Regel in der App (pure
`FreeCatalog.rightsNote`, getestet):

1. **Veröffentlichung ≤ 1925** → „Gemeinfrei". Selbst die längste Frist ist abgelaufen,
   die Aussage hält überall. **Gemessen: 408 der 4.271 Klassik-Titel.**
2. **1926 und später** → die **Fristen benennen**, kein Urteil über den Titel:
   „Aufnahme von 1945. Tonaufnahmen sind in der Schweiz nach 50 Jahren frei, in der EU
   nach 70 und in den USA nach 100." **Gemessen: 1.021 Titel.**
3. **Kein Jahr** → „Rechtelage von der Quelle nicht angegeben" + Link.
   **Gemessen: 2.842 Titel.**
4. Ein vorhandenes `licenseurl` **schlägt alles** — eine ausgewiesene Lizenz ist eine
   Tatsache der Quelle.

**Ausdrücklich nicht gebaut: Umschalten nach Geräte-Region.** Die Region ist nicht die
Rechtsordnung des Hörers (Reise, ausländisches Konto, VPN); eine Aussage auf falscher
Regionsannahme wäre schlechter als die genannten Fristen. Und Ausblenden verwandelte eine
Anzeige-Frage in eine Zugangs-Frage: **Wir beschriften, wir sperren nicht.**

Werk und Aufnahme sind zwei Schichten — bei der Klassik ist die Komposition fast immer
frei, offen ist die Einspielung. Die Fristzeile spricht deshalb von *Tonaufnahmen*.

**Anwaltlich geprüft ist nichts davon.** Das gehört vor eine Store-Veröffentlichung.

## Warum das Siegel mitentscheidet

Die Kapsel trug bei unbekannter Rechtelage ein `checkmark.seal`. **Ein Häkchen ist selbst
eine Behauptung** — es liest sich als Bestätigung. Unbekanntes trägt daher ein
Fragezeichen und den Link zur Quelle, damit man selbst nachsehen kann.

## Grenzen, die nicht das Urheberrecht betreffen

- **78rpm / „Alte Schallplatten" (gestoppt, `8888bdb`):** Lizenz- und Metadatenfelder sind
  disjunkt, der Bestand reicht bis weit nach 1929, und im Bestand liegt NS-Material
  (u. a. das Horst-Wessel-Lied). Eine breite Reihe über diese Sammlung braucht **zusätzlich
  zum Rechte-Ausweis einen inhaltlichen Ausschlussfilter**. Für die kuratierte
  Klassik-Teilmenge stellt sich die Frage nicht — beim nächsten Ausbau aber sofort wieder.
- **Position des Internet Archive ≠ unsere Position:** Deren Bewahrungszweck als
  US-Bibliothek trägt Argumente, die ein Client, der Endnutzern streamt, nicht hat. Aus
  „das Archiv hat es" folgt für uns nichts über die Rechtelage eines Titels.

## Verfahren bei einer neuen Quelle

1. Liefert sie ein Lizenzfeld **je Titel**? → Feld wörtlich zeigen, sonst keine Kapsel.
2. Trägt das Projekt-Prinzip die Aussage für den **gesamten** Bestand (LibriVox)?
   → dann und nur dann eine pauschale Kapsel. Gutenberg traegt sie fuer seine
   Hoerbuecher NICHT (gemessen 28.09.): dort gilt Punkt 1 je Werk.
3. Weder noch? → „Rechtelage von der Quelle nicht angegeben" plus Link. Nie raten.
4. Zeile in dieser Tabelle ergänzen, **bevor** die Reihe gebaut wird.
