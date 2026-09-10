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
WATCH="$ROOT/bin/fm-helm-watch.sh"
POLL="$ROOT/bin/fm-helm-poll.sh"
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
      for arg in "$@"; do
        case "$arg" in
          title=*) draft_title=${arg#title=} ;;
          body=*) draft_body=${arg#body=} ;;
        esac
      done
      jq --arg title "$draft_title" --arg body "$draft_body" '
        .data.user.projectV2.items.nodes += [{
          id:"created-item",
          content:{__typename:"DraftIssue",id:"created-draft",title:$title,body:$body},
          fieldValues:{nodes:[]}
        }]' "$FM_FAKE_BOARD_STATE" > "$FM_FAKE_BOARD_STATE.next" \
        && mv "$FM_FAKE_BOARD_STATE.next" "$FM_FAKE_BOARD_STATE"
      jq -n --arg title "$draft_title" --arg body "$draft_body" '
        {data:{addProjectV2DraftIssue:{projectItem:{
          id:"created-item",
          content:{__typename:"DraftIssue",id:"created-draft",title:$title,body:$body}
        }}}}' ;;
    *updateProjectV2DraftIssue*)
      for arg in "$@"; do
        case "$arg" in
          draftIssueId=*) draft_id=${arg#draftIssueId=} ;;
          title=*) draft_title=${arg#title=} ;;
          body=*) draft_body=${arg#body=} ;;
        esac
      done
      jq --arg id "$draft_id" --arg title "$draft_title" --arg body "$draft_body" '
        .data.user.projectV2.items.nodes |= map(
          if .content.id == $id then .content.title = $title | .content.body = $body else . end)' \
        "$FM_FAKE_BOARD_STATE" > "$FM_FAKE_BOARD_STATE.next" \
        && mv "$FM_FAKE_BOARD_STATE.next" "$FM_FAKE_BOARD_STATE"
      if [ -n "${FM_FAKE_BOARD_AFTER_DRAFT:-}" ]; then
        cp "$FM_FAKE_BOARD_AFTER_DRAFT" "$FM_FAKE_BOARD_STATE"
      fi
      printf '%s\n' '{"data":{"updateProjectV2DraftIssue":{"draftIssue":{"id":"updated-draft"}}}}' ;;
    *updateProjectV2ItemFieldValue*)
      [ -z "${FM_FAKE_HELM_MUTATION_STALL:-}" ] || sleep "$FM_FAKE_HELM_MUTATION_STALL"
      for arg in "$@"; do
        case "$arg" in
          itemId=*) item_id=${arg#itemId=} ;;
          fieldId=*) field_id=${arg#fieldId=} ;;
          optionId=*) option_id=${arg#optionId=} ;;
        esac
      done
      jq --arg item "$item_id" --arg field "$field_id" --arg option "$option_id" '
        (.data.user.projectV2.fields.nodes[] | select(.id == $field)) as $definition
        | ($definition.options[] | select(.id == $option).name) as $name
        | .data.user.projectV2.items.nodes |= map(
            if .id == $item then
              .fieldValues.nodes |=
                if any(.[]?; .field.name == $definition.name) then
                  map(if .field.name == $definition.name then .name = $name | .optionId = $option else . end)
                else . + [{field:{name:$definition.name},name:$name,optionId:$option}] end
            else . end)' "$FM_FAKE_BOARD_STATE" > "$FM_FAKE_BOARD_STATE.next" \
        && mv "$FM_FAKE_BOARD_STATE.next" "$FM_FAKE_BOARD_STATE"
      printf '%s\n' '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"updated-item"}}}}' ;;
    *cursor=page-2*)
      cat "$FM_FAKE_BOARD_PAGE_2" ;;
    *fields\(first:100\)*)
      cat "$FM_FAKE_BOARD_STATE" ;;
    *node\(id:\$itemId\)*)
      item_id=$(printf '%s\n' "$*" | sed -n 's/.*itemId=\([^ ]*\).*/\1/p')
      if [ -n "${FM_FAKE_BOARD_PREWRITE:-}" ]; then
        jq --arg id "$item_id" '{data:{node:([.data.user.projectV2.items.nodes[] | select(.id == $id)][0])}}' "$FM_FAKE_BOARD_PREWRITE"
      else
        jq --arg id "$item_id" '{data:{node:([.data.user.projectV2.items.nodes[] | select(.id == $id)][0])}}' "$FM_FAKE_BOARD_STATE"
      fi ;;
    *)
      if [ -n "${FM_FAKE_BOARD_AFTER_SYNC:-}" ]; then
        cat "$FM_FAKE_BOARD_AFTER_SYNC"
      else
        cat "$FM_FAKE_BOARD"
      fi
      ;;
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
if [ "${FM_FAKE_TASKS_FAIL_PRIORITY:-}" = 1 ] && [ "${1:-}" = update ] && [ "${3:-}" = --priority ]; then
  exit 1
fi
exit 0
SH
  chmod +x "$fb/tasks-axi"
  printf '%s\n' "$fb"
}

run_sync() {  # <case-dir> <fakebin> [--force]
  local case_dir=$1 fb=$2 arg=${3:-}
  local -a a=()
  [ -z "$arg" ] || a+=("$arg")
  cp "$case_dir/board.json" "$case_dir/board-state.json"
  if [ -n "${FM_FAKE_BOARD_PAGE_2:-}" ]; then
    if jq -s '.[0] as $first | .[1] as $second
      | $first
      | .data.user.projectV2.items.nodes += $second.data.user.projectV2.items.nodes
      | .data.user.projectV2.items.pageInfo = $second.data.user.projectV2.items.pageInfo' \
      "$case_dir/board-state.json" "$FM_FAKE_BOARD_PAGE_2" > "$case_dir/board-state.json.next"; then
      mv "$case_dir/board-state.json.next" "$case_dir/board-state.json" || fail "could not stage paginated fake board state"
    else
      fail "could not stage paginated fake board state"
    fi
  fi
  FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_BOARD="$case_dir/board.json" \
    FM_FAKE_BOARD_STATE="$case_dir/board-state.json" \
    FM_FAKE_BOARD_PAGE_2="${FM_FAKE_BOARD_PAGE_2:-}" \
    FM_FAKE_GH_LOG="$case_dir/gh.log" \
    FM_FAKE_TASKS_LOG="$case_dir/tasks-axi.log" \
    FM_FAKE_GH_MODE="${FM_FAKE_GH_MODE:-}" \
    FM_FAKE_TASKS_FAIL_PRIORITY="${FM_FAKE_TASKS_FAIL_PRIORITY:-}" \
    FM_FAKE_BOARD_AFTER_SYNC="${FM_FAKE_BOARD_AFTER_SYNC:-}" \
    FM_FAKE_BOARD_PREWRITE="${FM_FAKE_BOARD_PREWRITE:-}" \
    FM_FAKE_BOARD_AFTER_DRAFT="${FM_FAKE_BOARD_AFTER_DRAFT:-}" \
    FM_FAKE_HELM_MUTATION_STALL="${FM_FAKE_HELM_MUTATION_STALL:-}" \
    PATH="$fb:$PATH" \
    "$SYNC" "${a[@]}"
}

run_poll() {  # <case-dir> <fakebin>
  local case_dir=$1 fb=$2
  cp "$case_dir/board.json" "$case_dir/board-state.json"
  FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_BOARD="$case_dir/board.json" \
    FM_FAKE_BOARD_STATE="$case_dir/board-state.json" \
    FM_FAKE_BOARD_AFTER_SYNC="${FM_FAKE_BOARD_AFTER_SYNC:-}" \
    FM_FAKE_GH_LOG="$case_dir/gh.log" \
    PATH="$fb:$PATH" \
    "$POLL"
}

run_watch() {  # <case-dir> <fakebin>
  local case_dir=$1 fb=$2
  cp "$case_dir/board.json" "$case_dir/board-state.json"
  FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_BOARD="$case_dir/board.json" \
    FM_FAKE_BOARD_STATE="$case_dir/board-state.json" \
    FM_FAKE_BOARD_PAGE_2="${FM_FAKE_BOARD_PAGE_2:-}" \
    FM_FAKE_GH_LOG="$case_dir/gh.log" \
    FM_FAKE_TASKS_LOG="$case_dir/tasks-axi.log" \
    FM_FAKE_GH_MODE="${FM_FAKE_GH_MODE:-}" \
    FM_FAKE_TASKS_FAIL_PRIORITY="${FM_FAKE_TASKS_FAIL_PRIORITY:-}" \
    PATH="$fb:$PATH" \
    "$WATCH"
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

pagination_dir="$TMP_ROOT/pagination"
mkdir -p "$pagination_dir/home/config" "$pagination_dir/home/data" "$pagination_dir/home/state"
pagination_fb=$(install_fakes "$pagination_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$pagination_dir/home/config/helm.json"
cat > "$pagination_dir/home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] page-two-task - Second page task (repo: firstmate) (kind: ship) (since: 2026-09-05)
## Done
EOF
board_json '[]' | jq '.data.user.projectV2.items.pageInfo={hasNextPage:true,endCursor:"page-2"}' > "$pagination_dir/board.json"
board_json "$(jq -n \
  --argjson a "$(draft_item page-two-item page-two-draft page-two-task 'Second page task' 'x' Queued queued-status P3 p3-priority)" \
  --argjson b "$(draft_item page-two-gone page-two-gone-draft gone-page-two 'Gone page two' 'x' Queued queued-status P3 p3-priority)" \
  '[$a,$b]')" > "$pagination_dir/page-two.json"
: > "$pagination_dir/gh.log"; : > "$pagination_dir/tasks-axi.log"
FM_FAKE_BOARD_PAGE_2="$pagination_dir/page-two.json" run_sync "$pagination_dir" "$pagination_fb" >/dev/null 2>&1 \
  || fail "paginated sync failed"
grep -F 'itemId=page-two-item' "$pagination_dir/gh.log" | grep -F 'optionId=flight-status' >/dev/null \
  || fail "a page-two task was not reconciled"
grep -F 'itemId=page-two-gone' "$pagination_dir/gh.log" | grep -F 'optionId=done-status' >/dev/null \
  || fail "a page-two missing task was not closed"
pass "sync reconciles cards from a second project page"

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
acknowledged_body=$(cat <<'EOF'

## Facts

- **Repo:** firstmate
- **Type:** ship - produces a change and a PR
- **Priority:** P3
- **Filed:** 2026-09-09

## Notes


---
_Source of truth: `data/backlog.md` in the owning firstmate home._
EOF
)
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
board_json "$(jq -n \
  --argjson a "$(draft_item keep-item keep-draft keep-task 'Keep me' 'x' Queued queued-status P3 p3-priority)" \
  --argjson b "$(draft_item del-replacement del-replacement-draft del-task 'Delete my card' 'x' Queued queued-status P3 p3-priority)" \
  '[$a,$b]')" > "$case_dir/board.json"
: > "$case_dir/tasks-axi.log"
run_sync "$case_dir" "$fb" --force >/dev/null 2>&1 || fail "recreated-card sync failed"
if grep -F 'hold del-task --kind captain' "$case_dir/tasks-axi.log" >/dev/null; then
  fail "a replacement card was misread as a deletion"
fi
if grep -F 'helm-card-deleted:del-task' "$case_dir/home/state/.wake-queue" >/dev/null; then
  fail "a replacement card raised a deletion wake"
fi
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
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] keep-task - Keep me (repo: firstmate) (kind: ship) (since: 2026-09-05)
- [ ] del-task - Delete my card (repo: firstmate) (kind: ship) (since: 2026-09-05) (hold: captain review) (hold-kind: captain)
## Done
EOF
: > "$case_dir/gh.log"
run_sync "$case_dir" "$fb" >/dev/null 2>&1 || fail "deleted-card follow-up sync failed"
if grep -F 'addProjectV2DraftIssue' "$case_dir/gh.log" >/dev/null; then
  fail "a deleted live card was recreated on the next sync"
fi
board_json "$(jq -n \
  --argjson a "$(draft_item keep-item keep-draft keep-task 'Keep me' 'x' Queued queued-status P3 p3-priority)" \
  --argjson b "$(draft_item del-restored del-restored-draft del-task 'Delete my card' 'x' Queued queued-status P3 p3-priority)" \
  '[$a,$b]')" > "$case_dir/board.json"
: > "$case_dir/tasks-axi.log"
wake_count=$(wc -l < "$case_dir/home/state/.wake-queue")
run_sync "$case_dir" "$fb" --force >/dev/null 2>&1 || fail "restored-card sync failed"
if grep -F 'hold del-task --kind captain' "$case_dir/tasks-axi.log" >/dev/null; then
  fail "a restored card left its task held"
fi
[ "$(wc -l < "$case_dir/home/state/.wake-queue")" -eq "$wake_count" ] \
  || fail "a restored card queued another deletion wake"
[ ! -e "$case_dir/home/state/helm-deleted.tsv" ] \
  || fail "a restored card did not clear its deletion tombstone"
pass "a deleted card holds its live task for the captain and is not treated as new"

held_delete_dir="$TMP_ROOT/delete-already-held"
mkdir -p "$held_delete_dir/home/config" "$held_delete_dir/home/data" "$held_delete_dir/home/state"
held_delete_fb=$(install_fakes "$held_delete_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$held_delete_dir/home/config/helm.json"
cat > "$held_delete_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] captain-held-task - Captain-held task (repo: firstmate) (kind: ship) (since: 2026-09-05) (hold: captain review) (hold-kind: captain)
## Done
EOF
board_json "$(jq -n --argjson item "$(draft_item captain-held-item captain-held-draft captain-held-task 'Captain-held task' 'x' Queued queued-status P3 p3-priority)" '[$item]')" > "$held_delete_dir/board.json"
run_sync "$held_delete_dir" "$held_delete_fb" >/dev/null 2>&1 || fail "captain-held seed run failed"
board_json '[]' > "$held_delete_dir/board.json"
: > "$held_delete_dir/gh.log"
run_sync "$held_delete_dir" "$held_delete_fb" --force >/dev/null 2>&1 || fail "captain-held deletion run failed"
[ -s "$held_delete_dir/home/state/helm-deleted.tsv" ] \
  || fail "captain-held deletion did not retain a tombstone"
: > "$held_delete_dir/gh.log"
run_sync "$held_delete_dir" "$held_delete_fb" --force >/dev/null 2>&1 || fail "captain-held follow-up sync failed"
if grep -F 'addProjectV2DraftIssue' "$held_delete_dir/gh.log" >/dev/null; then
  fail "a deleted captain-held card was recreated on the next sync"
fi
pass "a deleted captain-held card remains suppressed across syncs"

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

case_dir="$TMP_ROOT/prio-failure"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] failed-prio - Priority task (repo: firstmate) (kind: ship) (priority: 2) (since: 2026-09-05)
## Done
EOF
board_json "$(jq -n --argjson a "$(draft_item failed-prio-item failed-prio-draft failed-prio 'Priority task' 'x' Queued queued-status P4 p4-priority)" '[$a]')" > "$case_dir/board.json"
: > "$case_dir/tasks-axi.log"; : > "$case_dir/gh.log"
FM_FAKE_TASKS_FAIL_PRIORITY=1 run_sync "$case_dir" "$fb" --force >/dev/null 2>&1 \
  || fail "priority write failure must fail open"
grep -F $'\tcheck\thelm-priority:failed-prio\t' "$case_dir/home/state/.wake-queue" >/dev/null \
  || fail "a failed Priority write-back did not queue reconciliation"
[ ! -e "$case_dir/home/state/.helm-sync-backlog.sha256" ] \
  || fail "a failed Priority write-back advanced the sync debounce state"
: > "$case_dir/tasks-axi.log"
run_sync "$case_dir" "$fb" --force >/dev/null 2>&1 || fail "priority retry sync failed"
grep -F 'update failed-prio --priority 4' "$case_dir/tasks-axi.log" >/dev/null \
  || fail "a failed Priority write-back was not retried by forced reconciliation"
pass "a failed Priority write-back queues reconciliation and remains retryable"

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

case_dir="$TMP_ROOT/poll-acknowledgement"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] acknowledged-task - Acknowledged task (repo: firstmate) (kind: ship) (since: 2026-09-09)
## Done
EOF
board_json "$(jq -n --argjson a "$(draft_item ack-item ack-draft acknowledged-task 'Acknowledged task' "$acknowledged_body" Queued queued-status P3 p3-priority)" '[$a]')" > "$case_dir/board.json"
run_sync "$case_dir" "$fb" >/dev/null 2>&1 || fail "initial acknowledgement sync failed"
run_poll "$case_dir" "$fb" >/dev/null 2>&1 || fail "initial acknowledgement poll failed"
sed 's/^## Queued$/## In flight/' "$case_dir/home/data/backlog.md" > "$case_dir/home/data/backlog.md.next" \
  || fail "could not stage the in-flight backlog"
mv "$case_dir/home/data/backlog.md.next" "$case_dir/home/data/backlog.md"
board_json "$(jq -n --argjson a "$(draft_item ack-item ack-draft acknowledged-task 'Acknowledged task' "$acknowledged_body" 'In flight' flight-status P3 p3-priority)" '[$a]')" > "$case_dir/after-sync-board.json"
FM_FAKE_BOARD_AFTER_SYNC="$case_dir/after-sync-board.json" run_sync "$case_dir" "$fb" >/dev/null 2>&1 \
  || fail "backlog-driven acknowledgement sync failed"
mv "$case_dir/after-sync-board.json" "$case_dir/board.json"
out=$(run_poll "$case_dir" "$fb" 2>&1) || fail "post-sync poll failed: $out"
[ -z "$out" ] || fail "a board write caused a false captain-edit wake: $out"
pass "a backlog-driven board sync acknowledges the poll signature"

case_dir="$TMP_ROOT/prewrite-conflict"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] conflict-task - Backlog title (repo: firstmate) (kind: ship) (since: 2026-09-09)
## Done
EOF
conflict_body=$(cat <<'EOF'

## Facts

- **Repo:** firstmate
- **Type:** ship - produces a change and a PR
- **Priority:** P3
- **Filed:** 2026-09-09

## Notes


---
_Source of truth: `data/backlog.md` in the owning firstmate home._
EOF
)
board_json "$(jq -n --argjson a "$(draft_item conflict-item conflict-draft conflict-task 'Backlog title' "$conflict_body" Queued queued-status P3 p3-priority)" '[$a]')" > "$case_dir/board.json"
run_sync "$case_dir" "$fb" >/dev/null 2>&1 || fail "conflict baseline sync failed"
run_poll "$case_dir" "$fb" >/dev/null 2>&1 || fail "conflict baseline poll failed"
baseline_hash=$(cat "$case_dir/home/state/.helm-sync-backlog.sha256")
sed 's/^## Queued$/## In flight/' "$case_dir/home/data/backlog.md" > "$case_dir/home/data/backlog.md.next" \
  || fail "could not stage the conflict backlog"
mv "$case_dir/home/data/backlog.md.next" "$case_dir/home/data/backlog.md"
board_json "$(jq -n --argjson a "$(draft_item conflict-item conflict-draft conflict-task 'Captain title' "$conflict_body" Queued queued-status P3 p3-priority)" '[$a]')" > "$case_dir/board.json"
: > "$case_dir/gh.log"
out=$(run_sync "$case_dir" "$fb" 2>&1) || fail "pre-write conflict sync exited nonzero: $out"
assert_contains "$out" "Helm board and backlog both changed" \
  "a board delta since poll baseline did not request reconciliation"
if grep -F 'updateProjectV2' "$case_dir/gh.log" >/dev/null || grep -F 'addProjectV2DraftIssue' "$case_dir/gh.log" >/dev/null; then
  fail "a pre-write board conflict mutated the board"
fi
[ "$(cat "$case_dir/home/state/.helm-sync-backlog.sha256")" = "$baseline_hash" ] \
  || fail "a pre-write board conflict advanced the sync debounce state"
pass "a pre-write board conflict preserves the captain edit"

case_dir="$TMP_ROOT/late-prewrite-conflict"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] late-conflict-task - Backlog title (repo: firstmate) (kind: ship) (since: 2026-09-09)
## Done
EOF
board_json "$(jq -n --argjson a "$(draft_item late-conflict-item late-conflict-draft late-conflict-task 'Backlog title' "$conflict_body" Queued queued-status P3 p3-priority)" '[$a]')" > "$case_dir/board.json"
run_sync "$case_dir" "$fb" >/dev/null 2>&1 || fail "late conflict baseline sync failed"
run_poll "$case_dir" "$fb" >/dev/null 2>&1 || fail "late conflict baseline poll failed"
baseline_hash=$(cat "$case_dir/home/state/.helm-sync-backlog.sha256")
sed 's/Backlog title/Revised backlog title/' "$case_dir/home/data/backlog.md" > "$case_dir/home/data/backlog.md.next" \
  || fail "could not stage the late conflict backlog"
mv "$case_dir/home/data/backlog.md.next" "$case_dir/home/data/backlog.md"
board_json "$(jq -n --argjson a "$(draft_item late-conflict-item late-conflict-draft late-conflict-task 'Captain title' "$conflict_body" Queued queued-status P3 p3-priority)" '[$a]')" > "$case_dir/prewrite-board.json"
: > "$case_dir/gh.log"
out=$(FM_FAKE_BOARD_PREWRITE="$case_dir/prewrite-board.json" run_sync "$case_dir" "$fb" 2>&1) \
  || fail "late pre-write conflict sync exited nonzero: $out"
assert_contains "$out" "Helm board and backlog both changed" \
  "a late board delta did not request reconciliation"
if grep -F 'updateProjectV2DraftIssue' "$case_dir/gh.log" >/dev/null; then
  fail "a late pre-write board conflict rewrote the captain edit"
fi
[ "$(cat "$case_dir/home/state/.helm-sync-backlog.sha256")" = "$baseline_hash" ] \
  || fail "a late pre-write board conflict advanced the sync debounce state"
pass "a late pre-write board conflict preserves the captain edit"

case_dir="$TMP_ROOT/second-write-conflict"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] second-write-task - Backlog title (repo: firstmate) (kind: ship) (since: 2026-09-09)
## Done
EOF
board_json "$(jq -n --argjson a "$(draft_item second-write-item second-write-draft second-write-task 'Backlog title' "$conflict_body" Queued queued-status P3 p3-priority)" '[$a]')" > "$case_dir/board.json"
run_sync "$case_dir" "$fb" >/dev/null 2>&1 || fail "second-write baseline sync failed"
run_poll "$case_dir" "$fb" >/dev/null 2>&1 || fail "second-write baseline poll failed"
sed -e 's/Backlog title/Revised backlog title/' -e 's/^## Queued$/## In flight/' "$case_dir/home/data/backlog.md" > "$case_dir/home/data/backlog.md.next" \
  || fail "could not stage the second-write backlog"
mv "$case_dir/home/data/backlog.md.next" "$case_dir/home/data/backlog.md"
board_json "$(jq -n --argjson a "$(draft_item second-write-item second-write-draft second-write-task 'Revised backlog title' "$conflict_body" 'Waiting on you' waiting-status P3 p3-priority)" '[$a]')" > "$case_dir/after-draft-board.json"
: > "$case_dir/gh.log"
out=$(FM_FAKE_BOARD_AFTER_DRAFT="$case_dir/after-draft-board.json" run_sync "$case_dir" "$fb" 2>&1) \
  || fail "second-write conflict sync exited nonzero: $out"
assert_contains "$out" "Helm board and backlog both changed" \
  "a second-write board delta did not request reconciliation"
grep -F 'updateProjectV2DraftIssue' "$case_dir/gh.log" >/dev/null \
  || fail "the draft mutation did not precede the second-write conflict"
if grep -F 'updateProjectV2ItemFieldValue' "$case_dir/gh.log" >/dev/null; then
  fail "a second board write overwrote the captain Status"
fi
jq -e '
  .data.user.projectV2.items.nodes[]
  | select(.id == "second-write-item")
  | any(.fieldValues.nodes[]; .field.name == "Status" and .name == "Waiting on you")
' "$case_dir/board-state.json" >/dev/null \
  || fail "the stateful board did not retain the captain Status"
pass "a second board write preserves the captain Status"

case_dir="$TMP_ROOT/bounded-mutation"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] bounded-task - Bounded mutation (repo: firstmate) (kind: ship) (since: 2026-09-09)
## Done
EOF
board_json "$(jq -n --argjson a "$(draft_item bounded-item bounded-draft bounded-task 'Bounded mutation' 'x' Queued queued-status P3 p3-priority)" '[$a]')" > "$case_dir/board.json"
started=$(date +%s)
out=$(FM_FAKE_HELM_MUTATION_STALL=26 run_sync "$case_dir" "$fb" 2>&1) \
  || fail "sync with a delayed mutation exited nonzero: $out"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -le 26 ] || fail "mutation exceeded the sync deadline: ${elapsed}s"
assert_contains "$out" "could not update Helm Status" \
  "a delayed mutation did not surface a watcher diagnostic"
[ ! -e "$case_dir/home/state/.helm-sync-backlog.sha256" ] \
  || fail "a timed-out mutation advanced the sync debounce state"
pass "a delayed board mutation is bounded and remains retryable"

# ---------------------------------------------------------------------------
# Watcher adapter: successful backlog changes are applied without creating a
# wake, while a fail-open skip becomes check output for the watcher to surface.
# ---------------------------------------------------------------------------
case_dir="$TMP_ROOT/watcher-trigger"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] watcher-task - Reaches the board automatically (repo: firstmate) (kind: ship) (since: 2026-09-09)
## Done
EOF
board_json '[]' > "$case_dir/board.json"
: > "$case_dir/gh.log"; : > "$case_dir/tasks-axi.log"
out=$(run_watch "$case_dir" "$fb") || fail "watcher adapter exited nonzero: $out"
[ -z "$out" ] || fail "successful watcher sync should stay silent: $out"
grep -F 'addProjectV2DraftIssue' "$case_dir/gh.log" >/dev/null \
  || fail "a new backlog item did not reach the board through the watcher adapter"
pass "watcher adapter synchronizes a new backlog item without a wake"

FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
  PATH="$fb:$PATH" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1 \
  || fail "bootstrap could not arm the Helm watcher check"
[ -x "$case_dir/home/state/helm-sync.check.sh" ] \
  || fail "bootstrap did not install the Helm watcher check"
[ -s "$case_dir/home/state/helm-sync.check-trust" ] \
  || fail "bootstrap did not authenticate the Helm watcher check"
[ -x "$case_dir/home/state/helm-board.check.sh" ] \
  || fail "bootstrap did not install the Helm board poll check"
[ -s "$case_dir/home/state/helm-board.check-trust" ] \
  || fail "bootstrap did not authenticate the Helm board poll check"
pass "bootstrap arms the authenticated Helm watcher checks"

rm -f "$case_dir/home/config/helm.json"
override_state="$case_dir/override-state"
mkdir -p "$override_state"
mv "$case_dir/home/state/helm-sync.check.sh" "$case_dir/home/state/helm-sync.check-trust" \
  "$case_dir/home/state/helm-board.check.sh" "$case_dir/home/state/helm-board.check-trust" "$override_state/"
FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$override_state" FM_BOOTSTRAP_NETWORK=skip \
  PATH="$fb:$PATH" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1 \
  || fail "bootstrap could not retire overridden Helm watcher checks"
[ ! -e "$override_state/helm-sync.check.sh" ] && [ ! -e "$override_state/helm-sync.check-trust" ] \
  || fail "bootstrap did not retire the overridden Helm sync check"
[ ! -e "$override_state/helm-board.check.sh" ] && [ ! -e "$override_state/helm-board.check-trust" ] \
  || fail "bootstrap did not retire the overridden Helm board check"
pass "bootstrap retires Helm checks from the overridden state directory"

case_dir="$TMP_ROOT/watcher-diagnostic"
mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
fb=$(install_fakes "$case_dir")
printf '{"owner":"geojitsu","number":2}\n' > "$case_dir/home/config/helm.json"
cat > "$case_dir/home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] unsupported-task - Must not disappear (repo: unrecognised-project) (kind: ship) (since: 2026-09-09)
## Done
EOF
board_json '[]' > "$case_dir/board.json"
: > "$case_dir/gh.log"; : > "$case_dir/tasks-axi.log"
out=$(run_watch "$case_dir" "$fb") || fail "diagnostic watcher adapter exited nonzero: $out"
assert_contains "$out" "unsupported repository unrecognised-project for unsupported-task; using other" \
  "an unsupported backlog project did not emit its fallback diagnostic"
grep -F 'optionId=other-project' "$case_dir/gh.log" >/dev/null \
  || fail "an unsupported backlog project was not synced into the other bucket"
pass "watcher adapter retains unsupported projects in the other bucket"

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
