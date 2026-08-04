#!/usr/bin/env bash
# Regression tests for bin/fm-context-usage.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USAGE="$ROOT/bin/fm-context-usage.sh"
SKILL="$ROOT/.agents/skills/context-compaction-advice/SKILL.md"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-context-usage.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

make_transcript() {  # <name> <contents>
  local contents=$2 path="$TMP_ROOT/$1.jsonl"
  printf '%s\n' "$contents" > "$path"
  printf '%s\n' "$path"
}

run_usage() {  # <transcript> [extra env assignments are supplied by caller]
  local transcript=$1
  FM_CONTEXT_USAGE_TRANSCRIPT="$transcript" \
    PI_SESSION_FILE='' \
    "$USAGE" --machine
}

test_help_and_known_measurement() {
  local transcript out
  out=$($USAGE --help) || fail "context usage help failed"
  assert_contains "$out" "--machine" "context usage help omitted machine mode"
  transcript=$(make_transcript known '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":300}},"session_id":"known-session"}')
  out=$(run_usage "$transcript") || fail "known context usage failed"
  assert_contains "$out" "status=known tokens=600" "context usage did not sum the three measured fields"
  assert_contains "$out" "window=1000000" "Claude Opus 5 did not use the documented window"
  assert_contains "$out" "percent=0.1" "context usage percentage was wrong"
  assert_contains "$out" "compact=0" "below-band usage was marked actionable"
  pass "context usage reports the measured total and documented window"
}

test_newest_usage_record_wins() {
  local transcript out
  transcript=$(make_transcript newest '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3}},"session_id":"newest-session"}
{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":1000,"cache_read_input_tokens":2000,"cache_creation_input_tokens":3000}},"session_id":"newest-session"}')
  out=$(run_usage "$transcript") || fail "newest usage record failed"
  assert_contains "$out" "tokens=6000" "context usage did not use the newest usage record"
  assert_not_contains "$out" "tokens=6 " "context usage used an older record"
  pass "context usage selects the newest usage record"
}

test_unknown_transcript_states() {
  local missing empty no_usage malformed incomplete unreadable out
  missing="$TMP_ROOT/missing.jsonl"
  out=$(run_usage "$missing") || fail "missing transcript command failed"
  assert_contains "$out" "status=unknown reason=transcript-missing" "missing transcript was not explicit"

  empty="$TMP_ROOT/empty.jsonl"
  : > "$empty"
  out=$(run_usage "$empty") || fail "empty transcript command failed"
  assert_contains "$out" "status=unknown reason=transcript-empty" "empty transcript was not explicit"

  no_usage=$(make_transcript no-usage '{"type":"user","message":{"role":"user","content":"hello"}}')
  out=$(run_usage "$no_usage") || fail "no-usage transcript command failed"
  assert_contains "$out" "status=unknown reason=no-usage-record" "missing usage record was not explicit"

  malformed=$(make_transcript malformed '{not-json')
  out=$(run_usage "$malformed") || fail "malformed transcript command failed"
  assert_contains "$out" "status=unknown reason=transcript-unreadable" "malformed transcript was not explicit"

  incomplete=$(make_transcript incomplete '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":100}},"session_id":"incomplete-session"}')
  out=$(run_usage "$incomplete") || fail "incomplete usage command failed"
  assert_contains "$out" "status=unknown reason=usage-record-incomplete" "incomplete usage record was not explicit"

  unreadable=$(make_transcript unreadable '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}}}')
  chmod 000 "$unreadable"
  out=$(run_usage "$unreadable") || fail "unreadable transcript command failed"
  chmod 600 "$unreadable"
  assert_contains "$out" "status=unknown reason=transcript-unreadable" "unreadable transcript was not explicit"
  pass "missing, empty, malformed, incomplete, and unreadable transcripts stay unknown"
}

test_unknown_window_and_override() {
  local transcript out config_dir
  transcript=$(make_transcript unknown-model '{"type":"assistant","message":{"model":"future-model","usage":{"input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":300}},"session_id":"future-session"}')
  out=$(run_usage "$transcript") || fail "unknown model command failed"
  assert_contains "$out" "status=known tokens=600 window=unknown" "unknown model received a guessed denominator"
  assert_contains "$out" "compact=unknown" "unknown window was treated as actionable"

  out=$(FM_CONTEXT_USAGE_TRANSCRIPT="$transcript" PI_SESSION_FILE='' FM_CONTEXT_WINDOW_TOKENS=1000 "$USAGE" --machine) \
    || fail "explicit context-window override failed"
  assert_contains "$out" "window=1000" "explicit context-window override was ignored"
  assert_contains "$out" "percent=60.0" "explicit context-window percentage was wrong"
  assert_contains "$out" "compact=1" "50% band did not trigger at an actionable measurement"
  out=$(FM_CONTEXT_USAGE_TRANSCRIPT="$transcript" PI_SESSION_FILE='' FM_CONTEXT_WINDOW_TOKENS=1201 "$USAGE" --machine) \
    || fail "just-below-band context usage failed"
  assert_contains "$out" "percent=50.0" "just-below-band percentage was not rendered"
  assert_contains "$out" "compact=0" "just-below-band usage incorrectly triggered advice"

  config_dir="$TMP_ROOT/config"
  mkdir -p "$config_dir"
  printf '# local override\n2000\n' > "$config_dir/context-window-tokens"
  out=$(FM_CONTEXT_USAGE_TRANSCRIPT="$transcript" PI_SESSION_FILE='' FM_CONFIG_OVERRIDE="$config_dir" "$USAGE" --machine) \
    || fail "config context-window override failed"
  assert_contains "$out" "window=2000" "config context-window override was ignored"
  assert_contains "$out" "percent=30.0" "config context-window percentage was wrong"
  pass "unknown windows stay unknown and explicit overrides are honored"
}

test_ambiguous_current_session_stays_unknown() {
  local out
  out=$(env -u FM_CONTEXT_USAGE_TRANSCRIPT -u PI_SESSION_FILE "$USAGE" --machine) \
    || fail "ambiguous current-session command failed"
  assert_contains "$out" "status=unknown" "unbound current session was not explicit"
  assert_contains "$out" "current-session-not-identifiable" "unbound current session reason was unclear"
  pass "an unproven current-session selection stays unknown"
}

test_auto_selection_rejects_siblings() {
  local home cwd slug project old current driver out
  home="$TMP_ROOT/auto-home"
  cwd="$TMP_ROOT/auto-cwd"
  mkdir -p "$home/.claude/projects" "$cwd"
  slug=$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')
  project="$home/.claude/projects/$slug"
  mkdir -p "$project"
  old="$project/old-session.jsonl"
  current="$project/current-session.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}},"session_id":"old-session"}' > "$old"
  touch -t 202001010000 "$old"
  driver="$TMP_ROOT/claude-driver.sh"
  cat > "$driver" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":300}},"session_id":"current-session"}' > '$current'
HOME='$home' PI_SESSION_FILE='' '$USAGE' --machine
EOF
  chmod +x "$driver"
  out=$(cd "$cwd" && HOME="$home" PI_SESSION_FILE='' env -u FM_CONTEXT_USAGE_TRANSCRIPT -u CLAUDE_CODE_SESSION_ID \
    bash -c "exec -a claude bash '$driver'") || fail "auto current-session selection failed"
  assert_contains "$out" "status=known tokens=600" "newest transcript was not bound to the active Claude process"

  rm -f "$current"
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":10,"cache_creation_input_tokens":10}},"session_id":"sibling-a"}' > "$project/sibling-a.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":20,"cache_read_input_tokens":20,"cache_creation_input_tokens":20}},"session_id":"sibling-b"}' > "$project/sibling-b.jsonl"
  touch -t 202608041500 "$project/sibling-a.jsonl" "$project/sibling-b.jsonl"
  cat > "$driver" <<EOF
#!/usr/bin/env bash
HOME='$home' PI_SESSION_FILE='' '$USAGE' --machine
EOF
  chmod +x "$driver"
  out=$(cd "$cwd" && HOME="$home" PI_SESSION_FILE='' env -u FM_CONTEXT_USAGE_TRANSCRIPT -u CLAUDE_CODE_SESSION_ID \
    bash -c "exec -a claude bash '$driver'") || fail "ambiguous sibling selection failed"
  assert_contains "$out" "status=unknown" "equal-mtime sibling transcripts were not rejected"
  assert_contains "$out" "ambiguous-or-missing-current-transcript" "sibling ambiguity reason was unclear"
  pass "current-session selection accepts the active transcript and rejects sibling ambiguity"
}

test_session_id_env_binds_exact_transcript() {
  local home cwd slug project bound sibling driver out
  home="$TMP_ROOT/session-id-home"
  cwd="$TMP_ROOT/session-id-cwd"
  mkdir -p "$home/.claude/projects" "$cwd"
  slug=$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')
  project="$home/.claude/projects/$slug"
  mkdir -p "$project"
  bound="$project/bound-session.jsonl"
  sibling="$project/sibling-session.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":300}},"session_id":"bound-session"}' > "$bound"
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":9000,"cache_read_input_tokens":9000,"cache_creation_input_tokens":9000}},"session_id":"sibling-session"}' > "$sibling"
  touch -t 202001010000 "$bound"
  touch -t 202608041600 "$sibling"
  driver="$TMP_ROOT/claude-session-id-driver.sh"
  cat > "$driver" <<EOF
#!/usr/bin/env bash
HOME='$home' PI_SESSION_FILE='' CLAUDE_CODE_SESSION_ID='bound-session' '$USAGE' --machine
EOF
  chmod +x "$driver"
  out=$(cd "$cwd" && HOME="$home" PI_SESSION_FILE='' env -u FM_CONTEXT_USAGE_TRANSCRIPT -u CLAUDE_CODE_SESSION_ID \
    bash -c "exec -a claude bash '$driver'") || fail "session-id exact binding command failed"
  assert_contains "$out" "status=known tokens=600" "CLAUDE_CODE_SESSION_ID did not bind the exact transcript"
  assert_not_contains "$out" "tokens=27000" "CLAUDE_CODE_SESSION_ID selection used a newer sibling instead of the exact match"

  cat > "$driver" <<EOF
#!/usr/bin/env bash
HOME='$home' PI_SESSION_FILE='' CLAUDE_CODE_SESSION_ID='missing-session' '$USAGE' --machine
EOF
  chmod +x "$driver"
  out=$(cd "$cwd" && HOME="$home" PI_SESSION_FILE='' env -u FM_CONTEXT_USAGE_TRANSCRIPT -u CLAUDE_CODE_SESSION_ID \
    bash -c "exec -a claude bash '$driver'") || fail "session-id missing-transcript command failed"
  assert_contains "$out" "status=unknown reason=session-id-transcript-missing" "an unmatched CLAUDE_CODE_SESSION_ID was not explicit"
  pass "CLAUDE_CODE_SESSION_ID binds the exact transcript ahead of sibling mtimes"
}

test_skill_boundary_contract() {
  local skill
  skill=$(cat "$SKILL") || fail "context advice skill could not be read"
  assert_contains "$skill" "after a task's cleanup completes" "context advice omitted task cleanup boundary"
  assert_contains "$skill" "after an investigation report has been written and completely read" "context advice omitted report boundary"
  assert_contains "$skill" "after a captain decision has been durably recorded and routed" "context advice omitted decision boundary"
  assert_contains "$skill" "when an approach is explicitly abandoned" "context advice omitted abandoned-approach boundary"
  assert_contains "$skill" "status=known\` with \`compact=1" "context advice did not require measured actionable usage"
  assert_contains "$skill" "It never calls a compaction command" "context advice did not preserve the no-action boundary"
  pass "context advice is scoped to the four safe boundaries and never drives compaction"
}

test_command_is_read_only() {
  local transcript before after
  transcript=$(make_transcript readonly '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30}},"session_id":"readonly-session"}')
  before=$(shasum -a 256 "$transcript" | awk '{print $1}')
  run_usage "$transcript" >/dev/null || fail "read-only measurement failed"
  after=$(shasum -a 256 "$transcript" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "context usage modified the transcript"
  pass "context usage is read-only"
}

test_help_and_known_measurement
test_newest_usage_record_wins
test_unknown_transcript_states
test_unknown_window_and_override
test_ambiguous_current_session_stays_unknown
test_auto_selection_rejects_siblings
test_session_id_env_binds_exact_transcript
test_skill_boundary_contract
test_command_is_read_only
printf 'all fm-context-usage tests passed\n'
