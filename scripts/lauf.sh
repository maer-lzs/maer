#!/bin/bash
# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS
#
# lauf.sh: the one way to run the unit tests and to push.
#   auswahl [--basis REV] [--nur-zeigen]  the selection after the change
#   voll [--nur-zeigen]                   the whole suite on iOS 27
#   abschluss                             the whole suite on 27, then 18.6,
#                                         on own simulators, the app reset
#                                         (erased only when new); green
#                                         writes the note at the head
#   push <zweig|dev|nachzug|doku>         checks the note and pushes
# Every run: at least LAUF_MIN_GB free (15), waits while a foreign simulator
# is booted, no parallel testing, nice 10 for xcodebuild and the processes of
# its simulator, no access file, the store of the run
# removed afterwards (green, red or aborted), the build state kept. The full
# and the final run wait for a quiet machine: the load over one minute below
# the number of cores.
#
# Limits, named: the pre-push hook knows this script by LAUF_PUSH=1, and a
# note under refs/notes/lauf can be written by hand with git notes add. Both
# can be faked; the hook keeps the habit, not a will. The notes are pushed,
# so whoever reviews reads them.
set -u
ROOT="$(git rev-parse --show-toplevel)" || exit 2
cd "$ROOT" || exit 2
XB="${LAUF_XCODEBUILD:-xcodebuild}"
SIMCTL="${LAUF_SIMCTL:-xcrun simctl}"
SYSCTL="${LAUF_SYSCTL:-sysctl}"
MIN_GB="${LAUF_MIN_GB:-15}"
ABLAGE_ROOT="${LAUF_ABLAGE:-$HOME/Developer/maer-lauf/ablage}"
BAU_ROOT="${LAUF_BAU:-$HOME/Developer/maer-lauf/bau}"
TEMP_ROOTS="${LAUF_TEMP_ROOTS:-/private/tmp/ /tmp/ /private/var/folders/ /var/folders/}"
WARTE_S="${LAUF_WARTE_S:-1800}"
TICK_S="${LAUF_TICK_S:-30}"
SIM_ARBEIT="${LAUF_SIM:-C1F0240C-E988-41D2-9081-4CFF0B8EA34B}"
SIM_27_NAME="${LAUF_SIM_27_NAME:-Maer-Abschluss-27}"
SIM_18_NAME="${LAUF_SIM_18_NAME:-Maer-Abschluss-18}"
SIM_DEVICES="${LAUF_SIM_DEVICES:-$HOME/Library/Developer/CoreSimulator/Devices}"
SILENT_DEVICE="${LAUF_STILLES_GERAET:-BlackHole2ch_UID}"
NOTES=refs/notes/lauf
AUSWAHL="python3 -I $ROOT/scripts/lauf/auswahl.py"

say() { echo "lauf: $*"; }
stop() { echo "lauf: $*" >&2; exit "${2:-1}"; }

space() {
    local free
    free="$(python3 -c "import shutil,sys; print(shutil.disk_usage(sys.argv[1]).free // 10**9)" "$ROOT")"
    [ "$free" -ge "$MIN_GB" ] || stop "zu wenig Platz: frei $free GB, verlangt $MIN_GB GB" 3
}

sim_json() { $SIMCTL list devices -j 2>/dev/null; }

# The udid of a simulator by name or udid.
sim_id() {
    sim_json | python3 -c "
import json, sys
want = sys.argv[1]
for devices in json.load(sys.stdin)['devices'].values():
    for d in devices:
        if want in (d['name'], d['udid']):
            print(d['udid']); sys.exit(0)
sys.exit(1)" "$1"
}

# Waits while a booted simulator that is not the run's own stands; stops with
# its name once the wait is over.
wait_for_foreign() {
    local own="$1" waited=0 foreign
    while :; do
        foreign="$(sim_json | python3 -c "
import json, sys
own = sys.argv[1]
for devices in json.load(sys.stdin)['devices'].values():
    for d in devices:
        if d['state'] == 'Booted' and d['udid'] != own:
            print(d['name'] + ' (' + d['udid'] + ')'); sys.exit(0)" "$own")"
        [ -z "$foreign" ] && return 0
        [ "$waited" -ge "$WARTE_S" ] && stop "fremder Simulator gebootet: $foreign, Abbruch nach $waited s" 4
        [ "$waited" = 0 ] && say "fremder Simulator gebootet: $foreign, ich warte"
        sleep "$TICK_S"; waited=$((waited + TICK_S))
    done
}

# The load over one minute, and whether it stands below the number of cores.
# sysctl prints the decimal mark of the locale (16,83); the note keeps a dot.
load_now() { $SYSCTL -n vm.loadavg | LC_ALL=C awk '{print $2}' | tr , .; }
quiet() { LC_ALL=C awk -v l="$1" -v c="$($SYSCTL -n hw.ncpu)" 'BEGIN { exit !(l + 0 < c + 0) }'; }

# Waits while the machine is loud; stops with the load measured once the wait
# is over. A run under heavy load measures nothing, red or green.
wait_for_quiet() {
    local waited=0 load
    while :; do
        load="$(load_now)"
        quiet "$load" && { LOAD_START="$load"; return 0; }
        [ "$waited" -ge "$WARTE_S" ] && stop "die Maschine ist laut: Last $load ueber eine Minute, $($SYSCTL -n hw.ncpu) Kerne, Abbruch nach $waited s" 5
        [ "$waited" = 0 ] && say "die Maschine ist laut: Last $load, ich warte"
        sleep "$TICK_S"; waited=$((waited + TICK_S))
    done
}
LOAD_START=""

# The runtime of a simulator, as its key in the list of devices.
sim_runtime() {
    sim_json | python3 -c "
import json, sys
for runtime, devices in json.load(sys.stdin)['devices'].items():
    if any(d['udid'] == sys.argv[1] for d in devices):
        print(runtime); sys.exit(0)
sys.exit(1)" "$1"
}

# The final run resets the app instead of erasing the simulator: the first
# boot after an erase drives the load of the Mac far over a hundred for some
# minutes. Every bundle of the app goes (the runner of the UI tests as well),
# its permissions and the keychain are reset, and the container of the app
# group is emptied while the simulator is shut down. Any failing step stops.
APP_PREFIX=fm.maer.
APP_ID=fm.maer.app
APP_GROUP=group.fm.maer.app
GROUP_META=.com.apple.mobile_container_manager.metadata.plist
# The bundles of the app installed on a booted simulator.
app_bundles() {
    $SIMCTL listapps "$1" 2>/dev/null | plutil -convert json -o - - 2>/dev/null | python3 -c "
import json, sys
try: apps = json.load(sys.stdin)
except ValueError: apps = {}
for key in sorted(apps):
    if key.startswith(sys.argv[1]): print(key)" "$APP_PREFIX"
}
# An uninstall can answer 0 and leave the bundle (iOS 18.6 right after the
# boot), so the list is asked again after each round.
reset_app() {
    local udid="$1" name="$2" id dir ids round
    $SIMCTL bootstatus "$udid" -b >/dev/null 2>&1 || stop "$name liess sich nicht booten" 2
    ids="$(printf '%s\n' "$APP_ID" $(app_bundles "$udid") | sort -u)"
    for round in 1 2 3; do
        for id in $ids; do
            $SIMCTL uninstall "$udid" "$id" >/dev/null 2>&1 || stop "$id liess sich auf $name nicht entfernen" 2
        done
        ids="$(app_bundles "$udid")"
        [ -z "$ids" ] && break
        sleep 1
    done
    [ -z "$ids" ] || stop "auf $name bleibt installiert: $(echo $ids)" 2
    $SIMCTL privacy "$udid" reset all "$APP_ID" >/dev/null 2>&1 || stop "die Rechte auf $name liessen sich nicht zuruecksetzen" 2
    $SIMCTL keychain "$udid" reset >/dev/null 2>&1 || stop "der Schluesselbund auf $name liess sich nicht zuruecksetzen" 2
    $SIMCTL shutdown "$udid" >/dev/null 2>&1
    for dir in "$SIM_DEVICES/$udid/data/Containers/Shared/AppGroup"/*/; do
        [ "$(plutil -extract MCMMetadataIdentifier raw "$dir$GROUP_META" 2>/dev/null)" = "$APP_GROUP" ] || continue
        find "$dir" -mindepth 1 -maxdepth 1 ! -name "$GROUP_META" -exec rm -rf {} + \
            || stop "die App-Gruppe auf $name liess sich nicht leeren" 2
    done
}

# Sound and microphone of a shut down simulator go to the silent device, so
# no run plays through the Mac. An erase clears this; it is written after.
silence() {
    local udid="$1" dir file
    $SIMCTL shutdown "$udid" >/dev/null 2>&1
    dir="$SIM_DEVICES/$udid/data/var/run"
    file="$dir/com.apple.coresimulator.audio.plist"
    mkdir -p "$dir" || stop "kein Ordner fuer den Ton von $udid" 2
    [ -f "$file" ] || plutil -create xml1 "$file"
    plutil -replace sim_output_device_uid -string "$SILENT_DEVICE" "$file" \
        && plutil -replace sim_input_device_uid -string "$SILENT_DEVICE" "$file" \
        && plutil -replace useHostDefaultOutputDevice -bool NO "$file" \
        && plutil -replace useHostDefaultInputDevice -bool NO "$file" \
        || stop "der Ton von $udid liess sich nicht stumm stellen" 2
}

# The processes of a simulator do not inherit nice from xcodebuild. While the
# run watched by pid goes on, launchd_sim of the udid and every process below
# it go to nice 10 each tick, the priority of xcodebuild, so a simulator
# booting late is caught as well. Only lowered, never raised, and nothing
# outside that tree.
below() {
    local p
    for p in $(pgrep -P "$1"); do echo "$p"; below "$p"; done
}
lower_simulator() {
    local udid="$1" watch="$2" root p n
    while kill -0 "$watch" 2>/dev/null; do
        for root in $(pgrep -f "launchd_sim .*$udid"); do
            for p in $root $(below "$root"); do
                n="$(ps -o ni= -p "$p" 2>/dev/null | tr -d ' ')"
                [ -n "$n" ] && [ "$n" -lt 10 ] && renice 10 -p "$p" >/dev/null 2>&1
            done
        done
        sleep "$TICK_S"
    done
}

STORE=""
CHILD=""
LOWER=""
cleanup() {
    [ -n "$LOWER" ] && kill "$LOWER" 2>/dev/null
    [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null
    [ -n "$STORE" ] && rm -rf -- "$STORE"
    STORE=""; CHILD=""; LOWER=""
}
trap 'cleanup' EXIT
trap 'cleanup; exit 143' TERM INT

# Runs MaerTests on one simulator. Arguments after the udid go to xcodebuild.
run_tests() {
    local udid="$1"; shift
    mkdir -p "$ABLAGE_ROOT" "$BAU_ROOT/${udid:0:8}"
    STORE="$(mktemp -d "$ABLAGE_ROOT/lauf.XXXXXX")"
    nice -n 10 env -u MAER_SERVER_ACCESS_FILE -u TEST_RUNNER_MAER_SERVER_ACCESS \
        $XB test -scheme MaerTests -destination "id=$udid" -derivedDataPath "$BAU_ROOT/${udid:0:8}" \
        -resultBundlePath "$STORE/lauf.xcresult" -parallel-testing-enabled NO "$@" > "$STORE/lauf.log" 2>&1 &
    CHILD=$!
    lower_simulator "$udid" "$CHILD" &
    LOWER=$!
    wait "$CHILD"; local rc=$?
    kill "$LOWER" 2>/dev/null; wait "$LOWER" 2>/dev/null
    CHILD=""; LOWER=""
    grep -E 'Test run with|\*\* TEST' "$STORE/lauf.log" | tail -2
    [ $rc -ne 0 ] && grep -E '✘|error:' "$STORE/lauf.log" | head -40
    $SIMCTL --set "$HOME/Library/Developer/XCTestDevices" delete all >/dev/null 2>&1
    rm -rf -- "$STORE"; STORE=""
    return $rc
}

# The -only-testing arguments for the top-level types of the chosen files.
types_of_files() {
    python3 -c "
import os, re, sys
root = sys.argv[1]
for name in sys.stdin.read().split():
    path = os.path.join(root, 'MaerTests', name + '.swift')
    text = open(path, encoding='utf-8', errors='replace').read()
    for t in re.findall(r'^(?:@\w+.*\n)*(?:final )?(?:struct|class|enum) (\w+)', text, re.M):
        print('-only-testing:MaerTests/' + t)" "$ROOT"
}

clean_tree() { [ -z "$(git status --porcelain)" ]; }
tree_of_head() { git rev-parse 'HEAD^{tree}'; }

write_note() {
    local line="lauf art=$1 laufzeiten=$2 ergebnis=gruen baum=$(tree_of_head) datum=$(date +%Y-%m-%dT%H:%M:%S)"
    [ -n "$LOAD_START" ] && line="$line last_beginn=$LOAD_START last_ende=$(load_now)"
    git notes --ref=lauf append -m "$line" HEAD && say "Vermerk: $line"
}

# A note line at the commit whose kind is one of the given and whose tree is
# the commit's tree. Prints why when there is none.
note_ok() {
    local commit="$1" kinds="$2" runtimes="${3:-}" notes tree
    notes="$(git notes --ref=lauf show "$commit" 2>/dev/null)"
    [ -n "$notes" ] || { echo "kein Vermerk am Commit $(git rev-parse --short "$commit")"; return 1; }
    tree="$(git rev-parse "$commit^{tree}")"
    local line kind fits=""
    while read -r line; do
        kind="$(echo "$line" | sed -n 's/.*art=\([a-z]*\).*/\1/p')"
        case " $kinds " in *" $kind "*) ;; *) continue;; esac
        echo "$line" | grep -q "ergebnis=gruen" || continue
        if [ -n "$runtimes" ]; then echo "$line" | grep -q "laufzeiten=$runtimes" || continue; fi
        fits=1
        echo "$line" | grep -q "baum=$tree" && return 0
    done <<< "$notes"
    if [ -n "$fits" ]; then echo "der Vermerk passt nicht zum Inhalt des Commits $(git rev-parse --short "$commit")"; return 1; fi
    echo "kein Vermerk der Art ($kinds${runtimes:+, $runtimes}) am Commit $(git rev-parse --short "$commit")"
    return 1
}

kind="${1:-}"; shift || true
case "$kind" in
auswahl|voll)
    show=""; basis=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --nur-zeigen) show=1;;
            --basis) basis="$2"; shift;;
            *) stop "unbekannt: $1" 2;;
        esac
        shift
    done
    if [ "$kind" = voll ]; then plan="$($AUSWAHL --voll)" || exit 2
    else plan="$($AUSWAHL ${basis:+--basis "$basis"})" || exit 2; fi
    if [ -n "$show" ]; then echo "$plan"; exit 0; fi
    space
    note_kind="$kind"
    echo "$plan" | grep -qx "art: doku" && note_kind=doku
    if [ "$kind" = voll ] || echo "$plan" | grep -qx "voll"; then
        [ "$kind" = auswahl ] && say "eine Bau-Datei ist geaendert: der volle Lauf"
        args=()
    else
        args=($(echo "$plan" | sed -n 's/^datei //p' | types_of_files))
    fi
    echo "$plan" | grep -v '^datei ' | sed 's/^/lauf: /'
    [ "$kind" = voll ] && wait_for_quiet
    wait_for_foreign "$SIM_ARBEIT"
    silence "$SIM_ARBEIT"
    run_tests "$SIM_ARBEIT" "${args[@]+"${args[@]}"}" || stop "rot" 1
    if clean_tree; then write_note "$note_kind" 27; else say "der Baum ist offen: kein Vermerk"; fi
    if echo "$plan" | grep -qx "ui: ja" && [ "$kind" = auswahl ]; then
        say "UI beruehrt: die Journeys laufen"
        ${LAUF_JOURNEYS:-zsh scripts/journeys.sh} || stop "Journeys rot" 1
    fi
    ;;
abschluss)
    clean_tree || stop "der Baum ist nicht sauber: $(git status --porcelain | head -5 | tr '\n' ' ')"
    real="$(cd "$ROOT" && pwd -P)/"
    for t in $TEMP_ROOTS; do
        case "$real" in "$t"*|"$(cd "$t" 2>/dev/null && pwd -P)/"*) stop "der Baum liegt unter einem temporaeren Pfad: $ROOT";; esac
        case "$ROOT/" in "$t"*) stop "der Baum liegt unter einem temporaeren Pfad: $ROOT";; esac
    done
    space
    wait_for_quiet
    for pair in "27:$SIM_27_NAME" "18.6:$SIM_18_NAME"; do
        runtime="${pair%%:*}"; name="${pair#*:}"
        udid="$(sim_id "$name")" || stop "kein Simulator $name; einmal anlegen mit simctl create" 2
        wait_for_foreign "$udid"
        mark="$BAU_ROOT/${udid:0:8}/stand"
        want="udid=$udid laufzeit=$(sim_runtime "$udid")"
        if [ "$(cat "$mark" 2>/dev/null)" = "$want" ]; then
            reset_app "$udid" "$name"
        else
            say "$name ist neu oder hat eine andere Laufzeit: ganz geloescht"
            $SIMCTL shutdown "$udid" >/dev/null 2>&1
            $SIMCTL erase "$udid" >/dev/null 2>&1 || stop "$name liess sich nicht loeschen" 2
            mkdir -p "${mark%/*}" && echo "$want" > "$mark"
        fi
        silence "$udid"
        say "voller Lauf auf $runtime ($name)"
        run_tests "$udid" || stop "rot auf $runtime: kein Vermerk" 1
    done
    write_note abschluss 27,18.6
    ;;
push)
    target="${1:-}"; shift || true
    [ $# -eq 0 ] || stop "push nimmt keine weiteren Angaben: $*; Umschreiben ist verboten" 2
    branch="$(git branch --show-current)"
    [ -n "$branch" ] || stop "kein Zweig ausgecheckt" 2
    clean_tree || stop "der Baum ist nicht sauber"
    git fetch -q origin 2>/dev/null
    case "$target" in
        zweig)
            case "$branch" in dev|main) stop "push zweig nicht auf $branch";; esac
            why="$(note_ok HEAD "abschluss" "27,18.6")" || stop "push zweig verlangt den Vermerk eines vollen Laufs auf 27 und 18.6 am Kopf: $why"
            remote="refs/heads/$branch";;
        dev)
            why="$(note_ok HEAD "abschluss" "27,18.6")" || stop "push dev verlangt den Vermerk am Commit: $why"
            git merge-base --is-ancestor origin/dev HEAD || stop "push dev ist kein Vorspulen von origin/dev"
            remote="refs/heads/dev";;
        nachzug)
            why="$(note_ok HEAD "auswahl doku voll abschluss")" || stop "push nachzug verlangt den Vermerk der Auswahl: $why"
            remote="refs/heads/$branch";;
        doku)
            why="$(note_ok HEAD "doku auswahl voll abschluss")" || stop "push doku verlangt den Vermerk der Dokument-Suiten: $why"
            remote="refs/heads/$branch";;
        *) stop "push zweig | dev | nachzug | doku" 2;;
    esac
    LAUF_PUSH=1 git push origin "HEAD:$remote" "$NOTES:$NOTES" || stop "der Push wurde abgelehnt"
    ;;
*)
    stop "lauf.sh auswahl | voll | abschluss | push <zweig|dev|nachzug|doku>" 2;;
esac
