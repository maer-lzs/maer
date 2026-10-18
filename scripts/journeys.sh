#!/bin/zsh
# Runs the UI journeys on a simulator template of their own, headless and in
# parallel, and writes a summary (green/red per journey with its duration).
#
# The template "Maer-Journeys" is never signed into an Apple ID and is erased
# before every run; the DEBUG build keeps the shared cloud store in memory on
# a simulator anyway (CloudKeyValue). Simulator.app is quit first so the
# clones boot headless.
#
# Usage: scripts/journeys.sh [--only <TestClass[/testName]> ...]
# Environment:
#   MAER_JOURNEY_WORKERS   parallel clones (default 1; see below)
#   MAER_JOURNEY_DEVICE    device type name (default "iPhone 17")
#   MAER_JOURNEY_DD        derived data directory (default a temp dir)
#   MAER_JOURNEY_RUNTIME   simulator runtime identifier (default the newest iOS)
#   MAER_JOURNEY_TARGET    deployment target for this build only, e.g. 18.0
#                          (default the project's own)
#   MAER_BERICHTE_DIR      a checkout of implementer-reports; when set, the summary
#                          is committed and pushed there
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
STARTED=$(date +%s)
STAMP=$(date +%Y-%m-%d-%H%M)
# ONE clone by default. Measured on 07.09.2026: with two clones 24 of 64
# journeys were red; run serially, 11 of those 24 turned green with no
# change to the app. Two clones on one machine starve each other and the
# waits in the witnesses run out, so the run measures the machine instead
# of the app. The time is the price; a red field that is only red under
# load costs more.
WORKERS=${MAER_JOURNEY_WORKERS:-1}
DEVICE=${MAER_JOURNEY_DEVICE:-"iPhone 17"}
DD=${MAER_JOURNEY_DD:-$(mktemp -d -t maer-journeys)}
LOG="$DD/journeys-$STAMP.log"
mkdir -p "$DD"

only=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) shift; only+=("-only-testing:MaerUITests/$1");;
        *) echo "unknown argument: $1" >&2; exit 2;;
    esac
    shift
done
[[ ${#only[@]} -eq 0 ]] && only=("-only-testing:MaerUITests")

# 0. The reader of the summary checks itself first: a reader that counts
# nothing makes a whole run measure nothing (it did, from 07.09.2026 on).
python3 scripts/journeys-summary.py --selbstprobe >/dev/null \
    || { echo "summary reader broken, see scripts/journeys-summary.py"; exit 1; }

# 1. Simulator.app closed: CoreSimulator boots the clones headless.
osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true

# 2. The template: created once, erased every run, never signed in. One
# template PER RUNTIME, named after it: a template shared by two runtimes
# changes its iOS version whenever it is recreated, and a journey then turns
# red on unchanged code (measured 25.09.2026, 26.5 green, 27.0 red).
runtime=${MAER_JOURNEY_RUNTIME:-$(xcrun simctl list runtimes available -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS"]; print(sorted(r, key=lambda x: [int(p) for p in x["version"].split(".")])[-1]["identifier"])')}
[[ -n "$runtime" ]] || { echo "no iOS simulator runtime found" >&2; exit 2; }
TEMPLATE="Maer-Journeys-${runtime##*.}"
udid=$(xcrun simctl list devices -j | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x['udid'] for l in d.values() for x in l if x['name']=='$TEMPLATE'), ''))")
if [[ -z "$udid" ]]; then
    udid=$(xcrun simctl create "$TEMPLATE" "$DEVICE" "$runtime")
    echo "template created: $TEMPLATE ($udid)"
fi
xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
xcrun simctl erase "$udid"
# Sound and microphone of the template on a silent device, so a run does not
# break the Mac's sound: a running simulator disturbs coreaudiod (18.10.2026).
# The erase removes the choice, so it is written after every erase, before
# the boot. MAER_JOURNEY_AUDIO_UID names another device; without BlackHole
# installed and without the variable the template keeps the Mac's devices.
audio_uid=${MAER_JOURNEY_AUDIO_UID:-}
[[ -z "$audio_uid" && -d /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver ]] && audio_uid=BlackHole2ch_UID
if [[ -n "$audio_uid" ]]; then
    audio_dir="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/var/run"
    audio_plist="$audio_dir/com.apple.coresimulator.audio.plist"
    mkdir -p "$audio_dir" && { [[ -f "$audio_plist" ]] || plutil -create xml1 "$audio_plist"; } \
        && plutil -replace sim_output_device_uid -string "$audio_uid" "$audio_plist" \
        && plutil -replace sim_input_device_uid -string "$audio_uid" "$audio_plist" \
        && plutil -replace useHostDefaultOutputDevice -bool NO "$audio_plist" \
        && plutil -replace useHostDefaultInputDevice -bool NO "$audio_plist" \
        || { echo "audio device of the template not set" >&2; exit 2; }
fi

# 3. Build once, then run. A lower target applies to this build only; the
# project keeps its own.
target=()
build_destination="platform=iOS Simulator,id=$udid"
# With a lower target the build goes against the GENERIC simulator: given
# the device, xcodebuild checks the PROJECT's target (26.5) against the
# device's OS before the override applies and refuses an 18.6 device
# (measured 29.09.2026, "doesn't match Maer.app's iOS Simulator 26.5
# deployment target"). The run below then takes the built products by
# their xctestrun, which carries the lowered target.
if [[ -n "${MAER_JOURNEY_TARGET:-}" ]]; then
    target=("IPHONEOS_DEPLOYMENT_TARGET=$MAER_JOURNEY_TARGET")
    build_destination="generic/platform=iOS Simulator"
fi
xcodebuild build-for-testing -project Maer.xcodeproj -scheme Maer \
    -destination "$build_destination" -derivedDataPath "$DD" "${target[@]}" > "$DD/build-$STAMP.log" 2>&1 \
    || { echo "build failed, see $DD/build-$STAMP.log"; exit 1; }
RESULT="$DD/journeys-$STAMP.xcresult"
# ONE worker means NO clone: enabling parallel testing creates a cloned
# simulator even for a single worker, and cloning one costs more than it
# can save when nothing runs beside it. It does NOT heal the two radio
# journeys that only fail in a sequence; measured 07.09.2026, their run
# times were identical to the tenth of a second with the clone and
# without it (194.4/194.6 and 210.3/210.4 s). That cause is still open.
parallel=(-parallel-testing-enabled YES -parallel-testing-worker-count "$WORKERS")
[[ "$WORKERS" -le 1 ]] && parallel=(-parallel-testing-enabled NO)
built=(-project Maer.xcodeproj -scheme Maer -derivedDataPath "$DD")
if [[ -n "${MAER_JOURNEY_TARGET:-}" ]]; then
    built=(-xctestrun "$(ls "$DD"/Build/Products/Maer_*.xctestrun | head -1)")
fi
# No simulator diagnostics after the run: without the option xcodebuild
# collected them after the last journey and ran into its 600 s limit
# (measured 18.10.2026 on iOS 27: closing line 15:24:31, end 15:34:35).
xcodebuild test-without-building "${built[@]}" \
    -destination "platform=iOS Simulator,id=$udid" \
    "${parallel[@]}" -collect-test-diagnostics never \
    -resultBundlePath "$RESULT" "${only[@]}" > "$LOG" 2>&1
# `status` is READ-ONLY in zsh (it mirrors $?), so assigning to it aborted
# the script right here and no summary was ever written.
rc=$?
xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
ELAPSED=$(( $(date +%s) - STARTED ))

# 4. Summary: one line per journey, red first. A table that does not
# account for every executed journey turns the run red (exit 3 of the reader).
SUMMARY="$DD/journeys-$STAMP.md"
TABLE=$(python3 scripts/journeys-summary.py "$LOG")
[[ $? -ne 0 && $rc -eq 0 ]] && rc=3
{
    echo "# Journeys $STAMP: $( [[ $rc -eq 0 ]] && echo grün || echo rot ), $ELAPSED s gesamt, $WORKERS Klone, $DEVICE, ${runtime##*.}"
    echo
    echo "| Journey | Ergebnis | Dauer |"
    echo "|---|---|---|"
    echo "$TABLE"
    echo
    echo "Log: $LOG · Ergebnis: $RESULT"
} > "$SUMMARY"
cat "$SUMMARY"

# 5. Into the reports repository, when one is given.
if [[ -n "${MAER_BERICHTE_DIR:-}" && -d "$MAER_BERICHTE_DIR/.git" ]]; then
    cp "$SUMMARY" "$MAER_BERICHTE_DIR/$STAMP-journeys.md"
    (cd "$MAER_BERICHTE_DIR" && git add "$STAMP-journeys.md" && git commit -q -m "Journeys $STAMP" && git push -q) \
        || echo "report not pushed (see $SUMMARY)"
elif [[ -n "${MAER_BERICHTE_DIR:-}" ]]; then
    echo "report not pushed: $MAER_BERICHTE_DIR is no git checkout (see $SUMMARY)"
fi
exit $rc
