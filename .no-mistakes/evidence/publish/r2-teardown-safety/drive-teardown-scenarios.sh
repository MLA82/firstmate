#!/usr/bin/env bash
# Drives the real bin/fm-teardown.sh against isolated, throwaway fixture homes
# for every scenario PR #3723 (teardown safety) must satisfy. It reuses the
# repository's own fixture builders from tests/fm-teardown.test.sh and
# tests/fm-backend-orca.test.sh (minus their full call lists) and prints a
# reviewer-readable transcript: exit code, the tail of teardown's stderr, and
# the on-disk state (hook file, meta, backlog-close marker, live processes).
#
# Scripts under test:
#   HEAD     = the worktree's bin/fm-teardown.sh (target 3ec10a7)
#   PRE-FIX  = PR head before ee6e265 (dfa1772), extracted to /tmp
#   BASE     = upstream base 4768e98, extracted to /tmp
set -u
WT=/home/mla/.no-mistakes/worktrees/c9a671237ef3/01M276FCJKMVV160YFQ47CQ4M3
HEAD_TD="$WT/bin/fm-teardown.sh"
PREFIX_TD=/tmp/fm-prefix-dfa1772/bin/fm-teardown.sh
BASE_TD=/tmp/fm-base-4768e98/bin/fm-teardown.sh
H=$(mktemp -d /tmp/fm-drive-harness.XXXXXX)
sed -e "59s#.*#. \"$WT/tests/lib.sh\"#" "$WT/tests/fm-teardown.test.sh" | head -n 3978 > "$H/teardown-harness.sh"
# The Orca suite calls its tests inline between definitions; drop every bare
# top-level test call so sourcing it only defines helpers and test functions.
sed -e "7s#.*#. \"$WT/tests/lib.sh\"#" -e '/^test_[a-z0-9_]*$/d' "$WT/tests/fm-backend-orca.test.sh" > "$H/orca-harness.sh"

banner() { printf '\n==================== %s ====================\n' "$*"; }
present() { if [ -e "$1" ]; then echo PRESENT; else echo ABSENT; fi; }

# A PATH with every tool teardown needs EXCEPT treehouse (the real host has a
# real treehouse at ~/.local/bin; it must not leak back in).
path_without_treehouse() {  # <case_dir>
  local p
  p=$(make_path_without_treehouse "$1")
  ln -sf "$(command -v tasks-axi)" "$p/tasks-axi"
  printf '%s\n' "$p"
}

# S1: missing treehouse binary must preserve the Claude hook (the finding).
# Orca main task: the path that runs remove_claude_hook_file and still
# completes when treehouse is entirely absent.
s_missing_treehouse_orca() {  # <label> <teardown-script>
  . "$H/teardown-harness.sh"
  TEARDOWN=$2
  local case_dir rc p
  case_dir=$(make_case "hook-no-treehouse-$1")
  rm -f "$case_dir/fakebin/treehouse"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "endpoint_task_id=task-x1" "terminal=term-task-x1" \
    "worktree=$case_dir/wt" "project=$case_dir/project" "harness=claude" \
    "kind=ship" "mode=local-only" "backend=orca" "orca_worktree_id=orca-wt-task-x1"
  add_claude_hook "$case_dir"
  cat > "$case_dir/fakebin/orca" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = worktree ] && [ "\${2:-}" = show ]; then
  printf '{"ok":true,"result":{"worktree":{"id":"orca-wt-task-x1","path":"$case_dir/wt"}}}\n'
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/orca"
  p=$(path_without_treehouse "$case_dir")
  echo "script under test: $TEARDOWN"
  echo "treehouse on teardown PATH: $(PATH="$case_dir/fakebin:$p"; command -v treehouse || echo '<none>')"
  echo "hook before teardown: $(present "$case_dir/wt/.claude/settings.local.json")"
  rc=0
  FM_TEARDOWN_TEST_PATH=$p run_teardown "$case_dir" --force >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  echo "teardown exit code: $rc"
  echo "--- teardown stderr (tail) ---"; tail -n 8 "$case_dir/stderr"
  echo "--- after ---"
  echo "hook file (.claude/settings.local.json): $(present "$case_dir/wt/.claude/settings.local.json")"
  echo "task meta: $(present "$case_dir/state/task-x1.meta")"
}

# S2 (adversarial): a normal treehouse-backend task on a real pool slot with
# the treehouse binary missing. The offline pool-slot proof must NOT refuse it
# (a missing binary cannot block the guard), and the hook must still be kept.
s_missing_treehouse_pool_slot() {
  . "$H/teardown-harness.sh"
  TEARDOWN=$HEAD_TD
  local case_dir rc p
  case_dir=$(make_case hook-no-treehouse-poolslot)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  add_claude_hook "$case_dir"
  rm -f "$case_dir/fakebin/treehouse"
  p=$(path_without_treehouse "$case_dir")
  echo "script under test: $TEARDOWN"
  echo "treehouse on teardown PATH: $(PATH="$case_dir/fakebin:$p"; command -v treehouse || echo '<none>')"
  echo "worktree is <pool>/<slot>/<repo> with pool treehouse-state.json: $(present "$(dirname "$(dirname "$case_dir/wt")")/treehouse-state.json")"
  rc=0
  FM_TEARDOWN_TEST_PATH=$p run_teardown "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  echo "teardown exit code: $rc"
  echo "--- teardown stderr (tail) ---"; tail -n 8 "$case_dir/stderr"
  echo "--- after ---"
  if grep -q "is not a Treehouse pool slot" "$case_dir/stderr"; then
    echo "pool-slot guard refused: YES (wrong)"
  else
    echo "pool-slot guard refused: no"
  fi
  echo "hook file (.claude/settings.local.json): $(present "$case_dir/wt/.claude/settings.local.json")"
}

# S3: `treehouse status` errors -> hook preserved (already fixed, must stay).
s_status_error() {
  . "$H/teardown-harness.sh"
  local case_dir rc
  case_dir=$(make_case hook-status-error)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  add_claude_hook "$case_dir"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then echo "treehouse: internal error" >&2; exit 1; fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  run_teardown "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  echo "treehouse status: exits 1 ('internal error'); every other treehouse call succeeds"
  echo "teardown exit code: $rc"
  echo "hook file (.claude/settings.local.json): $(present "$case_dir/wt/.claude/settings.local.json")"
  echo "task meta: $(present "$case_dir/state/task-x1.meta")"
}

# S4: treehouse reachable and the slot is NOT in use -> hook removed (the
# cleanup still does its job; the fix must not turn into "never remove").
s_not_in_use_removed() {
  . "$H/teardown-harness.sh"
  local case_dir rc
  case_dir=$(make_case hook-not-in-use)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  add_claude_hook "$case_dir"
  echo "hook before teardown: $(present "$case_dir/wt/.claude/settings.local.json")"
  rc=0
  run_teardown "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  echo "treehouse status: succeeds, slot not listed in-use"
  echo "teardown exit code: $rc"
  echo "hook file (.claude/settings.local.json): $(present "$case_dir/wt/.claude/settings.local.json")"
  echo "task meta: $(present "$case_dir/state/task-x1.meta")"
}

# S5: recorded worktree= is a real checkout of the same repo but NOT a pool
# slot -> refused before any process is touched and before the durable
# backlog-close marker; optionally with treehouse missing too (the offline
# proof must still refuse, not fail open).
s_non_pool_refusal() {  # <treehouse: present|absent>
  . "$H/teardown-harness.sh"
  local case_dir rc not_pool pid p=""
  case_dir=$(make_case "non-pool-refusal-$1")
  not_pool="$case_dir/primary/checkout"
  mkdir -p "$case_dir/primary"
  git -C "$case_dir/project" worktree add -q --detach "$not_pool" main
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$not_pool" \
    "project=$case_dir/project" "kind=ship" "mode=local-only" "spawn_gen=teardown-test-task-x1"
  seed_backlog_in_flight "$case_dir"
  if [ "$1" = absent ]; then
    rm -f "$case_dir/fakebin/treehouse"
    p=$(path_without_treehouse "$case_dir")
  fi
  ( cd "$not_pool" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  echo "treehouse binary: $1"
  echo "live process rooted in recorded worktree before teardown: pid $pid alive=$(kill -0 "$pid" 2>/dev/null && echo yes || echo no)"
  rc=0
  FM_TEARDOWN_TEST_PATH=${p:-$PATH} run_teardown "$case_dir" --force >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  echo "teardown exit code: $rc (run with --force)"
  echo "--- teardown stderr (tail) ---"; tail -n 4 "$case_dir/stderr"
  echo "--- after ---"
  echo "process in recorded worktree still alive: $(kill -0 "$pid" 2>/dev/null && echo yes || echo NO-KILLED)"
  echo "'reaping leaked' in stderr: $(grep -q 'reaping leaked' "$case_dir/stderr" && echo YES || echo no)"
  echo "task meta: $(present "$case_dir/state/task-x1.meta")"
  echo "backlog-close marker (state/task-x1.backlog-close): $(present "$case_dir/state/task-x1.backlog-close")"
  echo "backlog row: $(backlog_row_state "$case_dir")"
  kill -KILL "$pid" 2>/dev/null || true
}

# S6: Orca id/path mismatch with a live process in the recorded worktree ->
# Orca's own registry proof refuses BEFORE the reap (the already-fixed Orca
# reap-before-proof ordering), so the process survives.
s_orca_mismatch_sleeper() {  # <label> <teardown-script>
  . "$H/orca-harness.sh"
  local td=$2 proj wt other_wt data state config id out rc neutral pid
  id="orcasleepmismatch$1"
  proj="$TMP_ROOT/sm-project"; wt="$TMP_ROOT/sm-wt"; other_wt="$TMP_ROOT/sm-other-wt"
  data="$TMP_ROOT/sm-data"; state="$TMP_ROOT/sm-state"; config="$TMP_ROOT/sm-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet -b "fm/$id-other" "$other_wt"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-sm" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-sm" "decisions_reviewed=1" "decision_keys="
  orca_case "sleeper-mismatch-$1"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-sm","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  ( cd "$wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  echo "script under test: $td"
  echo "orca registry says wt-sm -> $other_wt; meta says worktree=$wt"
  rc=0
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$td" "$id" 2>&1 ) || rc=$?
  echo "teardown exit code: $rc"
  echo "--- teardown output (tail) ---"; printf '%s\n' "$out" | tail -n 4
  echo "--- after ---"
  echo "process in recorded worktree still alive: $(kill -0 "$pid" 2>/dev/null && echo yes || echo NO-KILLED)"
  echo "'reaping leaked' in output: $(printf '%s' "$out" | grep -q 'reaping leaked' && echo YES || echo no)"
  echo "task meta: $(present "$state/$id.meta")"
  kill -KILL "$pid" 2>/dev/null || true
}

run_existing() {  # <harness> <test_fn>
  ( . "$H/$1"; "$2" ) 2>&1 | tail -n 3
}

banner "S1a missing treehouse binary preserves Claude hook - HEAD (fixed)"
( s_missing_treehouse_orca head "$HEAD_TD" )
banner "S1b same scenario - PRE-FIX dfa1772 (reproduces the reported bug)"
( s_missing_treehouse_orca prefix "$PREFIX_TD" )
banner "S1c repo regression test test_claude_hook_left_when_treehouse_binary_is_missing - HEAD"
run_existing teardown-harness.sh test_claude_hook_left_when_treehouse_binary_is_missing
banner "S2 adversarial: pool-slot task, treehouse binary missing - HEAD"
( s_missing_treehouse_pool_slot )
banner "S3 treehouse status errors -> hook preserved - HEAD"
( s_status_error )
run_existing teardown-harness.sh test_claude_hook_left_when_treehouse_status_is_inconclusive
banner "S4 slot not in use -> hook removed - HEAD"
( s_not_in_use_removed )
run_existing teardown-harness.sh test_claude_hook_removed_when_worktree_not_in_use
run_existing teardown-harness.sh test_claude_hook_left_when_worktree_is_in_use
banner "S5a non-pool worktree= refused before reap and before close marker - HEAD, treehouse present"
( s_non_pool_refusal present )
banner "S5b same, treehouse binary missing (offline proof must still refuse) - HEAD"
( s_non_pool_refusal absent )
run_existing teardown-harness.sh test_worktree_not_a_pool_slot_refuses_before_reaping_anything
banner "S6a Orca id/path mismatch with live process - HEAD"
( s_orca_mismatch_sleeper head "$HEAD_TD" )
banner "S6b same scenario - BASE 4768e98 (before the Orca ordering fix)"
( s_orca_mismatch_sleeper base "$BASE_TD" )
banner "S7 Orca worktree outside any treehouse pool still tears down - HEAD"
run_existing orca-harness.sh test_scout_teardown_orca_worktree_not_in_treehouse_pool_still_succeeds
run_existing orca-harness.sh test_scout_teardown_refuses_orca_id_path_mismatch
run_existing orca-harness.sh test_scout_teardown_removes_orca_worktree_via_helper

rm -rf "$H"
