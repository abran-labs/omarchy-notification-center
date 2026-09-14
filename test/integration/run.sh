#!/bin/bash
# Headless integration run for ServiceStore: fixture history dir + fake HOME,
# quickshell offscreen under a pty (qmltestrunner/quickshell need /dev/tty),
# result parsed from HARNESS-RESULT. Phase 1 exercises fallback merge,
# tombstones, read marks, withdrawal scoping and clear; phase 2 relaunches
# against the same HOME to prove own-state persistence across restarts.
# Fixture files must be byte-identical afterwards (service disk read-only).
set -u

repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
mkdir -p "$work/history" "$work/fakehome" "$work/cfg"

# quickshell refuses component imports outside the config folder, so stage
# the unit under test plus the harness into the sandbox config dir.
sed -e 's#"../CenterState.js"#"./CenterState.js"#' \
  "$repo/components/ServiceStore.qml" > "$work/cfg/ServiceStore.qml"
cp "$repo/CenterState.js" "$work/cfg/CenterState.js"
sed -e '/import "..\/..\/components" as C/d; s#C\.ServiceStore#ServiceStore#' \
  "$repo/test/integration/shell.qml" > "$work/cfg/shell.qml"

mkrow() {
  printf '{"id":%s,"originalId":%s,"app":"%s","appIcon":"","summary":"%s","body":"b","image":"","glyph":"","execArgv":"","urgency":1,"expireTimeout":0,"timestamp":%s}' \
    "$1" "$2" "$3" "$4" "$5" > "$work/history/$5-$2.json"
}

mkrow 5 5 chat live 9000
mkrow 7 7 mail silenced 8000
mkrow 5 5 chat old 1000
printf '{torn write\n' > "$work/history/torn.json"

before="$(md5sum "$work"/history/*.json | md5sum)"

run_phase() {
  local phase="$1"
  local log="$work/$phase.log"
  # quickshell exposes no scripted quit (Qt.quit/Quickshell.quit are no-ops
  # here), so TERM at 30s only reaps the process; the harness always
  # finishes in ~2s (25s watchdog worst case).
  HOME="$work/fakehome" HARNESS_HIST="$work/history" HARNESS_PHASE="$phase" \
    script -qec "QT_QPA_PLATFORM=offscreen timeout -k 5 -s TERM 30 quickshell --path $work/cfg" /dev/null \
    > "$log" 2>&1
  grep -a -e HARNESS-CHECK -e HARNESS-RESULT "$log"
  grep -aq "HARNESS-RESULT: PASS" "$log"
}

fail=0
run_phase main || fail=1
run_phase native || fail=1
run_phase reload || fail=1

after="$(md5sum "$work"/history/*.json | md5sum)"
if [[ $before != "$after" ]]; then
  echo "HARNESS-CHECK fixture-dir-unmodified FAIL"
  fail=1
else
  echo "HARNESS-CHECK fixture-dir-unmodified ok"
fi

exit $fail
