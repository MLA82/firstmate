#!/usr/bin/env bash
# Live driver for PR 3723 (teardown safety): runs the real bin/fm-teardown.sh
# against REAL Treehouse pool slots leased by the real `treehouse` binary, in an
# isolated HOME/TREEHOUSE_ROOT sandbox under /tmp. Only tmux, no-mistakes, gh
# and gh-axi are stubbed (no tmux on this host; the others would reach GitHub
# or a live pipeline daemon). The Claude hook is written with fm-spawn.sh's
# own shell_quote/json_escape, extracted from the source under test.
# Usage: live-driver.sh <repo-root> <scenario>
set -u
ROOT=$1; SCEN=$2
REAL_TREEHOUSE=$(command -v treehouse)
REAL_TASKS_AXI=$(command -v tasks-axi)
eval "$(sed -n '/^shell_quote() {/,/^}/p; /^json_escape() {/,/^}/p' "$ROOT/bin/fm-spawn.sh")"

C=$(mktemp -d "/tmp/nm-live-teardown.$SCEN.XXXXXX")
export HOME="$C/home" TREEHOUSE_ROOT="$C/pool-root" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$TREEHOUSE_ROOT" "$C/fm/state" "$C/fm/data" "$C/fm/config" "$C/fakebin"
git config --global user.email live@example.invalid; git config --global user.name live
git config --global init.defaultBranch main
for t in tmux gh gh-axi no-mistakes; do printf '#!/usr/bin/env bash\nexit 0\n' > "$C/fakebin/$t"; chmod +x "$C/fakebin/$t"; done
git init -q --bare "$C/origin.git"
git clone -q "$C/origin.git" "$C/seed" 2>/dev/null
git -C "$C/seed" commit -q --allow-empty -m base; git -C "$C/seed" push -q origin main; rm -rf "$C/seed"
git clone -q "$C/origin.git" "$C/project" 2>/dev/null; git -C "$C/project" remote set-head origin main
PROJ=$C/project
SLOT=$(cd "$PROJ" && "$REAL_TREEHOUSE" get --lease --no-fetch --lease-holder live-driver 2>/dev/null)
STATE_REAL=$(cd "$C/fm/state" && pwd -P)
touch "$C/fm/state/.last-watcher-beat"

write_spawn_claude_hook() {  # <worktree> <state_real> <id> -- fm-spawn.sh's exact claude hook body
  local wt=$1 st=$2 id=$3 busy_cmd_prefix busy_suffix j_submit j_stop j_stopfail j_sessionend
  mkdir -p "$wt/.claude"
  busy_cmd_prefix="$(shell_quote "$ROOT/bin/fm-busy-event.sh") apply $(shell_quote "$st") $(shell_quote "$id")"
  busy_suffix="--gen $(shell_quote gen-live) --source claude-hook"
  j_submit=$(json_escape "$busy_cmd_prefix busy $busy_suffix --event user-prompt-submit 2>/dev/null || true")
  j_stop=$(json_escape "touch $(shell_quote "$st/$id.turn-ended"); $busy_cmd_prefix idle $busy_suffix --event stop 2>/dev/null || true")
  j_stopfail=$(json_escape "$busy_cmd_prefix idle $busy_suffix --event stop-failure 2>/dev/null || true")
  j_sessionend=$(json_escape "$busy_cmd_prefix idle $busy_suffix --event session-end 2>/dev/null || true")
  cat > "$wt/.claude/settings.local.json" <<EOF
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$j_submit"}]}],"Stop":[{"hooks":[{"type":"command","command":"$j_stop"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"$j_stopfail"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"$j_sessionend"}]}]}}
EOF
  printf '%s\n' '.claude/settings.local.json' >> "$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude)"
}

seed_backlog() {
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$C/fm/data/backlog.md"
  "$REAL_TASKS_AXI" add task-live "live teardown task" --kind ship --file "$C/fm/data/backlog.md" >/dev/null
  "$REAL_TASKS_AXI" start task-live --file "$C/fm/data/backlog.md" >/dev/null
}
row_state() { "$REAL_TASKS_AXI" show task-live --file "$C/fm/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
write_meta() {  # <worktree> <project>
  printf '%s\n' "window=firstmate:fm-task-live" "endpoint_task_id=task-live" "worktree=$1" "project=$2" \
    "harness=claude" "kind=ship" "mode=local-only" "spawn_gen=live-gen" > "$C/fm/state/task-live.meta"
}
run_teardown() {  # [PATH-override] -- extra args follow
  local path=${TEARDOWN_PATH:-$PATH}
  # This driver itself runs inside a no-mistakes gate worktree; use the same
  # documented test-harness hatch tests/lib.sh exports (bin/fm-gate-refuse-lib.sh).
  FM_GATE_REFUSE_BYPASS=1 \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$C/fm" FM_STATE_OVERRIDE="$C/fm/state" \
    FM_DATA_OVERRIDE="$C/fm/data" FM_CONFIG_OVERRIDE="$C/fm/config" \
    PATH="$C/fakebin:$path" "$ROOT/bin/fm-teardown.sh" task-live "$@"
}
th_status() { (cd "$PROJ" && "$REAL_TREEHOUSE" status) 2>&1 | sed "s#$C#\$SANDBOX#g"; }
show() { printf '%-44s %s\n' "$1" "$2"; }
exists() { [ -e "$1" ] && echo present || echo absent; }

echo "=== scenario: $SCEN   (sandbox \$SANDBOX=$C)"
echo "real treehouse: $REAL_TREEHOUSE ($("$REAL_TREEHOUSE" --version 2>&1))"
echo "leased slot:    ${SLOT/#$C/\$SANDBOX}"
seed_backlog
write_spawn_claude_hook "$SLOT" "$STATE_REAL" task-live
echo "--- spawn-format Stop hook command in the slot:"
jq -r '.hooks.Stop[0].hooks[0].command' "$SLOT/.claude/settings.local.json" | sed "s#$C#\$SANDBOX#g"

case "$SCEN" in
  happy-pool-slot)
    write_meta "$SLOT" "$PROJ"
    echo "--- treehouse status BEFORE:"; th_status
    rc=0; run_teardown > "$C/out" 2> "$C/err" || rc=$?
    ;;
  incident-primary-checkout)
    # 2026-08-26 incident shape: worktree= names the PRIMARY checkout itself,
    # with a live process rooted there. --force must not bypass the refusal.
    write_meta "$PROJ" "$PROJ"
    ( cd "$PROJ" && exec sleep 300 ) & SLEEPER=$!; disown; sleep 0.3
    echo "--- live process rooted in primary checkout: pid $SLEEPER cwd=$(readlink /proc/$SLEEPER/cwd | sed "s#$C#\$SANDBOX#")"
    rc=0; run_teardown --force > "$C/out" 2> "$C/err" || rc=$?
    ;;
  wrong-project-real-pool-slot)
    # worktree= IS a real, leased Treehouse pool slot - but of ANOTHER project,
    # while project= names this one (stale/wrong project=). Must refuse.
    git init -q --bare "$C/other.git"; git clone -q "$C/other.git" "$C/otherseed" 2>/dev/null
    git -C "$C/otherseed" commit -q --allow-empty -m o; git -C "$C/otherseed" push -q origin main; rm -rf "$C/otherseed"
    git clone -q "$C/other.git" "$C/other" 2>/dev/null
    OTHER_SLOT=$(cd "$C/other" && "$REAL_TREEHOUSE" get --lease --no-fetch --lease-holder other 2>/dev/null)
    echo "other project's real leased slot: ${OTHER_SLOT/#$C/\$SANDBOX}"
    write_meta "$OTHER_SLOT" "$PROJ"
    ( cd "$OTHER_SLOT" && exec sleep 300 ) & SLEEPER=$!; disown; sleep 0.3
    rc=0; run_teardown --force > "$C/out" 2> "$C/err" || rc=$?
    ;;
  forged-symlinked-pool-state)
    # A linked worktree of the SAME repo laid out as <fakepool>/<slot>/<repo>,
    # whose <fakepool>/treehouse-state.json is a symlink to the real pool's
    # state file. The offline proof must not accept a symlinked state file.
    real_state="$(dirname "$(dirname "$SLOT")")/treehouse-state.json"
    mkdir -p "$C/fakepool/9"; ln -s "$real_state" "$C/fakepool/treehouse-state.json"
    git -C "$PROJ" worktree add -q --detach "$C/fakepool/9/project" main
    write_meta "$C/fakepool/9/project" "$PROJ"
    ( cd "$C/fakepool/9/project" && exec sleep 300 ) & SLEEPER=$!; disown; sleep 0.3
    rc=0; run_teardown --force > "$C/out" 2> "$C/err" || rc=$?
    ;;
  missing-treehouse-binary)
    # Real pool slot, non-orca, but treehouse genuinely absent from PATH.
    write_meta "$SLOT" "$PROJ"
    mkdir -p "$C/nothpath"
    for cmd in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id jq ln \
      lsof mkdir mktemp mv node perl ps readlink realpath rm sed sh sleep sort stat tail timeout tr uname wc xargs flock; do
      r=$(command -v "$cmd" 2>/dev/null) && ln -sf "$r" "$C/nothpath/$cmd"
    done
    ln -sf "$REAL_TASKS_AXI" "$C/nothpath/tasks-axi"
    echo "command -v treehouse under teardown PATH: $(PATH="$C/fakebin:$C/nothpath" command -v treehouse || echo '<none>')"
    rc=0; TEARDOWN_PATH="$C/nothpath" run_teardown > "$C/out" 2> "$C/err" || rc=$?
    ;;
  treehouse-status-errors)
    # Real treehouse for everything except `status`, which errors (fault injection).
    write_meta "$SLOT" "$PROJ"
    cat > "$C/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = status ]; then echo "treehouse: injected status failure" >&2; exit 1; fi
exec "$REAL_TREEHOUSE" "\$@"
SH
    chmod +x "$C/fakebin/treehouse"
    rc=0; run_teardown > "$C/out" 2> "$C/err" || rc=$?
    ;;
  hook-for-other-home)
    # The slot's hook belongs to ANOTHER home's state dir (same task id): a
    # successful teardown must leave it alone, never blind-rm it.
    mkdir -p "$C/otherhome/state"
    write_spawn_claude_hook "$SLOT" "$(cd "$C/otherhome/state" && pwd -P)" task-live
    write_meta "$SLOT" "$PROJ"
    rc=0; run_teardown > "$C/out" 2> "$C/err" || rc=$?
    ;;
esac

echo "--- teardown exit code: $rc"
echo "--- teardown stderr:"; sed "s#$C#\$SANDBOX#g" "$C/err"
echo "--- observable state AFTER:"
show "claude hook in real pool slot:" "$(exists "$SLOT/.claude/settings.local.json")"
show "state/task-live.meta:" "$(exists "$C/fm/state/task-live.meta")"
show "state/task-live.backlog-close marker:" "$(exists "$C/fm/state/task-live.backlog-close")"
show "backlog row state:" "$(row_state)"
if [ -n "${SLEEPER:-}" ]; then
  if kill -0 "$SLEEPER" 2>/dev/null; then show "live process pid $SLEEPER:" "ALIVE (untouched)"; else show "live process pid $SLEEPER:" "KILLED"; fi
  kill -KILL "$SLEEPER" 2>/dev/null || true
fi
echo "--- treehouse status AFTER (real binary, this project's pool):"; th_status
echo "$C" >> /tmp/nm-live-teardown.sandboxes
exit 0
