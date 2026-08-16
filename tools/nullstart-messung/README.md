# Null-Start-Messung (Auftraege efc68ca / c59e96e / ac97fb6)

Misst, wo ein HERUNTERGELADENES Buch startet, wenn es keinen lokalen Zeugen
mehr hat — und was die App in dieser Lage zum Server schreibt.

`server.py` ist ein Audiobookshelf-Ersatz mit genau den Endpunkten, die das
Oeffnen braucht, plus einem Schreibprotokoll (`/__writes`). Vier Zustaende:
`ok`, `slow` (antwortet nach der 1,5-s-Kante), `empty` (200 ohne Fortschritt),
`down` (503). TLS mit eigener CA, weil ATS nur Medien im Klartext durchlaesst;
die CA gehoert per `simctl keychain <sim> add-root-cert` in den Simulator.

`messung.sh` stellt den Zustand einmal her und oeffnet das Buch danach je
Server-Zustand. Der Simulator wird zwischen den Faellen NICHT geloescht.

**Nie gegen ein echtes Konto laufen lassen:** nach einem Null-Start steht
`lastSyncedTime` auf 0, und die Sync-Schwelle liegt bei 5 s Differenz — die
Messung koennte zerstoeren, was sie misst.

**Fallen, die der Harness selbst produziert hat** (alle behoben, hier als
Warnung): Tondatei und angegebene Dauer muessen zusammenpassen, sonst meldet
die App sofort „fertig"; der Sync-Takt ist 30 s, kuerzeres Hoeren misst nichts;
ohne bewusstes Pausieren schreibt der Sekundenschreiber den Zeugen sofort neu;
und ein Messfall muss seine eigene Voraussetzung zusichern — die erste Fassung
meldete gruen, ohne dass je Wiedergabe lief.
