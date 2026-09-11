#!/usr/bin/env bash
# Drives the real bin/fm-config-push.sh CLI of PRODUCT_ROOT: a primary home
# whose data/captain-shared.md header is hard-wrapped mid-phrase is pushed to a
# live secondmate home, then headers that must still be rejected are pushed.
set -u
WT=/home/mla/.no-mistakes/worktrees/c9a671237ef3/01M2746FQWNN40C4TDB9JDX78K
# shellcheck source=/dev/null
. "$WT/tests/lib.sh"
PRODUCT=${PRODUCT_ROOT:?set PRODUCT_ROOT}
fm_git_identity fmtest fmtest@example.invalid
W=$(fm_test_tmproot fm-header-evidence)
root="$W/root"
home="$W/home"
mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
touch "$home/state/.last-watcher-beat"
git init -q -b main "$root"
printf '%s\n' .fm-secondmate-home data/ state/ config/ projects/ > "$root/.gitignore"
printf 'instructions\n' > "$root/AGENTS.md"
mkdir -p "$root/bin"
printf 'echo spawn\n' > "$root/bin/fm-spawn.sh"
git -C "$root" add -A
git -C "$root" commit -qm initial
git -C "$root" worktree add -q --detach "$W/sm" HEAD
sm="$W/sm"
printf 'sm\n' > "$sm/.fm-secondmate-home"
mkdir -p "$sm/data" "$sm/state" "$sm/config" "$sm/projects"
printf 'window=firstmate:fm-sm\nkind=secondmate\nhome=%s\n' "$sm" > "$home/state/sm.meta"

push() {
  local rc=0
  printf '\n$ fm-config-push.sh\n'
  PATH=/usr/bin:/bin FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$PRODUCT/bin/fm-config-push.sh" 2>&1 | grep -E 'captain-shared|error|warning|^sm|home' || true
  PATH=/usr/bin:/bin FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$PRODUCT/bin/fm-config-push.sh" >/dev/null 2>&1 || rc=$?
  printf '[exit of an immediate re-run: %s]\n' "$rc"
}

show_sm() {
  printf -- '-- secondmate data/captain-shared.md --\n'
  if [ -f "$sm/data/captain-shared.md" ]; then cat "$sm/data/captain-shared.md"; else printf '(absent)\n'; fi
}

printf '== product under test: %s ==\n' "$PRODUCT"
printf '\n### case 1: header hard-wrapped mid-phrase (every phrase intact once reflowed)\n'
cat > "$home/data/captain-shared.md" <<'EOF'
# Shared captain preferences

This file is main-authoritative in the main
firstmate home. In secondmate homes it is
read-only in secondmate
    homes and must not be
    edited there. Route new captain-preference
discoveries to the main firstmate through marked
status or a document pointer.

reflowed-header shared body v1
EOF
push
show_sm

printf '\n### case 2 (adversarial): header genuinely missing "must not be edited there"\n'
cat > "$home/data/captain-shared.md" <<'EOF'
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.

missing-phrase shared body v2
EOF
push
show_sm

printf '\n### case 3 (adversarial): required phrase only appears after line 12, outside the header window\n'
cat > "$home/data/captain-shared.md" <<'EOF'
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.

body line 1
body line 2
body line 3
body line 4
body line 5
body line 6
and it must not be edited there
late-phrase shared body v3
EOF
push
show_sm
