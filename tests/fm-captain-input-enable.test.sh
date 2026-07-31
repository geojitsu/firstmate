#!/usr/bin/env bash
# tests/fm-captain-input-enable.test.sh - behavior tests for
# bin/fm-captain-input-enable.sh, the one-time per-home setup step for the
# async SSH-delivered captain-input screenshot-drop channel (Phase 1).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"

ENABLE="$ROOT/bin/fm-captain-input-enable.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-input-enable-tests)

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

run_enable() {
  local home=$1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ENABLE"
}

test_enable_creates_expected_artifacts() {
  local home out
  home="$TMP_ROOT/fresh"; mkdir -p "$home"
  out=$(run_enable "$home") || fail "enable script failed: $out"
  assert_present "$home/config/captain-input" "presence flag was not written"
  assert_present "$home/state/captain-drop" "drop directory was not created"
  assert_present "$home/state/captain-drop/.consumed" "consumed directory was not created"
  [ "$(file_mode "$home/state/captain-drop")" = 700 ] || fail "drop directory is not mode 700"
  [ "$(file_mode "$home/state/captain-drop/.consumed")" = 700 ] || fail "consumed directory is not mode 700"
  assert_present "$home/config/captain-input.env" "cadence env file was not written"
  assert_grep "FM_CHECK_INTERVAL=15" "$home/config/captain-input.env" "cadence file missing FM_CHECK_INTERVAL=15"
  assert_present "$home/state/captain-input.check.sh" "check script was not written"
  [ "$(file_mode "$home/state/captain-input.check.sh")" = 700 ] || fail "check script is not mode 700"
  assert_grep "fm-captain-input-watch.sh" "$home/state/captain-input.check.sh" \
    "check script does not exec the trusted watch script"
  fm_custom_check_registered "$home/state" captain-input \
    || fail "captain-input check was not registered (hash trust binding missing or mismatched)"
  pass "a fresh enable run writes the presence flag, private drop dirs, cadence file, and a registered check"
}

test_enable_reuses_x_mode_cadence_when_present() {
  local home
  home="$TMP_ROOT/xmode"; mkdir -p "$home/config"
  printf 'export FM_CHECK_INTERVAL=30\n' > "$home/config/x-mode.env"
  run_enable "$home" >/dev/null || fail "enable script failed with existing x-mode.env"
  assert_absent "$home/config/captain-input.env" \
    "a separate captain-input.env must not be written when config/x-mode.env already exists"
  pass "enable reuses config/x-mode.env's cadence instead of writing a second cadence file"
}

test_enable_is_idempotent() {
  local home flag_mtime_1 flag_mtime_2
  home="$TMP_ROOT/idempotent"; mkdir -p "$home"
  run_enable "$home" >/dev/null || fail "first enable run failed"
  flag_mtime_1=$(file_mode "$home/config/captain-input")
  run_enable "$home" >/dev/null || fail "second enable run failed"
  flag_mtime_2=$(file_mode "$home/config/captain-input")
  [ "$flag_mtime_1" = "$flag_mtime_2" ] || fail "re-running enable changed the presence flag's mode"
  fm_custom_check_registered "$home/state" captain-input \
    || fail "captain-input check registration did not survive a second enable run"
  pass "re-running the enable script is safe and keeps the check registered"
}

# ---------------------------------------------------------------------------

test_enable_creates_expected_artifacts
test_enable_reuses_x_mode_cadence_when_present
test_enable_is_idempotent
