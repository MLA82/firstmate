#!/usr/bin/env bash
# Live end-to-end: spawn a Firstmate Claude SECONDMATE into a REAL tmux window
# and record the process environment the secondmate's claude process started with.
set -u
ROOT=${ROOT:?}
EV=${EV:?}
. "$ROOT/tests/fixtures.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-live-sm-$$"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-sm.XXXXXX")
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT
fakebin="$TMP/fakebin"; mkdir -p "$fakebin"
cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
{ printf '### argv: %s\n' "\$*"; env | sort; } > "$TMP/claude-env.txt"
printf 'stub claude secondmate running\n'
sleep 600
SH
for t in treehouse gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$t"; chmod +x "$fakebin/$t"; done
chmod +x "$fakebin/tmux" "$fakebin/claude"

home="$TMP/home"; smhome="$TMP/smhome"
fm_test_spawn_home "$home" claude
id=sm1
mkdir -p "$smhome/bin" "$smhome/data"
printf '# Firstmate\n' > "$smhome/AGENTS.md"
printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
printf 'charter for %s\n' "$id" > "$smhome/data/charter.md"
"$fakebin/tmux" new-session -d -s firstmate -x 200 -y 50
spawn_home="$home/user-home"; mkdir -p "$spawn_home"
env -u TMUX CLAUDE_CODE_CHILD_SESSION=1 \
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" CLAUDE_CONFIG_DIR='' \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX="/tmp/fake,1,0" PATH="$fakebin:$PATH" \
  bash "$ROOT/bin/fm-spawn.sh" "$id" "$smhome" --harness claude --secondmate
echo "spawn exit: $?"
for i in $(seq 1 60); do [ -s "$TMP/claude-env.txt" ] && break; sleep 1; done
echo "=== tmux windows ==="; "$fakebin/tmux" list-windows -a
echo "=== pane capture ==="
for i in $(seq 1 20); do
  cap=$("$fakebin/tmux" capture-pane -p -t "firstmate:fm-$id" 2>/dev/null)
  case "$cap" in *"secondmate running"*) break ;; esac; sleep 1
done
printf '%s\n' "$cap" | grep -v '^$' | tail -15 | tee "$EV/secondmate-pane-capture.txt"
echo "=== spawned secondmate claude process environment (filtered) ==="
if [ -s "$TMP/claude-env.txt" ]; then
  cp "$TMP/claude-env.txt" "$EV/secondmate-claude-process-env.txt"
  grep -E '^(###|CLAUDE_CODE_)' "$TMP/claude-env.txt"
else echo "NO ENV CAPTURED"; fi
