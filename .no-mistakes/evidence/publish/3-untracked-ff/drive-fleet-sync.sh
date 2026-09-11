#!/usr/bin/env bash
# Live driver: stand up an isolated firstmate home with one project clone per
# scenario under projects/, then run the real bin/fm-fleet-sync.sh (whole-fleet
# form, exactly as bootstrap invokes it) and print the transcript plus the
# resulting git state of every clone.
# Usage: drive-fleet-sync.sh <path-to-fm-fleet-sync.sh> <scratch-dir>
set -u
SYNC=$1
H=$2
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C
export GIT_AUTHOR_NAME=drv GIT_AUTHOR_EMAIL=drv@example.invalid
export GIT_COMMITTER_NAME=drv GIT_COMMITTER_EMAIL=drv@example.invalid
rm -rf "$H"; mkdir -p "$H/projects" "$H/remotes" "$H/state"
touch "$H/state/.last-watcher-beat"

commit_file() { printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -qm "$4"; }

# pair <name>: bare origin + projects/<name> clone on main + work-<name> pusher
pair() {
  local n=$1
  git init -q "$H/work-$n"; git -C "$H/work-$n" symbolic-ref HEAD refs/heads/main
  commit_file "$H/work-$n" file.txt v0 C0
  git clone -q --bare "$H/work-$n" "$H/remotes/$n.git"
  git -C "$H/work-$n" remote add origin "file://$H/remotes/$n.git"
  git -C "$H/work-$n" fetch -q origin
  git clone -q "file://$H/remotes/$n.git" "$H/projects/$n"
}
advance() { commit_file "$H/work-$1" file.txt "$2" "$2"; git -C "$H/work-$1" push -q origin main; }

# a-untracked-cache: on main, behind, only an untracked tool cache present
pair a-untracked-cache; advance a-untracked-cache C1
mkdir -p "$H/projects/a-untracked-cache/.opencode"; printf 'cache\n' > "$H/projects/a-untracked-cache/.opencode/opencode.db"

# b-detached-untracked: detached HEAD ancestor of origin/main + untracked cache
pair b-detached-untracked; advance b-detached-untracked C1
git -C "$H/projects/b-detached-untracked" checkout -q --detach
printf 'cache\n' > "$H/projects/b-detached-untracked/.tool-cache"

# c-tracked-dirty: on main, behind, tracked file modified (must stay STUCK)
pair c-tracked-dirty; advance c-tracked-dirty C1
printf 'local edit\n' >> "$H/projects/c-tracked-dirty/file.txt"

# d-tracked-plus-untracked: tracked edit AND untracked cache (must stay STUCK)
pair d-tracked-plus-untracked; advance d-tracked-plus-untracked C1
printf 'local edit\n' >> "$H/projects/d-tracked-plus-untracked/file.txt"
printf 'cache\n' > "$H/projects/d-tracked-plus-untracked/.tool-cache"

# e-ff-collision: on main; origin adds tracked new.txt; clone has untracked new.txt
pair e-ff-collision
commit_file "$H/work-e-ff-collision" new.txt from-origin "add new.txt"; git -C "$H/work-e-ff-collision" push -q origin main
printf 'local-untracked-version\n' > "$H/projects/e-ff-collision/new.txt"

# f-checkout-collision: local main has new.txt, HEAD detached one commit back,
# untracked new.txt collides with the re-attach checkout
pair f-checkout-collision
commit_file "$H/work-f-checkout-collision" new.txt from-origin "add new.txt"; git -C "$H/work-f-checkout-collision" push -q origin main
git -C "$H/projects/f-checkout-collision" pull -q --ff-only
advance f-checkout-collision C2
git -C "$H/projects/f-checkout-collision" checkout -q --detach HEAD~1
printf 'local-untracked-version\n' > "$H/projects/f-checkout-collision/new.txt"

# g-reattach-then-ff-collision: detached at local main's tip; re-attach succeeds,
# then the ff collides with an untracked file
pair g-reattach-then-ff-collision
git -C "$H/projects/g-reattach-then-ff-collision" checkout -q --detach
commit_file "$H/work-g-reattach-then-ff-collision" new.txt from-origin "add new.txt"; git -C "$H/work-g-reattach-then-ff-collision" push -q origin main
printf 'local-untracked-version\n' > "$H/projects/g-reattach-then-ff-collision/new.txt"

echo "\$ FM_HOME=$H FM_FLEET_PRUNE=0 $SYNC"
FM_HOME="$H" FM_FLEET_PRUNE=0 "$SYNC" 2>&1 | sed "s#$H#<home>#g"
echo "exit=${PIPESTATUS[0]}"
echo
echo "--- resulting clone state"
for p in "$H"/projects/*; do
  n=$(basename "$p")
  br=$(git -C "$p" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)
  at=$(git -C "$p" rev-parse --short HEAD); tip=$(git -C "$p" rev-parse --short origin/main)
  eq=behind; [ "$at" = "$tip" ] && eq=at-origin
  printf '%-30s head=%-8s %s origin/main=%s (%s)\n' "$n" "$br" "$at" "$tip" "$eq"
  git -C "$p" status --porcelain | sed 's/^/    status: /'
  [ -f "$p/new.txt" ] && printf '    new.txt: %s\n' "$(cat "$p/new.txt")"
  [ -f "$p/.opencode/opencode.db" ] && printf '    .opencode/opencode.db preserved\n'
  [ -f "$p/.tool-cache" ] && printf '    .tool-cache preserved\n'
done
