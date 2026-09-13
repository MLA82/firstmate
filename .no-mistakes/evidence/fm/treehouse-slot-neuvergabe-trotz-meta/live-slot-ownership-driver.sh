#!/usr/bin/env bash
# Live driver: real bin/fm-spawn.sh + bin/fm-teardown.sh on the herdr backend,
# real Treehouse (pool isolated under a temp TREEHOUSE_ROOT), isolated herdr
# lab session. Exercises slot-reissue refusal and teardown ownership checks.
#
# Usage: live-slot-ownership-driver.sh <firstmate-root> [head|base]
set -u
ROOT=$(cd "$1" && pwd)
MODE=${2:-head}

command -v herdr >/dev/null && command -v jq >/dev/null && command -v treehouse >/dev/null \
  || { echo "missing herdr/jq/treehouse"; exit 2; }

# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-live-slot.XXXXXX")
SESSION="fm-lab-slotlease-$$"
export HERDR_SESSION="$SESSION"
export TREEHOUSE_ROOT="$TMP/th"
FAILS=0
cleanup() { herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "lab prepare failed"; exit 2; }
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr

say()   { printf '\n=== %s\n' "$*"; }
ok()    { printf 'PASS: %s\n' "$*"; }
bad()   { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

mkhome() {  # <dir>
  mkdir -p "$1/state" "$1/data" "$1/config"
  printf 'off\n' > "$1/config/herdr-presentation-spaces"
}
brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  printf '# Task\n## Captain'"'"'s intent\nLive slot test %s.\n\n## Firstmate spec\nIdle.\n' "$2" > "$1/data/$2/brief.md"
}
spawn() {  # <home> <id>  -> rc; stdout+stderr to $TMP/<id>.spawn
  brief "$1" "$2"
  (cd "$TMP" && FM_SPAWN_NO_GUARD=1 FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$2" "$PROJ" "sh -c 'echo worker-$2-up; exec sleep 3600'" \
    --mode no-mistakes --yolo off --backend herdr) >"$TMP/$2.spawn" 2>&1
}
teardown() {  # <home> <id> [--force] -> rc; output to $TMP/<id>.td
  (cd "$TMP" && FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$1/state" \
    FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" \
    "$ROOT/bin/fm-teardown.sh" "$2" ${3:+"$3"}) >"$TMP/$2.td" 2>&1
}
wt_of()   { sed -n 's/^worktree=//p' "$1/state/$2.meta"; }
pane_of() { sed -n 's/^herdr_pane_id=//p' "$1/state/$2.meta"; }
pool()    { (cd "$PROJ" && treehouse status --json); }
slot_json() { pool | jq -c --arg p "$1" '.[] | select(.path == $p) | {name,status,lease_holder,lease_id,processes:(.processes|length)}'; }
holder_of() { pool | jq -r --arg p "$1" '.[] | select(.path == $p) | .lease_holder // ""'; }
leaseid_of() { pool | jq -r --arg p "$1" '.[] | select(.path == $p) | .lease_id // ""'; }
nproc_of() { pool | jq -r --arg p "$1" '.[] | select(.path == $p) | (.processes|length)'; }
canon()   { (cd "$1" && pwd -P); }
kill_pane() { fm_backend_herdr_kill "$SESSION:$1" >/dev/null 2>&1; sleep 1; }
show()    { printf -- '--- %s ---\n' "$1"; sed 's/^/  | /' "$2"; }

PH="$TMP/primary-home"; mkhome "$PH"; PH=$(canon "$PH")
SM="$TMP/secondmate-home"; mkhome "$SM"; SM=$(canon "$SM")
printf 'mate\n' > "$SM/.fm-secondmate-home"
printf -- '- mate - Test (home: %s; scope: test; projects: proj; added 2026-09-13)\n' "$SM" > "$PH/data/secondmates.md"
OH="$TMP/other-home"; mkhome "$OH"; OH=$(canon "$OH")
PROJ="$TMP/proj"
mkdir -p "$PROJ"; git -C "$PROJ" init -q -b main
printf '# scratch\n' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
echo "ROOT=$ROOT MODE=$MODE TREEHOUSE_ROOT=$TREEHOUSE_ROOT treehouse=$(treehouse --version)"

# ---------------------------------------------------------------- S1
say "S1 spawn task A from the primary home: durable lease bound to A"
spawn "$PH" A; rc=$?
[ "$rc" -eq 0 ] || { show "A spawn" "$TMP/A.spawn"; bad "A spawn rc=$rc"; exit 1; }
WTA=$(canon "$(wt_of "$PH" A)"); PANEA=$(pane_of "$PH" A)
echo "A worktree=$WTA"; echo "A slot: $(slot_json "$WTA")"
case "$WTA" in "$TREEHOUSE_ROOT"/*) ok "pane shell used the isolated TREEHOUSE_ROOT pool" ;; *) bad "slot outside isolated pool: $WTA" ;; esac
if [ "$MODE" = head ]; then
  echo "A claim ($(dirname "$WTA")/.fm-slot-owner):"; sed 's/^/  | /' "$(dirname "$WTA")/.fm-slot-owner"
  check "A's slot is durably leased by holder firstmate:$PH:A" [ "$(holder_of "$WTA")" = "firstmate:$PH:A" ]
  check "A's claim stores Treehouse's lease_id" grep -Fxq "lease_id=$(leaseid_of "$WTA")" "$(dirname "$WTA")/.fm-slot-owner"
fi

# ---------------------------------------------------------------- S2
say "S2 A's worker exits (pane closed) but A is never torn down; spawn B"
kill_pane "$PANEA"
echo "A slot after worker exit: $(slot_json "$WTA")"
spawn "$PH" B; rc=$?
[ "$rc" -eq 0 ] || { show "B spawn" "$TMP/B.spawn"; bad "B spawn rc=$rc"; exit 1; }
WTB=$(canon "$(wt_of "$PH" B)"); PANEB=$(pane_of "$PH" B)
echo "B worktree=$WTB"; echo "A meta still records worktree=$(wt_of "$PH" A)"
if [ "$WTB" = "$WTA" ]; then
  bad "REISSUE: B was handed slot $WTB while A's record still names it"
else
  ok "B got a different slot ($WTB); A's still-recorded slot was not reissued"
fi
[ "$MODE" = head ] || { echo "RESULT mode=$MODE fails=$FAILS"; exit "$FAILS"; }
check "A's slot is still leased by A with no process in it" \
  [ "$(holder_of "$WTA"):$(nproc_of "$WTA")" = "firstmate:$PH:A:0" ]

# ---------------------------------------------------------------- S3
say "S3 legacy (process-only, pre-fix) record in the SECONDMATE home names a free, unleased slot"
L=$(cd "$PROJ" && treehouse get --lease --no-fetch --lease-holder setup 2>/dev/null)
(cd "$PROJ" && treehouse return --force --if-lease-holder setup "$L") >/dev/null 2>&1
WTL=$(canon "$L")
echo "legacy-unlanded-work" > "$WTL/UNLANDED.txt"
printf 'window=firstmate:fm-legacy\nworktree=%s\nproject=%s\nharness=echo\nkind=ship\nmode=no-mistakes\nyolo=off\n' \
  "$WTL" "$PROJ" > "$SM/state/legacy.meta"
echo "legacy slot before: $(slot_json "$WTL")"
state_file="$(dirname "$(dirname "$WTL")")/treehouse-state.json"
before=$(sha256sum < "$state_file"); head_before=$(git -C "$WTL" rev-parse HEAD)
spawn "$PH" C; rc=$?
show "C spawn (expected refusal)" "$TMP/C.spawn"
check "spawn C refuses (rc=$rc)" [ "$rc" -ne 0 ]
check "refusal names the secondmate-home record" grep -Fq "$SM/state/legacy.meta" "$TMP/C.spawn"
check "refusal happens before any slot is requested" grep -Fq "no slot was requested" "$TMP/C.spawn"
check "no record published for C" [ ! -e "$PH/state/C.meta" ]
check "Treehouse pool state is byte-identical (no lease taken)" [ "$(sha256sum < "$state_file")" = "$before" ]
check "legacy slot's unlanded file and HEAD untouched" \
  [ "$(cat "$WTL/UNLANDED.txt" 2>/dev/null):$(git -C "$WTL" rev-parse HEAD)" = "legacy-unlanded-work:$head_before" ]

say "S3-control: once the legacy record is reconciled, spawn C proceeds"
rm -f "$SM/state/legacy.meta" "$WTL/UNLANDED.txt"
spawn "$PH" C; rc=$?
[ "$rc" -eq 0 ] || show "C spawn" "$TMP/C.spawn"
check "spawn C succeeds after reconciliation" [ "$rc" -eq 0 ]
WTC=$(canon "$(wt_of "$PH" C)"); echo "C worktree=$WTC slot: $(slot_json "$WTC")"

# ---------------------------------------------------------------- S4
say "S4 reported case: A's stale record names a slot now held by live task D of an unregistered home"
spawn "$OH" D; rc=$?
[ "$rc" -eq 0 ] || { show "D spawn" "$TMP/D.spawn"; bad "D spawn rc=$rc"; exit 1; }
WTD=$(canon "$(wt_of "$OH" D)"); sleep 1
echo "D-unlanded-work" > "$WTD/D-WORK.txt"
echo "D slot before: $(slot_json "$WTD")"
cp "$PH/state/A.meta" "$TMP/A.meta.orig"
sed -i "s|^worktree=.*|worktree=$WTD|" "$PH/state/A.meta"
teardown "$PH" A --force; rc=$?
show "teardown A --force (expected refusal)" "$TMP/A.td"
echo "D slot after: $(slot_json "$WTD")"
check "teardown of the stale record refuses even with --force (rc=$rc)" [ "$rc" -ne 0 ]
check "refusal names the reassignment to D" grep -Fq "reassigned to task D (home $OH)" "$TMP/A.td"
check "D's worker is still running in its slot" [ "$(nproc_of "$WTD")" -ge 1 ]
check "D's unlanded file survives" [ "$(cat "$WTD/D-WORK.txt" 2>/dev/null)" = "D-unlanded-work" ]
check "D's lease is untouched" [ "$(holder_of "$WTD")" = "firstmate:$OH:D" ]
check "A's stale record is preserved for reconciliation" [ -e "$PH/state/A.meta" ]
cp "$TMP/A.meta.orig" "$PH/state/A.meta"

# ---------------------------------------------------------------- S5
say "S5 adversarial: E's slot lease is returned by hand and re-leased to another holder; E's claim still says E"
spawn "$PH" E; rc=$?
[ "$rc" -eq 0 ] || { show "E spawn" "$TMP/E.spawn"; bad "E spawn rc=$rc"; exit 1; }
WTE=$(canon "$(wt_of "$PH" E)"); kill_pane "$(pane_of "$PH" E)"
old_id=$(leaseid_of "$WTE")
(cd "$PROJ" && treehouse return --force --if-lease-holder "firstmate:$PH:E" "$WTE") >/dev/null 2>&1
G=$(cd "$PROJ" && treehouse get --lease --no-fetch --lease-holder drydock 2>/dev/null); G=$(canon "$G")
echo "E slot=$WTE old lease=$old_id; drydock got $G; now: $(slot_json "$WTE")"
if [ "$G" = "$WTE" ]; then
  echo "drydock-work" > "$WTE/DRYDOCK.txt"
  teardown "$PH" E --force; rc=$?
  show "teardown E --force (expected refusal)" "$TMP/E.td"
  check "teardown refuses when the slot's lease identity changed (rc=$rc)" [ "$rc" -ne 0 ]
  check "refusal cites the lost lease" grep -Fq "no longer holds its Treehouse lease $old_id" "$TMP/E.td"
  check "drydock's file survives and lease is still drydock's" \
    [ "$(cat "$WTE/DRYDOCK.txt" 2>/dev/null):$(holder_of "$WTE")" = "drydock-work:drydock" ]
else
  bad "drydock did not receive E's returned slot ($G); lease-swap case not constructed"
fi

# ---------------------------------------------------------------- S6
say "S6 normal teardown of A (its own slot, lease and claim) still works"
teardown "$PH" A; rc=$?
show "teardown A" "$TMP/A.td"
check "teardown A succeeds" [ "$rc" -eq 0 ]
check "A's record removed" [ ! -e "$PH/state/A.meta" ]
check "A's slot returned to the pool (no lease)" [ -z "$(holder_of "$WTA")" ]
check "A's claim removed" [ ! -e "$(dirname "$WTA")/.fm-slot-owner" ]
echo "A slot after teardown: $(slot_json "$WTA")"

# ---------------------------------------------------------------- S7
say "S7 locked abort: the only free slot carries a foreign claim, so spawn F aborts and must return its lease"
printf 'task=ghost\nhome=%s\n' "$TMP/ghost-home" > "$(dirname "$WTA")/.fm-slot-owner"
echo "free slots: $(pool | jq -c '[.[] | select(.status != "leased") | .path]')"
spawn "$PH" F; rc=$?
show "F spawn (expected abort)" "$TMP/F.spawn"
check "spawn F aborts (rc=$rc)" [ "$rc" -ne 0 ]
check "abort reason is the unclaimable slot" grep -Fq "could not claim Treehouse pool slot" "$TMP/F.spawn"
check "no record published for F" [ ! -e "$PH/state/F.meta" ]
check "no Treehouse lease remains under F's holder" \
  [ -z "$(pool | jq -r --arg h "firstmate:$PH:F" '.[] | select(.lease_holder == $h) | .path')" ]
check "the foreign claim is left intact" grep -Fxq "task=ghost" "$(dirname "$WTA")/.fm-slot-owner"
echo "pool after F abort: $(pool | jq -c '[.[] | {name,status,lease_holder}]')"

# ---------------------------------------------------------------- S6b
say "S6b normal teardown of live tasks B, C (primary) and D (other home) still works"
rm -f "$WTD/D-WORK.txt"  # driver-planted S4 sentinel; the dirty-work guard would rightly refuse it
for spec in "$PH:B" "$PH:C" "$OH:D"; do
  h=${spec%:*}; id=${spec##*:}; w=$(canon "$(wt_of "$h" "$id")")
  teardown "$h" "$id"; rc=$?
  [ "$rc" -eq 0 ] || show "teardown $id" "$TMP/$id.td"
  check "teardown $id succeeds and returns its lease" [ "$rc:$(holder_of "$w")" = "0:" ]
done
echo "final pool: $(pool | jq -c '[.[] | {name,status,lease_holder}]')"
echo "RESULT mode=$MODE fails=$FAILS"
exit "$FAILS"
