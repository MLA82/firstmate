#!/usr/bin/env bash
# tests/fm-watch-benign-absorb.test.sh - regression tests for the benign-absorb
# delivery-record fix.
#
# Before this fix, a watcher cycle that ended after only absorbing benign events
# (no wake() call) was reported as
#   "watcher: FAILED - cycle ended without an actionable reason"
# by an attached arm, even though the watcher ran perfectly healthy - it simply
# had nothing actionable to report. The watcher publishes a delivery-ledger record
# inside watch_delivery_publish() only from wake(), so benign-absorb paths never
# wrote one. close_unobserved_cycle() in the arm found no record and failed.
#
# The fix: absorb paths now also call watch_delivery_publish with a reason starting
# "absorbed", and close_unobserved_cycle() treats "absorbed" delivery records as
# a clean close instead of FAILED.
#
# These are real-process tests: a real bin/fm-watch.sh holds the singleton, a real
# bin/fm-watch-arm.sh attaches to it, and we verify both the fixed false-positive
# and the preserved genuine-failure alarm.

set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-benign-absorb-tests)

SEED_PID=
ARM_PID=

# Start the real watcher as the singleton holder.
# Sets FM_HOME to the case's home dir so all state is isolated.
start_seed_watcher() {  # <home> <state> <fakebin> <watch-out>
  local home=$1 state=$2 fakebin=$3 out=$4 i
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "seed watcher did not take the lock"
}

# Attach a real arm to the live cycle.
start_attached_arm() {  # <home> <state> <fakebin> <arm-out> <confirm-timeout>
  local home=$1 state=$2 fakebin=$3 armout=$4 confirm=$5 i
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT="$confirm" "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$SEED_PID" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$SEED_PID" "$armout" \
    || fail "arm did not attach to the live watcher: $(cat "$armout")"
}

# --- regression: benign absorb (signal) then clean exit ---

test_attached_arm_clean_close_after_benign_signal_absorb() {
  local dir home state fakebin out armout status
  dir=$(make_case benign-signal-absorb-clean-close)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  mkdir -p "$home/data"

  # Create a benign status file: "working: step 1" is a no-verb status
  # whose crew will be classed as NOT provably working by default (unknown).
  # To make it benign, we need to set the fake verdict to provably working
  # via FM_FAKE_CREW_STATE in the watcher's environment.
  printf 'working: step 1\n' > "$state/task.status"

  # Start the watcher with a fake crew-state that classifies this task as
  # provably working, so the signal is benign and gets absorbed.
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "seed watcher did not take the lock"

  start_attached_arm "$home" "$state" "$fakebin" "$armout" 1

  # The watcher sees task.status as "working: step 1" with provably-working crew.
  # It should absorb (benign) and log "absorbed benign". Let it absorb at least
  # one full poll cycle.
  sleep 3

  # Now kill the watcher. The attached arm should find the "absorbed benign"
  # delivery record and report clean exit, not FAILED.
  kill -TERM "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true

  wait_for_exit "$ARM_PID" 120 || {
    kill -KILL "$ARM_PID" 2>/dev/null || true
    fail "attached arm did not close after benign-signal-absorb watcher exit"
  }
  status=$?

  # Verify: no FAILED line, and a clean close reason starting with "absorbed"
  grep -qF 'watcher: FAILED' "$armout" \
    && fail "attached arm reported a benign-absorb close as FAILED: $(cat "$armout")"

  # The arm should report the absorbed reason from the delivery record
  grep -qE '^absorbed ' "$armout" \
    || fail "attached arm did not report the absorbed close reason: $(cat "$armout")"

  expect_code 0 "$status" "a benign-signal-absorb close must exit cleanly"
  pass "watch-arm: attached arm reports clean close after watcher that absorbed benign signals"
}

# --- regression: benign absorb (heartbeat) then clean exit ---

test_attached_arm_clean_close_after_benign_heartbeat_absorb() {
  local dir home state fakebin out armout status
  dir=$(make_case benign-heartbeat-absorb-clean-close)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  mkdir -p "$home/data"

  # Create a benign status file so the heartbeat scan has something to scan.
  printf 'working: step 1\n' > "$state/task.status"
  # Prime the .seen-* suppressor so the heartbeat scan sees nothing new.
  prime_status_seen "$state" "$state/task.status"

  # Use a short HEARTBEAT so the heartbeat scan runs every poll cycle.
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=1 \
    FM_HEARTBEAT=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$WATCH" > "$out" &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "seed watcher did not take the lock"

  start_attached_arm "$home" "$state" "$fakebin" "$armout" 1

  # Heartbeat scan will find task.status but the .seen-* suppressor means
  # nothing actionable. The watcher absorbs and logs "absorbed heartbeat".
  # FM_HEARTBEAT=1 means the first heartbeat runs after ~1s, then doubles.
  # Wait 2s to ensure at least one heartbeat cycle completes.
  sleep 3

  # Kill the watcher. The attached arm should find the "absorbed heartbeat"
  # delivery record and report clean exit.
  kill -TERM "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true

  wait_for_exit "$ARM_PID" 120 || {
    kill -KILL "$ARM_PID" 2>/dev/null || true
    fail "attached arm did not close after benign-heartbeat-absorb watcher exit"
  }
  status=$?

  # Verify: no FAILED line
  grep -qF 'watcher: FAILED' "$armout" \
    && fail "attached arm reported a benign-heartbeat-absorb close as FAILED: $(cat "$armout")"

  # The arm should report the absorbed heartbeat reason
  grep -qE '^absorbed heartbeat' "$armout" \
    || fail "attached arm did not report the absorbed heartbeat reason: $(cat "$armout")"

  expect_code 0 "$status" "a benign-heartbeat-absorb close must exit cleanly"
  pass "watch-arm: attached arm reports clean close after watcher that absorbed benign heartbeat"
}

# --- regression: genuine failure still fails ---

test_attached_arm_still_fails_when_no_delivery_record_at_all() {
  local dir home state fakebin out armout
  dir=$(make_case benign-absorb-no-record-genuine-failure)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  mkdir -p "$home/data"

  # Start a real watcher. No status files at all - the watcher will silently
  # loop (no pending, no stale, no heartbeat actionable). No delivery record
  # will ever be published.
  start_seed_watcher "$home" "$state" "$fakebin" "$out"
  start_attached_arm "$home" "$state" "$fakebin" "$armout" 1

  # Give the arm time to fully attach and settle before we kill the watcher.
  # This ensures the arm's cycle_watcher_pid/identity are correctly set.
  sleep 1

  # Kill the watcher abruptly before any poll cycle completes. This simulates a
  # genuinely unexplained gap: the watcher process was destroyed before it could
  # publish any delivery record (no wake, no absorb, nothing).
  kill -KILL "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true

  # The arm must still detect this as FAILED because there is no delivery record
  # at all - not a wake record and not an absorbed record. This is the real safety
  # property that must not be weakened.
  # Wait for the arm to exit (it will exit with code 1 because it reports FAILED).
  # We poll kill -0 and then call wait ourselves to capture the exit code.
  i=0
  arm_exit=124
  while [ "$i" -lt 300 ]; do
    if ! kill -0 "$ARM_PID" 2>/dev/null; then
      wait "$ARM_PID" 2>/dev/null
      arm_exit=$?
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$i" -ge 300 ]; then
    kill -KILL "$ARM_PID" 2>/dev/null || true
    fail "arm did not close after abrupt watcher kill"
  fi

  # The genuine failure case: no delivery record at all -> FAILED
  # The arm should have exited nonzero (code 1 = fail_unexplained_cycle)
  [ "$arm_exit" -ne 0 ] || fail "arm exited 0 when it should have failed: $(cat "$armout")"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "genuine failure (no delivery record) was not reported as FAILED: $(cat "$armout")"

  pass "watch-arm: a cycle with no delivery record at all still fails loudly"
}

test_attached_arm_clean_close_after_benign_signal_absorb
test_attached_arm_clean_close_after_benign_heartbeat_absorb
test_attached_arm_still_fails_when_no_delivery_record_at_all
