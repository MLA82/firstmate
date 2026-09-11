#!/usr/bin/env bash
# refusal-caller-shape.sh <repo-root>: a denial-asserting test in the exact
# caller shape of fm-secondmate-safety.test.sh:188 / fm-shared-captain-inheritance.test.sh:202
# (`fm_run_without_dac_override ... >/dev/null 2>"$err"`), run as a root runner
# whose setpriv cannot drop the capabilities.
. "$1/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-refusal-shape)
err="$TMP_ROOT/denied.err"
if fm_run_without_dac_override bash -c ': >/dev/null' >/dev/null 2>"$err"; then
  fail "write unexpectedly succeeded"
fi
pass "write correctly denied (VACUOUS if reached: nothing ran)"
