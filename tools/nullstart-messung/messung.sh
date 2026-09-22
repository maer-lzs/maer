#!/bin/bash
# Null-Start-Messung (c59e96e / ac97fb6) — reproduzierbare Abfolge.
#
# Stellt EINMAL den Zustand her, den der echte Vorfall hatte (heruntergeladen,
# ohne lokalen Zeugen, gecachtes Detail vom Download-Zeitpunkt), und oeffnet das
# Buch danach in jedem der vier Server-Zustaende. Zwischen den Faellen wird der
# Simulator NICHT geloescht — sonst waere der Zustand weg, der gemessen wird.
set -u
S="$(cd "$(dirname "$0")/.." && pwd)"
M="$S/absmock"
D="${SIM_ID:-62909F86-CC2C-483A-9471-A255EB70B844}"
REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
DD="$S/dd-meas"
OUT="$M/ergebnis.md"

mock_start() {   # $1 = Modus, $2 = Serverstand
  pkill -f "absmock/server.py" 2>/dev/null; sleep 1
  MOCK_MODE="$1" MOCK_SERVER_TIME="$2" MOCK_PORT=8770 MOCK_CERT="$M/srv-chain.pem" \
    python3 "$M/server.py" > "$M/run-$1.log" 2>&1 &
  sleep 2
}
writes() { curl -s --cacert "$M/ca.pem" https://127.0.0.1:8770/__writes; }
container() { xcrun simctl get_app_container "$D" fm.maer.app data 2>/dev/null; }

cached_progress() {
  local c j; c="$(container)"; j="$(find "$c" -name 'mock-book-1.json' 2>/dev/null | head -1)"
  [ -n "$j" ] && python3 -c "
import json,sys
d=json.load(open('$j')).get('userMediaProgress') or {}
print(d.get('currentTime','—'))" || echo "—"
}
# Die Position, die der Sekundenschreiber waehrend des Falls gehalten hat.
# Sie ist der eigentliche Messwert: bei 40 s Hoeren heisst ~40 "Start bei 0",
# ~80 "Start beim Serverstand". Der Schreibvorgang allein sagt das nicht,
# denn ohne Server gibt es gar keinen.
position() {
  local c; c="$(container)"
  plutil -p "$c/Library/Preferences/fm.maer.app.plist" 2>/dev/null \
    | grep -A 2 "localPosition.mock-book-1" | grep -oE "=> [0-9]+\.[0-9]+" \
    | head -1 | sed "s/=> //" | cut -d. -f1
}
witness() {
  local c; c="$(container)"
  plutil -p "$c/Library/Preferences/fm.maer.app.plist" 2>/dev/null \
    | grep -q "localPosition.mock-book-1" && echo "vorhanden" || echo "geloescht"
}
run_case() { # $1 = Testname
  xcodebuild test-without-building -project "$REPO/Maer.xcodeproj" -scheme Maer \
    -destination "id=$D" -derivedDataPath "$DD" -parallel-testing-enabled NO \
    -only-testing:"MaerUITests/NullStartMeasurement/$1" > "$M/$1-${MODUS:-A}.log" 2>&1
  echo $?
}

echo "# Null-Start-Messung — Rohergebnis" > "$OUT"
echo "" >> "$OUT"

# --- Zustand herstellen: Download OHNE Fortschritt auf dem Server ------------
xcrun simctl shutdown "$D" 2>/dev/null; xcrun simctl erase "$D"
xcrun simctl boot "$D"; xcrun simctl bootstatus "$D" -b > /dev/null 2>&1
xcrun simctl keychain "$D" add-root-cert "$M/ca.pem"
mock_start empty 0          # `empty` = Server kennt das Buch, aber keinen Stand
rc=$(run_case testAProduceDownloadedStateAndListen)
pushed=$(writes | python3 -c "import json,sys; w=json.load(sys.stdin)['writes']; print(w[-1]['body']['currentTime'] if w else '—')")
{
  echo "## Zustand nach dem Herstellungs-Lauf (rc=$rc)"
  echo ""
  echo "| | |"
  echo "|---|---|"
  echo "| gecachtes Detail (Download-Zeitpunkt) | $(cached_progress) |"
  echo "| lokaler Zeuge | $(witness) |"
  echo "| zuletzt zum Server geschrieben | $pushed |"
  echo ""
} >> "$OUT"

SERVER_HAT="${pushed%%.*}"; [ -z "$SERVER_HAT" ] && SERVER_HAT=0

# --- Die vier Faelle ---------------------------------------------------------
{
  echo "## Oeffnen des heruntergeladenen Buches, je Server-Zustand"
  echo ""
  echo "Server haelt jeweils **${SERVER_HAT}s**; das gecachte Detail traegt den"
  echo "Download-Stand, ein lokaler Zeuge existiert nicht."
  echo ""
  echo "| Server | Zeuge | rc | Position nach 40 s | zum Server geschrieben |"
  echo "|---|---|---|---|---|"
} >> "$OUT"

# Der Vorher/Nachher-Vergleich laeuft mit DERSELBEN Binaerdatei: der einzige
# Unterschied ist, ob der geflusht-Zeuge da ist. Ihn zu loeschen stellt exakt
# den ausgelieferten Zustand her (der Sync loeschte ihn ersatzlos), ohne einen
# zweiten Bau — und damit ohne den Verdacht, zwei verschiedene Dinge zu messen.
drop_witness() {
  local c; c="$(container)"
  local p="$c/Library/Preferences/fm.maer.app.plist"
  plutil -remove "flushedPosition.mock-book-1" "$p" 2>/dev/null
  plutil -remove "localPosition.mock-book-1" "$p" 2>/dev/null
  xcrun simctl spawn "$D" defaults read fm.maer.app > /dev/null 2>&1
}

for fall in "down:ohne" "down:mit" "slow:mit" "empty:mit" "ok:mit"; do
  modus="${fall%%:*}"; zeuge="${fall##*:}"
  mock_start "$modus" "$SERVER_HAT"
  [ "$zeuge" = "ohne" ] && drop_witness
  MODUS="$modus-$zeuge" rc=$(MODUS="$modus-$zeuge" run_case testBOpenDownloadedBook)
  w=$(writes | python3 -c "
import json,sys
d=json.load(sys.stdin)['writes']
print(', '.join(str(x['body'].get('currentTime')) for x in d) if d else 'nichts')")
  echo "| \`$modus\` | Zeuge $zeuge | $rc | $(position)s | $w |" >> "$OUT"
done

# --- Flugmodus-Matrix ----------------------------------------------------------
# ENTSCHIEDEN: DREI Klassen statt acht. Sie decken die strukturell
# verschiedenen Lesewege (ABS-Server / iCloud / gar kein Sync); die uebrigen
# fuenf unterscheiden sich nur im Namensraum, und dafuer sind die
# Vertreter-Unit-Tests das angemessene Mittel.
rss_position() {
  local c p; c="$(container)"
  p="$c/Library/Preferences/fm.maer.app.plist"
  plutil -p "$p" 2>/dev/null | grep -A 2 "localPosition.rss:" \
    | grep -oE "=> [0-9]+\.[0-9]+" | head -1 | sed "s/=> //" | cut -d. -f1
}
{
  echo ""
  echo "## Flugmodus-Matrix"
  echo ""
  echo "| Klasse | Sync-Herr | offline geoeffnet | Stand danach | Urteil |"
  echo "|---|---|---|---|---|"
} >> "$OUT"

xcrun simctl shutdown "$D" 2>/dev/null; xcrun simctl erase "$D"
xcrun simctl boot "$D"; xcrun simctl bootstatus "$D" -b > /dev/null 2>&1
xcrun simctl keychain "$D" add-root-cert "$M/ca.pem"
mock_start ok 0
rc=$(run_case testMatrixRSSPodcastResumesOffline)
POS="$(rss_position)"
# Der Fall spielt VOR dem Neustart ~16 s und DANACH ~11 s. Ein Null-Start
# stuende also bei ~11, ein korrekter Wiedereinstieg deutlich darueber.
if [ -n "$POS" ] && [ "$POS" -gt 20 ]; then URTEIL="setzte fort"; else URTEIL="🔴 Null-Start"; fi
echo "| RSS-Podcast | iCloud | ja (Feed 503, Ton lokal) | ${POS:-—}s | $URTEIL (rc=$rc) |" >> "$OUT"

echo "" >> "$OUT"
echo "Erzeugt von \`messung.sh\`; Bildschirmfotos je Fall in den xcresult-Buendeln." >> "$OUT"
cat "$OUT"
