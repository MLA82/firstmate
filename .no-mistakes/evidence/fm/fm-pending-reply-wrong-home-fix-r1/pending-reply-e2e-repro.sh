#!/usr/bin/env bash
set -eu
LIB=$1
LABEL=$2
ROOT=$3
SCRATCH="$ROOT/.pending-reply-e2e-$LABEL"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/parent/state" "$SCRATCH/mate/state"
# shellcheck disable=SC1090
. "$LIB"
export FM_PENDING_REPLY_GRACE_SECS=0 FM_PENDING_REPLY_NOW=17000
STATE="$SCRATCH/parent/state"
MATE="$SCRATCH/mate"
RECOVERY_LOG="$SCRATCH/recovery.log"
: > "$RECOVERY_LOG"
recovery_hook() { printf 'recovery sent\n' >> "$RECOVERY_LOG"; }
export FM_PENDING_REPLY_SEND_HOOK=recovery_hook
corr=$(fm_pending_reply_create "$SCRATCH/parent" "$STATE" mate "status of healthy mate")
fm_pending_reply_mark_delivered "$STATE" "$corr"
cat > "$STATE/mate.meta" <<EOF
window=session:fm-mate
endpoint_task_id=mate
worktree=$MATE
project=$MATE
harness=echo
kind=secondmate
mode=secondmate
home=$MATE
projects=alpha
EOF
printf 'done [corr=%s]: healthy mate answered\n' "$corr" > "$MATE/state/mate.status"
# Exercise both original and recovery busy->idle turns: the historical
# implementation reaches pending-reply-missed; the fixed one repairs first.
fm_pending_reply_tick_one "$STATE" "$corr" busy "$MATE"
fm_pending_reply_tick_one "$STATE" "$corr" idle "$MATE"
fm_pending_reply_tick_one "$STATE" "$corr" busy "$MATE"
fm_pending_reply_tick_one "$STATE" "$corr" idle "$MATE"
rec=$(fm_pending_reply_path "$STATE" "$corr")
printf 'implementation=%s\n' "$LABEL"
printf 'final_phase=%s\n' "$(fm_pending_reply_get "$rec" phase)"
printf 'recovery_sends=%s\n' "$(wc -l < "$RECOVERY_LOG" | tr -d ' ')"
printf 'pending_reply_missed=%s\n' "$(grep -c 'pending-reply-missed' "$STATE/mate.status" 2>/dev/null || true)"
printf 'parent_channel:\n'
if [ -f "$STATE/mate.status" ]; then sed 's/^/  /' "$STATE/mate.status"; else printf '  <empty>\n'; fi
rm -rf "$SCRATCH"
