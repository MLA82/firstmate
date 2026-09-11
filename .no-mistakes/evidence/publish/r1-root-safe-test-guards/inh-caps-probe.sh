#!/usr/bin/env bash
# inh-caps-probe.sh <repo-root>
# Run as a root runner whose inheritable set already holds CAP_DAC_OVERRIDE and
# CAP_DAC_READ_SEARCH (e.g. older Docker engines):
#   unshare -r setpriv --inh-caps=+dac_override,+dac_read_search -- bash inh-caps-probe.sh <repo>
set -u
repo=$1
echo "lib.sh under test: $repo/tests/lib.sh"
echo "runner: uid $(id -u); $(grep -E 'CapInh' /proc/self/status | tr '\t' ' ')"
. "$repo/tests/lib.sh"
T=$(fm_test_tmproot fm-inhprobe)
mkdir "$T/d"
chmod a-w "$T/d"
# shellcheck disable=SC2016
if setpriv --bounding-set=-dac_override,-dac_read_search -- bash -c ': > "$1/bounding-only"' _ "$T/d" 2>/dev/null; then
  echo "plain bounding-set-only drop: write into a-w dir SUCCEEDED (root regained the caps from the inheritable set)"
else
  echo "plain bounding-set-only drop: write denied"
fi
chmod u+w "$T/d"
# shellcheck disable=SC2016
fm_run_dir_readonly "$T/d" bash -c ': > "$1/via-helper"' _ "$T/d"
rc=$?
echo "fm_run_dir_readonly write attempt: rc=$rc; file created: $([ -e "$T/d/via-helper" ] && echo yes || echo no)"
case $rc in
  0) echo "RESULT: helper let root write into a write-blocked dir (guard defeated)" ;;
  97) echo "RESULT: helper refused (97) - drop cannot be proven on this runner, protection unavailable" ;;
  *) echo "RESULT: write denied under the helper - drop holds on this runner" ;;
esac
