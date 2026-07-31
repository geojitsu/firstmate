#!/usr/bin/env bash
# tests/fm-captain-input-e2e.test.sh - proves the captain-input channel's real
# integration through bin/fm-watch.sh's registered-custom-check pipeline, not
# just bin/fm-captain-input-watch.sh's own logic in isolation (covered by
# tests/fm-captain-input-watch.test.sh). Runs the actual enable script to
# register the check (trampoline + hash trust binding), drops a synthetic
# complete envelope, then runs the real watcher for one cycle and confirms it
# executes the registered check via its snapshot mechanism, wakes on the
# printed summary, and the durable queue ends up holding both the watcher's
# own generic per-check wake and the finer-grained per-envelope wake this
# channel enqueues directly.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
ENABLE="$ROOT/bin/fm-captain-input-enable.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-input-e2e-tests)

test_registered_check_delivers_a_captain_drop_through_the_real_watcher() {
  local dir state out drain_out png json
  dir=$(make_case captain-input-e2e)
  state="$dir/state"

  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" "$ENABLE" >/dev/null \
    || fail "captain-input enable script failed"
  [ -f "$state/captain-input.check.sh" ] || fail "enable script did not register a check under the test's own state dir"

  png="$state/captain-drop/shot-e2e.png"
  json="$state/captain-drop/shot-e2e.json"
  printf '\211PNG\r\n\032\nfirstmate-test-png' > "$png"
  printf '{"id":"shot-e2e","type":"screenshot","path":"%s","caption":"","dropped_at":"2026-07-31T00:00:00Z"}\n' \
    "$png" > "$json"
  touch -t 200001010000 "$png" "$json"

  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for the captain-input check"
  grep -F "check: $state/captain-input.check.sh:" "$out" >/dev/null \
    || fail "watcher did not print the generic check wake for captain-input"
  grep -F "new captain-input drop(s)" "$out" >/dev/null \
    || fail "watcher's printed wake did not carry the captain-input summary"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after the captain-input wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$state/captain-input.check.sh" >/dev/null \
    || fail "the generic per-check wake was not queued"
  grep "$(printf '\tcheck\tcaptain-input:shot-e2e\t')" "$drain_out" >/dev/null \
    || fail "the fine-grained per-envelope wake (captain-input:shot-e2e) was not queued"

  assert_present "$state/captain-drop/.consumed/shot-e2e.json" "envelope was not consumed by the real watcher run"
  assert_absent "$state/captain-drop/shot-e2e.json" "envelope must not remain in the watched directory after the real watcher run"
  pass "a registered captain-input check delivers a complete drop through the real watcher end to end"
}

test_registered_check_delivers_a_captain_drop_through_the_real_watcher
