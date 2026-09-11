#!/usr/bin/env bash
# sig-cleanup-repro.sh <repo-root>
# Drives a real test process sourcing <repo-root>/tests/lib.sh that blocks a
# fixture directory with fm_dir_block_writes inside a command substitution
# (the shape of fm-session-start.test.sh:841 / fm-sessionstart-nudge.test.sh:1018),
# then delivers TERM to the whole process group - what fm-test-run.sh's
# per-script timeout (bin/fm-timeout-lib.sh) does - before fm_dir_unblock_writes
# runs. Reports whether the fixture temp root survived cleanup.
set -u
repo=$1
work=$(mktemp -d /tmp/fm-sigrepro.XXXXXX)
cat > "$work/victim.test.sh" <<'EOF'
#!/usr/bin/env bash
. "$1/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-sigrepro-fixture)
printf '%s\n' "$TMP_ROOT" > "$2/tmproot"
mkdir -p "$TMP_ROOT/home/state"
echo data > "$TMP_ROOT/home/state/entry"
out=$(fm_dir_block_writes "$TMP_ROOT/home/state"; : > "$2/blocked"; sleep 30; fm_dir_unblock_writes "$TMP_ROOT/home/state")
pass "unreachable: signal should have landed first"
EOF
setsid bash "$work/victim.test.sh" "$repo" "$work" &
pid=$!
for _ in $(seq 200); do [ -f "$work/blocked" ] && break; sleep 0.05; done
root=$(cat "$work/tmproot")
echo "lib.sh under test: $repo/tests/lib.sh (uid $(id -u))"
echo "fixture root: $root"
echo "state dir mode while blocked: $(stat -c %a "$root/home/state")"
kill -TERM -- "-$pid"
wait "$pid"
echo "test process exit after group TERM: $?"
if [ -e "$root" ]; then
  echo "RESULT: fixture root LEFT BEHIND after cleanup:"
  find "$root" -printf '  %M %p\n' 2>&1
  chmod -R u+w "$root"; rm -rf "$root"
else
  echo "RESULT: fixture root removed by fm_test_cleanup"
fi
rm -rf "$work"
