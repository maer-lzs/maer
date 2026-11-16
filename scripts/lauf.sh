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
#   wiederhole <Suite[/Fall]> [Anzahl]   one case many times in one run,
#                                         then three cold runs; counts reds
#   release <tag> <build> [--sha S] [--main]
#                                         the one way to a tag and to main:
#                                         the commit is the GitSHA of the
#                                         uploaded build, on origin/dev, with
#                                         the note of the final run (a commit
#                                         from before this script needs none),
#                                         the tag new, main only forward to it;
#                                         origin only, never another remote
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
ARCHIVE_ROOT="${LAUF_ARCHIVE:-$HOME/Library/Developer/Xcode/Archives}"
NM="${LAUF_NM:-xcrun nm}"
DEMANGLE="${LAUF_DEMANGLE:-xcrun swift-demangle --simplified}"
STRINGS="${LAUF_STRINGS:-strings}"
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
# The bundles of the app installed on a booted simulator. A list that cannot
# be read fails; it is not an empty list.
app_bundles() {
    local list
    list="$($SIMCTL listapps "$1" 2>/dev/null)" || return 1
    printf '%s' "$list" | plutil -convert json -o - - 2>/dev/null | python3 -c "
import json, sys
try: apps = json.load(sys.stdin)
except ValueError: sys.exit(1)
for key in sorted(apps):
    if key.startswith(sys.argv[1]): print(key)" "$APP_PREFIX"
}
# An uninstall can answer 0 and leave the bundle (iOS 18.6 right after the
# boot), so the list is asked again after each round.
reset_app() {
    local udid="$1" name="$2" id dir ids round
    $SIMCTL bootstatus "$udid" -b >/dev/null 2>&1 || stop "$name liess sich nicht booten" 2
    ids="$(app_bundles "$udid")" || stop "die Liste der Apps auf $name liess sich nicht lesen" 2
    ids="$(printf '%s\n' "$APP_ID" $ids | sort -u)"
    for round in 1 2 3; do
        for id in $ids; do
            $SIMCTL uninstall "$udid" "$id" >/dev/null 2>&1 || stop "$id liess sich auf $name nicht entfernen" 2
        done
        ids="$(app_bundles "$udid")" || stop "die Liste der Apps auf $name liess sich nicht lesen" 2
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
# Ends the run's xcodebuild: TERM, ten seconds to end its test session,
# then KILL; xcodebuild can go on after TERM.
end_child() {
    local i
    kill -TERM "$1" 2>/dev/null || return 0
    for i in $(seq 1 20); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.5; done
    kill -KILL "$1" 2>/dev/null
}
cleanup() {
    [ -n "$LOWER" ] && kill "$LOWER" 2>/dev/null
    [ -n "$CHILD" ] && end_child "$CHILD"
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
    # The red cases by name, and how often a case failed (once per
    # repetition in a run that repeats).
    RED_NAMES="$(grep -o '✘ Test "[^"]*"' "$STORE/lauf.log" | sed 's/^✘ Test "//; s/"$//' | sort -u | paste -sd ';' -)"
    RED_COUNT="$(grep -c '✘ Test "[^"]*" failed after' "$STORE/lauf.log")"
    $SIMCTL --set "$HOME/Library/Developer/XCTestDevices" delete all >/dev/null 2>&1
    rm -rf -- "$STORE"; STORE=""
    return $rc
}

RED_NAMES=""
RED_COUNT=0

# R8: whether the commit changes tests.
touches_tests() {
    git diff-tree --no-commit-id --name-only -r --root "$1" | grep -qE '^(MaerTests|MaerUITests)/'
}

# The names of test hooks (_test...) in a program, among its symbols and in
# its text: a stripped program, as in an archive, keeps the names of its
# fields as text only. A program that is not there fails.
test_hooks_in() {
    [ -f "$1" ] || { echo "kein Programm: $1"; return 2; }
    { $NM -a "$1" 2>/dev/null | $DEMANGLE; $STRINGS -a "$1" 2>/dev/null; } | grep -E '(^|[^A-Za-z])_test[A-Z]' | sort -u | head -5
    return 0
}

# Builds the release program of the head and reads its symbols. On a branch
# the stamp fence of the project ends the build after the link (HEAD is not
# on origin/dev); that one line is expected, any other error is not.
release_symbols() {
    local dd="$BAU_ROOT/release" log began program hooks
    mkdir -p "$dd"; log="$(mktemp "$ABLAGE_ROOT/release.XXXXXX")"; began="$(date +%s)"
    nice -n 10 $XB build -scheme Maer -configuration Release -destination 'generic/platform=iOS' \
        CODE_SIGNING_ALLOWED=NO -derivedDataPath "$dd" > "$log" 2>&1
    if grep 'error:' "$log" | grep -qv 'HEAD is not on origin/dev'; then
        grep 'error:' "$log" | head -5; rm -f "$log"; stop "der Release-Bau ist rot: kein Vermerk" 1
    fi
    rm -f "$log"
    program="$dd/Build/Products/Release-iphoneos/Maer.app/Maer"
    [ -f "$program" ] && [ "$(stat -f %m "$program")" -ge "$began" ] || stop "kein frisches Release-Programm: kein Vermerk" 1
    hooks="$(test_hooks_in "$program")" || stop "$hooks" 1
    [ -z "$hooks" ] || stop "Test-Haken im Release-Programm: $(echo "$hooks" | head -3 | tr '\n' ' '): kein Vermerk" 1
    say "Release-Programm ohne Test-Haken"
}

# R8, rule 10 of the coding rules (tests before the code, kontext/
# coding-regelwerk.md): the first commit of the branch that changes Sources/, or a commit
# before it, carries the note of a red selection at its content; a red
# commit may bring empty shells of a new function under Sources/, so its
# witnesses fail at the behaviour, not at the build. A branch of form, a follow-up after the review and a pure
# translation are named so and pass (form-, nachzug-, sprache-). The hook
# checks order and red, not whether the tests test the right thing.
r8_order() {
    local branch="$1" head="$2" c unproven="" proven=""
    case "$branch" in form-*|nachzug-*|sprache-*) return 0;; esac
    git rev-parse -q --verify origin/dev >/dev/null || { echo "origin/dev fehlt hier: die Reihenfolge ist nicht gemessen"; return 1; }
    for c in $(git rev-list --reverse "$head" --not origin/dev); do
        if git notes --ref=lauf show "$c" 2>/dev/null | grep "art=rot" | grep -q "baum=$(git rev-parse "$c^{tree}")"; then
            proven=1
        elif touches_tests "$c"; then
            unproven="${unproven:-$(git rev-parse --short "$c")}"
        fi
        if git diff-tree --no-commit-id --name-only -r --root "$c" | grep -q '^Sources/'; then
            [ -n "$proven" ] && return 0
            [ -n "$unproven" ] && { echo "kein roter Vermerk am Test-Commit $unproven vor dem Code $(git rev-parse --short "$c")"; return 1; }
            echo "kein Test-Commit vor dem Code $(git rev-parse --short "$c")"; return 1
        fi
    done
    return 0
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

# Whether a commit is from before this script: it does not hold
# scripts/lauf.sh, and it lies at or before the commit of origin/dev the
# script grew from. Such a commit had no final run to note.
before_the_script() {
    local commit="$1" added since
    git cat-file -e "$commit:scripts/lauf.sh" 2>/dev/null && return 1
    added="$(git log --diff-filter=A --format=%H HEAD -- scripts/lauf.sh | tail -1)"
    [ -n "$added" ] || return 1
    since="$(git merge-base "$added" origin/dev 2>/dev/null)" || return 1
    git merge-base --is-ancestor "$commit" "$since"
}

# The GitSHA of the archives of one version and build in the organizer, one
# per line.
archive_shas() {
    find "$ARCHIVE_ROOT" -maxdepth 2 -name '*.xcarchive' 2>/dev/null | while read -r a; do
        [ "$(plutil -extract ApplicationProperties.CFBundleShortVersionString raw "$a/Info.plist" 2>/dev/null)" = "$1" ] || continue
        [ "$(plutil -extract ApplicationProperties.CFBundleVersion raw "$a/Info.plist" 2>/dev/null)" = "$2" ] || continue
        plutil -extract GitSHA raw "$a/Products/Applications/Maer.app/Info.plist" 2>/dev/null
    done | sort -u
}

# The program inside the archive of one version and build.
archive_program() {
    find "$ARCHIVE_ROOT" -maxdepth 2 -name '*.xcarchive' 2>/dev/null | while read -r a; do
        [ "$(plutil -extract ApplicationProperties.CFBundleShortVersionString raw "$a/Info.plist" 2>/dev/null)" = "$1" ] || continue
        [ "$(plutil -extract ApplicationProperties.CFBundleVersion raw "$a/Info.plist" 2>/dev/null)" = "$2" ] || continue
        echo "$a/Products/Applications/Maer.app/Maer"; break
    done
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
    if ! run_tests "$SIM_ARBEIT" "${args[@]+"${args[@]}"}"; then
        # A commit of only tests that is red at the selection notes its red
        # cases: the proof of R8 that the witnesses were red before the code.
        if [ "$kind" = auswahl ] && clean_tree && touches_tests HEAD && [ -n "$RED_NAMES" ]; then
            line="lauf art=rot baum=$(tree_of_head) datum=$(date +%Y-%m-%dT%H:%M:%S) faelle=$RED_NAMES"
            git notes --ref=lauf append -m "$line" HEAD && say "Vermerk: $line"
        fi
        stop "rot" 1
    fi
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
    release_symbols
    write_note abschluss 27,18.6
    ;;
push)
    target="${1:-}"; shift || true
    [ $# -eq 0 ] || stop "push nimmt keine weiteren Angaben: $*; Umschreiben ist verboten" 2
    branch="$(git branch --show-current)"
    [ -n "$branch" ] || stop "kein Zweig ausgecheckt" 2
    clean_tree || stop "der Baum ist nicht sauber"
    git fetch -q origin 2>/dev/null
    # The commit checked is the commit pushed: by its sha, not by a name
    # that a commit during the push could move.
    sha="$(git rev-parse HEAD)"
    case "$target" in
        zweig)
            case "$branch" in dev|main) stop "push zweig nicht auf $branch";; esac
            why="$(note_ok "$sha" "abschluss" "27,18.6")" || stop "push zweig verlangt den Vermerk eines vollen Laufs auf 27 und 18.6 am Kopf: $why"
            why="$(r8_order "$branch" "$sha")" || stop "R8: $why"
            remote="refs/heads/$branch";;
        dev)
            why="$(note_ok "$sha" "abschluss" "27,18.6")" || stop "push dev verlangt den Vermerk am Commit: $why"
            git merge-base --is-ancestor origin/dev "$sha" || stop "push dev ist kein Vorspulen von origin/dev"
            remote="refs/heads/dev";;
        nachzug)
            why="$(note_ok "$sha" "auswahl doku voll abschluss")" || stop "push nachzug verlangt den Vermerk der Auswahl: $why"
            remote="refs/heads/$branch";;
        doku)
            why="$(note_ok "$sha" "doku auswahl voll abschluss")" || stop "push doku verlangt den Vermerk der Dokument-Suiten: $why"
            remote="refs/heads/$branch";;
        *) stop "push zweig | dev | nachzug | doku" 2;;
    esac
    LAUF_PUSH=1 git push origin "$sha:$remote" "$NOTES:$NOTES" || stop "der Push wurde abgelehnt"
    ;;
r8)
    # For the pre-push hook: the order of R8 on a branch.
    r8_order "${1:-}" "${2:-HEAD}"
    ;;
wiederhole)
    target="${1:-}"; count="${2:-100}"
    [ -n "$target" ] || stop "wiederhole <Suite[/Fall]> [Anzahl]" 2
    echo "$count" | grep -Eq '^[1-9][0-9]*$' || stop "keine Anzahl: $count" 2
    space
    wait_for_quiet
    wait_for_foreign "$SIM_ARBEIT"
    silence "$SIM_ARBEIT"
    run_tests "$SIM_ARBEIT" "-only-testing:MaerTests/$target" -test-iterations "$count"; rc=$?
    once="$RED_COUNT"
    say "in einem Lauf: rot $once von $count"
    cold=0
    for i in 1 2 3; do
        silence "$SIM_ARBEIT"
        run_tests "$SIM_ARBEIT" "-only-testing:MaerTests/$target" >/dev/null || cold=$((cold + 1))
    done
    say "kalt: rot $cold von 3"
    [ $rc = 0 ] && [ $cold = 0 ] || stop "wackelt: rot $once von $count in einem Lauf, $cold von 3 kalt" 1
    ;;
vor-dem-skript)
    # For the pre-push hook: exit 0 when the commit is from before this script.
    before_the_script "$(git rev-parse --verify -q "${1:-}^{commit}")"
    ;;
release)
    tag="${1:-}"; build="${2:-}"; shift 2 2>/dev/null || stop "release <tag> <build> [--sha S] [--main]" 2
    sha=""; main=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --sha) sha="${2:-}"; shift;;
            --main) main=1;;
            *) stop "release nimmt nur --sha und --main: $1" 2;;
        esac
        shift
    done
    echo "$tag" | grep -Eq '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' || stop "kein Tag der Form v3.8 oder v3.6.4: $tag" 2
    echo "$build" | grep -Eq '^[0-9]+$' || stop "kein Build: $build" 2
    version="${tag#v}"
    git fetch -q origin 2>/dev/null
    found="$(archive_shas "$version" "$build")"
    [ "$(echo "$found" | grep -c .)" -le 1 ] || stop "mehrere Archive $version ($build) mit verschiedenem GitSHA: $(echo $found)"
    [ -n "$found$sha" ] || stop "kein Archiv $version ($build) unter $ARCHIVE_ROOT und kein --sha"
    commit="$(git rev-parse --verify -q "${found:-$sha}^{commit}")" || stop "der Commit ${found:-$sha} ist hier nicht bekannt"
    if [ -n "$found" ]; then
        program="$(archive_program "$version" "$build")"
        hooks="$(test_hooks_in "$program")" || stop "$hooks"
        [ -z "$hooks" ] || stop "Test-Haken im hochgeladenen Programm $version ($build): $(echo "$hooks" | head -3 | tr '\n' ' ')"
    else
        say "kein Archiv: die Symbole des hochgeladenen Programms sind nicht gelesen"
    fi
    if [ -n "$found" ] && [ -n "$sha" ]; then
        [ "$(git rev-parse --verify -q "$sha^{commit}")" = "$commit" ] || stop "--sha $sha ist nicht der GitSHA $found des Archivs $version ($build)"
    fi
    git merge-base --is-ancestor "$commit" origin/dev || stop "$(git rev-parse --short "$commit") liegt nicht auf origin/dev"
    if ! before_the_script "$commit"; then
        why="$(note_ok "$commit" abschluss 27,18.6)" || stop "release verlangt den Vermerk des vollen Laufs auf 27 und 18.6: $why"
    fi
    git rev-parse -q --verify "refs/tags/$tag" >/dev/null && stop "der Tag $tag ist hier schon da"
    [ -z "$(git ls-remote origin "refs/tags/$tag")" ] || stop "der Tag $tag ist am Server schon da"
    refs=("refs/tags/$tag")
    if [ -n "$main" ]; then
        git merge-base --is-ancestor origin/main "$commit" || stop "main geht nur vorwaerts: kein Vorspulen von origin/main auf $(git rev-parse --short "$commit")"
        refs+=("$commit:refs/heads/main")
    fi
    git tag -a "$tag" "$commit" -m "Mär $version" || stop "der Tag liess sich nicht anlegen"
    if ! LAUF_PUSH=1 LAUF_RELEASE="$tag" git push origin "${refs[@]}"; then
        git tag -d "$tag" >/dev/null
        stop "der Push wurde abgelehnt; der Tag ist lokal wieder weg"
    fi
    say "$tag an $(git rev-parse --short "$commit")${main:+, main ebenso}, nur nach origin"
    ;;
*)
    stop "lauf.sh auswahl | voll | abschluss | push <zweig|dev|nachzug|doku> | wiederhole <Suite> [Anzahl] | release <tag> <build>" 2;;
esac
