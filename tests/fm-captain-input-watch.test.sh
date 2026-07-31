#!/usr/bin/env bash
# tests/fm-captain-input-watch.test.sh - behavior tests for
# bin/fm-captain-input-watch.sh, the registered check body for the async
# SSH-delivered captain-input screenshot-drop channel (Phase 1).
#
# Exercises the watch/enqueue/dedupe logic directly against a synthetic
# state/captain-drop/ fixture - real scp/SSH delivery is out of scope for this
# worktree and is not what this script's own logic depends on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-captain-input-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-input-tests)

# make_home <name>: create a fresh FM_HOME with a mode-0700 state/captain-drop/
# and .consumed/ pair, matching what fm-captain-input-enable.sh would have
# created. Echoes the home path.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state/captain-drop/.consumed"
  chmod 700 "$home/state/captain-drop" "$home/state/captain-drop/.consumed"
  printf '%s\n' "$home"
}

# write_envelope <home> <id> [type] [settled]: write a complete envelope + tiny
# PNG payload pair. settled defaults to true (both files backdated to a fixed
# past date, well outside the quiet period, using the same portable "touch -t
# <fixed-past-date>" convention the rest of this suite's staleness tests use);
# pass false to leave both at their just-written (now) mtime, simulating a
# mid-transfer / still-growing pair.
write_envelope() {
  local home=$1 id=$2 type=${3:-screenshot} settled=${4:-true} drop png json
  drop="$home/state/captain-drop"
  png="$drop/$id.png"
  json="$drop/$id.json"
  printf '\211PNG\r\n\032\nfirstmate-test-png' > "$png"
  printf '{"id":"%s","type":"%s","path":"%s","caption":"a caption","dropped_at":"2026-07-31T00:00:00Z"}\n' \
    "$id" "$type" "$png" > "$json"
  [ "$settled" = true ] && touch -t 200001010000 "$png" "$json"
}

wake_queue_lines() {
  local home=$1
  [ -f "$home/state/.wake-queue" ] && cat "$home/state/.wake-queue" || true
}

run_watch() {
  local home=$1
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CAPTAIN_INPUT_QUIET_SECS=3 "$WATCH"
}

# ---------------------------------------------------------------------------

test_no_drop_dir_is_silent() {
  local home out rc
  home="$TMP_ROOT/no-dir"; mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$WATCH"); rc=$?
  expect_code 0 "$rc" "missing drop dir exit"
  [ -z "$out" ] || fail "missing drop dir must print nothing (got: $out)"
  pass "no state/captain-drop/ is a silent no-op"
}

test_complete_envelope_is_reported_and_consumed() {
  local home out queue
  home=$(make_home complete)
  write_envelope "$home" shot-1
  out=$(run_watch "$home")
  assert_contains "$out" "new captain-input drop(s)" "complete envelope did not print a summary line"
  assert_contains "$out" "$home/state/captain-drop/shot-1.png" "summary line missing the payload path"
  assert_present "$home/state/captain-drop/.consumed/shot-1.json" "envelope was not moved to .consumed/"
  assert_present "$home/state/captain-drop/.consumed/shot-1.png" "payload was not moved to .consumed/"
  assert_absent "$home/state/captain-drop/shot-1.json" "envelope must not remain in the watched directory"
  assert_absent "$home/state/captain-drop/shot-1.png" "payload must not remain in the watched directory"
  queue=$(wake_queue_lines "$home")
  assert_contains "$queue" "$(printf '\tcheck\tcaptain-input:shot-1\t')" \
    "wake queue is missing a check record keyed captain-input:shot-1"
  pass "a complete envelope is reported, enqueued once, and consumed"
}

test_still_growing_envelope_is_skipped() {
  local home out
  home=$(make_home growing)
  # settled=false leaves both files at their just-written mtime, inside the
  # quiet period.
  write_envelope "$home" shot-2 screenshot false
  out=$(run_watch "$home")
  [ -z "$out" ] || fail "a still-growing envelope must not be reported yet (got: $out)"
  assert_present "$home/state/captain-drop/shot-2.json" "still-growing envelope must stay in the watched directory"
  assert_absent "$home/state/captain-drop/.consumed/shot-2.json" "still-growing envelope must not be consumed"
  queue=$(wake_queue_lines "$home")
  assert_not_contains "$queue" "captain-input:shot-2" "still-growing envelope must not be enqueued"
  pass "a still-growing envelope (fresh mtime) is skipped this poll"
}

test_rescanned_drop_never_enqueues_twice() {
  local home queue_first queue_second first_count second_count
  home=$(make_home dedupe)
  write_envelope "$home" shot-3
  run_watch "$home" >/dev/null
  queue_first=$(wake_queue_lines "$home")
  first_count=$(printf '%s\n' "$queue_first" | grep -c "captain-input:shot-3" || true)
  [ "$first_count" -eq 1 ] || fail "expected exactly one queue record after first poll, got $first_count"

  # Re-run against the now-consumed directory: must be a pure no-op.
  run_watch "$home" >/dev/null
  queue_second=$(wake_queue_lines "$home")
  second_count=$(printf '%s\n' "$queue_second" | grep -c "captain-input:shot-3" || true)
  [ "$second_count" -eq 1 ] || fail "re-scanning after consumption enqueued again (count now $second_count)"
  pass "a re-scanned drop is never enqueued twice, via the .consumed/ move"
}

test_multiple_complete_envelopes_each_get_own_wake_key() {
  local home out queue
  home=$(make_home multi)
  write_envelope "$home" shot-a
  write_envelope "$home" shot-b
  out=$(run_watch "$home")
  assert_contains "$out" "2 new captain-input drop(s)" "expected a batched summary line for two drops"
  queue=$(wake_queue_lines "$home")
  assert_contains "$queue" "captain-input:shot-a" "missing queue record for shot-a"
  assert_contains "$queue" "captain-input:shot-b" "missing queue record for shot-b"
  pass "multiple simultaneous drops each get a distinct wake-queue key"
}

test_unrecognized_type_is_left_unconsumed() {
  local home out
  home=$(make_home futuretype)
  write_envelope "$home" clip-1 audio
  out=$(run_watch "$home")
  [ -z "$out" ] || fail "a non-screenshot type must not be reported in Phase 1 (got: $out)"
  assert_present "$home/state/captain-drop/clip-1.json" "unrecognized-type envelope must be left in place, not discarded"
  pass "an envelope of an unrecognized type is left unconsumed rather than guessed at"
}

test_wrong_directory_mode_is_silent() {
  local home out
  home=$(make_home badmode)
  chmod 755 "$home/state/captain-drop"
  write_envelope "$home" shot-4
  out=$(run_watch "$home")
  [ -z "$out" ] || fail "a non-0700 drop directory must not be trusted (got: $out)"
  pass "a drop directory that is not mode 0700 is treated as not-enabled"
}

# ---------------------------------------------------------------------------

test_no_drop_dir_is_silent
test_complete_envelope_is_reported_and_consumed
test_still_growing_envelope_is_skipped
test_rescanned_drop_never_enqueues_twice
test_multiple_complete_envelopes_each_get_own_wake_key
test_unrecognized_type_is_left_unconsumed
test_wrong_directory_mode_is_silent
