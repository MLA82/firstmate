#!/usr/bin/env bash
# Drives the real bin/fm-backlog-handoff.sh CLI of PRODUCT_ROOT against a
# throwaway main home + seeded secondmate home, with the real tasks-axi doing
# the move. tmux is not installed on this host, so the best-effort terminal
# doorbell goes to the repo's fake tmux; the durable inbox record written by
# the real fm-send.sh (the actual delivery on the INBOX data plane) is what is
# printed below.
set -u
WT=/home/mla/.no-mistakes/worktrees/c9a671237ef3/01M2746FQWNN40C4TDB9JDX78K
# shellcheck source=/dev/null
. "$WT/tests/secondmate-helpers.sh"
PRODUCT=${PRODUCT_ROOT:?set PRODUCT_ROOT}
W=$(fm_test_tmproot fm-handoff-evidence)
home="$W/main"
sub="$W/design-home"
mkdir -p "$home/data" "$home/state"
seed_secondmate_home_marker "$sub" design
mkdir -p "$sub/state" "$sub/data"
sub_abs=$(cd "$sub" && pwd -P)
printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-07-09)\n' \
  "$sub_abs" > "$home/data/secondmates.md"
cat > "$home/state/design.meta" <<EOF
window=firstmate:fm-design
kind=secondmate
harness=claude
backend=tmux
home=$sub_abs
worktree=$sub_abs
EOF
cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] postfach-uebergang-abschliessen - first routed item (repo: alpha)
- [ ] vault-regelfragen-umsetzung - second routed item (repo: alpha)
- [ ] ops-runbook-refresh - third routed item (repo: alpha)

## Done
EOF
printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
fakebin=$(make_fake_tmux "$W/fake")
export PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW='firstmate:fm-design'
export FM_FAKE_TMUX_LOG="$W/tmux.log" FM_FAKE_TMUX_CAPTURE="$W/fake/pane.txt"
export FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1

handoff() {
  local rc=0
  printf '\n$ fm-backlog-handoff.sh design %s\n' "$*"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$PRODUCT" "$PRODUCT/bin/fm-backlog-handoff.sh" design "$@" 2>&1 || rc=$?
  printf '[exit %s]\n' "$rc"
}

records() {
  local rec n=0
  printf '\n-- receiver inbox records (state/design.inbox/*.msg), one body per record --\n'
  for rec in "$home/state/design.inbox"/*.msg; do
    [ -f "$rec" ] || continue
    n=$((n + 1))
    printf 'record %s: ' "$n"
    bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$PRODUCT/bin/fm-task-inbox-lib.sh" "$rec"
    printf '\n'
  done
  printf 'total records: %s\n' "$n"
}

printf '== product under test: %s ==\n' "$PRODUCT"
handoff postfach-uebergang-abschliessen
handoff vault-regelfragen-umsetzung ops-runbook-refresh
records
printf '\n-- adversarial: rerun the first handoff (item already in the receiver backlog) --'
handoff postfach-uebergang-abschliessen
records
printf '\n-- leftover wake state files in main state/ --\n'
ls -A "$home/state" | grep -E '^\.backlog-handoff-' || printf '(none)\n'
printf '\n-- receiver backlog (secondmate data/backlog.md) --\n'
cat "$sub/data/backlog.md"
