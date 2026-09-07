#!/usr/bin/env bash
# Behavior tests for the fleet-aware opt-in Helm board sync.
#
# The fake GitHub CLI returns a project fixture and records every mutation, so
# these tests never mutate the captain's live board. A fake tasks-axi records
# the back-writes the sync makes into an owning home's backlog.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-helm-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-helm-sync)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# board_json <extra-item-nodes-json> - a project fixture with the P0..P4 and the
# nocout/cryptoseacurrents options the shipped board carries.
board_json() {
  local items=$1
  jq -n --argjson items "$items" '
    {data:{user:{projectV2:{
      id:"project-1",
      fields:{pageInfo:{hasNextPage:false},nodes:[
        {__typename:"ProjectV2SingleSelectField",id:"status-field",name:"Status",options:[
          {id:"queued-status",name:"Queued"},
          {id:"flight-status",name:"In flight"},
          {id:"waiting-status",name:"Waiting on you"},
          {id:"done-status",name:"Done"}
        ]},
        {__typename:"ProjectV2SingleSelectField",id:"project-field",name:"Project",options:[
          {id:"firetabs-project",name:"firetabs"},
          {id:"bbt-project",name:"BetterBlueToo"},
          {id:"firstmate-project",name:"firstmate"},
          {id:"nocout-project",name:"nocout"},
          {id:"csc-project",name:"cryptoseacurrents"},
          {id:"other-project",name:"other"}
        ]},
        {__typename:"ProjectV2SingleSelectField",id:"kind-field",name:"Kind",options:[
          {id:"ship-kind",name:"ship"},
          {id:"investigation-kind",name:"investigation"},
          {id:"decision-kind",name:"decision"}
        ]},
        {__typename:"ProjectV2SingleSelectField",id:"priority-field",name:"Priority",options:[
          {id:"p0-priority",name:"P0"},
          {id:"p1-priority",name:"P1"},
          {id:"p2-priority",name:"P2"},
          {id:"p3-priority",name:"P3"},
          {id:"p4-priority",name:"P4"}
        ]}
      ]},
      items:{pageInfo:{hasNextPage:false},nodes:$items}
    }}}}'
}

draft_item() {  # <item-id> <draft-id> <task-id> <title> <body-rest> <status-opt> <status-id> <priority-name> <priority-id>
  jq -n --arg i "$1" --arg d "$2" --arg t "$3" --arg ti "$4" --arg br "$5" \
    --arg so "$6" --arg si "$7" --arg pn "$8" --arg pi "$9" '
    {id:$i,content:{__typename:"DraftIssue",id:$d,title:$ti,body:("`" + $t + "`\n" + $br)},
     fieldValues:{nodes:[
       {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Status"},name:$so,optionId:$si},
       {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Priority"},name:$pn,optionId:$pi}
     ]}}'
}

install_fakes() {  # <case-dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  [ "${FM_FAKE_GH_MODE:-}" = noauth ] && exit 1
  if [ "${FM_FAKE_GH_MODE:-}" = scope ]; then
    printf "%s\n" "Token scopes: 'repo'"
  else
    printf "%s\n" "Token scopes: 'project', 'repo'"
  fi
  exit 0
fi
if [ "${1:-}" = api ]; then
  [ "${FM_FAKE_GH_MODE:-}" = network ] && exit 1
  case "$*" in
    *addProjectV2DraftIssue*)
      printf '%s\n' '{"data":{"addProjectV2DraftIssue":{"projectItem":{"id":"created-item","content":{"id":"created-draft"}}}}}' ;;
    *updateProjectV2DraftIssue*)
      printf '%s\n' '{"data":{"updateProjectV2DraftIssue":{"draftIssue":{"id":"updated-draft"}}}}' ;;
    *updateProjectV2ItemFieldValue*)
      printf '%s\n' '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"updated-item"}}}}' ;;
    *)
      cat "$FM_FAKE_BOARD" ;;
  esac
  exit 0
fi
exit 1
SH
  chmod +x "$fb/gh"
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\t%s\n' "${FM_HOME:-}" "$*" >> "$FM_FAKE_TASKS_LOG"
exit 0
SH
  chmod +x "$fb/tasks-axi"
  printf '%s\n' "$fb"
}

run_sync() {  # <case-dir> <fakebin> [--force]
  local case_dir=$1 fb=$2 arg=${3:-}
  local -a a=()
  [ -z "$arg" ] || a+=("$arg")
  FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_BOARD="$case_dir/board.json" \
    FM_FAKE_GH_LOG="$case_dir/gh.log" \
    FM_FAKE_TASKS_LOG="$case_dir/tasks-axi.log" \
    FM_FAKE_GH_MODE="${FM_FAKE_GH_MODE:-}" \
    PATH="$fb:$PATH" \
    "$SYNC" "${a[@]}"
}

# ---------------------------------------------------------------------------
# Two-home union: close-missing only fires for a card in no home's backlog.
# ---------------------------------------------------------------------------
case_dir="$TMP_ROOT/union"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state" \
  "$case_dir/sm/data" "$case_dir/sm/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2,"dispatch_status":"In flight"}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] main-task - Main queued (repo: firstmate) (kind: ship) (priority: 0) (since: 2026-09-05)
## Done
EOF
cat > "$case_dir/home/data/secondmates.md" <<EOF
- sm - Owns the sub project (home: $case_dir/sm; scope: The sub project only.; projects: sub; added 2026-09-05)
EOF
cat > "$case_dir/sm/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] sm-task - Secondmate flight (repo: firetabs) (kind: ship) (priority: 2) (since: 2026-09-05)
## Done
EOF
board_json "$(jq -n \
  --argjson a "$(draft_item main-item main-draft main-task 'Main queued' 'old' Queued queued-status P3 p3-priority)" \
  --argjson b "$(draft_item sm-item sm-draft sm-task 'Secondmate flight' 'old' Queued queued-status P3 p3-priority)" \
  --argjson c "$(draft_item gone-item gone-draft gone-task 'Gone' 'old' Queued queued-status P3 p3-priority)" \
  '[$a,$b,$c]')" > "$case_dir/board.json"
: > "$case_dir/gh.log"; : > "$case_dir/tasks-axi.log"
out=$(run_sync "$case_dir" "$fb" 2>&1) || fail "union sync exited nonzero: $out"
assert_contains "$out" "fm-helm-sync: synchronized" "union sync completes"
grep -F 'done-status' "$case_dir/gh.log" | grep -F 'itemId=gone-item' >/dev/null \
  || fail "card in no home's backlog was not closed to Done"
if grep -F 'itemId=sm-item' "$case_dir/gh.log" | grep -F 'done-status' >/dev/null; then
  fail "a secondmate-owned card was wrongly closed to Done"
fi
grep -F 'itemId=sm-item' "$case_dir/gh.log" | grep -F 'optionId=flight-status' >/dev/null \
  || fail "secondmate task status was not reconciled from its own home"
grep -F 'itemId=main-item' "$case_dir/gh.log" | grep -F 'optionId=p0-priority' >/dev/null \
  || fail "priority 0 did not map to the P0 board option"
[ -s "$case_dir/home/state/helm-cards.tsv" ] || fail "identity cache was not written"
grep -F $'\tmain-item\t' "$case_dir/home/state/helm-cards.tsv" >/dev/null \
  || fail "identity cache is missing the main task row"
grep -F $'\tsm-item\t' "$case_dir/home/state/helm-cards.tsv" >/dev/null \
  || fail "identity cache is missing the secondmate task row"
pass "fleet union reconciles every home and closes only cards in no home's backlog"

# Identity cache rebuild: drop it, run again, it comes back from the board.
rm -f "$case_dir/home/state/helm-cards.tsv"
: > "$case_dir/gh.log"
run_sync "$case_dir" "$fb" --force >/dev/null 2>&1 || fail "rebuild run failed"
grep -F $'\tmain-item\t' "$case_dir/home/state/helm-cards.tsv" >/dev/null \
  || fail "identity cache was not rebuilt from the board"
pass "identity cache rebuilds from the board when absent"

# ---------------------------------------------------------------------------
# Delete detection: a previously synced card gone from the board holds its
# still-live task for the captain and wakes firstmate; it is not a new card.
# ---------------------------------------------------------------------------
case_dir="$TMP_ROOT/delete"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] keep-task - Keep me (repo: firstmate) (kind: ship) (since: 2026-09-05)
- [ ] del-task - Delete my card (repo: firstmate) (kind: ship) (since: 2026-09-05)
## Done
EOF
board_json "$(jq -n \
  --argjson a "$(draft_item keep-item keep-draft keep-task 'Keep me' 'x' Queued queued-status P3 p3-priority)" \
  --argjson b "$(draft_item del-item del-draft del-task 'Delete my card' 'x' Queued queued-status P3 p3-priority)" \
  '[$a,$b]')" > "$case_dir/board.json"
run_sync "$case_dir" "$fb" >/dev/null 2>&1 || fail "delete-case seed run failed"
# Captain deletes del-item from the board.
board_json "$(jq -n \
  --argjson a "$(draft_item keep-item keep-draft keep-task 'Keep me' 'x' Queued queued-status P3 p3-priority)" \
  '[$a]')" > "$case_dir/board.json"
: > "$case_dir/gh.log"; : > "$case_dir/tasks-axi.log"
run_sync "$case_dir" "$fb" --force >/dev/null 2>&1 || fail "delete-detect run failed"
if grep -F 'addProjectV2DraftIssue' "$case_dir/gh.log" >/dev/null; then
  fail "a deleted live card was recreated before delete detection"
fi
grep -F 'hold del-task --kind captain' "$case_dir/tasks-axi.log" >/dev/null \
  || fail "deleted card did not hold its live task for the captain: $(cat "$case_dir/tasks-axi.log")"
grep -F $'\tcheck\thelm-card-deleted:del-task\t' "$case_dir/home/state/.wake-queue" >/dev/null \
  || fail "deleted card did not wake firstmate"
if grep -F 'helm-new-card:del-task' "$case_dir/home/state/.wake-queue" >/dev/null; then
  fail "a deleted card was misread as a brand-new captain card"
fi
grep -F $'\tdel-item\t' "$case_dir/home/state/helm-cards.tsv" >/dev/null \
  && fail "the deleted card's identity row was retained"
pass "a deleted card holds its live task for the captain and is not treated as new"

# New, not yet carded: a board card with no backlog task and never seen before
# is a new captain card, not a deletion and not closed to Done.
board_json "$(jq -n \
  --argjson a "$(draft_item keep-item keep-draft keep-task 'Keep me' 'x' Queued queued-status P3 p3-priority)" \
  --argjson b "$(draft_item new-item new-draft brand-new-idea 'Brand new idea' 'from the captain' Queued queued-status P3 p3-priority)" \
  '[$a,$b]')" > "$case_dir/board.json"
: > "$case_dir/gh.log"
run_sync "$case_dir" "$fb" --force >/dev/null 2>&1 || fail "new-card run failed"
grep -F $'\tcheck\thelm-new-card:brand-new-idea\t' "$case_dir/home/state/.wake-queue" >/dev/null \
  || fail "a brand-new captain card did not wake firstmate for intake"
if grep -F 'itemId=new-item' "$case_dir/gh.log" | grep -F 'done-status' >/dev/null; then
  fail "a brand-new captain card was wrongly closed to Done"
fi
pass "a never-seen board card with no task is intake, not a deletion"

# A completed task's card (already Done, no backlog row) is left alone: no new
# wake, no re-close.
board_json "$(jq -n \
  --argjson a "$(draft_item keep-item keep-draft keep-task 'Keep me' 'x' Queued queued-status P3 p3-priority)" \
  --argjson b "$(draft_item torndown-item td-draft torndown-task 'Shipped and gone' 'x' Done done-status P3 p3-priority)" \
  '[$a,$b]')" > "$case_dir/board.json"
: > "$case_dir/gh.log"
wq_before=$(wc -l <"$case_dir/home/state/.wake-queue" 2>/dev/null || echo 0)
run_sync "$case_dir" "$fb" --force >/dev/null 2>&1 || fail "torn-down card run failed"
[ "$(wc -l <"$case_dir/home/state/.wake-queue")" -eq "$wq_before" ] \
  || fail "a completed task's Done card raised a spurious wake"
if grep -F 'itemId=torndown-item' "$case_dir/gh.log" >/dev/null; then
  fail "the sync touched a completed task's Done card"
fi
pass "a completed task's Done card is left untouched with no wake"

# ---------------------------------------------------------------------------
# Issue tolerance: a card converted to a real issue gets field-only sync.
# ---------------------------------------------------------------------------
case_dir="$TMP_ROOT/issue"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] issue-task - Backlog authoritative title (repo: firstmate) (kind: ship) (priority: 1) (since: 2026-09-05)
## Done
EOF
board_json "$(jq -n --argjson it "$(jq -n '
  {id:"issue-item",content:{__typename:"Issue",id:"issue-node",number:42,url:"https://x",
    title:"Captain edited issue title",body:"`issue-task`\ncollaborator thread"},
   fieldValues:{nodes:[
     {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Status"},name:"Queued",optionId:"queued-status"},
     {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Priority"},name:"P3",optionId:"p3-priority"}
   ]}}')" '[$it]')" > "$case_dir/board.json"
: > "$case_dir/gh.log"
run_sync "$case_dir" "$fb" >/dev/null 2>&1 || fail "issue-case run failed"
if grep -F 'updateProjectV2DraftIssue' "$case_dir/gh.log" >/dev/null; then
  fail "the sync rewrote a real issue's title or body"
fi
grep -F 'itemId=issue-item' "$case_dir/gh.log" | grep -F 'optionId=p1-priority' >/dev/null \
  || fail "a real issue did not get its board Priority field synced"
pass "a real repo issue keeps field-only sync and its own title and body"

# ---------------------------------------------------------------------------
# Priority write-back: a forced read of a captain board Priority edit lands in
# the owning backlog row.
# ---------------------------------------------------------------------------
case_dir="$TMP_ROOT/prio"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] prio-task - Priority task (repo: firstmate) (kind: ship) (priority: 2) (since: 2026-09-05)
## Done
EOF
board_json "$(jq -n --argjson a "$(draft_item prio-item prio-draft prio-task 'Priority task' 'x' Queued queued-status P4 p4-priority)" '[$a]')" > "$case_dir/board.json"
: > "$case_dir/tasks-axi.log"; : > "$case_dir/gh.log"
run_sync "$case_dir" "$fb" --force >/dev/null 2>&1 || fail "priority write-back run failed"
grep -F 'update prio-task --priority 4' "$case_dir/tasks-axi.log" >/dev/null \
  || fail "a captain board Priority edit was not written back to the backlog: $(cat "$case_dir/tasks-axi.log")"
if grep -F 'itemId=prio-item' "$case_dir/gh.log" | grep -F 'fieldId=priority-field' >/dev/null; then
  fail "the sync pushed over the captain's board Priority edit"
fi
pass "a forced read accepts a captain board Priority edit into the owning backlog"

# ---------------------------------------------------------------------------
# Debounce and fail-open posture.
# ---------------------------------------------------------------------------
case_dir="$TMP_ROOT/debounce"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] d-task - D (repo: firstmate) (kind: ship) (since: 2026-09-05)
## Done
EOF
board_json "$(jq -n --argjson a "$(draft_item d-item d-draft d-task 'D' 'x' Queued queued-status P3 p3-priority)" '[$a]')" > "$case_dir/board.json"
run_sync "$case_dir" "$fb" >/dev/null 2>&1 || fail "debounce seed run failed"
before=$(wc -l <"$case_dir/gh.log")
run_sync "$case_dir" "$fb" >/dev/null 2>&1 || fail "debounce second run failed"
[ "$(wc -l <"$case_dir/gh.log")" -eq "$before" ] || fail "an unchanged fleet backlog made a GitHub call"
pass "an unchanged fleet backlog is debounced without a GitHub call"

for mode in no-config noauth scope network; do
  cd_dir="$TMP_ROOT/fail-$mode"
  mkdir -p "$cd_dir/home/config" "$cd_dir/home/data" "$cd_dir/home/state"
  fbx=$(install_fakes "$cd_dir")
  [ "$mode" = no-config ] || printf '{"owner":"geojitsu","number":2}\n' > "$cd_dir/home/config/helm.json"
  cat > "$cd_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] f-task - F (repo: firstmate) (kind: ship) (since: 2026-09-05)
## Done
EOF
  board_json "$(jq -n --argjson a "$(draft_item f-item f-draft f-task 'F' 'x' Queued queued-status P3 p3-priority)" '[$a]')" > "$cd_dir/board.json"
  before_files=$(find "$cd_dir/home/state" -type f -print | sort)
  set +e
  case "$mode" in
    noauth|scope|network) out=$(FM_FAKE_GH_MODE="$mode" run_sync "$cd_dir" "$fbx" 2>&1) ;;
    *) out=$(run_sync "$cd_dir" "$fbx" 2>&1) ;;
  esac
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$mode fail-open path exited nonzero: $out"
  [ "$before_files" = "$(find "$cd_dir/home/state" -type f -print | sort)" ] \
    || fail "$mode fail-open path touched state"
  pass "$mode fail-open path exits 0 without touching state"
done
