#!/usr/bin/env bash
# Live driver: run the real bin/fm-teardown.sh from <firstmate-root> on a task
# whose worktree is a REAL treehouse pool slot (leased with the real treehouse
# binary in an isolated pool/HOME) blocked by a real git index.lock, from a German
# operator shell (LC_ALL unset, LANG=de_DE.UTF-8). treehouse, git and lsof are
# real; only tmux/gh/gh-axi/no-mistakes are stubbed so nothing touches the
# operator's live sessions, GitHub, or the active no-mistakes pipeline.
# Usage: teardown-live.sh <firstmate-root> <case: stale|live-holder>
set -u
ROOTDIR=$1 CASE=$2
T=$(mktemp -d /tmp/td-live.XXXX)
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.state" \
  XDG_DATA_HOME="$T/home/.data" XDG_CACHE_HOME="$T/home/.cache" TREEHOUSE_ROOT="$T/pool"
mkdir -p "$HOME" "$T/state" "$T/data" "$T/config" "$T/fakebin"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e.invalid
for s in tmux gh-axi gh no-mistakes; do printf '#!/usr/bin/env bash\nexit 0\n' > "$T/fakebin/$s"; done
printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "pr list") printf "%%s\\n" "count: 0 (showing first 0)" "pull_requests[]: []";; "pr view") exit 1;; esac\nexit 0\n' > "$T/fakebin/gh-axi"
chmod +x "$T/fakebin"/*
git init -q --bare "$T/origin.git"; git -C "$T/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin.git" "$T/_seed" 2>/dev/null
git -C "$T/_seed" commit -q --allow-empty -m baseline; git -C "$T/_seed" push -q origin main; rm -rf "$T/_seed"
git clone -q "$T/origin.git" "$T/project"; git -C "$T/project" remote set-head origin main
WT=$(cd "$T/project" && treehouse get --lease --no-fetch 2>/dev/null) || { echo "treehouse get failed"; exit 1; }
touch "$T/state/.last-watcher-beat"
printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$WT" \
  "project=$T/project" "kind=ship" "mode=no-mistakes" "spawn_gen=live-task-x1" > "$T/state/task-x1.meta"
lock=$(git -C "$WT" rev-parse --path-format=absolute --git-path index.lock)
: > "$lock"; touch -d '10 minutes ago' "$lock"
holder=
if [ "$CASE" = live-holder ]; then sleep 60 9<"$lock" & holder=$!; fi
echo "### case=$CASE root=$ROOTDIR shell: LC_ALL='' LANG=de_DE.UTF-8"
echo "### worktree (real treehouse slot): $WT"
echo "### before: index.lock present=$([ -e "$lock" ] && echo yes || echo no) age=10min live_holder=$([ -n "$holder" ] && echo yes || echo no)"
echo "### treehouse status before:"; (cd "$T/project" && treehouse status 2>&1 | sed 's/^/  /')
# FM_GATE_REFUSE_BYPASS=1: the same exemption tests/lib.sh gives firstmate's own
# suite when a no-mistakes gate runs it; this sandbox never touches the live fleet.
(cd "$T/project" && env LC_ALL= LC_MESSAGES= LANG=de_DE.UTF-8 FM_GATE_REFUSE_BYPASS=1 \
  PATH="$T/fakebin:$PATH" \
  FM_ROOT_OVERRIDE="$ROOTDIR" FM_STATE_OVERRIDE="$T/state" FM_DATA_OVERRIDE="$T/data" FM_CONFIG_OVERRIDE="$T/config" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=60 \
  "$ROOTDIR/bin/fm-teardown.sh" task-x1 > "$T/out" 2> "$T/err")
rc=$?
echo "### exit=$rc"
echo "### stdout:"; sed 's/^/  /' "$T/out"
echo "### stderr:"; sed 's/^/  /' "$T/err"
echo "### after: index.lock present=$([ -e "$lock" ] && echo yes || echo no) meta_present=$([ -e "$T/state/task-x1.meta" ] && echo yes || echo no)"
echo "### treehouse status after:"; (cd "$T/project" && treehouse status 2>&1 | sed 's/^/  /')
[ -z "$holder" ] || kill "$holder" 2>/dev/null
wait 2>/dev/null
rm -rf "$T"
