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
#   MAER_JOURNEY_WORKERS   parallel clones (default 3)
#   MAER_JOURNEY_DEVICE    device type name (default "iPhone 17")
#   MAER_JOURNEY_DD        derived data directory (default a temp dir)
#   MAER_BERICHTE_DIR      a checkout of implementer-reports; when set, the summary
#                          is committed and pushed there
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
STARTED=$(date +%s)
STAMP=$(date +%Y-%m-%d-%H%M)
WORKERS=${MAER_JOURNEY_WORKERS:-3}
DEVICE=${MAER_JOURNEY_DEVICE:-"iPhone 17"}
DD=${MAER_JOURNEY_DD:-$(mktemp -d -t maer-journeys)}
TEMPLATE="Maer-Journeys"
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

# 1. Simulator.app closed: CoreSimulator boots the clones headless.
osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true

# 2. The template: created once, erased every run, never signed in.
runtime=$(xcrun simctl list runtimes available -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS"]; print(sorted(r, key=lambda x: x["version"])[-1]["identifier"])')
udid=$(xcrun simctl list devices -j | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x['udid'] for l in d.values() for x in l if x['name']=='$TEMPLATE'), ''))")
if [[ -z "$udid" ]]; then
    udid=$(xcrun simctl create "$TEMPLATE" "$DEVICE" "$runtime")
    echo "template created: $TEMPLATE ($udid)"
fi
xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
xcrun simctl erase "$udid"

# 3. Build once, then run on clones.
xcodebuild build-for-testing -project Maer.xcodeproj -scheme Maer \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$DD" > "$DD/build-$STAMP.log" 2>&1 \
    || { echo "build failed, see $DD/build-$STAMP.log"; exit 1; }
RESULT="$DD/journeys-$STAMP.xcresult"
xcodebuild test-without-building -project Maer.xcodeproj -scheme Maer \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$DD" \
    -parallel-testing-enabled YES -parallel-testing-worker-count "$WORKERS" \
    -resultBundlePath "$RESULT" "${only[@]}" > "$LOG" 2>&1
status=$?
xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
ELAPSED=$(( $(date +%s) - STARTED ))

# 4. Summary: one line per journey, red first.
SUMMARY="$DD/journeys-$STAMP.md"
{
    echo "# Journeys $STAMP: $( [[ $status -eq 0 ]] && echo grün || echo rot ), $ELAPSED s gesamt, $WORKERS Klone, $DEVICE"
    echo
    echo "| Journey | Ergebnis | Dauer |"
    echo "|---|---|---|"
    grep -aE "Test case '.*' (passed|failed)" "$LOG" \
        | sed -E "s/.*Test case '([^']*)' (passed|failed) on '[^']*' \(([0-9.]+) seconds\).*/\1|\2|\3/" \
        | sort -t'|' -k2,2 -k1,1 | awk -F'|' '{printf "| %s | %s | %.0f s |\n", $1, ($2=="passed" ? "grün" : "ROT"), $3}'
    echo
    echo "Log: $LOG · Ergebnis: $RESULT"
} > "$SUMMARY"
cat "$SUMMARY"

# 5. Into the reports repository, when one is given.
if [[ -n "${MAER_BERICHTE_DIR:-}" && -d "$MAER_BERICHTE_DIR/.git" ]]; then
    cp "$SUMMARY" "$MAER_BERICHTE_DIR/$STAMP-journeys.md"
    (cd "$MAER_BERICHTE_DIR" && git add "$STAMP-journeys.md" && git commit -q -m "Journeys $STAMP" && git push -q) \
        || echo "report not pushed (see $SUMMARY)"
fi
exit $status
