#!/usr/bin/env bash
# Live driver: run the real bin/fm-fleet-sync.sh from <firstmate-root> against a
# real clone whose `git fetch --prune` hits a real .git/packed-refs.lock, from a
# German operator shell (LC_ALL unset, LANG=de_DE.UTF-8). No git/lsof fakes.
# Usage: fleet-sync-live.sh <firstmate-root> <case: stale|transient|live-holder|non-lock>
set -u
ROOTDIR=$1 CASE=$2
T=$(mktemp -d /tmp/fleet-live.XXXX)
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e.invalid
home="$T/home"; mkdir -p "$home/projects"
git init -q "$T/work"; git -C "$T/work" symbolic-ref HEAD refs/heads/main
echo v0 > "$T/work/f"; git -C "$T/work" add f; git -C "$T/work" commit -qm C0
git -C "$T/work" branch feature
git clone -q --bare "$T/work" "$T/origin.git"
git clone -q "file://$T/origin.git" "$home/projects/demo"
clone="$home/projects/demo"
git -C "$clone" pack-refs --all                      # origin/feature now lives in packed-refs
git -C "$T/origin.git" branch -q -D feature           # so --prune must rewrite packed-refs
echo v1 > "$T/work/f"; git -C "$T/work" commit -qam C1
git -C "$T/work" push -q "$T/origin.git" main         # origin one commit ahead: sync must fast-forward
want=$(git -C "$T/origin.git" rev-parse main)
lock="$clone/.git/packed-refs.lock"
holder=
wait_secs=0
case "$CASE" in
  stale)       : > "$lock"; touch -d '10 minutes ago' "$lock" ;;
  # fresh lock (not provably stale) that the "dying owner" releases only once
  # fleet-sync has reported the first blocked fetch, i.e. during its retry wait
  transient)   : > "$lock"; wait_secs=2
               ( for _ in $(seq 150); do grep -q 'fetch blocked' "$T/err" 2>/dev/null && { rm -f "$lock"; break; }; sleep 0.1; done ) & ;;
  live-holder) touch -d '10 minutes ago' "$lock"; sleep 60 9>>"$lock" & holder=$!; touch -d '10 minutes ago' "$lock" ;;
  non-lock)    git -C "$clone" remote set-url origin "file://$T/does-not-exist.git" ;;
esac
echo "### case=$CASE root=$ROOTDIR shell: LC_ALL='' LANG=de_DE.UTF-8"
echo "### before: clone HEAD=$(git -C "$clone" rev-parse --short HEAD) origin/main=$(git -C "$T/origin.git" rev-parse --short main) lock_present=$([ -e "$lock" ] && echo yes || echo no)"
env LC_ALL= LC_MESSAGES= LANG=de_DE.UTF-8 \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOTDIR" \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=$wait_secs \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=60 \
  "$ROOTDIR/bin/fm-fleet-sync.sh" demo > "$T/out" 2> "$T/err"
rc=$?
echo "### exit=$rc"
echo "### stdout:"; sed 's/^/  /' "$T/out"
echo "### stderr:"; sed 's/^/  /' "$T/err"
head_now=$(git -C "$clone" rev-parse HEAD)
echo "### after: clone HEAD=$(git -C "$clone" rev-parse --short HEAD) fast_forwarded=$([ "$head_now" = "$want" ] && echo yes || echo no) lock_present=$([ -e "$lock" ] && echo yes || echo no) origin/feature_pruned=$(git -C "$clone" show-ref -q refs/remotes/origin/feature && echo no || echo yes)"
[ -z "$holder" ] || kill "$holder" 2>/dev/null
wait 2>/dev/null
rm -rf "$T"
