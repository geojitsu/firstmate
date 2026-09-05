#!/usr/bin/env bash
# Behavior tests for the opt-in Helm board sync.
#
# The fake GitHub CLI returns a project fixture and records every mutation, so
# these tests never mutate the captain's live board.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-helm-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-helm-sync)

make_fixture() {
  local case_dir="$TMP_ROOT/$1" home fakebin
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/config" "$home/data" "$home/state"
  cat >"$home/config/helm.json" <<'EOF'
{
  "owner": "geojitsu",
  "number": 2,
  "dispatch_status": "In flight"
}
EOF
  cat >"$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] queued-task - New queued title (repo: firetabs) (kind: ship) (priority: 1) (since: 2026-09-05)
  Keep the queued task body authoritative.
- [ ] captain-task - Captain dispatch title (repo: firstmate) (kind: captain) (since: 2026-09-05) (hold: Captain must choose the delivery path.) (hold-kind: captain)
## In flight
- [ ] flight-task - Newly created flight task (repo: BetterBlueToo) (kind: ship) (priority: 2) (since: 2026-09-05)
## Done
- [x] done-task - Completed task (repo: firstmate) (kind: ship) (done 2026-09-05)
EOF
  jq -n '
    {
      data:{user:{projectV2:{
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
            {id:"other-project",name:"other"}
          ]},
          {__typename:"ProjectV2SingleSelectField",id:"kind-field",name:"Kind",options:[
            {id:"ship-kind",name:"ship"},
            {id:"investigation-kind",name:"investigation"},
            {id:"decision-kind",name:"decision"}
          ]},
          {__typename:"ProjectV2SingleSelectField",id:"priority-field",name:"Priority",options:[
            {id:"p1-priority",name:"P1"},
            {id:"p2-priority",name:"P2"},
            {id:"p3-priority",name:"P3"}
          ]}
        ]},
        items:{pageInfo:{hasNextPage:false},nodes:[
          {id:"queued-item",content:{__typename:"DraftIssue",id:"queued-draft",title:"Old queued title",body:"`queued-task`\nold body"},fieldValues:{nodes:[
            {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Status"},name:"Queued",optionId:"queued-status"},
            {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Project"},name:"other",optionId:"other-project"},
            {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Kind"},name:"investigation",optionId:"investigation-kind"},
            {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Priority"},name:"P3",optionId:"p3-priority"}
          ]}},
          {id:"captain-item",content:{__typename:"DraftIssue",id:"captain-draft",title:"Captain dispatch title",body:"`captain-task`\nold body"},fieldValues:{nodes:[
            {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Status"},name:"In flight",optionId:"flight-status"},
            {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Project"},name:"firstmate",optionId:"firstmate-project"},
            {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Kind"},name:"decision",optionId:"decision-kind"},
            {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Priority"},name:"P3",optionId:"p3-priority"}
          ]}},
          {id:"gone-item",content:{__typename:"DraftIssue",id:"gone-draft",title:"Gone task",body:"`gone-task`\nold body"},fieldValues:{nodes:[
            {__typename:"ProjectV2ItemFieldSingleSelectValue",field:{name:"Status"},name:"Queued",optionId:"queued-status"}
          ]}}
        ]}
      }}}}
  ' >"$case_dir/board.json"
  cat >"$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  if [ "${FM_FAKE_GH_MODE:-}" = scope ]; then
    printf '%s\n' "Token scopes: 'repo'"
  else
    printf '%s\n' "Token scopes: 'project', 'repo'"
  fi
  exit 0
fi
if [ "${1:-}" = api ]; then
  [ "${FM_FAKE_GH_MODE:-}" != network ] || exit 1
  case "$*" in
    *addProjectV2DraftIssue*)
      printf '%s\n' '{"data":{"addProjectV2DraftIssue":{"projectItem":{"id":"created-item","content":{"id":"created-draft"}}}}}'
      ;;
    *updateProjectV2DraftIssue*)
      printf '%s\n' '{"data":{"updateProjectV2DraftIssue":{"draftIssue":{"id":"updated-draft"}}}}'
      ;;
    *updateProjectV2ItemFieldValue*)
      printf '%s\n' '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"updated-item"}}}}'
      ;;
    *)
      cat "$FM_FAKE_BOARD"
      ;;
  esac
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$case_dir"
}

run_sync() {
  local case_dir=$1 path=${2:-$PATH} arg=${3:-}
  local -a sync_args=()
  [ -z "$arg" ] || sync_args+=("$arg")
  FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_BOARD="$case_dir/board.json" \
    FM_FAKE_GH_LOG="$case_dir/gh.log" \
    PATH="$path" \
    "$SYNC" "${sync_args[@]}"
}

fixture=$(make_fixture reconcile)
fakebin="$fixture/fakebin"
: >"$fixture/gh.log"
set +e
out=$(run_sync "$fixture" "$fakebin:/bin" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "reconcile fixture exited nonzero: $out"
assert_contains "$out" "fm-helm-sync: synchronized" "successful reconcile reports completion"
[ -s "$fixture/home/state/.helm-sync-backlog.sha256" ] \
  || fail "successful reconcile did not publish the backlog hash"
grep -F $'\tcheck\thelm-dispatch:captain-task\t' "$fixture/home/state/.wake-queue" >/dev/null \
  || fail "captain board request did not produce a durable wake"
grep -F $'captain-task\tcaptain-item\tflight-status\tcaptain-item:flight-status' \
  "$fixture/home/state/.helm-dispatch-requests" >/dev/null \
  || fail "dispatch request marker was not recorded"
grep -F 'updateProjectV2DraftIssue' "$fixture/gh.log" >/dev/null \
  || fail "existing card content was not reconciled"
grep -F 'addProjectV2DraftIssue' "$fixture/gh.log" >/dev/null \
  || fail "missing task card was not created"
grep -F 'title=New queued title ' "$fixture/gh.log" >/dev/null \
  || fail "backlog metadata was not stripped from the card title"
grep -F -- '- **Filed:** 2026-09-05' "$fixture/gh.log" >/dev/null \
  || fail "backlog filing date was not parsed into the card body"
grep -F 'done-status' "$fixture/gh.log" >/dev/null \
  || fail "missing backlog task was not marked Done"
if grep -F 'deleteProjectV2Item' "$fixture/gh.log" >/dev/null \
  || grep -F 'archiveProjectV2Item' "$fixture/gh.log" >/dev/null \
  || grep -F 'fm-spawn.sh' "$fixture/gh.log" >/dev/null; then
  fail "reconcile attempted a destructive or spawn operation"
fi
pass "Helm reconcile updates cards, creates missing work, closes gone work, and queues one dispatch wake"

before=$(wc -l <"$fixture/gh.log")
run_sync "$fixture" "$fakebin:/bin" '' >/dev/null 2>&1
after=$(wc -l <"$fixture/gh.log")
[ "$before" -eq "$after" ] || fail "unchanged backlog made a network call"
pass "unchanged backlog is debounced without a GitHub call"

run_sync "$fixture" "$fakebin:/bin" --force >/dev/null 2>&1
dispatch_wakes=$(grep -F -c -- $'\tcheck\thelm-dispatch:captain-task\t' "$fixture/home/state/.wake-queue")
[ "$dispatch_wakes" -eq 1 ] || fail "forced board read duplicated an unhandled dispatch wake"
pass "forced board reads preserve dispatch idempotence"

for mode in no-config no-gh scope network; do
  case_dir=$(make_fixture "$mode")
  before_files=$(find "$case_dir/home/state" -type f -print | sort)
  case "$mode" in
    no-config)
      rm -f "$case_dir/home/config/helm.json"
      path="$case_dir/fakebin:/bin"
      ;;
    no-gh)
      path="$case_dir/fakebin:/bin"
      ;;
    scope)
      path="$case_dir/fakebin:/bin"
      ;;
    network)
      path="$case_dir/fakebin:/bin"
      ;;
  esac
  set +e
  if [ "$mode" = no-gh ]; then
    rm -f "$case_dir/fakebin/gh"
    out=$(FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$path" "$SYNC" 2>&1)
  else
    out=$(FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_BOARD="$case_dir/board.json" FM_FAKE_GH_LOG="$case_dir/gh.log" FM_FAKE_GH_MODE="$mode" PATH="$path" "$SYNC" 2>&1)
  fi
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$mode fail-open path exited nonzero: $out"
  after_files=$(find "$case_dir/home/state" -type f -print | sort)
  [ "$before_files" = "$after_files" ] || fail "$mode fail-open path touched state"
  pass "$mode fail-open path exits 0 without touching state"
done

pass "Helm sync failure posture is fail-open for absent config, missing gh, missing scope, and network errors"
