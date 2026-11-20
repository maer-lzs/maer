#!/bin/bash
# test-lauf.sh: the witnesses of the run script (scripts/lauf.sh), its
# selection (scripts/lauf/auswahl.py) and the pre-push hook. Builds a
# throwaway repository with a bare origin and a second remote, replaces
# xcodebuild and simctl by stubs through the environment, and asks the script
# about each case. No simulator runs. One case, the history of this week,
# reads the real repository. Prints one line per case and exits non-zero when
# any case goes the wrong way.
set -u
# The archives, the silent device and the marks of the simulators are
# property lists; without plutil this copy cannot ask those cases. Skipped
# with the reason, not counted as failures.
command -v plutil >/dev/null || { echo "skipped: no plutil in this copy, the witnesses read and write property lists"; exit 0; }
LAUF="$(cd "$(dirname "$0")" && pwd)"
REAL="$(cd "$LAUF/../.." && pwd)"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lauf-witness.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
DEV="$WORK/dev"; TEMP="$WORK/tmp"; STUB="$WORK/stub"
mkdir -p "$DEV" "$TEMP" "$STUB"
REPO="$DEV/repo"
failures=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/     /' | head -6; failures=$((failures + 1)); }

# The stubs. xcodebuild logs its arguments, its nice value, whether an access
# file reached it and its start and end, sleeps if asked, and passes or fails.
cat > "$STUB/xcodebuild" <<'EOF'
#!/bin/bash
log="$LAUF_STUB_DIR/xcodebuild.log"
# The release build writes the program, its symbols from the file
# release-symbols (none of a witness by default); it logs a line of its own.
if [ "${1:-}" = build ]; then
    echo "release-build $*" >> "$log"
    prev=""; for arg in "$@"; do
        if [ "$prev" = "-derivedDataPath" ]; then
            app="$arg/Build/Products/Release-iphoneos/Maer.app"
            mkdir -p "$app"
            # With the file keep-program the program is not linked again, as
            # Xcode does when no source changed; the stamp is written always,
            # with the head, or with another commit while stale-stamp exists.
            if [ ! -f "$LAUF_STUB_DIR/keep-program" ] || [ ! -f "$app/Maer" ]; then
                cat "$LAUF_STUB_DIR/release-symbols" 2>/dev/null > "$app/Maer" || echo "0000 T _main" > "$app/Maer"
            fi
            stamp="$(git rev-parse --short HEAD)"; [ -f "$LAUF_STUB_DIR/stale-stamp" ] && stamp=0000000
            plutil -create xml1 "$app/Info.plist"; plutil -insert GitSHA -string "$stamp" "$app/Info.plist"
        fi
        prev="$arg"
    done
    exit 0
fi
now() { python3 -c 'import time; print(int(time.time()*1000))'; }
echo "start $(now) $*" >> "$log"
echo "xcodebuild start $*" >> "$LAUF_STUB_DIR/order.log"
echo "nice $(ps -o nice= -p $$ | tr -d ' ')" >> "$log"
if [ -n "${MAER_SERVER_ACCESS_FILE:-}" ]; then echo "access set" >> "$log"; else echo "access unset" >> "$log"; fi
prev=""
for arg in "$@"; do
    if [ "$prev" = "-destination" ]; then
        udid="${arg#id=}"
        audio="$LAUF_SIM_DEVICES/$udid/data/var/run/com.apple.coresimulator.audio.plist"
        if [ "$(plutil -extract sim_output_device_uid raw "$audio" 2>/dev/null)" = "$LAUF_STILLES_GERAET" ]; then
            echo "silent yes $udid" >> "$log"; else echo "silent no $udid" >> "$log"; fi
    fi
    if [ "$prev" = "-resultBundlePath" ]; then mkdir -p "$arg"; echo data > "$arg/Info.plist"; fi
    if [ "$prev" = "-derivedDataPath" ]; then mkdir -p "$arg/Build"; fi
    prev="$arg"
done
# With the file stubborn the stub ignores TERM, as the real xcodebuild did
# while it ended its test session.
[ -f "$LAUF_STUB_DIR/stubborn" ] && trap '' TERM
sleep "${LAUF_STUB_SLEEP:-0}"
if [ -f "$LAUF_STUB_DIR/flaky" ]; then
    # A case that fails in four of its repetitions, two issues each, written
    # as the real xcodebuild writes a repeated run: a start line per
    # repetition, issue lines without a line of their own per failed
    # repetition, and a test run line that says passed.
    echo "◇ Test \"the row keeps four buttons\" started."
    for i in $(seq 2 300); do
        echo "◇ Test \"the row keeps four buttons\" started (repetition $i)."
        case $i in 7|50|51|299)
            echo "✘ Test \"the row keeps four buttons\" recorded an issue at RowTests.swift:12:5: Expectation failed: a"
            echo "✘ Test \"the row keeps four buttons\" recorded an issue at RowTests.swift:13:5: Expectation failed: b";;
        esac
    done
    echo "✔ Test run with 1 test in 1 suite passed after 9.0 seconds."
    echo "** TEST FAILED **"
    echo "end $(now) 65" >> "$log"
    exit 65
fi
if [ -f "$LAUF_STUB_DIR/red" ]; then
    echo "✘ Test \"the row keeps four buttons\" recorded an issue at RowTests.swift:12:5"
    echo "** TEST FAILED **"
    echo "end $(now) 65" >> "$log"
    exit 65
fi
echo "✔ Test run with 5 tests in 2 suites passed after 0.1 seconds."
echo "** TEST SUCCEEDED **"
echo "end $(now) 0" >> "$log"
exit 0
EOF
# simctl answers list with the run's own simulators and, while the file
# booted-foreign exists, one foreign booted device; with the file moved, the
# 18.6 simulator stands under another runtime. listapps names two bundles of
# the app and one of the system, less those uninstalled; with the file sticky
# the first uninstall of a bundle does not take (seen on iOS 18.6 right after
# the boot), with the file stuck none does; listapps fails while its file
# exists, as privacy and keychain do. Every call is logged.
cat > "$STUB/simctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$LAUF_STUB_DIR/simctl.log"
echo "simctl $*" >> "$LAUF_STUB_DIR/order.log"
case "$*" in
    bootstatus\ *) touch "$LAUF_STUB_DIR/booted-once"; echo "$2" >> "$LAUF_STUB_DIR/booted" ;;
    shutdown\ *) [ -f "$LAUF_STUB_DIR/booted" ] && { grep -vx "$2" "$LAUF_STUB_DIR/booted" > "$LAUF_STUB_DIR/booted.tmp"; mv "$LAUF_STUB_DIR/booted.tmp" "$LAUF_STUB_DIR/booted"; } ;;
    erase\ *) rm -rf "$LAUF_SIM_DEVICES/$2/data" ;;
    listapps\ *)
        [ -f "$LAUF_STUB_DIR/listapps-fails" ] && exit 1
        printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
        for id in fm.maer.app fm.maer.app.uitests.xctrunner com.apple.mobilesafari; do
            need=1; [ -f "$LAUF_STUB_DIR/sticky" ] && need=2; [ -f "$LAUF_STUB_DIR/stuck" ] && need=99
            [ "$(grep -cx "$id" "$LAUF_STUB_DIR/uninstalled.$2" 2>/dev/null)" -ge "$need" ] && continue
            printf '<key>%s</key><dict><key>CFBundleIdentifier</key><string>%s</string></dict>' "$id" "$id"
        done
        echo '</dict></plist>' ;;
    uninstall\ *) echo "$3" >> "$LAUF_STUB_DIR/uninstalled.$2" ;;
    privacy\ *) [ -f "$LAUF_STUB_DIR/privacy-fails" ] && exit 1 ;;
    keychain\ *) [ -f "$LAUF_STUB_DIR/keychain-fails" ] && exit 1 ;;
    *"list devices"*)
        r18=iOS-18-6; [ -f "$LAUF_STUB_DIR/moved" ] && r18=iOS-26-0
        state() { grep -qx "$1" "$LAUF_STUB_DIR/booted" 2>/dev/null && echo Booted || echo Shutdown; }
        s27="$(state AAAA2700-0000-0000-0000-000000000000)"; s18="$(state BBBB1860-0000-0000-0000-000000000000)"
        foreign=""
        if [ -f "$LAUF_STUB_DIR/booted-foreign" ]; then
            foreign=',{"name":"Fremder Sim","udid":"FFFF0000-0000-0000-0000-000000000000","state":"Booted"}'
        fi
        echo '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"name":"Maer-Abschluss-27","udid":"AAAA2700-0000-0000-0000-000000000000","state":"'"$s27"'"},{"name":"Maer-Test-Bau","udid":"C1F0240C-E988-41D2-9081-4CFF0B8EA34B","state":"Shutdown"}'"$foreign"'],"com.apple.CoreSimulator.SimRuntime.'"$r18"'":[{"name":"Maer-Abschluss-18","udid":"BBBB1860-0000-0000-0000-000000000000","state":"'"$s18"'"}]}}'
        ;;
esac
exit 0
EOF
# sysctl answers the load over one minute from the file load (default 0,50,
# quiet) and ten cores, with the decimal comma of the German locale as the
# real one prints it; every call is logged.
cat > "$STUB/sysctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$LAUF_STUB_DIR/sysctl.log"
echo "sysctl $*" >> "$LAUF_STUB_DIR/order.log"
# With the file load-after-boot the load is high once a simulator booted.
if [ -f "$LAUF_STUB_DIR/load-after-boot" ] && [ -f "$LAUF_STUB_DIR/booted-once" ]; then
    case "$*" in *vm.loadavg*) echo "{ 30,00 20,00 10,00 }"; exit 0;; esac
fi
case "$*" in
    *vm.loadavg*) echo "{ $(cat "$LAUF_STUB_DIR/load" 2>/dev/null || echo 0,50) 0,40 0,30 }" ;;
    *hw.ncpu*) echo 10 ;;
esac
EOF
# nm and the demangler read the program as text: a stub program is its own
# list of symbols.
printf '#!/bin/bash\nfor a in "$@"; do [ -f "$a" ] && grep -E "^[0-9a-f]+ [A-Za-z-] " "$a"; done; exit 0\n' > "$STUB/nm"
# strings reads every line of the program: a stripped program keeps the
# names of its fields as text, not as symbols.
printf '#!/bin/bash\nfor a in "$@"; do [ -f "$a" ] && cat "$a"; done; exit 0\n' > "$STUB/strings"
printf '#!/bin/bash\ncat\n' > "$STUB/demangle"
chmod +x "$STUB/xcodebuild" "$STUB/simctl" "$STUB/sysctl" "$STUB/nm" "$STUB/demangle" "$STUB/strings"
export LAUF_NM="$STUB/nm" LAUF_DEMANGLE="$STUB/demangle" LAUF_STRINGS="$STUB/strings"
export LAUF_XCODEBUILD="$STUB/xcodebuild" LAUF_SIMCTL="$STUB/simctl" LAUF_SYSCTL="$STUB/sysctl" LAUF_STUB_DIR="$STUB"
export LAUF_ABLAGE="$DEV/ablage" LAUF_BAU="$DEV/bau" LAUF_TEMP_ROOTS="$TEMP/" LAUF_MIN_GB=0
export LAUF_WARTE_S=4 LAUF_TICK_S=1
export LAUF_SIM_DEVICES="$DEV/devices" LAUF_STILLES_GERAET=Witness_Silent_UID
export LAUF_ARCHIVE="$DEV/archives"
# The copied hooks read the list of names from the fence of the real tree.
export MAER_ROLE_FENCE="$REAL/MaerTests/PublicReadmeFenceTests.swift"
unset LAUF_PUSH
clear_stub() { rm -f "$STUB/xcodebuild.log" "$STUB/simctl.log" "$STUB/sysctl.log" "$STUB/red" "$STUB/booted-foreign" "$STUB/load" \
    "$STUB/order.log" "$STUB/booted-once" "$STUB/booted" "$STUB/load-after-boot" "$STUB/release-symbols" "$STUB/keep-program" "$STUB/stale-stamp" "$STUB/moved" "$STUB/privacy-fails" "$STUB/keychain-fails" "$STUB/sticky" "$STUB/stuck" "$STUB/listapps-fails" "$STUB"/uninstalled.*; }
# A simulator the script has not seen: its mark is gone, the next final run erases it.
forget_marks() { rm -f "$DEV"/bau/*/stand; }

# The throwaway repository: a few sources, their tests, a fence, a document
# suite, a measurement, documents and a project file, and the scripts of this
# tree with lists of its own.
git init -q --bare "$WORK/origin.git"
git init -q --bare "$WORK/codeberg.git"
git init -q -b dev "$REPO"
cd "$REPO" || exit 2
git config user.name lzs
git config user.email 352619651+maer-lzs@users.noreply.github.com
mkdir -p Sources/Models Sources/Views MaerTests docs Maer.xcodeproj scripts
cp -R "$REAL/scripts/." scripts/
printf 'enum PlaybackSkip {}\n' > Sources/Models/PlaybackSkip.swift
printf 'struct Lonely {}\n' > Sources/Models/Lonely.swift
printf 'struct Gone {}\n' > Sources/Models/Gone.swift
printf 'struct RowView {}\n' > Sources/Views/RowView.swift
printf 'struct PlaybackSkipTests { let s = PlaybackSkip.self }\n' > MaerTests/PlaybackSkipTests.swift
printf 'struct PlayerToolsTests { let s = PlaybackSkip.self }\n' > MaerTests/PlayerToolsTests.swift
printf 'struct SoundCurveTests {}\n' > MaerTests/SoundCurveTests.swift
printf 'struct RowViewTests { let v = RowView.self }\n' > MaerTests/RowViewTests.swift
printf 'struct GoneTests { let g = Gone.self }\n' > MaerTests/GoneTests.swift
printf 'struct FenceTests {}\n' > MaerTests/FenceTests.swift
printf 'struct DocsTests {}\n' > MaerTests/DocsTests.swift
printf 'struct MeasureTests {}\n' > MaerTests/MeasureTests.swift
printf 'base\n' > docs/a.md
printf 'readme\n' > README.md
printf '// project\n' > Maer.xcodeproj/project.pbxproj
mkdir -p scripts/lauf
printf '# fences, one test file per line\nFenceTests\n' > scripts/lauf/zaeune.txt
printf '# measurements, only in the full run\nMeasureTests\n' > scripts/lauf/nur-voll.txt
printf '# path prefix, test files, reason\ndocs/ DocsTests # the document suite reads the documents\nREADME.md DocsTests # the document suite reads the readme\n' > scripts/lauf/karte.txt
echo "witness repository of the run script" > .wegwerf
git add -A && git commit -q --no-verify -m "Base of the witness repository"
git remote add origin "$WORK/origin.git"
git remote add codeberg "$WORK/codeberg.git"
git push -q origin dev dev:main 2>/dev/null
git config core.hooksPath "$REPO/scripts/hooks"
BASE="$(git rev-parse HEAD)"

plan() { bash scripts/lauf.sh auswahl --basis "$BASE" --nur-zeigen 2>&1; }
change() { printf '%s\n' "$2" >> "$1"; git add -A; git commit -q --no-verify -m "$3"; }
reset_base() { git reset -q --hard "$BASE"; }
has() { echo "$1" | grep -qxF -- "$2"; }

# 1. A source file selects every test file naming one of its types, and the fences.
change Sources/Models/PlaybackSkip.swift "extension PlaybackSkip {}" "Change the skip"
out="$(plan)"
if has "$out" "datei PlaybackSkipTests" && has "$out" "datei PlayerToolsTests" && has "$out" "datei FenceTests" \
    && ! has "$out" "datei MeasureTests" && ! has "$out" "datei SoundCurveTests"; then ok "1 a source file selects its tests and the fences"; else fail "1 a source file selects its tests and the fences" "$out"; fi
reset_base

# 2. A test file alone selects itself and the fences, nothing else.
change MaerTests/SoundCurveTests.swift "// one more" "Change a test"
out="$(plan)"
if has "$out" "datei SoundCurveTests" && has "$out" "datei FenceTests" && [ "$(echo "$out" | grep -c '^datei ')" = 2 ]; then
    ok "2 a test file selects itself and the fences"; else fail "2 a test file selects itself and the fences" "$out"; fi
reset_base

# 3. Documents select the document suites and the fences.
change docs/a.md "more" "Change a document"
out="$(plan)"
if has "$out" "datei DocsTests" && has "$out" "datei FenceTests" && [ "$(echo "$out" | grep -c '^datei ')" = 2 ]; then
    ok "3 documents select the document suites"; else fail "3 documents select the document suites" "$out"; fi
reset_base

# 4. A source file no test names selects the fences and says so in a line.
change Sources/Models/Lonely.swift "extension Lonely {}" "Change a lonely type"
out="$(plan)"
if has "$out" "datei FenceTests" && echo "$out" | grep -q "keine eigene Suite getroffen: Sources/Models/Lonely.swift"; then
    ok "4 an untested source says so"; else fail "4 an untested source says so" "$out"; fi
reset_base

# 5. A map line without a reason, or naming a suite that does not exist, stops the selection.
cp scripts/lauf/karte.txt "$WORK/karte.bak"
printf 'docs/ DocsTests\n' >> scripts/lauf/karte.txt
git add -A && git commit -q --no-verify -m "Map line without reason"
out="$(plan)"; rc=$?
reset_base
printf 'docs/ NoSuchTests # a suite that is not there\n' >> scripts/lauf/karte.txt
git add -A && git commit -q --no-verify -m "Map line with an unknown suite"
out2="$(plan)"; rc2=$?
reset_base
if [ $rc -ne 0 ] && [ $rc2 -ne 0 ] && echo "$out2" | grep -q "NoSuchTests"; then
    ok "5 a map line without reason or with an unknown suite stops"; else fail "5 a map line without reason or with an unknown suite stops" "$out / $out2"; fi

# 6. History: for ten commits of this week the selection of the whole commit
# chooses at least the test files the commit itself changed.
# 6b. The source part of each commit alone chooses them as well, except a
# test file whose change is formatting only (equal once every space and line
# break is removed): only the rule for a changed test file reaches that one.
missing=""; missing_source=""
squeeze() { git -C "$REAL" show "$1" 2>/dev/null | tr -d ' \t\n'; }
while read -r commit expected; do
    case "$commit" in ''|'#'*) continue;; esac
    got="$(cd "$REAL" && python3 -I scripts/lauf/auswahl.py --basis "$commit^" --kopf "$commit" 2>&1)"
    from_source="$(cd "$REAL" && python3 -I scripts/lauf/auswahl.py --basis "$commit^" --kopf "$commit" --nur Sources/ 2>&1)"
    for file in $expected; do
        has "$got" "datei $file" || missing="$missing $commit:$file"
        [ "$(squeeze "$commit^:MaerTests/$file.swift")" = "$(squeeze "$commit:MaerTests/$file.swift")" ] && continue
        has "$from_source" "datei $file" || missing_source="$missing_source $commit:$file"
    done
done < "$REAL/scripts/lauf/geschichte.txt"
if [ -z "$missing" ] && [ -s "$REAL/scripts/lauf/geschichte.txt" ]; then ok "6 ten commits of this week select their suites"; else fail "6 ten commits of this week select their suites" "missing:$missing"; fi
if [ -z "$missing_source" ]; then ok "6b their source part alone selects them, formatting aside"; else fail "6b their source part alone selects them, formatting aside" "missing:$missing_source"; fi

# 7. The measurements stay out of the selection and run in the full run.
change Sources/Models/PlaybackSkip.swift "extension PlaybackSkip { }" "Change the skip again"
out="$(plan)"
full="$(bash scripts/lauf.sh voll --nur-zeigen 2>&1)"
if ! has "$out" "datei MeasureTests" && has "$full" "datei MeasureTests"; then ok "7 measurements only in the full run"; else fail "7 measurements only in the full run" "$out / $full"; fi
reset_base

# 8. A view, the catalog, the assets or the widgets plan the journeys.
uiplans=0
for path in Sources/Views/RowView.swift Sources/Localizable.xcstrings Assets.xcassets/Contents.json MaerWidgets/Line.swift; do
    mkdir -p "$(dirname "$path")"; change "$path" "// ui" "Change $path"
    plan | grep -qx "ui: ja" && uiplans=$((uiplans + 1))
    reset_base
done
if [ $uiplans = 4 ]; then ok "8 views, catalog, assets and widgets plan the journeys"; else fail "8 views, catalog, assets and widgets plan the journeys" "$uiplans of 4"; fi

# 9. A model alone plans no journeys and says it in exactly one line.
change Sources/Models/PlaybackSkip.swift "// model" "Change a model"
out="$(plan)"
if [ "$(echo "$out" | grep -c 'keine UI-Tests: kein Pfad der Liste beruehrt')" = 1 ] && ! has "$out" "ui: ja"; then
    ok "9 no journeys without a ui path, in one line"; else fail "9 no journeys without a ui path, in one line" "$out"; fi
reset_base

# 10. Too little space: every kind stops before xcodebuild and names free and needed.
clear_stub
refused=0
for kind in auswahl voll abschluss; do
    out="$(LAUF_MIN_GB=999999 bash scripts/lauf.sh $kind 2>&1)"; rc=$?
    [ $rc -ne 0 ] && echo "$out" | grep -q "frei" && echo "$out" | grep -q "verlangt" && refused=$((refused + 1))
done
if [ $refused = 3 ] && [ ! -s "$STUB/xcodebuild.log" ]; then ok "10 too little space stops every kind before the build"; else fail "10 too little space stops every kind before the build" "$refused of 3"; fi

# 11. After a green run the store of the run is gone, the build state stays.
clear_stub
change Sources/Models/PlaybackSkip.swift "// green" "A green run"
bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ -z "$(ls -A "$LAUF_ABLAGE" 2>/dev/null)" ] && [ -n "$(ls -A "$LAUF_BAU" 2>/dev/null)" ]; then
    ok "11 green run: the store is gone, the build stays"; else fail "11 green run: the store is gone, the build stays" "rc=$rc store=$(ls -A "$LAUF_ABLAGE" 2>/dev/null) bau=$(ls -A "$LAUF_BAU" 2>/dev/null)"; fi

# 12. After an aborted run the store is gone as well.
clear_stub
LAUF_STUB_SLEEP=20 bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 50); do grep -q '^start' "$STUB/xcodebuild.log" 2>/dev/null && break; sleep 0.2; done
kill -TERM $pid 2>/dev/null; wait $pid 2>/dev/null
sleep 1
if grep -q '^start' "$STUB/xcodebuild.log" 2>/dev/null && [ -z "$(ls -A "$LAUF_ABLAGE" 2>/dev/null)" ]; then
    ok "12 aborted run: the store is gone"; else fail "12 aborted run: the store is gone" "$(ls -A "$LAUF_ABLAGE" 2>/dev/null)"; fi
pkill -f "$STUB/xcodebuild" 2>/dev/null

# 13. After a red run the store of the run is gone, only the kept log of the
# red run stays, and the red cases stand in the output.
clear_stub; touch "$STUB/red"
out="$(bash scripts/lauf.sh auswahl --basis "$BASE" 2>&1)"; rc=$?
left="$(ls -A "$LAUF_ABLAGE" 2>/dev/null | grep -v '^rot-.*\.log$')"
rm -f "$LAUF_ABLAGE"/rot-*.log
if [ $rc -ne 0 ] && echo "$out" | grep -q "the row keeps four buttons" && [ -z "$left" ]; then
    ok "13 red run: the store is gone, the red cases are named"; else fail "13 red run: the store is gone, the red cases are named" "$out"; fi
reset_base

# 14. A dirty tree is refused by the final run, without a run.
clear_stub
echo "open" > open.txt
out="$(bash scripts/lauf.sh abschluss 2>&1)"; rc=$?
rm -f open.txt
if [ $rc -ne 0 ] && [ ! -s "$STUB/xcodebuild.log" ] && echo "$out" | grep -q "open.txt"; then ok "14 final run refuses a dirty tree"; else fail "14 final run refuses a dirty tree" "$out"; fi

# 15. A tree under a temporary path is refused, even with the throwaway mark.
clear_stub
git worktree add -q "$TEMP/wt" -b temp-tree
out="$(cd "$TEMP/wt" && bash scripts/lauf.sh abschluss 2>&1)"; rc=$?
git worktree remove --force "$TEMP/wt"; git branch -q -D temp-tree
if [ $rc -ne 0 ] && [ ! -s "$STUB/xcodebuild.log" ] && echo "$out" | grep -q "$TEMP/wt"; then ok "15 final run refuses a temporary tree"; else fail "15 final run refuses a temporary tree" "$out"; fi

# 16. Green writes the note at the head; red writes nothing, pushes nothing, moves nothing.
# The slice begins with its witness, red at the selection (R8).
git checkout -q -b scheibe
change MaerTests/PlaybackSkipTests.swift "// the witness of the slice" "The witness of the slice"
clear_stub; touch "$STUB/red"; bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1
change Sources/Models/PlaybackSkip.swift "// slice" "A change of the slice"
clear_stub; forget_marks; touch "$STUB/red"
before="$(git for-each-ref --format='%(refname) %(objectname)' | sort)"
remote_before="$(git ls-remote origin | sort)"
bash scripts/lauf.sh abschluss >/dev/null 2>&1; rc=$?
red_note="$(git notes --ref=lauf show HEAD 2>/dev/null)"
after="$(git for-each-ref --format='%(refname) %(objectname)' | sort)"
remote_after="$(git ls-remote origin | sort)"
clear_stub; forget_marks
bash scripts/lauf.sh abschluss >/dev/null 2>&1; rc2=$?
green_note="$(git notes --ref=lauf show HEAD 2>/dev/null)"
if [ $rc -ne 0 ] && [ -z "$red_note" ] && [ "$before" = "$after" ] && [ "$remote_before" = "$remote_after" ] \
    && [ $rc2 = 0 ] && echo "$green_note" | grep -q "art=abschluss" && echo "$green_note" | grep -q "ergebnis=gruen"; then
    ok "16 green writes the note, red moves nothing"; else fail "16 green writes the note, red moves nothing" "rc=$rc rc2=$rc2 note=$green_note"; fi

# 17. The final run uses its own throwaway simulator, erased first, with nice and without access.
if grep -q "erase AAAA2700" "$STUB/simctl.log" && grep -q "id=AAAA2700" "$STUB/xcodebuild.log" \
    && grep -q "^nice [1-9]" "$STUB/xcodebuild.log" && ! grep -q "access set" "$STUB/xcodebuild.log" \
    && ! grep -q "C1F0240C" "$STUB/xcodebuild.log"; then
    ok "17 own erased simulator, nice, no access"; else fail "17 own erased simulator, nice, no access" "$(cat "$STUB/xcodebuild.log" "$STUB/simctl.log" 2>/dev/null)"; fi
export MAER_SERVER_ACCESS_FILE="$WORK/access"; clear_stub
bash scripts/lauf.sh abschluss >/dev/null 2>&1
if grep -q "access unset" "$STUB/xcodebuild.log" 2>/dev/null && ! grep -q "access set" "$STUB/xcodebuild.log"; then
    ok "17b an access file in the environment does not reach the final run"; else fail "17b an access file in the environment does not reach the final run"; fi
unset MAER_SERVER_ACCESS_FILE

# 18. A foreign booted simulator makes the run wait; it starts once the foreign one is off,
# and stops with its name when it stays on.
clear_stub; touch "$STUB/booted-foreign"
( sleep 2; rm -f "$STUB/booted-foreign" ) &
bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1; rc=$?
waited=$rc
clear_stub; touch "$STUB/booted-foreign"
out="$(LAUF_WARTE_S=2 bash scripts/lauf.sh auswahl --basis "$BASE" 2>&1)"; rc=$?
rm -f "$STUB/booted-foreign"
if [ $waited = 0 ] && [ $rc -ne 0 ] && echo "$out" | grep -q "Fremder Sim" && [ ! -s "$STUB/xcodebuild.log" ]; then
    ok "18 a foreign simulator: wait, then start or stop with its name"; else fail "18 a foreign simulator: wait, then start or stop with its name" "waited=$waited $out"; fi

# 19. Every run without parallel testing, and the clones deleted afterwards.
clear_stub
bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1
if grep -q -- "-parallel-testing-enabled NO" "$STUB/xcodebuild.log" && grep -q "XCTestDevices delete all" "$STUB/simctl.log"; then
    ok "19 no parallel testing, clones deleted"; else fail "19 no parallel testing, clones deleted" "$(cat "$STUB/xcodebuild.log" "$STUB/simctl.log")"; fi

# The head of the slice carries a green final note from case 16.
# 20. A bare git push is refused and the message names the command.
out="$(git push origin HEAD:refs/heads/scheibe 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "scripts/lauf.sh push" && [ -z "$(git ls-remote origin refs/heads/scheibe)" ]; then
    ok "20 a bare push is refused"; else fail "20 a bare push is refused" "$out"; fi

# 21. push zweig without the note of a full run is refused, with it it passes.
git checkout -q -b ohne-vermerk
change Sources/Models/PlaybackSkip.swift "// no note" "A change without a run"
out="$(bash scripts/lauf.sh push zweig 2>&1)"; rc=$?
git checkout -q scheibe
out2="$(bash scripts/lauf.sh push zweig 2>&1)"; rc2=$?
if [ $rc -ne 0 ] && [ -z "$(git ls-remote origin refs/heads/ohne-vermerk)" ] && [ $rc2 = 0 ] \
    && [ "$(git ls-remote origin refs/heads/scheibe | cut -f1)" = "$(git rev-parse HEAD)" ] && git ls-remote origin | grep -q "refs/notes/lauf"; then
    ok "21 push zweig needs the note of a full run"; else fail "21 push zweig needs the note of a full run" "$out / $out2"; fi

# 22. push dev without the note at the commit is refused.
git checkout -q ohne-vermerk
out="$(bash scripts/lauf.sh push dev 2>&1)"; rc=$?
if [ $rc -ne 0 ] && [ "$(git ls-remote origin refs/heads/dev | cut -f1)" = "$BASE" ] && echo "$out" | grep -q "Vermerk"; then ok "22 push dev needs the note"; else fail "22 push dev needs the note" "$out"; fi

# 23. push dev that is no fast forward is refused.
git checkout -q -b quer "$BASE"
git commit -q --no-verify --allow-empty -m "Elsewhere on dev"
# Setup only: another history on dev, pushed past the hooks.
git -c core.hooksPath=/dev/null push -q origin HEAD:refs/heads/dev 2>/dev/null
git checkout -q scheibe
out="$(bash scripts/lauf.sh push dev 2>&1)"; rc=$?
if [ $rc -ne 0 ] && [ "$(git ls-remote origin refs/heads/dev | cut -f1)" = "$(git rev-parse quer)" ] && echo "$out" | grep -q "Vorspulen"; then
    ok "23 push dev that is no fast forward is refused"; else fail "23 push dev that is no fast forward is refused" "$out"; fi

# 24. push nachzug needs a note of the selection, push doku the note of the document suites.
git checkout -q -b nachzug-text scheibe
change Sources/Models/PlaybackSkip.swift "// text" "A text after the review"
out="$(bash scripts/lauf.sh push nachzug 2>&1)"; rc=$?
clear_stub; bash scripts/lauf.sh auswahl >/dev/null 2>&1
out2="$(bash scripts/lauf.sh push nachzug 2>&1)"; rc2=$?
git checkout -q -b doku-text scheibe
change docs/a.md "a line" "A line in the documents"
out3="$(bash scripts/lauf.sh push doku 2>&1)"; rc3=$?
clear_stub; bash scripts/lauf.sh auswahl >/dev/null 2>&1
out4="$(bash scripts/lauf.sh push doku 2>&1)"; rc4=$?
if [ $rc -ne 0 ] && [ $rc2 = 0 ] && [ $rc3 -ne 0 ] && [ $rc4 = 0 ]; then ok "24 nachzug and doku need their notes"; else fail "24 nachzug and doku need their notes" "$rc $rc2 $rc3 $rc4: $out / $out3"; fi

# 25. A commit of the slice whose message breaks the rules stops the push and is named.
git checkout -q -b regelbruch scheibe
change Sources/Models/PlaybackSkip.swift "// rule" "The $(python3 -I "$REAL/scripts/hooks/rules.py" rolle) session adds a line"
bad="$(git rev-parse --short HEAD)"
clear_stub; bash scripts/lauf.sh abschluss >/dev/null 2>&1
out="$(bash scripts/lauf.sh push zweig 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "$bad" && [ -z "$(git ls-remote origin refs/heads/regelbruch)" ]; then
    ok "25 a commit against the rules stops the push"; else fail "25 a commit against the rules stops the push" "$out"; fi

# 26. main, a tag and another remote are refused, also through the command.
git checkout -q scheibe
git tag -a v0 -m "A tag" 2>/dev/null
o1="$(LAUF_PUSH=1 git push origin HEAD:refs/heads/main 2>&1)"; r1=$?
o2="$(LAUF_PUSH=1 git push origin v0 2>&1)"; r2=$?
o3="$(LAUF_PUSH=1 git push codeberg HEAD:refs/heads/scheibe 2>&1)"; r3=$?
if [ $r1 -ne 0 ] && [ $r2 -ne 0 ] && [ $r3 -ne 0 ] && [ "$(git ls-remote origin refs/heads/main | cut -f1)" = "$BASE" ] \
    && [ -z "$(git ls-remote origin refs/tags/v0)" ] && [ -z "$(git ls-remote codeberg)" ]; then
    ok "26 main, tags and other remotes are refused"; else fail "26 main, tags and other remotes are refused" "$o1 / $o2 / $o3"; fi

# 27. A build file selects the full run.
reset_full=0
for path in Maer.xcodeproj/project.pbxproj Package.resolved Config/App.xcconfig Maer-Info.plist Maer.entitlements; do
    git checkout -q -B bau "$BASE"; mkdir -p "$(dirname "$path")"; change "$path" "// build" "Change $path"
    plan | grep -qx "voll" && reset_full=$((reset_full + 1))
done
git checkout -q scheibe
if [ $reset_full = 5 ]; then ok "27 build files select the full run"; else fail "27 build files select the full run" "$reset_full of 5"; fi

# 28. A deleted or renamed source file selects the tests naming its types at the base.
git checkout -q -B weg "$BASE"
git rm -q Sources/Models/Gone.swift && git commit -q --no-verify -m "Drop a type"
out="$(plan)"
git checkout -q -B umbenannt "$BASE"
git mv Sources/Models/Gone.swift Sources/Models/Went.swift && git commit -q --no-verify -m "Rename a file"
out2="$(plan)"
git checkout -q scheibe
if has "$out" "datei GoneTests" && has "$out2" "datei GoneTests"; then ok "28 deleted and renamed files select at the base"; else fail "28 deleted and renamed files select at the base" "$out / $out2"; fi

# 29. The final run runs on 27 and then on 18.6, never at once, and the note names both;
# a note with one runtime does not carry push zweig.
clear_stub
bash scripts/lauf.sh abschluss >/dev/null 2>&1
starts="$(grep '^start' "$STUB/xcodebuild.log")"
first_end="$(grep '^end' "$STUB/xcodebuild.log" | head -1 | cut -d' ' -f2)"
second_start="$(echo "$starts" | sed -n 2p | cut -d' ' -f2)"
note="$(git notes --ref=lauf show HEAD 2>/dev/null)"
git checkout -q -B eine-laufzeit scheibe
change Sources/Models/PlaybackSkip.swift "// one runtime" "A change with one runtime"
git notes --ref=lauf add -f -m "lauf art=abschluss laufzeiten=27 ergebnis=gruen baum=$(git rev-parse HEAD^{tree})" HEAD
out="$(bash scripts/lauf.sh push zweig 2>&1)"; rc=$?
git checkout -q scheibe
if [ "$(echo "$starts" | wc -l | tr -d ' ')" = 2 ] && echo "$starts" | head -1 | grep -q "AAAA2700" && echo "$starts" | sed -n 2p | grep -q "BBBB1860" \
    && [ "$second_start" -ge "$first_end" ] && echo "$note" | grep -q "laufzeiten=27,18.6" && [ $rc -ne 0 ]; then
    ok "29 final run on 27 then 18.6, one runtime is not enough"; else fail "29 final run on 27 then 18.6, one runtime is not enough" "$starts / $note / $out"; fi

# 30. The note holds only while the head has not moved on: a later commit, or a note
# copied onto a commit with other content, does not carry the push.
git checkout -q -B weiter scheibe
change Sources/Models/PlaybackSkip.swift "// later" "A commit after the run"
out="$(bash scripts/lauf.sh push zweig 2>&1)"; rc=$?
git notes --ref=lauf add -f -m "lauf art=abschluss laufzeiten=27,18.6 ergebnis=gruen baum=$(git rev-parse scheibe^{tree})" HEAD
out2="$(bash scripts/lauf.sh push zweig 2>&1)"; rc2=$?
git checkout -q scheibe
if [ $rc -ne 0 ] && [ $rc2 -ne 0 ] && [ -z "$(git ls-remote origin refs/heads/weiter)" ] \
    && echo "$out" | grep -q "Vermerk" && echo "$out2" | grep -q "Inhalt"; then
    ok "30 the note is bound to the content of the head"; else fail "30 the note is bound to the content of the head" "$out / $out2"; fi

# 31. No rewriting on any branch: --force, --force-with-lease and a push that is no
# fast forward are refused, also through the command.
git checkout -q -B scheibe-neu "$BASE"
change Sources/Models/PlaybackSkip.swift "// other" "Another history"
o1="$(LAUF_PUSH=1 git push --force origin HEAD:refs/heads/scheibe 2>&1)"; r1=$?
o2="$(LAUF_PUSH=1 git push --force-with-lease origin HEAD:refs/heads/scheibe 2>&1)"; r2=$?
o3="$(bash scripts/lauf.sh push zweig --force 2>&1)"; r3=$?
git checkout -q scheibe
if [ $r1 -ne 0 ] && [ $r2 -ne 0 ] && [ $r3 -ne 0 ] && [ "$(git ls-remote origin refs/heads/scheibe | cut -f1)" = "$(git rev-parse scheibe)" ]; then
    ok "31 no rewriting on any branch"; else fail "31 no rewriting on any branch" "$o1 / $o2 / $o3"; fi

# 32. A change only at a brace or at whitespace still selects: a test file
# selects itself, a source file the tests naming its types.
git checkout -q -B klammer "$BASE"
printf 'struct SoundCurveTests {\n}\n' > MaerTests/SoundCurveTests.swift
printf 'enum PlaybackSkip {\n}\n' > Sources/Models/PlaybackSkip.swift
git add -A && git commit -q --no-verify -m "Move two braces"
out="$(plan)"
git checkout -q scheibe
if has "$out" "datei SoundCurveTests" && has "$out" "datei PlaybackSkipTests"; then
    ok "32 a brace or whitespace alone still selects"; else fail "32 a brace or whitespace alone still selects" "$out"; fi

# 33. Every simulator of a run sends its sound and microphone to the silent
# device, and the final run writes that after the erase, which clears it.
clear_stub; rm -rf "$LAUF_SIM_DEVICES"; forget_marks
bash scripts/lauf.sh abschluss >/dev/null 2>&1
quiet=0
for udid in AAAA2700-0000-0000-0000-000000000000 BBBB1860-0000-0000-0000-000000000000; do
    f="$LAUF_SIM_DEVICES/$udid/data/var/run/com.apple.coresimulator.audio.plist"
    [ -f "$f" ] && [ "$(plutil -extract sim_output_device_uid raw "$f" 2>/dev/null)" = "$LAUF_STILLES_GERAET" ] \
        && [ "$(plutil -extract sim_input_device_uid raw "$f" 2>/dev/null)" = "$LAUF_STILLES_GERAET" ] \
        && [ "$(plutil -extract useHostDefaultOutputDevice raw "$f" 2>/dev/null)" = false ] && quiet=$((quiet + 1))
done
# The erase of the stub clears the data of the device, as the real one does;
# xcodebuild notes at its start whether the device it runs on is silent.
if [ $quiet = 2 ] && [ "$(grep -c '^silent yes' "$STUB/xcodebuild.log")" = 2 ] && ! grep -q '^silent no' "$STUB/xcodebuild.log"; then
    ok "33 the simulators are silent, written after the erase"; else fail "33 the simulators are silent, written after the erase" "quiet=$quiet $(grep '^silent' "$STUB/xcodebuild.log" 2>/dev/null)"; fi
clear_stub
bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1
if grep -q '^silent yes' "$STUB/xcodebuild.log"; then ok "33b the selection runs on a silent simulator as well"; else fail "33b the selection runs on a silent simulator as well" "$(grep '^silent' "$STUB/xcodebuild.log")"; fi

# The lowering of the simulator. A stand-in for launchd_sim of one udid is a
# process named like it with two children; nice is read from the processes.
FAKES=""
fake_sim() {
    bash -c 'exec -a "launchd_sim /devices/'"$1"'/data/var/run/launchd_bootstrap.plist" bash -c "sleep 120 & sleep 120 & wait"' >/dev/null 2>&1 &
    local pid=$!
    FAKES="$FAKES $pid"
    sleep 0.3
    echo "$pid"
}
tree_of() { echo "$1"; pgrep -P "$1"; }
nice_of() { ps -o ni= -p "$1" 2>/dev/null | tr -d ' '; }
all_at() {
    local want="$1" p; shift
    for p in "$@"; do [ "$(nice_of "$p")" = "$want" ] || return 1; done
}
end_fakes() {
    local p
    for p in $FAKES; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    FAKES=""
}
trap 'end_fakes; rm -rf "$WORK"' EXIT
WORK_SIM=C1F0240C-E988-41D2-9081-4CFF0B8EA34B
SIM27=AAAA2700-0000-0000-0000-000000000000
SIM18=BBBB1860-0000-0000-0000-000000000000

# 34. While a selection runs, launchd_sim of its udid and its children go to nice 10, as xcodebuild.
clear_stub
sim="$(fake_sim "$WORK_SIM")"; FAKES="$FAKES $sim"; procs="$(tree_of "$sim")"
LAUF_STUB_SLEEP=3 bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1
if [ "$(echo "$procs" | wc -l | tr -d ' ')" = 3 ] && all_at 10 $procs; then
    ok "34 the simulator of the run is lowered to nice 10"; else fail "34 the simulator of the run is lowered to nice 10" "$(for p in $procs; do echo "$p $(nice_of "$p")"; done)"; fi
end_fakes

# 35. The final run lowers both of its simulators.
clear_stub
a="$(fake_sim "$SIM27")"; b="$(fake_sim "$SIM18")"; FAKES="$FAKES $a $b"
procs="$(tree_of "$a"; tree_of "$b")"
LAUF_STUB_SLEEP=3 bash scripts/lauf.sh abschluss >/dev/null 2>&1
if all_at 10 $procs; then ok "35 the final run lowers both simulators"; else fail "35 the final run lowers both simulators" "$(for p in $procs; do echo "$p $(nice_of "$p")"; done)"; fi
end_fakes

# 36. A simulator that boots after the start is lowered at the next tick.
clear_stub; rm -f "$WORK/late"
( sleep 1; fake_sim "$WORK_SIM" > "$WORK/late" ) &
LAUF_STUB_SLEEP=4 bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1
late="$(cat "$WORK/late" 2>/dev/null)"; FAKES="$FAKES $late"
if [ -n "$late" ] && all_at 10 $(tree_of "$late"); then
    ok "36 a simulator booting late is lowered"; else fail "36 a simulator booting late is lowered" "late=$late $(nice_of "$late")"; fi
end_fakes

# 37. Only the run's own udid: launchd_sim of another udid keeps its nice.
clear_stub
own="$(fake_sim "$WORK_SIM")"; other="$(fake_sim FFFF0000-0000-0000-0000-000000000000)"; FAKES="$FAKES $own $other"
before="$(nice_of "$other")"
LAUF_STUB_SLEEP=3 bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1
if [ "$(nice_of "$own")" = 10 ] && all_at "$before" $(tree_of "$other"); then
    ok "37 a simulator of another udid stays"; else fail "37 a simulator of another udid stays" "own=$(nice_of "$own") other=$(nice_of "$other") before=$before"; fi
end_fakes

# 38. After the run, green, red or ended by TERM, no lowering goes on: a
# simulator booting afterwards keeps its nice.
after_run() {
    local late p before
    late="$(fake_sim "$WORK_SIM")"; FAKES="$FAKES $late"; before="$(nice_of "$late")"
    sleep 3
    for p in $(tree_of "$late"); do [ "$(nice_of "$p")" = "$before" ] || return 1; done
    return 0
}
clear_stub
LAUF_STUB_SLEEP=1 bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1
green_ok=0; after_run && green_ok=1; end_fakes
clear_stub; touch "$STUB/red"
LAUF_STUB_SLEEP=1 bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1
red_ok=0; after_run && red_ok=1; end_fakes
clear_stub
LAUF_STUB_SLEEP=5 bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1 &
run=$!; sleep 2; kill -TERM "$run"; wait "$run" 2>/dev/null
term_ok=0; after_run && term_ok=1; end_fakes
if [ $green_ok = 1 ] && [ $red_ok = 1 ] && [ $term_ok = 1 ]; then
    ok "38 no lowering after the run, green, red or ended"; else fail "38 no lowering after the run, green, red or ended" "green=$green_ok red=$red_ok term=$term_ok"; fi

# 39. The lowering never raises and touches nothing outside the tree of
# launchd_sim of that udid: a child already at 20 stays at 20, the window of
# the simulator and xcodebuild keep theirs.
clear_stub
sim="$(fake_sim "$WORK_SIM")"; FAKES="$FAKES $sim"; kid="$(pgrep -P "$sim" | head -1)"; renice 20 -p "$kid" >/dev/null
bash -c 'exec -a "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator" sleep 120' >/dev/null 2>&1 &
window=$!; disown "$window"; FAKES="$FAKES $window"; sleep 0.3
window_before="$(nice_of "$window")"
LAUF_STUB_SLEEP=3 bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1
if [ "$(nice_of "$kid")" = 20 ] && [ "$(nice_of "$sim")" = 10 ] && [ "$(nice_of "$window")" = "$window_before" ] \
    && ! grep -qE "^nice (19|20)$" "$STUB/xcodebuild.log"; then
    ok "39 never raises, nothing outside the tree"; else fail "39 never raises, nothing outside the tree" "kid=$(nice_of "$kid") sim=$(nice_of "$sim") window=$(nice_of "$window")/$window_before $(grep '^nice' "$STUB/xcodebuild.log")"; fi
end_fakes

# 40. The full run and the final run start only while the load over one minute
# stands below the number of cores; they wait, with a limit, and stop with the
# load measured. The load at the start and at the end stands in the note. The
# selection does not wait for the load.
clear_stub; echo 30,00 > "$STUB/load"
out_full="$(LAUF_WARTE_S=2 bash scripts/lauf.sh voll 2>&1)"; rc_full=$?
full_ran=0; [ -s "$STUB/xcodebuild.log" ] && full_ran=1
clear_stub; echo 30,00 > "$STUB/load"
git notes --ref=lauf remove HEAD >/dev/null 2>&1
out_final="$(LAUF_WARTE_S=2 bash scripts/lauf.sh abschluss 2>&1)"; rc_final=$?
final_touched=0; { [ -s "$STUB/xcodebuild.log" ] || grep -q erase "$STUB/simctl.log" 2>/dev/null; } && final_touched=1
final_note="$(git notes --ref=lauf show HEAD 2>/dev/null)"
clear_stub; echo 30,00 > "$STUB/load"
( sleep 2; echo 1,50 > "$STUB/load" ) &
bash scripts/lauf.sh abschluss >/dev/null 2>&1; rc_wait=$?
wait
note="$(git notes --ref=lauf show HEAD 2>/dev/null | tail -1)"
clear_stub; echo 30,00 > "$STUB/load"
LAUF_WARTE_S=2 bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1; rc_sel=$?
if [ $rc_full -ne 0 ] && [ $full_ran = 0 ] && echo "$out_full" | grep -q "Last 30" \
    && [ $rc_final -ne 0 ] && [ $final_touched = 0 ] && [ -z "$final_note" ] && echo "$out_final" | grep -q "Last 30" \
    && [ $rc_wait = 0 ] && echo "$note" | grep -qF "last_beginn=1.50" && echo "$note" | grep -qF "last_ende=1.50" \
    && [ $rc_sel = 0 ]; then
    ok "40 full and final run wait for a quiet machine, the load in the note"
else
    fail "40 full and final run wait for a quiet machine, the load in the note" "full rc=$rc_full ran=$full_ran / final rc=$rc_final touched=$final_touched note=$final_note / wait rc=$rc_wait note=$note / sel rc=$rc_sel"
fi

# The final run resets the app instead of erasing the simulator.
S27=AAAA2700-0000-0000-0000-000000000000; S18=BBBB1860-0000-0000-0000-000000000000
group_dir() { echo "$LAUF_SIM_DEVICES/$1/data/Containers/Shared/AppGroup/$2"; }
make_group() {
    local dir; dir="$(group_dir "$1" "$2")"; mkdir -p "$dir/Library/Preferences"
    plutil -create xml1 "$dir/.com.apple.mobile_container_manager.metadata.plist"
    plutil -replace MCMMetadataIdentifier -string "$3" "$dir/.com.apple.mobile_container_manager.metadata.plist"
    echo data > "$dir/Library/Preferences/$3.plist"; echo data > "$dir/shared.json"
}
in_order() { python3 -c "
import sys
log = open(sys.argv[1]).read().splitlines()
pos = 0
for want in sys.argv[2:]:
    while pos < len(log) and want not in log[pos]: pos += 1
    if pos == len(log): sys.exit(1)
    pos += 1" "$@"; }

# 41. A simulator the script knows: no erase; uninstall, privacy reset and
# keychain reset in that order, then silent, then the tests; on 27 and on 18.6.
clear_stub; forget_marks
bash scripts/lauf.sh abschluss >/dev/null 2>&1
clear_stub
bash scripts/lauf.sh abschluss >/dev/null 2>&1; rc=$?
order=1
for u in $S27 $S18; do
    in_order "$STUB/simctl.log" "uninstall $u fm.maer.app" "privacy $u reset all fm.maer.app" "keychain $u reset" || order=0
done
if [ $rc = 0 ] && ! grep -q "^erase" "$STUB/simctl.log" && [ $order = 1 ] \
    && [ "$(grep -c '^silent yes' "$STUB/xcodebuild.log")" = 2 ]; then
    ok "41 a known simulator is reset, not erased"; else fail "41 a known simulator is reset, not erased" "rc=$rc order=$order $(cat "$STUB/simctl.log")"; fi

# 42. Erased only when the mark is missing or names another runtime; the mark
# is written after the erase, and the sound is silent after it.
clear_stub; forget_marks
bash scripts/lauf.sh abschluss >/dev/null 2>&1
new_erased="$(grep -c '^erase' "$STUB/simctl.log")"
marks="$(ls "$DEV"/bau/*/stand 2>/dev/null | wc -l | tr -d ' ')"
clear_stub; touch "$STUB/moved"
bash scripts/lauf.sh abschluss >/dev/null 2>&1
moved_27="$(grep -c "^erase $S27" "$STUB/simctl.log")"; moved_18="$(grep -c "^erase $S18" "$STUB/simctl.log")"
silent="$(grep -c '^silent yes' "$STUB/xcodebuild.log")"
if [ "$new_erased" = 2 ] && [ "$marks" = 2 ] && [ "$moved_27" = 0 ] && [ "$moved_18" = 1 ] && [ "$silent" = 2 ]; then
    ok "42 erased only when new or moved to another runtime"; else fail "42 erased only when new or moved to another runtime" "new=$new_erased marks=$marks moved27=$moved_27 moved18=$moved_18 silent=$silent"; fi

# 43. The container of the app group is emptied, its metadata stays, and the
# container of another group stays as it is.
clear_stub
make_group $S27 G1 group.fm.maer.app; make_group $S27 G2 group.other.app
bash scripts/lauf.sh abschluss >/dev/null 2>&1
mine="$(group_dir $S27 G1)"; other="$(group_dir $S27 G2)"
if [ -f "$mine/.com.apple.mobile_container_manager.metadata.plist" ] \
    && [ -z "$(find "$mine" -mindepth 1 ! -name .com.apple.mobile_container_manager.metadata.plist | head -1)" ] \
    && [ -f "$other/shared.json" ] && [ -f "$other/Library/Preferences/group.other.app.plist" ]; then
    ok "43 the app group is emptied, another group stays"; else fail "43 the app group is emptied, another group stays" "$(find "$mine" "$other" -type f)"; fi

# 44. A failing reset stops the run: no tests, no note.
fails=0
for f in privacy-fails keychain-fails; do
    clear_stub; touch "$STUB/$f"; git notes --ref=lauf remove HEAD >/dev/null 2>&1
    bash scripts/lauf.sh abschluss >/dev/null 2>&1 && fails=$((fails + 1))
    [ -s "$STUB/xcodebuild.log" ] && fails=$((fails + 1))
    git notes --ref=lauf show HEAD >/dev/null 2>&1 && fails=$((fails + 1))
done
if [ $fails = 0 ]; then ok "44 a failing reset stops the run"; else fail "44 a failing reset stops the run" "fails=$fails"; fi

# 45. The selection and the full run neither uninstall nor erase nor reset.
clear_stub
bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1
bash scripts/lauf.sh voll >/dev/null 2>&1
if ! grep -qE "^(uninstall|erase|keychain|privacy)" "$STUB/simctl.log"; then
    ok "45 selection and full run reset nothing"; else fail "45 selection and full run reset nothing" "$(cat "$STUB/simctl.log")"; fi

# 46. Every bundle of the app goes, the runner of the UI tests as well; a
# bundle of the system stays.
clear_stub
bash scripts/lauf.sh abschluss >/dev/null 2>&1
gone=1
for u in $S27 $S18; do
    grep -qx "uninstall $u fm.maer.app" "$STUB/simctl.log" || gone=0
    grep -qx "uninstall $u fm.maer.app.uitests.xctrunner" "$STUB/simctl.log" || gone=0
done
if [ $gone = 1 ] && ! grep -q "uninstall .* com.apple" "$STUB/simctl.log"; then
    ok "46 every bundle of the app goes, none of the system"; else fail "46 every bundle of the app goes, none of the system" "$(grep uninstall "$STUB/simctl.log")"; fi

# 47. An uninstall that answers 0 but leaves the bundle is not believed: the
# reset asks listapps again and uninstalls once more; a bundle that stays
# stops the run without tests or note.
clear_stub; touch "$STUB/sticky"
bash scripts/lauf.sh abschluss >/dev/null 2>&1; rc_sticky=$?
twice="$(grep -cx "uninstall $S18 fm.maer.app" "$STUB/simctl.log")"
ran="$(grep -c '^start' "$STUB/xcodebuild.log" 2>/dev/null)"
clear_stub; touch "$STUB/stuck"; git notes --ref=lauf remove HEAD >/dev/null 2>&1
out="$(bash scripts/lauf.sh abschluss 2>&1)"; rc_stuck=$?
if [ $rc_sticky = 0 ] && [ "$twice" = 2 ] && [ "$ran" = 2 ] && [ $rc_stuck -ne 0 ] && [ ! -s "$STUB/xcodebuild.log" ] \
    && ! git notes --ref=lauf show HEAD >/dev/null 2>&1 && echo "$out" | grep -q "fm.maer.app"; then
    ok "47 a bundle left after uninstall is caught"; else fail "47 a bundle left after uninstall is caught" "sticky rc=$rc_sticky twice=$twice ran=$ran / stuck rc=$rc_stuck $out"; fi

# 48. A list of apps that cannot be read is not an empty list: the run stops
# without tests or note.
clear_stub; touch "$STUB/listapps-fails"; git notes --ref=lauf remove HEAD >/dev/null 2>&1
bash scripts/lauf.sh abschluss >/dev/null 2>&1; rc=$?
if [ $rc -ne 0 ] && [ ! -s "$STUB/xcodebuild.log" ] && ! git notes --ref=lauf show HEAD >/dev/null 2>&1; then
    ok "48 an unreadable list of apps stops the run"; else fail "48 an unreadable list of apps stops the run" "rc=$rc"; fi

# The release: a tag, and main with it, only through lauf.sh release. An
# archive of the organizer is a folder with the version and build of the app
# and the GitSHA in the plist of the app.
make_archive() {
    local dir="$LAUF_ARCHIVE/2026-11-16/Maer $1 ($2).xcarchive"
    mkdir -p "$dir/Products/Applications/Maer.app"
    plutil -create xml1 "$dir/Info.plist"
    plutil -insert ApplicationProperties -dictionary "$dir/Info.plist"
    plutil -insert ApplicationProperties.CFBundleShortVersionString -string "$1" "$dir/Info.plist"
    plutil -insert ApplicationProperties.CFBundleVersion -string "$2" "$dir/Info.plist"
    plutil -create xml1 "$dir/Products/Applications/Maer.app/Info.plist"
    plutil -insert GitSHA -string "$3" "$dir/Products/Applications/Maer.app/Info.plist"
    printf '%s\n' "${4:-0000 T _main}" > "$dir/Products/Applications/Maer.app/Maer"
}
remote_ref() { git ls-remote origin "$1" | cut -f1; }
# A commit on dev with the note of the final run, pushed; and one without a note.
clear_stub; forget_marks; rm -rf "$LAUF_ARCHIVE"
git checkout -q -B dev origin/dev
change Sources/Models/PlaybackSkip.swift "// release" "A change that goes out"
bash scripts/lauf.sh abschluss >/dev/null 2>&1
bash scripts/lauf.sh push dev >/dev/null 2>&1
REL="$(git rev-parse HEAD)"; REL8="${REL:0:8}"
change Sources/Models/PlaybackSkip.swift "// unnoted" "A change without a final run"
git push -q --no-verify origin HEAD:refs/heads/dev >/dev/null 2>&1
BARE="$(git rev-parse HEAD)"
git checkout -q scheibe
main_before="$(remote_ref refs/heads/main)"
on_dev=0; [ "$(remote_ref refs/heads/dev)" = "$BARE" ] && git notes --ref=lauf show "$REL" >/dev/null 2>&1 && on_dev=1

# 49. Without an archive and without --sha the release stops.
out="$(bash scripts/lauf.sh release v9.1 91 2>&1)"; rc=$?
if [ $on_dev = 1 ] && [ $rc -ne 0 ] && echo "$out" | grep -q "Archiv" && [ -z "$(remote_ref refs/tags/v9.1)" ] && ! git rev-parse -q --verify refs/tags/v9.1 >/dev/null; then
    ok "49 no archive and no sha: no release"; else fail "49 no archive and no sha: no release" "on_dev=$on_dev rc=$rc $out"; fi

# 50. A sha that differs from the archive's GitSHA stops the release.
make_archive 9.1 91 "$REL8"
out="$(bash scripts/lauf.sh release v9.1 91 --sha "${BARE:0:8}" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "GitSHA" && [ -z "$(remote_ref refs/tags/v9.1)" ]; then
    ok "50 a sha other than the archive's stops"; else fail "50 a sha other than the archive's stops" "rc=$rc $out"; fi

# 51. Without the note of the final run at the commit the release stops.
make_archive 9.2 92 "${BARE:0:8}"
out="$(bash scripts/lauf.sh release v9.2 92 2>&1)"; rc=$?
if [ $rc -ne 0 ] && [ -z "$(remote_ref refs/tags/v9.2)" ] && echo "$out" | grep -q "Vermerk"; then
    ok "51 no note of the final run: no release"; else fail "51 no note of the final run: no release" "rc=$rc $out"; fi

# 53. --main where main cannot move forward to the commit stops; nothing moves.
git push -q --no-verify origin "$BARE:refs/heads/main" >/dev/null 2>&1
out="$(bash scripts/lauf.sh release v9.1 91 --main 2>&1)"; rc=$?
ff_main="$(remote_ref refs/heads/main)"
git push -q --no-verify --force origin "$main_before:refs/heads/main" >/dev/null 2>&1
if [ $rc -ne 0 ] && echo "$out" | grep -q "Vorspulen" && [ "$ff_main" = "$BARE" ] && [ -z "$(remote_ref refs/tags/v9.1)" ]; then
    ok "53 main only forward"; else fail "53 main only forward" "rc=$rc main=$ff_main $out"; fi

# 54. Green: the tag, annotated, at the commit on origin; main with it; codeberg untouched.
out="$(bash scripts/lauf.sh release v9.1 91 --main 2>&1)"; rc=$?
tag_commit="$(git rev-parse -q --verify "refs/tags/v9.1^{commit}" 2>/dev/null)"
if [ $rc = 0 ] && [ "$tag_commit" = "$REL" ] && [ "$(git cat-file -t refs/tags/v9.1 2>/dev/null)" = tag ] \
    && [ "$(git ls-remote origin 'refs/tags/v9.1^{}' | cut -f1)" = "$REL" ] && [ "$(remote_ref refs/heads/main)" = "$REL" ] \
    && [ -z "$(git ls-remote codeberg)" ]; then
    ok "54 the release sets the tag and main, on origin only"; else fail "54 the release sets the tag and main, on origin only" "rc=$rc tag=$tag_commit main=$(remote_ref refs/heads/main) $out"; fi

# 52. A tag that is there already, locally or on origin, stops.
out="$(bash scripts/lauf.sh release v9.1 91 2>&1)"; rc=$?
git tag -a v9.3 "$REL" -m "Local only" 2>/dev/null; make_archive 9.3 93 "$REL8"
out2="$(bash scripts/lauf.sh release v9.3 93 2>&1)"; rc2=$?
git tag -d v9.3 >/dev/null 2>&1
if [ $rc -ne 0 ] && [ $rc2 -ne 0 ] && echo "$out" | grep -q "Tag" && echo "$out2" | grep -q "Tag" && [ -z "$(remote_ref refs/tags/v9.3)" ]; then
    ok "52 a tag that is there already stops"; else fail "52 a tag that is there already stops" "rc=$rc rc2=$rc2 $out / $out2"; fi

# 55. The hook: a tag or main with LAUF_PUSH=1 but without LAUF_RELEASE, with the
# LAUF_RELEASE of another tag, or main to another commit than the tag's: refused.
git tag -a v9.4 "$REL" -m "Witness" 2>/dev/null
o1="$(LAUF_PUSH=1 git push origin refs/tags/v9.4 2>&1)"; r1=$?
o2="$(LAUF_PUSH=1 LAUF_RELEASE=v9.1 git push origin refs/tags/v9.4 2>&1)"; r2=$?
o3="$(LAUF_PUSH=1 LAUF_RELEASE=v9.4 git push origin "$BARE:refs/heads/main" 2>&1)"; r3=$?
o4="$(LAUF_PUSH=1 git push origin "$BARE:refs/heads/main" 2>&1)"; r4=$?
git tag -d v9.4 >/dev/null 2>&1
if [ $r1 -ne 0 ] && [ $r2 -ne 0 ] && [ $r3 -ne 0 ] && [ $r4 -ne 0 ] && [ -z "$(remote_ref refs/tags/v9.4)" ] \
    && [ "$(remote_ref refs/heads/main)" = "$REL" ]; then
    ok "55 the hook lets a tag and main through only for the release"; else fail "55 the hook lets a tag and main through only for the release" "$r1 $r2 $r3 $r4"; fi

# 56. A commit that is not on origin/dev stops.
change Sources/Models/PlaybackSkip.swift "// local" "A local commit"
bash scripts/lauf.sh abschluss >/dev/null 2>&1
LOCAL="$(git rev-parse HEAD)"; make_archive 9.5 95 "${LOCAL:0:8}"
out="$(bash scripts/lauf.sh release v9.5 95 2>&1)"; rc=$?
git reset -q --hard HEAD~1
if [ $rc -ne 0 ] && [ -z "$(remote_ref refs/tags/v9.5)" ] && echo "$out" | grep -q "origin/dev"; then
    ok "56 a commit not on origin/dev: no release"; else fail "56 a commit not on origin/dev: no release" "rc=$rc $out"; fi

# 57. A commit from before the script (it does not hold scripts/lauf.sh, and
# it lies before the commit of dev the script grew from) needs no note; the
# GitSHA of its archive is still the rule. A separate throwaway repository:
# the old commit, then the script added on dev.
OLDREPO="$DEV/old-repo"
git init -q --bare "$WORK/old-origin.git"
git init -q -b dev "$OLDREPO"
(
    cd "$OLDREPO" || exit 2
    git config user.name lzs; git config user.email 352619651+maer-lzs@users.noreply.github.com
    printf 'struct Old {}\n' > Old.swift
    git add -A && git commit -q --no-verify -m "A commit from before the script"
    git remote add origin "$WORK/old-origin.git"
    git push -q --no-verify origin dev dev:main 2>/dev/null
    mkdir -p scripts && cp -R "$REAL/scripts/." scripts/
    git add -A && git commit -q --no-verify -m "The script arrives"
    git push -q --no-verify origin dev 2>/dev/null
    git config core.hooksPath "$OLDREPO/scripts/hooks"
)
OLD="$(git -C "$OLDREPO" rev-parse dev~1)"
make_archive 9.6 96 "${OLD:0:8}"
out="$(cd "$OLDREPO" && bash scripts/lauf.sh release v9.6 96 --main 2>&1)"; rc=$?
make_archive 9.7 97 "$(git -C "$OLDREPO" rev-parse --short=8 dev)"
out2="$(cd "$OLDREPO" && bash scripts/lauf.sh release v9.7 97 2>&1)"; rc2=$?
if [ $rc = 0 ] && [ "$(git -C "$OLDREPO" ls-remote origin 'refs/tags/v9.6^{}' | cut -f1)" = "$OLD" ] \
    && [ $rc2 -ne 0 ] && echo "$out2" | grep -q "Vermerk" && [ -z "$(git -C "$OLDREPO" ls-remote origin refs/tags/v9.7)" ]; then
    ok "57 a commit from before the script needs no note, the next one does"; else fail "57 a commit from before the script needs no note, the next one does" "rc=$rc $out / rc2=$rc2 $out2"; fi

# R8: before the first commit that changes Sources/ stands a commit that
# changes only tests, red at the selection, with a note naming its red cases.
r8_branch() { git checkout -q -B "$1" origin/dev; }
r8_test() { change MaerTests/PlaybackSkipTests.swift "// $1" "A witness: $1"; }
r8_code() { change Sources/Models/PlaybackSkip.swift "// $1" "A change: $1"; }
r8_green() { clear_stub; bash scripts/lauf.sh abschluss >/dev/null 2>&1; }

# 58. Code before any test commit: push zweig and the hook refuse, and say so.
r8_branch r8-code; r8_code "first"; r8_test "after"; r8_green
out="$(bash scripts/lauf.sh push zweig 2>&1)"; rc=$?
out2="$(LAUF_PUSH=1 git push origin HEAD:refs/heads/r8-code 2>&1)"; rc2=$?
if [ $rc -ne 0 ] && [ $rc2 -ne 0 ] && echo "$out" | grep -q "kein Test-Commit vor dem Code" && [ -z "$(remote_ref refs/heads/r8-code)" ]; then
    ok "58 code before a test commit is refused"; else fail "58 code before a test commit is refused" "rc=$rc rc2=$rc2 $out / $out2"; fi

# 59. A test commit without the note of a red selection: refused, and said so.
r8_branch r8-ohne; r8_test "unproven"; r8_code "then"; r8_green
out="$(bash scripts/lauf.sh push zweig 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "kein roter Vermerk" && [ -z "$(remote_ref refs/heads/r8-ohne)" ]; then
    ok "59 a test commit without a red note is refused"; else fail "59 a test commit without a red note is refused" "rc=$rc $out"; fi

# 60. The right order: the selection at the test commit is red and notes the
# red cases; the code follows; the head is green; the push goes through.
r8_branch r8-recht; r8_test "proven"
clear_stub; touch "$STUB/red"; bash scripts/lauf.sh auswahl --basis "$(git rev-parse origin/dev)" >/dev/null 2>&1; red_rc=$?
red_note="$(git notes --ref=lauf show HEAD 2>/dev/null)"
r8_code "builds"; r8_green
out="$(bash scripts/lauf.sh push zweig 2>&1)"; rc=$?
if [ $red_rc -ne 0 ] && echo "$red_note" | grep -q "art=rot" && echo "$red_note" | grep -q "the row keeps four buttons" \
    && [ $rc = 0 ] && [ -n "$(remote_ref refs/heads/r8-recht)" ]; then
    ok "60 a red test commit before the code lets the push through"; else fail "60 a red test commit before the code lets the push through" "red_rc=$red_rc note=$red_note rc=$rc $out"; fi

# 61. A branch of form (form-) needs no test commit before its code.
r8_branch form-farbe; r8_code "a colour"; r8_green
out="$(bash scripts/lauf.sh push zweig 2>&1)"; rc=$?
if [ $rc = 0 ] && [ -n "$(remote_ref refs/heads/form-farbe)" ]; then
    ok "61 a branch of form passes without a test commit"; else fail "61 a branch of form passes without a test commit" "rc=$rc $out"; fi
git checkout -q scheibe

# B8: "does it flake?" asks one case many times in one run, and a few cold
# runs besides, because some failures show only at a start.
# 62. wiederhole runs the case N times in one run, then three cold runs.
clear_stub
out="$(bash scripts/lauf.sh wiederhole PlannedQueueTests 300 2>&1)"; rc=$?
runs="$(grep -c '^start' "$STUB/xcodebuild.log" 2>/dev/null)"
first="$(grep '^start' "$STUB/xcodebuild.log" 2>/dev/null | head -1)"
if [ $rc = 0 ] && [ "$runs" = 4 ] && echo "$first" | grep -q -- "-test-iterations 300" \
    && echo "$first" | grep -q -- "-only-testing:MaerTests/PlannedQueueTests" && grep -q "^silent yes" "$STUB/xcodebuild.log"; then
    ok "62 a case repeated in one run, then three cold runs"; else fail "62 a case repeated in one run, then three cold runs" "rc=$rc runs=$runs $first $out"; fi

# 63. A flaking case is counted, not just called red: four of three hundred.
clear_stub; touch "$STUB/flaky"
out="$(bash scripts/lauf.sh wiederhole PlannedQueueTests 300 2>&1)"; rc=$?
rm -f "$STUB/flaky"
if [ $rc -ne 0 ] && echo "$out" | grep -q "rot 4 von 300"; then
    ok "63 a flaking case is counted"; else fail "63 a flaking case is counted" "rc=$rc $out"; fi

# 64. Without a case, or with a count of none, nothing runs.
clear_stub
bash scripts/lauf.sh wiederhole >/dev/null 2>&1; r1=$?
bash scripts/lauf.sh wiederhole PlannedQueueTests 0 >/dev/null 2>&1; r2=$?
if [ $r1 -ne 0 ] && [ $r2 -ne 0 ] && [ ! -s "$STUB/xcodebuild.log" ]; then
    ok "64 no case, no count: nothing runs"; else fail "64 no case, no count: nothing runs" "$r1 $r2"; fi

# 65. R8 as agreed: a red commit may carry shells under Sources/ for a new
# function; the note of its red selection proves it, and the code follows.
r8_branch r8-huelle
printf 'struct Shell { func work() -> Int { 0 } }\n' > Sources/Models/Shell.swift
printf 'struct ShellTests { let s = Shell.self }\n' > MaerTests/ShellTests.swift
git add -A && git commit -q --no-verify -m "A witness with an empty shell of the new function"
clear_stub; touch "$STUB/red"; bash scripts/lauf.sh auswahl --basis "$(git rev-parse origin/dev)" >/dev/null 2>&1
shell_note="$(git notes --ref=lauf show HEAD 2>/dev/null)"
printf 'struct Shell { func work() -> Int { 1 } }\n' > Sources/Models/Shell.swift
git add -A && git commit -q --no-verify -m "The function works"
r8_green
out="$(bash scripts/lauf.sh push zweig 2>&1)"; rc=$?
git checkout -q scheibe
if echo "$shell_note" | grep -q "art=rot" && [ $rc = 0 ] && [ -n "$(remote_ref refs/heads/r8-huelle)" ]; then
    ok "65 a red commit with shells under Sources proves the order"; else fail "65 a red commit with shells under Sources proves the order" "note=$shell_note rc=$rc $out"; fi

# 66. The release reads the symbols of the uploaded program: a name of a test
# hook stops it.
make_archive 9.8 98 "$REL8" '0000 T $s4Maer15PlayerViewModelC17_testPlansSettledyyYaF'
out="$(bash scripts/lauf.sh release v9.8 98 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "_test" && [ -z "$(remote_ref refs/tags/v9.8)" ] && ! git rev-parse -q --verify refs/tags/v9.8 >/dev/null; then
    ok "66 a test hook in the uploaded program stops the release"; else fail "66 a test hook in the uploaded program stops the release" "rc=$rc $out"; fi

# 67. The final run builds the release program and reads its symbols: a name
# of a test hook writes no note; a clean program lets the note be written.
clear_stub; git notes --ref=lauf remove HEAD >/dev/null 2>&1
echo '0000 T $s4Maer13StreamPlannerC12_testSettledyyYaF' > "$STUB/release-symbols"
out="$(bash scripts/lauf.sh abschluss 2>&1)"; rc=$?
hooked_note="$(git notes --ref=lauf show HEAD 2>/dev/null)"
built="$(grep -c '^release-build' "$STUB/xcodebuild.log")"
clear_stub
bash scripts/lauf.sh abschluss >/dev/null 2>&1; rc2=$?
if [ $rc -ne 0 ] && [ -z "$hooked_note" ] && echo "$out" | grep -q "_test" && [ "$built" = 1 ] && [ $rc2 = 0 ] \
    && git notes --ref=lauf show HEAD 2>/dev/null | grep -q "art=abschluss"; then
    ok "67 the final run reads the symbols of the release program"; else fail "67 the final run reads the symbols of the release program" "rc=$rc built=$built rc2=$rc2 $out"; fi

# 68. Without origin/dev the order of R8 is not measured: red, and said so.
git checkout -q r8-recht
kept_dev="$(git rev-parse origin/dev)"
git update-ref -d refs/remotes/origin/dev
out="$(bash scripts/lauf.sh r8 r8-recht HEAD 2>&1)"; rc=$?
git update-ref refs/remotes/origin/dev "$kept_dev"
git checkout -q scheibe
if [ $rc -ne 0 ] && echo "$out" | grep -q "nicht gemessen"; then
    ok "68 without origin/dev the order is not measured"; else fail "68 without origin/dev the order is not measured" "rc=$rc $out"; fi

# 69. The hook refuses a push whose ref moved after git measured it: the
# commit it checked is not the one that would land.
git checkout -q -B gewandert scheibe
measured="$(git rev-parse HEAD)"
change Sources/Models/PlaybackSkip.swift "// moved on" "A commit during the push"
out="$(printf 'refs/heads/gewandert %s refs/heads/gewandert %s\n' "$measured" 0000000000000000000000000000000000000000 \
    | LAUF_PUSH=1 bash scripts/hooks/pre-push origin "$WORK/origin.git" 2>&1)"; rc=$?
git checkout -q scheibe
if [ $rc -ne 0 ] && echo "$out" | grep -q "gewandert"; then
    ok "69 a ref that moved after the measure is refused"; else fail "69 a ref that moved after the measure is refused" "rc=$rc $out"; fi

# 70. lauf.sh push pushes the commit it checked by its sha, not by a name
# that can move: the hook sees the sha as the local ref.
clear_stub
git checkout -q r8-recht
change MaerTests/PlaybackSkipTests.swift "// fixed" "A witness line for the fixed push"
r8_green
LAUF_HOOK_LOG="$WORK/hook.log" bash scripts/lauf.sh push zweig >/dev/null 2>&1; rc=$?
line="$(grep "refs/heads/r8-recht" "$WORK/hook.log" 2>/dev/null | tail -1)"
git checkout -q scheibe
if [ $rc = 0 ] && [ "$(echo "$line" | cut -d' ' -f1)" = "$(echo "$line" | cut -d' ' -f2)" ] && [ -n "$line" ]; then
    ok "70 the push names the checked commit by its sha"; else fail "70 the push names the checked commit by its sha" "rc=$rc line=$line"; fi

# 71. A run ended by TERM ends its xcodebuild as well, also one that does not
# end on TERM.
clear_stub; touch "$STUB/stubborn"
LAUF_STUB_SLEEP=30 bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1 &
run=$!
sleep 3
kill -TERM "$run"; wait "$run" 2>/dev/null
sleep 1
left="$(pgrep -f "$STUB/xcodebuild" | head -3)"
[ -n "$left" ] && kill -KILL $left 2>/dev/null
rm -f "$STUB/stubborn"
if [ -z "$left" ]; then ok "71 TERM ends the xcodebuild of the run"; else fail "71 TERM ends the xcodebuild of the run" "left: $left"; fi

# 72. A stripped program keeps the names of its fields as text: the release
# reads the text as well as the symbols.
make_archive 9.9 99 "$REL8" $'0000 T _main\n_testFeedFetcher'
out="$(bash scripts/lauf.sh release v9.9 99 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "_testFeedFetcher" && [ -z "$(remote_ref refs/tags/v9.9)" ]; then
    ok "72 a test hook only in the text of the program stops the release"; else fail "72 a test hook only in the text of the program stops the release" "rc=$rc $out"; fi

# 73. A seam named testXxx, without the underscore, is a test hook as well:
# release and the final run stop on it.
make_archive 9.10 910 "$REL8" '0000 T $s4Maer14FileDownloaderC12testSetClockyyF'
out="$(bash scripts/lauf.sh release v9.10 910 2>&1)"; rc=$?
clear_stub; git notes --ref=lauf remove HEAD >/dev/null 2>&1
echo '0000 T $s4Maer14FileDownloaderC10testPassesSivg' > "$STUB/release-symbols"
out2="$(bash scripts/lauf.sh abschluss 2>&1)"; rc2=$?
noted="$(git notes --ref=lauf show HEAD 2>/dev/null)"
clear_stub
if [ $rc -ne 0 ] && echo "$out" | grep -q "testSetClock" && [ -z "$(remote_ref refs/tags/v9.10)" ] \
    && [ $rc2 -ne 0 ] && echo "$out2" | grep -q "testPasses" && [ -z "$noted" ]; then
    ok "73 a seam without the underscore stops release and final run"; else fail "73 a seam without the underscore stops release and final run" "rc=$rc rc2=$rc2 $out / $out2"; fi

# 74. A name of the product that begins with test is on the list with its
# reason and does not stop; an entry of the list without a reason does.
make_archive 9.11 911 "$REL8" '0000 T Maer.APIClient.testConnection() async throws'
out="$(bash scripts/lauf.sh release v9.11 911 2>&1)"; rc=$?
list="scripts/lauf/release-namen.txt"
kept="$(cat "$list" 2>/dev/null)"
printf 'testConnection\n' > "$list"
make_archive 9.12 912 "$REL8" '0000 T Maer.APIClient.testConnection() async throws'
out2="$(bash scripts/lauf.sh release v9.12 912 2>&1)"; rc2=$?
printf '%s\n' "$kept" > "$list"
if [ $rc = 0 ] && [ -n "$(remote_ref refs/tags/v9.11)" ] && [ $rc2 -ne 0 ] && echo "$out2" | grep -q "ohne Grund"; then
    ok "74 a product name on the list passes, an entry without a reason stops"; else fail "74 a product name on the list passes, an entry without a reason stops" "rc=$rc rc2=$rc2 $out / $out2"; fi

# 75. A red run keeps its log in the store as the evidence, and names the red
# cases, not lines that only carry the word error; a green run keeps none.
clear_stub; rm -f "$LAUF_ABLAGE"/rot-*.log; touch "$STUB/red"
out="$(bash scripts/lauf.sh auswahl --basis "$BASE" 2>&1)"
kept="$(ls "$LAUF_ABLAGE"/rot-*.log 2>/dev/null | head -1)"
clear_stub
bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1
after_green="$(ls "$LAUF_ABLAGE"/rot-*.log 2>/dev/null | wc -l | tr -d ' ')"
if [ -n "$kept" ] && grep -q "the row keeps four buttons" "$kept" && echo "$out" | grep -q "the row keeps four buttons" \
    && echo "$out" | grep -q "rot-" && [ "$after_green" = 1 ]; then
    ok "75 a red run keeps its log and names its red cases"; else fail "75 a red run keeps its log and names its red cases" "kept=$kept after_green=$after_green $out"; fi
rm -f "$LAUF_ABLAGE"/rot-*.log

# 76. A release program that Xcode did not link again, because no source
# changed, is current when the stamp beside it names the head; a stamp of
# another commit is not.
clear_stub; git notes --ref=lauf remove HEAD >/dev/null 2>&1
bash scripts/lauf.sh abschluss >/dev/null 2>&1
git notes --ref=lauf remove HEAD >/dev/null 2>&1
sleep 1; touch "$STUB/keep-program"
out="$(bash scripts/lauf.sh abschluss 2>&1)"; rc=$?
kept_note="$(git notes --ref=lauf show HEAD 2>/dev/null)"
git notes --ref=lauf remove HEAD >/dev/null 2>&1
touch "$STUB/stale-stamp"
out2="$(bash scripts/lauf.sh abschluss 2>&1)"; rc2=$?
stale_note="$(git notes --ref=lauf show HEAD 2>/dev/null)"
clear_stub
if [ $rc = 0 ] && echo "$kept_note" | grep -q "art=abschluss" && [ $rc2 -ne 0 ] && [ -z "$stale_note" ]; then
    ok "76 an unlinked program is current by the stamp of the head"; else fail "76 an unlinked program is current by the stamp of the head" "rc=$rc rc2=$rc2 $out / $out2"; fi

# 77. The final run boots each simulator, then waits for a quiet machine
# before xcodebuild starts the app: the boot drives the load far up, and a
# start of the app in that window can fail. A load that stays up after the
# boot stops the run without a test.
clear_stub; git notes --ref=lauf remove HEAD >/dev/null 2>&1
bash scripts/lauf.sh abschluss >/dev/null 2>&1; rc=$?
order_ok="$(python3 -c "
import sys
lines = open(sys.argv[1]).read().splitlines()
ok = True
for udid in ('AAAA2700', 'BBBB1860'):
    boot = next((i for i, l in enumerate(lines) if l.startswith('simctl bootstatus ' + udid)), None)
    run = next((i for i, l in enumerate(lines) if l.startswith('xcodebuild start') and 'id=' + udid in l), None)
    load = [i for i, l in enumerate(lines) if l.startswith('sysctl') and 'vm.loadavg' in l]
    ok = ok and boot is not None and run is not None and any(boot < i < run for i in load)
print('ja' if ok else 'nein')" "$STUB/order.log" 2>/dev/null)"
clear_stub; git notes --ref=lauf remove HEAD >/dev/null 2>&1; touch "$STUB/load-after-boot"
out="$(LAUF_WARTE_S=2 bash scripts/lauf.sh abschluss 2>&1)"; rc2=$?
ran="$(grep -c '^start' "$STUB/xcodebuild.log" 2>/dev/null)"
clear_stub
if [ $rc = 0 ] && [ "$order_ok" = ja ] && [ $rc2 -ne 0 ] && [ "${ran:-0}" = 0 ] && echo "$out" | grep -q "nach dem Booten"; then
    ok "77 the final run waits for a quiet machine after the boot"; else fail "77 the final run waits for a quiet machine after the boot" "rc=$rc order=$order_ok rc2=$rc2 ran=$ran $out"; fi

# 78. The final run shuts each simulator down after its run: the next
# simulator does not wait for it as a foreign one, and none stays booted.
clear_stub; git notes --ref=lauf remove HEAD >/dev/null 2>&1
out="$(LAUF_WARTE_S=2 bash scripts/lauf.sh abschluss 2>&1)"; rc=$?
left="$(cat "$STUB/booted" 2>/dev/null | grep -c .)"
clear_stub
if [ $rc = 0 ] && [ "$left" = 0 ] && ! echo "$out" | grep -q "fremder Simulator"; then
    ok "78 each simulator is shut down after its run"; else fail "78 each simulator is shut down after its run" "rc=$rc left=$left $out"; fi

# 79. No way out of the final run leaves its simulator booted: a load that
# stays up after the boot, a reset that fails after the boot, and TERM or
# INT during the run. The next run would wait for it as a foreign one.
booted_after() { cat "$STUB/booted" 2>/dev/null | grep -c . ; }
clear_stub; git notes --ref=lauf remove HEAD >/dev/null 2>&1; touch "$STUB/load-after-boot"
LAUF_WARTE_S=2 bash scripts/lauf.sh abschluss >/dev/null 2>&1; loud=$?; loud_left="$(booted_after)"
clear_stub; touch "$STUB/privacy-fails"
bash scripts/lauf.sh abschluss >/dev/null 2>&1; reset=$?; reset_left="$(booted_after)"
clear_stub
LAUF_STUB_SLEEP=20 bash scripts/lauf.sh abschluss >/dev/null 2>&1 &
run=$!; sleep 3; kill -TERM "$run"; wait "$run" 2>/dev/null; term_left="$(booted_after)"
clear_stub
LAUF_STUB_SLEEP=20 bash scripts/lauf.sh abschluss >/dev/null 2>&1 &
run=$!; sleep 3; kill -INT "$run"; wait "$run" 2>/dev/null; int_left="$(booted_after)"
pkill -f "$STUB/xcodebuild" 2>/dev/null
clear_stub
if [ $loud -ne 0 ] && [ "$loud_left" = 0 ] && [ $reset -ne 0 ] && [ "$reset_left" = 0 ] && [ "$term_left" = 0 ] && [ "$int_left" = 0 ]; then
    ok "79 no way out of the final run leaves a simulator booted"; else fail "79 no way out of the final run leaves a simulator booted" "loud=$loud/$loud_left reset=$reset/$reset_left term=$term_left int=$int_left"; fi

# 80. An entry of the list of product names in the underscore form names a
# test hook, not a product name: the read stops.
list="scripts/lauf/release-namen.txt"; kept="$(cat "$list")"
printf '%s\n_testFeedFetcher # a seam of the podcast subscriptions\n' "$kept" > "$list"
make_archive 9.13 913 "$REL8" '0000 T Maer.APIClient.testConnection() async throws'
out="$(bash scripts/lauf.sh release v9.13 913 2>&1)"; rc=$?
printf '%s\n' "$kept" > "$list"
if [ $rc -ne 0 ] && echo "$out" | grep -q "Unterstrich" && [ -z "$(remote_ref refs/tags/v9.13)" ]; then
    ok "80 an entry in the underscore form stops the read"; else fail "80 an entry in the underscore form stops the read" "rc=$rc $out"; fi

# 81. The journeys of a selection build into one folder of the run's build
# state, the same for every run, never a new temporary one: each of those
# stayed behind with its 1.3 GB.
clear_stub
printf 'printf %%s "$MAER_JOURNEY_DD" > "%s/journeys-dd"\n' "$WORK" > "$WORK/journeys-stub"
change Sources/Views/RowView.swift "// journeys" "A view for the journeys"
LAUF_JOURNEYS="sh $WORK/journeys-stub" bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1; rc=$?
got="$(cat "$WORK/journeys-dd" 2>/dev/null)"
reset_base
if [ $rc = 0 ] && [ "$got" = "$LAUF_BAU/journeys" ]; then
    ok "81 the journeys build into one folder of the run's build state"; else fail "81 the journeys build into one folder of the run's build state" "rc=$rc folder=$got"; fi

echo "failures: $failures"
[ "$failures" -eq 0 ]
