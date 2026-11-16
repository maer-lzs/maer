#!/bin/bash
# test-lauf.sh: the witnesses of the run script (scripts/lauf.sh), its
# selection (scripts/lauf/auswahl.py) and the pre-push hook. Builds a
# throwaway repository with a bare origin and a second remote, replaces
# xcodebuild and simctl by stubs through the environment, and asks the script
# about each case. No simulator runs. One case, the history of this week,
# reads the real repository. Prints one line per case and exits non-zero when
# any case goes the wrong way.
set -u
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
now() { python3 -c 'import time; print(int(time.time()*1000))'; }
echo "start $(now) $*" >> "$log"
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
sleep "${LAUF_STUB_SLEEP:-0}"
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
# booted-foreign exists, one foreign booted device; every call is logged.
cat > "$STUB/simctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$LAUF_STUB_DIR/simctl.log"
case "$*" in
    erase\ *) rm -rf "$LAUF_SIM_DEVICES/$2/data" ;;
    *"list devices"*)
        foreign=""
        if [ -f "$LAUF_STUB_DIR/booted-foreign" ]; then
            foreign=',{"name":"Fremder Sim","udid":"FFFF0000-0000-0000-0000-000000000000","state":"Booted"}'
        fi
        echo '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"name":"Maer-Abschluss-27","udid":"AAAA2700-0000-0000-0000-000000000000","state":"Shutdown"},{"name":"Maer-Test-Bau","udid":"C1F0240C-E988-41D2-9081-4CFF0B8EA34B","state":"Shutdown"}'"$foreign"'],"com.apple.CoreSimulator.SimRuntime.iOS-18-6":[{"name":"Maer-Abschluss-18","udid":"BBBB1860-0000-0000-0000-000000000000","state":"Shutdown"}]}}'
        ;;
esac
exit 0
EOF
# sysctl answers the load over one minute from the file load (default 0.50,
# quiet) and ten cores; every call is logged.
cat > "$STUB/sysctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$LAUF_STUB_DIR/sysctl.log"
case "$*" in
    *vm.loadavg*) echo "{ $(cat "$LAUF_STUB_DIR/load" 2>/dev/null || echo 0.50) 0.40 0.30 }" ;;
    *hw.ncpu*) echo 10 ;;
esac
EOF
chmod +x "$STUB/xcodebuild" "$STUB/simctl" "$STUB/sysctl"
export LAUF_XCODEBUILD="$STUB/xcodebuild" LAUF_SIMCTL="$STUB/simctl" LAUF_SYSCTL="$STUB/sysctl" LAUF_STUB_DIR="$STUB"
export LAUF_ABLAGE="$DEV/ablage" LAUF_BAU="$DEV/bau" LAUF_TEMP_ROOTS="$TEMP/" LAUF_MIN_GB=0
export LAUF_WARTE_S=4 LAUF_TICK_S=1
export LAUF_SIM_DEVICES="$DEV/devices" LAUF_STILLES_GERAET=Witness_Silent_UID
# The copied hooks read the list of names from the fence of the real tree.
export MAER_ROLE_FENCE="$REAL/MaerTests/PublicReadmeFenceTests.swift"
unset LAUF_PUSH
clear_stub() { rm -f "$STUB/xcodebuild.log" "$STUB/simctl.log" "$STUB/sysctl.log" "$STUB/red" "$STUB/booted-foreign" "$STUB/load"; }

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

# 13. After a red run the store is gone and the red cases stand in the output.
clear_stub; touch "$STUB/red"
out="$(bash scripts/lauf.sh auswahl --basis "$BASE" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "the row keeps four buttons" && [ -z "$(ls -A "$LAUF_ABLAGE" 2>/dev/null)" ]; then
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
git checkout -q -b scheibe
change Sources/Models/PlaybackSkip.swift "// slice" "A change of the slice"
clear_stub; touch "$STUB/red"
before="$(git for-each-ref --format='%(refname) %(objectname)' | sort)"
remote_before="$(git ls-remote origin | sort)"
bash scripts/lauf.sh abschluss >/dev/null 2>&1; rc=$?
red_note="$(git notes --ref=lauf show HEAD 2>/dev/null)"
after="$(git for-each-ref --format='%(refname) %(objectname)' | sort)"
remote_after="$(git ls-remote origin | sort)"
clear_stub
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
clear_stub; rm -rf "$LAUF_SIM_DEVICES"
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
clear_stub; echo 30.00 > "$STUB/load"
out_full="$(LAUF_WARTE_S=2 bash scripts/lauf.sh voll 2>&1)"; rc_full=$?
full_ran=0; [ -s "$STUB/xcodebuild.log" ] && full_ran=1
clear_stub; echo 30.00 > "$STUB/load"
git notes --ref=lauf remove HEAD >/dev/null 2>&1
out_final="$(LAUF_WARTE_S=2 bash scripts/lauf.sh abschluss 2>&1)"; rc_final=$?
final_touched=0; { [ -s "$STUB/xcodebuild.log" ] || grep -q erase "$STUB/simctl.log" 2>/dev/null; } && final_touched=1
final_note="$(git notes --ref=lauf show HEAD 2>/dev/null)"
clear_stub; echo 30.00 > "$STUB/load"
( sleep 2; echo 1.50 > "$STUB/load" ) &
bash scripts/lauf.sh abschluss >/dev/null 2>&1; rc_wait=$?
wait
note="$(git notes --ref=lauf show HEAD 2>/dev/null | tail -1)"
clear_stub; echo 30.00 > "$STUB/load"
LAUF_WARTE_S=2 bash scripts/lauf.sh auswahl --basis "$BASE" >/dev/null 2>&1; rc_sel=$?
if [ $rc_full -ne 0 ] && [ $full_ran = 0 ] && echo "$out_full" | grep -q "Last 30" \
    && [ $rc_final -ne 0 ] && [ $final_touched = 0 ] && [ -z "$final_note" ] && echo "$out_final" | grep -q "Last 30" \
    && [ $rc_wait = 0 ] && echo "$note" | grep -q "last_beginn=1.50" && echo "$note" | grep -q "last_ende=1.50" \
    && [ $rc_sel = 0 ]; then
    ok "40 full and final run wait for a quiet machine, the load in the note"
else
    fail "40 full and final run wait for a quiet machine, the load in the note" "full rc=$rc_full ran=$full_ran / final rc=$rc_final touched=$final_touched note=$final_note / wait rc=$rc_wait note=$note / sel rc=$rc_sel"
fi

echo "failures: $failures"
[ "$failures" -eq 0 ]
