#!/usr/bin/env bash
# Manual end-user drive of bin/fm-teardown.sh for Orca-backed tasks.
# usage: drive.sh <case-name> <teardown-script> <stale|match|missing-cli> <kind> [--force]
set -u
ROOT=/home/mlalocal/.no-mistakes/worktrees/3dffb74839bd/01M2TA5JKTHEMKKWCDY74NWK1J
name=$1; script=$2; mode=$3; kind=$4; force=${5:-}
dir=/tmp/orca-drive/$name
rm -rf "$dir"; mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" \
  "$dir/fakebin" "$dir/worktree/.claude" "$dir/project" "$dir/elsewhere-worktree"
git init -q "$dir/project"
: > "$dir/worktree/sentinel"; : > "$dir/runtime.log"
printf '{}' > "$dir/worktree/.claude/settings.local.json"
for t in tmux treehouse; do
cat > "$dir/fakebin/$t" <<SH
#!/usr/bin/env bash
printf '$t' >> "\${FM_RUNTIME_LOG:?}"; printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"; printf '\n' >> "\${FM_RUNTIME_LOG:?}"
exit 0
SH
chmod +x "$dir/fakebin/$t"; done

case "$mode" in
  missing-cli) : ;;  # no orca on PATH at all
  *) cat > "$dir/fakebin/orca" <<'SH'
#!/usr/bin/env bash
printf 'orca' >> "${FM_RUNTIME_LOG:?}"; printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"; printf '\n' >> "${FM_RUNTIME_LOG:?}"
if [ "$1" = worktree ] && [ "$2" = show ]; then
  if [ "${FM_TEST_ORCA_SHOW_FAILS:-0}" = 1 ]; then
    printf '{"ok":false,"error":"worktree lookup failed"}\n'; exit 1
  fi
  printf '{"ok":true,"result":{"worktree":{"path":"%s"}}}\n' "${FM_TEST_ORCA_WORKTREE_PATH:?}"; exit 0
fi
printf '{"ok":true,"result":{}}\n'; exit 0
SH
  chmod +x "$dir/fakebin/orca" ;;
esac

target=$dir/elsewhere-worktree
showfails=0
[ "$mode" = match ] && target=$dir/worktree
[ "$mode" = unresolvable ] && showfails=1
if [ "$mode" = absent ]; then showfails=1; rm -rf "$dir/worktree"; fi

id=$name
{ printf 'window=fm-%s\n' "$id"
  printf 'endpoint_task_id=%s\nterminal=term-1\n' "$id"
  printf 'worktree=%s\nproject=%s\n' "$dir/worktree" "$dir/project"
  printf 'backend=orca\norca_worktree_id=worktree-1::/orca/worktree-1\nkind=%s\n' "$kind"
  [ "$kind" = ship ] && printf 'mode=no-mistakes\n'
} > "$dir/home/state/$id.meta"

mkdir -p "$dir/home/data/$id"
printf 'scout report\n' > "$dir/home/data/$id/report.md"

( cd "$dir/worktree" && exec sleep 60 ) &
worker=$!
sleep 0.3

echo "\$ fm-teardown.sh $id $force      # backend=orca kind=$kind, orca worktree id -> $( [ "$mode" = match ] && echo 'the recorded worktree' || echo "$mode" )"
env -u TMUX -u TMUX_PANE \
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
  FM_TEST_ORCA_WORKTREE_PATH="$target" FM_TEST_ORCA_SHOW_FAILS="$showfails" \
  PATH="$dir/fakebin:$PATH" "$script" "$id" ${force:+$force} > "$dir/stdout" 2> "$dir/stderr"
rc=$?
echo "--- stdout ---"; cat "$dir/stdout"
echo "--- stderr ---"; cat "$dir/stderr"
echo "--- exit code: $rc"
if kill -0 "$worker" 2>/dev/null; then echo "worker process $worker in $dir/worktree: STILL ALIVE"; else echo "worker process $worker in $dir/worktree: KILLED"; fi
if [ ! -d "$dir/worktree" ]; then echo "recorded worktree: ABSENT on disk (as staged)"; fi
if grep -q "orca <worktree> <show>" "$dir/runtime.log"; then echo "orca worktree show: CALLED"; else echo "orca worktree show: NOT CALLED"; fi
if [ -f "$dir/worktree/.claude/settings.local.json" ]; then echo "claude hook file .claude/settings.local.json: PRESENT"; else echo "claude hook file .claude/settings.local.json: REMOVED"; fi
if [ -f "$dir/home/state/$id.meta" ]; then echo "task record $id.meta: PRESERVED"; else echo "task record $id.meta: DELETED"; fi
kill "$worker" 2>/dev/null; wait "$worker" 2>/dev/null
exit $rc
