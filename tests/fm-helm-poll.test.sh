#!/usr/bin/env bash
# Behavior tests for bin/fm-helm-poll.sh, the read-only Helm board-change poll.
#
# A fake GitHub CLI serves a board fixture; the poll never mutates anything.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLL="$ROOT/bin/fm-helm-poll.sh"
SYNC="$ROOT/bin/fm-helm-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-helm-poll)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

board_fixture() {  # <status> <priority-name> <priority-id>
  jq -n --arg so "$1" --arg pn "$2" --arg pi "$3" '
    {data:{user:{projectV2:{
      id:"p1",
      fields:{pageInfo:{hasNextPage:false},nodes:[
        {__typename:"ProjectV2SingleSelectField",id:"status-field",name:"Status",options:[
          {id:"queued-status",name:"Queued"},{id:"flight-status",name:"In flight"},
          {id:"waiting-status",name:"Waiting on you"},{id:"done-status",name:"Done"}]},
        {__typename:"ProjectV2SingleSelectField",id:"project-field",name:"Project",options:[
          {id:"firstmate-project",name:"firstmate"},{id:"other-project",name:"other"}]},
        {__typename:"ProjectV2SingleSelectField",id:"kind-field",name:"Kind",options:[
          {id:"ship-kind",name:"ship"},{id:"investigation-kind",name:"investigation"},
          {id:"decision-kind",name:"decision"}]},
        {__typename:"ProjectV2SingleSelectField",id:"priority-field",name:"Priority",options:[
          {id:"p0-priority",name:"P0"},{id:"p1-priority",name:"P1"},{id:"p2-priority",name:"P2"},
          {id:"p3-priority",name:"P3"},{id:"p4-priority",name:"P4"}]}
      ]},
      items:{pageInfo:{hasNextPage:false},nodes:[
        {id:"i1",content:{__typename:"DraftIssue",id:"d1",title:"T",body:"`t`\nbody"},
         fieldValues:{nodes:[
           {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Status"},name:$so,optionId:"x"},
           {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Priority"},name:$pn,optionId:$pi}
         ]}}
      ]}
    }}}}'
}

install_gh() {  # <case-dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = auth ]; then printf "%s\n" "Token scopes: 'project', 'repo'"; exit 0; fi
if [ "${1:-}" = api ]; then
  case "$*" in
    *cursor=page-2*)
      [ -z "${FM_FAKE_GH_STALL_PAGE_2:-}" ] || sleep "$FM_FAKE_GH_STALL_PAGE_2"
      cat "$FM_FAKE_BOARD_PAGE_2"
      ;;
    *) cat "$FM_FAKE_BOARD" ;;
  esac
  exit 0
fi
exit 1
SH
  chmod +x "$fb/gh"
  printf '%s\n' "$fb"
}

run_poll() {  # <case-dir> <fakebin>
  FM_HOME="$1/home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_BOARD="$1/board.json" \
    FM_FAKE_BOARD_PAGE_2="${FM_FAKE_BOARD_PAGE_2:-}" \
    PATH="$2:$PATH" "$POLL"
}

run_poll_without_timeout() {  # <case-dir> <fakebin>
  local portable_bin command
  portable_bin="$1/portable-bin"
  mkdir -p "$portable_bin"
  for command in awk bash cat chmod date dirname env grep jq mktemp mv rm sed sha256sum sleep sort; do
    ln -sf "$(command -v "$command")" "$portable_bin/$command"
  done
  ln -sf "$2/gh" "$portable_bin/gh"
  FM_HOME="$1/home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_BOARD="$1/board.json" \
    FM_FAKE_BOARD_PAGE_2="$1/page-two.json" PATH="$portable_bin" "$POLL"
}

case_dir="$TMP_ROOT/main"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_gh "$case_dir")

# Inert with no config.
out=$(run_poll "$case_dir" "$fb" 2>&1) || fail "poll without config exited nonzero: $out"
[ -z "$out" ] || fail "poll without config printed something: $out"
[ -e "$case_dir/home/state/.helm-board-poll" ] && fail "poll without config wrote state"
pass "the board poll is inert until config/helm.json exists"

printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] t - T (repo: firstmate) (kind: ship) (since: 2026-09-05)
## Done
EOF
board_fixture Queued P3 p3-priority > "$case_dir/board.json"

# Make the backlog "quiescent": record its combined hash the way the sync does.
FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_BOARD="$case_dir/board.json" \
  PATH="$fb:$PATH" "$SYNC" >/dev/null 2>&1 || fail "seed sync failed"

# First poll baselines silently.
out=$(run_poll "$case_dir" "$fb" 2>&1) || fail "first poll exited nonzero: $out"
[ -z "$out" ] || fail "first poll should baseline silently: $out"
[ -s "$case_dir/home/state/.helm-board-poll" ] || fail "first poll did not store a board signature"
pass "the first board poll baselines the signature without waking"

# No change -> silent.
out=$(run_poll "$case_dir" "$fb" 2>&1)
[ -z "$out" ] || fail "an unchanged board woke firstmate: $out"
pass "an unchanged board produces no wake"

# Captain edits the board while the backlog is quiescent -> one wake line.
board_fixture "In flight" P0 p0-priority > "$case_dir/board.json"
out=$(run_poll "$case_dir" "$fb" 2>&1)
printf '%s\n' "$out" | grep -F 'fm-helm-sync.sh --force' >/dev/null \
  || fail "a captain board edit did not print a reconcile wake line: $out"
pass "a board edit on a quiescent backlog prints exactly one wake line"

# Same edit again -> already baselined -> silent.
out=$(run_poll "$case_dir" "$fb" 2>&1)
[ -z "$out" ] || fail "the same board edit woke firstmate twice: $out"
pass "a board edit wakes firstmate only once"

# Board change while a backlog change is pending -> reconciliation wake.
board_fixture Done P4 p4-priority > "$case_dir/board.json"
cat >> "$case_dir/home/data/backlog.md" <<'EOF'
- [ ] t2 - Another (repo: firstmate) (kind: ship) (since: 2026-09-06)
EOF
out=$(run_poll "$case_dir" "$fb" 2>&1)
printf '%s\n' "$out" | grep -F 'Helm board and backlog both changed' >/dev/null \
  || fail "a concurrent board and backlog change did not request reconciliation: $out"
pass "a board change with a pending backlog change requests reconciliation"

FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_BOARD="$case_dir/board.json" \
  PATH="$fb:$PATH" "$SYNC" >/dev/null 2>&1 || fail "pagination sync baseline failed"
rm -f "$case_dir/home/state/.helm-board-poll"
board_fixture Done P4 p4-priority | jq '.data.user.projectV2.items.pageInfo={hasNextPage:true,endCursor:"page-2"}' > "$case_dir/board.json"
board_fixture Queued P3 p3-priority > "$case_dir/page-two.json"
FM_FAKE_BOARD_PAGE_2="$case_dir/page-two.json" out=$(run_poll "$case_dir" "$fb" 2>&1) \
  || fail "first paginated poll exited nonzero: $out"
[ -z "$out" ] || fail "first paginated poll should baseline silently: $out"
board_fixture "In flight" P0 p0-priority > "$case_dir/page-two.json"
FM_FAKE_BOARD_PAGE_2="$case_dir/page-two.json" out=$(run_poll "$case_dir" "$fb" 2>&1) \
  || fail "second paginated poll exited nonzero: $out"
printf '%s\n' "$out" | grep -F 'fm-helm-sync.sh --force' >/dev/null \
  || fail "a page-two board edit did not wake firstmate: $out"
pass "the board poll detects an edit on a second project page"

rm -f "$case_dir/home/state/.helm-board-poll"
board_fixture Queued P3 p3-priority | jq '.data.user.projectV2.items.pageInfo={hasNextPage:true,endCursor:"page-2"}' > "$case_dir/board.json"
board_fixture Queued P3 p3-priority > "$case_dir/page-two.json"
started=$(date +%s)
export FM_FAKE_GH_STALL_PAGE_2=21
out=$(run_poll_without_timeout "$case_dir" "$fb" 2>&1) \
  || fail "portable stalled poll exited nonzero: $out"
unset FM_FAKE_GH_STALL_PAGE_2
elapsed=$(( $(date +%s) - started ))
[ -z "$out" ] || fail "portable stalled poll printed output: $out"
[ "$elapsed" -le 22 ] || fail "portable stalled poll exceeded its overall deadline: ${elapsed}s"
[ ! -e "$case_dir/home/state/.helm-board-poll" ] \
  || fail "portable stalled poll published a partial board signature"
pass "a stalled paginated poll gives up within one overall deadline"
