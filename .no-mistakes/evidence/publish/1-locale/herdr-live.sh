#!/usr/bin/env bash
# Live driver: against a REAL herdr server on an isolated fm-lab-* session (never
# the default session; provisioned and torn down through bin/fm-herdr-lab.sh's
# guarded helpers), create a real task pane and run the exact pair
# fm_backend_herdr_send_text_submit uses after Enter -
#   confirm=$(fm_backend_herdr_submit_confirm_budget <caller-budget>)
#   fm_backend_herdr_wait_for_working <session> <pane> "$confirm" $FM_BACKEND_HERDR_SUBMIT_POLLS
# - under LC_ALL=C and LC_ALL=de_DE.UTF-8 (decimal comma), timing the real
# confirmation window. Usage: herdr-live.sh <firstmate-root>
set -u
ROOTDIR=$1
# shellcheck source=/dev/null
. "$ROOTDIR/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-locale-$$"
export HERDR_SESSION="$SESSION"
cleanup() { herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1; }
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "lab prepare failed"; exit 1; }
# shellcheck source=/dev/null
. "$ROOTDIR/bin/fm-backend.sh"
fm_backend_source herdr || { echo "fm_backend_source herdr failed"; exit 1; }
RAW=$(fm_backend_herdr_container_ensure /tmp) || { echo "container_ensure failed"; exit 1; }
CONTAINER=${RAW%%$'\t'*}; SEED=${RAW#*$'\t'}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" fm-locale-probe /tmp "$SEED") || { echo "create_task failed"; exit 1; }
read -r TAB_ID PANE_ID <<<"$IDS"
echo "### root=$ROOTDIR"
echo "### real herdr: $(herdr --version 2>&1 | head -1); lab session=$SESSION tab=$TAB_ID pane=$PANE_ID"
echo "### pane agent status (raw): $(fm_backend_herdr_agent_status_raw "$SESSION" "$PANE_ID")"
echo "### FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=$FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP polls=$FM_BACKEND_HERDR_SUBMIT_POLLS caller budget=0.4s (expected: 0.6s floor spread as 5 x 0.12s sleeps)"
for loc in C de_DE.UTF-8; do
  for run in 1 2 3; do
    budget=$(LC_ALL=$loc fm_backend_herdr_submit_confirm_budget 0.4)
    t0=$(date +%s%N)
    verdict=$(LC_ALL=$loc fm_backend_herdr_wait_for_working "$SESSION" "$PANE_ID" "$budget" "$FM_BACKEND_HERDR_SUBMIT_POLLS")
    t1=$(date +%s%N)
    printf 'LC_ALL=%-12s run=%s confirm_budget=%-7s verdict=%-8s confirmation_window_ms=%s\n' \
      "$loc" "$run" "$budget" "$verdict" "$(( (t1 - t0) / 1000000 ))"
  done
done
