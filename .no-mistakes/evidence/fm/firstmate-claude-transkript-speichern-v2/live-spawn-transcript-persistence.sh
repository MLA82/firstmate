#!/usr/bin/env bash
# Live end-to-end: spawn a Firstmate Claude crewmate into a REAL tmux window on a
# private socket, with a stub `claude` on PATH that records the process
# environment it was actually started with. Proves the spawned Claude process
# carries CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 even when Firstmate itself runs
# with an inherited CLAUDE_CODE_CHILD_SESSION marker.
set -u
ROOT=${ROOT:?}
EV=${EV:?}
SPAWN_BIN=${SPAWN_BIN:-$ROOT/bin/fm-spawn.sh}
. "$ROOT/tests/fixtures.sh"

REAL_TMUX=$(command -v tmux)
SOCKET="fm-live-persist-$$"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-persist.XXXXXX")
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

HARNESS=${HARNESS:-claude}
KIND=${KIND:-ship}
fakebin="$TMP/fakebin"; mkdir -p "$fakebin"
cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
# stub agent CLIs: record the real process environment + argv, then idle.
for tool in claude codex; do
cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
{ printf '### argv: %s\n' "\$*"; env | sort; } > "$TMP/\${0##*/}-env.txt"
printf 'stub \${0##*/} running\n'
sleep 600
SH
chmod +x "$fakebin/$tool"
done
for t in treehouse gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$t"; chmod +x "$fakebin/$t"; done
chmod +x "$fakebin/tmux"

home="$TMP/home"; proj="$TMP/project"; wt="$TMP/wt"
fm_test_spawn_home "$home" "$HARNESS"
id=live1
fm_test_spawn_brief "$home" "$id"
fm_git_worktree "$proj" "$wt" "wt-live"

"$fakebin/tmux" new-session -d -s firstmate -x 200 -y 50
spawn_home="$home/user-home"; mkdir -p "$spawn_home"

set -x
env -u TMUX \
  CLAUDE_CODE_CHILD_SESSION=1 \
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" CLAUDE_CONFIG_DIR='' \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX="/tmp/fake,1,0" \
  PATH="$fakebin:$PATH" \
  bash "$SPAWN_BIN" "$id" "$wt" --mode local-only --yolo off --backend tmux
rc=$?
set +x
echo "spawn exit: $rc"

for i in $(seq 1 60); do [ -s "$TMP/$HARNESS-env.txt" ] && break; sleep 1; done
echo "=== tmux windows ==="
"$fakebin/tmux" list-windows -a
echo "=== pane capture ==="
for i in $(seq 1 30); do
  cap=$("$fakebin/tmux" capture-pane -p -t "firstmate:fm-$id" 2>/dev/null)
  case "$cap" in *"stub $HARNESS running"*) break ;; esac
  sleep 1
done
printf '%s\n' "$cap" | grep -v '^$' | tail -20 | tee "$EV/${LABEL:-pane}-capture-$HARNESS.txt"
echo "=== global claude settings in the spawning user's HOME after the spawn ==="
find "$spawn_home" -name 'settings.json' -o -name '.claude.json' | while read -r f; do echo "--- $f"; cat "$f"; done
echo "=== spawned $HARNESS process environment (filtered) ==="
if [ -s "$TMP/$HARNESS-env.txt" ]; then
  cp "$TMP/$HARNESS-env.txt" "$EV/${LABEL:-spawned}-$HARNESS-process-env.txt"
  grep -E '^(###|CLAUDE_|FM_|CURSOR|GEMINI)' "$TMP/$HARNESS-env.txt"
else
  echo "NO ENV CAPTURED"
fi
