#!/usr/bin/env bash
# Behavioral tests for bin/captain-input-linux-capture.sh.  The script runs
# against a fake wl-clipboard/SSH toolchain so its clipboard MIME contract is
# exercised without a Wayland session or a remote firstmate endpoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAPTURE="$ROOT/bin/captain-input-linux-capture.sh"
TMP_ROOT=$(fm_test_tmproot captain-input-linux-capture-tests)

make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin" "$case_dir/tmp"

  cat > "$fakebin/wl-paste" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-types ]; then
  [ "${WL_LIST_FAIL:-0}" = 1 ] && exit 1
  printf '%s\n' "${WL_TYPES:-text/plain}"
  exit 0
fi
printf 'wl-paste %s\n' "$*" >> "$TRACE"
printf 'fake-image-data'
SH
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
printf '{"test":true}\n'
SH
  cat > "$fakebin/scp" <<'SH'
#!/usr/bin/env bash
printf 'scp %s\n' "$*" >> "$TRACE"
SH
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$TRACE"
SH
  chmod +x "$fakebin/wl-paste" "$fakebin/jq" "$fakebin/scp" "$fakebin/ssh"
  printf '%s\n' "$case_dir"
}

run_capture() {
  local case_dir=$1 types=$2 out=$3 err=$4
  PATH="$case_dir/fakebin:$PATH" TMPDIR="$case_dir/tmp" TRACE="$case_dir/trace" \
    WL_TYPES="$types" "$CAPTURE" >"$out" 2>"$err"
}

test_missing_wl_paste_fails_before_delivery() {
  local case_dir out err rc
  case_dir="$TMP_ROOT/missing-wl-paste"
  mkdir -p "$case_dir/fakebin"
  out="$case_dir/out"; err="$case_dir/err"
  PATH="$case_dir/fakebin" /usr/bin/bash "$CAPTURE" >"$out" 2>"$err"; rc=$?
  expect_code 1 "$rc" "missing wl-paste exit"
  assert_contains "$(cat "$err")" "wl-paste not found" "missing wl-paste error"
  pass "missing wl-paste fails before any clipboard or delivery work"
}

test_png_is_preferred_over_other_offered_images() {
  local case_dir out err trace
  case_dir=$(make_case png-preferred)
  out="$case_dir/out"; err="$case_dir/err"
  run_capture "$case_dir" "image/bmp
image/jpeg
image/png" "$out" "$err" \
    || fail "capture failed: $(cat "$err")"
  trace=$(cat "$case_dir/trace")
  assert_contains "$trace" "wl-paste -t image/png" "capture did not request the preferred PNG representation"
  assert_contains "$trace" ".png" "PNG payload was not delivered with a .png extension"
  assert_not_contains "$trace" "image/jpeg" "capture selected JPEG despite an offered PNG"
  pass "an offered PNG is selected ahead of JPEG and unsupported image types"
}

test_jpeg_uses_watcher_compatible_extension() {
  local case_dir out err trace
  case_dir=$(make_case jpeg-extension)
  out="$case_dir/out"; err="$case_dir/err"
  run_capture "$case_dir" "image/jpeg" "$out" "$err" \
    || fail "capture failed: $(cat "$err")"
  trace=$(cat "$case_dir/trace")
  assert_contains "$trace" "wl-paste -t image/jpeg" "capture did not request JPEG"
  assert_contains "$trace" ".jpg" "JPEG payload was not delivered with a .jpg extension"
  pass "a JPEG-only clipboard produces a watcher-compatible .jpg payload"
}

test_plain_text_clipboard_is_a_silent_noop() {
  local case_dir out err rc
  case_dir=$(make_case plain-text)
  out="$case_dir/out"; err="$case_dir/err"
  run_capture "$case_dir" "text/plain" "$out" "$err"; rc=$?
  expect_code 0 "$rc" "plain-text clipboard exit"
  [ ! -e "$case_dir/trace" ] || fail "plain-text clipboard must not invoke delivery tools"
  [ ! -s "$out" ] || fail "plain-text clipboard must not print output"
  pass "a clipboard without an image exits successfully without delivery"
}

test_clipboard_type_listing_failure_is_reported() {
  local case_dir out err rc
  case_dir=$(make_case list-failure)
  out="$case_dir/out"; err="$case_dir/err"
  PATH="$case_dir/fakebin:$PATH" TMPDIR="$case_dir/tmp" TRACE="$case_dir/trace" WL_LIST_FAIL=1 \
    "$CAPTURE" >"$out" 2>"$err"; rc=$?
  expect_code 1 "$rc" "clipboard listing failure exit"
  assert_contains "$(cat "$err")" "could not list clipboard types" "clipboard listing failure error"
  [ ! -e "$case_dir/trace" ] || fail "failed type listing must not invoke delivery tools"
  pass "a failed clipboard type query is an explicit delivery failure"
}

test_missing_wl_paste_fails_before_delivery
test_png_is_preferred_over_other_offered_images
test_jpeg_uses_watcher_compatible_extension
test_plain_text_clipboard_is_a_silent_noop
test_clipboard_type_listing_failure_is_reported
