# Was wir je Katalog-Quelle über die Rechtelage WISSEN

Grundlage für jede Lizenz-Kapsel in der App. Regel: **Was hier nicht belegt ist, wird in
der App nicht behauptet.** Eine Kapsel ist eine Aussage über fremde Rechte — sie darf nur
stehen, wo eine Quelle sie trägt.

Angelegt nach `50aefa8` (05.08.2026): Der Fallback der Detail-Kapsel behauptete
„Public Domain" für **jeden** Titel ohne Lizenzfeld. Für die Klassik-Reihe traf das alle
**4.271** Titel — bei höchstens 647 ist die Aussage haltbar, bei 782 nach US-Recht
nachweislich falsch, bei 2.842 unbelegt.

| Quelle | Namensraum | Was die Quelle liefert | Was die App sagt |
|---|---|---|---|
| **LibriVox** | `lv:` | Projekt-Prinzip: Aufnahmen sind gemeinfrei (Grundlage des Projekts, gilt für den gesamten Bestand) | „Gemeinfrei" — belegt |
| **Project Gutenberg** | `gut:` | Permissions-Seite: gemeinfrei in den USA, ohne Zweckbindung, Weitergabe- oder Speicherverbot (gemessen 05.08.) | „Gemeinfrei" — belegt. Die **Marke** „Project Gutenberg" darf nicht für eigene Werke verwendet werden; Quellennennung ist erlaubt und erfolgt an der Reihe |
| **archive.org — Hörbücher / Old Time Radio** | `lva:` | `licenseurl` **je Item vorhanden** (CC-Varianten, teils PD) | Die Lizenz aus dem Feld, wörtlich. Kein Feld ⇒ **keine** Kapsel |
| **archive.org — georgeblood / Klassik** | `lva:` | **Kein Lizenzfeld** (0 von 200 in der Stichprobe, 4.271 Titel gesamt). Jahr nur bei etwa einem Drittel | „Rechtelage von der Quelle nicht angegeben" + Link zum Item. **Nie** eine Lizenz behaupten. Das Jahr wird gezeigt, wo vorhanden — die einzige Einordnungshilfe |
| **Jamendo** | `jam:` | CC-Lizenz je Titel, ausdrücklich ausgewiesen | Die Lizenz je Titel + Pflicht-Attribution (Künstler, „via Jamendo", Backlink). Freie API nur **nicht-kommerziell** |
| **archive.org — Netlabels** | `lva:` | CC je Item | Wie Hörbücher: Feld wörtlich, kein Feld ⇒ keine Kapsel |

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
2. Trägt das Projekt-Prinzip die Aussage für den **gesamten** Bestand (LibriVox,
   Gutenberg)? → dann und nur dann eine pauschale Kapsel.
3. Weder noch? → „Rechtelage von der Quelle nicht angegeben" plus Link. Nie raten.
4. Zeile in dieser Tabelle ergänzen, **bevor** die Reihe gebaut wird.
