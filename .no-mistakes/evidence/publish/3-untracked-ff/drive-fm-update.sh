#!/usr/bin/env bash
# Live driver: stand up an isolated firstmate checkout (clone of a bare origin)
# plus one registered secondmate home (detached linked worktree, as treehouse
# leases it), then run the real bin/fm-update.sh (the /updatefirstmate
# mechanics) and print the transcript and resulting state.
# Usage: drive-fm-update.sh <path-to-fm-update.sh> <scratch-dir> <case>
#   case = untracked | tracked | collision
set -u
UPDATE=$1
W=$2
CASE=$3
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C
export GIT_AUTHOR_NAME=drv GIT_AUTHOR_EMAIL=drv@example.invalid
export GIT_COMMITTER_NAME=drv GIT_COMMITTER_EMAIL=drv@example.invalid
rm -rf "$W"; mkdir -p "$W/home/state" "$W/home/data" "$W/fakebin" "$W/fake"
: > "$W/fake/windows"
# tmux stand-in so the secondmate window reads as live (no real tmux session).
cat > "$W/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) cat "$FM_FAKE_DIR/windows" ;;
  display-message) case "${*: -1}" in *pane_current_command*) echo claude ;; *) echo ;; esac ;;
esac
SH
chmod +x "$W/fakebin/tmux"
touch "$W/home/state/.last-watcher-beat"

git init -q --bare "$W/origin.git"; git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$W/seed" 2>/dev/null
printf 'v1\n' > "$W/seed/AGENTS.md"; printf 'r1\n' > "$W/seed/README.md"
mkdir -p "$W/seed/bin"; printf 'echo a\n' > "$W/seed/bin/tool.sh"
git -C "$W/seed" add -A; git -C "$W/seed" commit -qm c1; git -C "$W/seed" push -q origin main
git clone -q "$W/origin.git" "$W/main"
git -C "$W/main" remote set-head origin main >/dev/null 2>&1 || true

# secondmate home sm1: detached worktree + untracked identity marker
git -C "$W/main" worktree add -q --detach "$W/sm1" main
printf 'window=main:fm-sm1\nendpoint_task_id=sm1\nworktree=%s/sm1\nproject=%s/sm1\nkind=secondmate\nharness=claude\nhome=%s/sm1\n' "$W" "$W" "$W" > "$W/home/state/sm1.meta"
echo fm-sm1 >> "$W/fake/windows"
echo sm1 > "$W/sm1/.fm-secondmate-home"

# origin advances (also adds bin/collide.txt for the collision case)
printf 'v2\n' > "$W/seed/AGENTS.md"; printf 'r2\n' >> "$W/seed/README.md"
[ "$CASE" = collision ] && printf 'echo collide\n' > "$W/seed/bin/collide.txt"
git -C "$W/seed" add -A; git -C "$W/seed" commit -qm bump; git -C "$W/seed" push -q origin main

case "$CASE" in
  untracked)
    mkdir -p "$W/main/.opencode"; printf 'cache\n' > "$W/main/.opencode/opencode.db"
    printf 'cache\n' > "$W/sm1/.tool-cache"   # untracked besides the seed marker
    ;;
  tracked)
    printf 'local edit\n' >> "$W/main/README.md"
    printf 'local edit\n' >> "$W/sm1/README.md"
    echo cache > "$W/sm1/.tool-cache"
    ;;
  collision)
    printf 'local-untracked-version\n' > "$W/main/bin/collide.txt"
    ;;
esac

echo "\$ FM_ROOT_OVERRIDE=<w>/main FM_HOME=<w>/home $UPDATE   # case=$CASE"
PATH="$W/fakebin:$PATH" FM_FAKE_DIR="$W/fake" FM_ROOT_OVERRIDE="$W/main" FM_HOME="$W/home" \
  "$UPDATE" 2>&1 | sed "s#$W#<w>#g"
echo "exit=${PIPESTATUS[0]}"
echo "--- resulting state"
for t in main sm1; do
  at=$(git -C "$W/$t" rev-parse --short HEAD); tip=$(git -C "$W/$t" rev-parse --short origin/main)
  eq=behind; [ "$at" = "$tip" ] && eq=at-origin
  printf '%-5s head=%s origin/main=%s (%s)\n' "$t" "$at" "$tip" "$eq"
  git -C "$W/$t" status --porcelain | sed 's/^/    status: /'
done
[ -f "$W/main/bin/collide.txt" ] && echo "    main/bin/collide.txt: $(cat "$W/main/bin/collide.txt")"
exit 0
